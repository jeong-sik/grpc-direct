(** Multi-domain gRPC Server using OCaml 5 Domains.

    Spawns multiple domains (OS threads), each with its own Eio scheduler,
    listening on the same port via SO_REUSEPORT. The kernel load-balances
    connections across domains.

    {b Architecture:}
    {v
    ┌─────────────────────────────────────────────────────────────────┐
    │                         Kernel (SO_REUSEPORT)                   │
    │                      Load-balances across domains               │
    └─────────────────────────────────────────────────────────────────┘
                ↓                    ↓                    ↓
    ┌───────────────────┐ ┌───────────────────┐ ┌───────────────────┐
    │  Domain 0 (Main)  │ │     Domain 1      │ │     Domain 2      │
    │  ┌─────────────┐  │ │  ┌─────────────┐  │ │  ┌─────────────┐  │
    │  │ Eio Sched   │  │ │  │ Eio Sched   │  │ │  │ Eio Sched   │  │
    │  │ ┌─────────┐ │  │ │  │ ┌─────────┐ │  │ │  │ ┌─────────┐ │  │
    │  │ │ Server  │ │  │ │  │ │ Server  │ │  │ │  │ │ Server  │ │  │
    │  │ └─────────┘ │  │ │  │ └─────────┘ │  │ │  │ └─────────┘ │  │
    │  └─────────────┘  │ │  └─────────────┘  │ │  └─────────────┘  │
    └───────────────────┘ └───────────────────┘ └───────────────────┘
    v}

    {b Usage:}
    {[
      let server = Server.create ()
        |> Server.add_service greeter
      in
      (* Use all available cores *)
      Server_multi.serve_multi ~domains:0 ~env server
    ]}

    {b Performance Notes:}
    - Each domain has independent GC, reducing stop-the-world pauses
    - SO_REUSEPORT provides fair distribution with minimal lock contention
    - Optimal domain count is typically num_cpus - 1 (leaving one for OS)
*)

(** Shared shutdown flag using Atomic for thread safety *)
let global_shutdown = Atomic.make false

(** Serve with multiple domains.

    @param domains Number of worker domains to spawn.
                   0 = auto-detect (num_cpus - 1, minimum 1)
    @param env Eio environment (only used in main domain)
    @param server The configured gRPC server *)
let serve_multi ?(domains = 0) ~env (server : Server.t) : unit =
  let num_domains =
    if domains > 0 then domains
    else max 1 (Domain.recommended_domain_count () - 1)
  in

  Eio.traceln "🚀 Starting multi-domain gRPC server with %d domains" num_domains;

  (* Reset shutdown flag *)
  Atomic.set global_shutdown false;

  (* Extract config that can be shared across domains *)
  let config = Server.config server in
  let services_list =
    Hashtbl.fold (fun _ service acc -> service :: acc) (Server.services server) []
  in
  let interceptors = Server.interceptors server in

  (* Worker domain function - creates its own Eio environment *)
  let domain_worker domain_id () =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->

    (* Recreate server state in this domain (avoid sharing mutable state) *)
    let local_server = Server.create ~config () in
    List.iter (fun service ->
      ignore (Server.add_service service local_server)
    ) services_list;
    let local_server =
      List.fold_left (fun s i -> Server.with_interceptor i s)
        local_server interceptors
    in
    Server.set_running local_server true;

    Eio.traceln "  Domain %d: Listening on port %d" domain_id config.port;

    (* Each domain binds to the same port with SO_REUSEPORT *)
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, config.port) in

    let socket = Eio.Net.listen net ~sw ~backlog:128 ~reuse_addr:true ~reuse_port:true addr in
    let h2_handler = H2_eio.Server.create_connection_handler
        ~request_handler:(fun _ -> Server.request_handler ~sw ~clock local_server)
        ~error_handler:Server.error_handler
    in

    (* Handle TLS if configured *)
    let tls_server_config = match config.tls with
      | Some tls ->
          (* Each domain needs its own TLS config *)
          let tls_config = Tls_config.load tls in
          Some tls_config
      | None -> None
    in

    let handle_connection sock addr =
      match tls_server_config with
      | Some tls_config ->
          let tls_flow = Tls_eio.server_of_flow tls_config sock in
          Flow_handler.create_server_handler
            ~request_handler:(fun _ -> Server.request_handler ~sw ~clock local_server)
            ~error_handler:Server.error_handler
            ~sw
            addr
            tls_flow
      | None ->
          h2_handler ~sw addr sock
    in

    while Server.running local_server && not (Atomic.get global_shutdown) do
      Eio.Net.accept_fork socket ~sw
        ~on_error:(fun exn -> Eio.traceln "Domain %d error: %s" domain_id (Printexc.to_string exn))
        handle_connection
    done;
    Eio.traceln "  Domain %d: Stopped" domain_id
  in

  (* Spawn worker domains (1 to N-1) *)
  let worker_domains =
    List.init (num_domains - 1) (fun i ->
      Eio.traceln "  Spawning domain %d..." (i + 1);
      Domain.spawn (domain_worker (i + 1))
    )
  in

  (* Main domain (domain 0) also serves *)
  Eio.Switch.run @@ fun sw ->
  begin
    (* Mark as running before starting to serve *)
    Server.set_running server true;

    Eio.traceln "  Domain 0: Listening on port %d (main)" config.port;

    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, config.port) in

    let socket = Eio.Net.listen net ~sw ~backlog:128 ~reuse_addr:true ~reuse_port:true addr in
    let h2_handler = H2_eio.Server.create_connection_handler
        ~request_handler:(fun _ -> Server.request_handler ~sw ~clock server)
        ~error_handler:Server.error_handler
    in

    let tls_server_config = match config.tls with
      | Some tls ->
          let tls_config = Tls_config.load tls in
          Some tls_config
      | None -> None
    in

    let handle_connection sock addr =
      match tls_server_config with
      | Some tls_config ->
          let tls_flow = Tls_eio.server_of_flow tls_config sock in
          Flow_handler.create_server_handler
            ~request_handler:(fun _ -> Server.request_handler ~sw ~clock server)
            ~error_handler:Server.error_handler
            ~sw
            addr
            tls_flow
      | None ->
          h2_handler ~sw addr sock
    in

    while Server.running server && not (Atomic.get global_shutdown) do
      Eio.Net.accept_fork socket ~sw
        ~on_error:(fun exn -> Eio.traceln "Domain 0 error: %s" (Printexc.to_string exn))
        handle_connection
    done;
    Eio.traceln "  Domain 0: Stopped (main)"
  end;

  (* Wait for all worker domains to finish *)
  List.iter Domain.join worker_domains;
  Eio.traceln "All domains stopped"


(** Shutdown all domains gracefully.

    Sets the global shutdown flag which all domains check.
    Also shuts down the main server instance. *)
let shutdown (server : Server.t) : unit =
  Eio.traceln "Shutting down multi-domain gRPC server...";
  Atomic.set global_shutdown true;
  Server.shutdown server
