let src = Logs.Src.create "bob.unix"
module Log = (val Logs.src_log src : Logs.LOG)

open Fiber

let rec full_write fd str ~off ~len =
  Fiber.write fd str ~off ~len >>= function
  | Error _ as err -> Fiber.return err
  | Ok len' ->
    if len - len' > 0 then full_write fd str ~off:(off + len') ~len:(len - len')
    else Fiber.return (Ok ())

type error =
  [ `Connection_closed_by_relay
  | `Write of [ `Closed | `Unix of Unix.error ]
  | Bob.Protocol.error ]

let pp_error ppf = function
  | `Connection_closed_by_relay -> Fmt.string ppf "Connection closed by relay"
  | `Write `Closed -> Fmt.pf ppf "Connection closed"
  | `Write (`Unix err) -> Fmt.pf ppf "write(): %s" (Unix.error_message err)
  | #Bob.Protocol.error as err -> Bob.Protocol.pp_error ppf err

let map_read = function
  | `Data str -> `Read (`Data (str, 0, String.length str))
  | `End -> `Read `End

type outcome =
  [ `Error of error
  | `Done
  | `Write of string
  | `Continue ]

type income =
  [ `Read of [ `Data of (string * int * int) | `End ]
  | `Error of error ]

let pp_data ppf = function
  | `End -> Fmt.pf ppf "<end>"
  | `Data (str, off, len) ->
    Fmt.pf ppf "@[<hov>%a@]" (Hxd_string.pp Hxd.default)
      (String.sub str off len)

let run ~choose ~agreement ~receive ~send socket t =
  let handshake_is_done : [ `Done ] Fiber.Ivar.t = Fiber.Ivar.create () in
  let errored : [ `Error of error ] Fiber.Ivar.t = Fiber.Ivar.create () in
  let rec read () =
    Fiber.npick
      [ begin fun () -> Fiber.read socket >>| map_read end
      ; begin fun () -> Fiber.wait errored >>| fun v ->
                        (v :> income) end ]
    >>= function
    | `Error err ->
      Log.err (fun m -> m "Got a global error: %a" pp_error err) ;
      Fiber.return (Error err)
    | `Read data ->
      Log.debug (fun m -> m "recv <- %a" pp_data data) ;
      match receive t data with
      | `Continue | `Read -> Fiber.pause () >>= read
      | `Agreement identity -> choose identity >>= fun v ->
        agreement t v ; Fiber.pause () >>= read
      | `Done shared_keys ->
        Fiber.Ivar.fill handshake_is_done `Done ;
        Log.debug (fun m -> m "Finish the read fiber.") ;
        Fiber.close socket >>= fun () -> Fiber.return (Ok shared_keys)
      | `Close ->
        Log.err (fun m -> m "The relay closed the connection.") ;
        Fiber.Ivar.fill errored (`Error `Connection_closed_by_relay) ;
        Fiber.return (Error `Connection_closed_by_relay)
      | `Error (#Bob.Protocol.error as err) ->
        Log.err (fun m -> m "Got a recv error: %a" Bob.Protocol.pp_error err) ;
        Fiber.Ivar.fill errored (`Error (err :> error)) ;
        Fiber.return (Error err) in
  let rec write () =
    let send () = Fiber.return (send t) in
    Fiber.npick
      [ begin fun () -> Fiber.wait handshake_is_done >>| fun v ->
                        (v :> outcome) end
      ; begin fun () -> Fiber.wait errored >>| fun v ->
                        (v :> outcome) end
      ; begin fun () -> send () >>| fun v ->
                        (v :> outcome) end ] >>= function
    | `Done ->
      Log.debug (fun m -> m "Finish the write fiber.") ;
      Fiber.return (Ok ())
    | `Continue -> Fiber.pause () >>= write
    | `Error err ->
      Log.err (fun m -> m "Got an error: %a" pp_error err) ;
      if Fiber.Ivar.is_empty errored
      then Fiber.Ivar.fill errored (`Error (err :> error)) ;
      Fiber.return (Error err)
    | `Write str ->
      Log.debug (fun m -> m "send -> @[<hov>%a@]"
        (Hxd_string.pp Hxd.default) str) ;
      full_write socket str ~off:0 ~len:(String.length str) >>= function
      | Ok () -> Fiber.pause () >>= write
      | Error `Closed ->
        (* XXX(dinosaure): according to our protocol, only the relay is able
           to close the connection. *)
        if not (Fiber.Ivar.is_empty handshake_is_done)
        then Fiber.return (Ok ())
        else ( if Fiber.Ivar.is_empty errored
               then Fiber.Ivar.fill errored (`Error (`Write `Closed))
             ; Fiber.return (Error (`Write `Closed)) )
      | Error (`Unix err) ->
        Log.err (fun m -> m "Got a write error: %s" (Unix.error_message err)) ;
        if Fiber.Ivar.is_empty errored
        then Fiber.Ivar.fill errored (`Error (`Write (`Unix err))) ;
        Fiber.return (Error (`Write (`Unix err))) in
  Fiber.fork_and_join write read >>= function
  | Ok (), Ok shared_keys ->
    Log.debug (fun m -> m "The peer finished correctly.") ;
    Fiber.return (Ok shared_keys)
  | Error err, _ -> Fiber.return (Error err)
  | _, Error err -> Fiber.return (Error err)

let server socket ~g ~secret =
  let t = Bob.Server.hello ~g ~secret in
  let choose _ = assert false in
  let agreement _ = assert false in
  run ~choose ~agreement
    ~receive:Bob.Server.receive ~send:Bob.Server.send socket t

let client socket ~choose ~g ~password =
  let identity = Unix.gethostname () in
  let t = Bob.Client.make ~g ~password ~identity in
  run ~choose ~agreement:Bob.Client.agreement
    ~receive:Bob.Client.receive ~send:Bob.Client.send socket t

let pp_sockaddr ppf = function
  | Unix.ADDR_UNIX str -> Fmt.pf ppf "<%s>" str
  | Unix.ADDR_INET (inet_addr, port) ->
    Fmt.pf ppf "%s:%d" (Unix.string_of_inet_addr inet_addr) port

let serve_when_ready ?stop ~handler socket =
  let stop = match stop with
    | Some stop -> stop
    | None -> Fiber.Ivar.create () in
  let rec loop () =
    Fiber.pick
      begin fun () -> Fiber.wait stop >>| fun () -> `Stop end
      begin fun () -> Fiber.accept socket >>| fun v -> `Accept v end
    >>= function
    | `Stop -> Fiber.return ()
    | `Accept (fd, sockaddr) ->
      Log.debug (fun m -> m "Got a new connection from %a."
        pp_sockaddr sockaddr) ;
      let _ = Fiber.async begin fun () -> handler fd sockaddr end in
      Fiber.pause () >>= loop in
  loop ()

let relay ?(timeout= 5.) socket ~stop =
  let t = Bob.Relay.make () in
  let fds = Hashtbl.create 0x100 in
  let rec write () =
    let send_to () = Fiber.return (Bob.Relay.send_to t) in
    Fiber.npick
      [ begin fun () -> Fiber.wait stop >>| fun () -> `Stop end
      ; send_to ]
    >>= function
    | `Stop     -> Fiber.return ()
    | `Continue -> Fiber.pause () >>= write
    | `Close identity ->
      Log.debug (fun m -> m "Close %s" identity) ;
      ( match Hashtbl.find_opt fds identity with
      | Some (fd, _) ->
        Hashtbl.remove fds identity ;
        Fiber.close fd
      | None -> Fiber.return () ) >>= write
    | `Write (identity, str) ->
      ( match Hashtbl.find_opt fds identity with
      | None ->
        Log.err (fun m -> m "%s does not exists as an active peer."
          identity) ; write ()
      | Some (fd, _) ->
        Log.debug (fun m -> m "to   [%20s] <- @[<hov>%a@]"
          identity (Hxd_string.pp Hxd.default) str) ;
        full_write fd str ~off:0 ~len:(String.length str) >>= function
        | Ok v -> Fiber.return v
        | Error _err ->
          Hashtbl.remove fds identity ;
          Fiber.close fd ) >>= write in
  let rec read () =
    Fiber.npick [ begin fun () -> Fiber.wait stop >>| fun () -> `Stop end
                ; begin fun () -> Fiber.return `Continue end ] >>= function
    | `Stop -> Fiber.return ()
    | `Continue ->
      Hashtbl.filter_map_inplace begin fun identity (fd, ivar) ->
      match Fiber.Ivar.get ivar with
      | None -> Some (fd, ivar)
      | Some `Delete -> Log.debug (fun m -> m "Delete %s from the reader" identity) ; None
      | Some `Continue ->
        let ivar = Fiber.detach begin fun () ->
          match Hashtbl.mem fds identity with
          | false -> Fiber.return `Delete
          | true  ->
          Fiber.read fd >>| map_read >>= function
          | `Read `End -> Fiber.return `Delete
          | `Read (`Data _ as data) ->
            Log.debug (fun m -> m "from [%20s] -> %a" identity pp_data data) ;
            match Bob.Relay.receive_from t ~identity data with
            | `Close -> Fiber.return `Delete
            | `Agreement _ | `Read | `Continue -> Fiber.return `Continue end in
        Some (fd, ivar) end fds ; 
      Fiber.pause () >>= read in
  let handler fd sockaddr =
    Log.debug (fun m -> m "Current state: %a" Bob.Relay.pp t) ;
    let identity = Fmt.str "%a" pp_sockaddr sockaddr in
    Log.debug (fun m -> m "Add %s as an active connection." identity) ;
    Hashtbl.add fds identity (fd, Fiber.Ivar.full `Continue) ;
    Bob.Relay.new_peer t ~identity ;

    (* XXX(dinosaure): handle timeout. *)
    Fiber.async begin fun () -> Fiber.sleep timeout >>= fun () ->
    if Bob.Relay.exists t ~identity
    then ( Log.warn (fun m -> m "%s timeout" identity)
         ; Bob.Relay.rem_peer t ~identity ) ;
    Fiber.return () end ;

    Fiber.return () in
  fork_and_join
    begin fun () -> serve_when_ready ~stop ~handler socket end
    begin fun () -> fork_and_join read write >>= fun ((), ()) ->
          Fiber.return () end
  >>= fun ((), ()) -> Fiber.return ()
