module Transport :
  Dns_client.S
    with type io_addr =
      [ `Plaintext of Ipaddr.t * int
      | `Tls of Tls.Config.client * Ipaddr.t * int ]
     and type +'a io = 'a Fiber.t
     and type stack = unit

include module type of Dns_client.Make (Transport)
