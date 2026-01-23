(** gRPC Server Reflection v1 implementation.

    Implements the gRPC Server Reflection protocol for service discovery.
    This allows tools like grpcurl to discover available services and methods
    without needing proto files.

    Usage:
    {[
      (* Option 1: Create server with reflection enabled *)
      let server = Reflection.create_server_with_reflection ()
        |> Server.add_service my_service
      in
      Server.serve ~sw ~env server

      (* Option 2: Add reflection to existing server *)
      let server_ref = ref server in
      let server = Server.add_service (Reflection.to_service server_ref) server in
      server_ref := server
    ]}

    Supported operations:
    - ListServices: Returns all registered service names
    - FileContainingSymbol: Returns service info for a symbol

    Limitations:
    - No FileDescriptor support (would require proto file registration)
    - Method introspection returns empty list *)

(** Service info returned by reflection queries *)
type service_info =
  { name : string
  ; methods : string list
  }

(** Create the ServerReflection service.

    Note: Uses a ref to break circular dependency with server.
    The server must be updated after adding the reflection service.

    @param server_ref Reference to the server *)
val to_service : Server.t ref -> Service.t

(** Create a new server with reflection pre-enabled.

    This is the recommended way to enable reflection:
    {[
      let server = Reflection.create_server_with_reflection ()
        |> Server.add_service my_service
    ]} *)
val create_server_with_reflection : ?config:Server.config -> unit -> Server.t

(** Check if a server has reflection enabled *)
val is_enabled : Server.t -> bool

(** Reflection service name constant *)
val service_name : string
