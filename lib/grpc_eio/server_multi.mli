(** Multi-domain gRPC Server using OCaml 5 Domains.

    This module provides a multi-core gRPC server that leverages OCaml 5's
    domain API for true parallelism. Each domain runs its own Eio scheduler
    and listens on the same port via SO_REUSEPORT, with the kernel providing
    load balancing.

    {b Key Benefits:}
    - True parallel request processing across CPU cores
    - Independent GC per domain (reduced stop-the-world pauses)
    - Linear scalability up to CPU core count
    - Graceful shutdown across all domains

    {b Architecture:}
    {v
    Client Requests
          │
          ▼
    ┌─────────────────────────────────────┐
    │    Kernel (SO_REUSEPORT LB)         │
    └─────────────────────────────────────┘
          │         │         │
          ▼         ▼         ▼
    ┌─────────┐ ┌─────────┐ ┌─────────┐
    │Domain 0 │ │Domain 1 │ │Domain 2 │
    │  (Main) │ │(Worker) │ │(Worker) │
    │ [Eio]   │ │ [Eio]   │ │ [Eio]   │
    │ ┌─────┐ │ │ ┌─────┐ │ │ ┌─────┐ │
    │ │ RPC │ │ │ │ RPC │ │ │ │ RPC │ │
    │ └─────┘ │ │ └─────┘ │ │ └─────┘ │
    └─────────┘ └─────────┘ └─────────┘
    v}

    {b Example:}
    {[
      let () = Eio_main.run @@ fun env ->
        let server = Server.create ()
          |> Server.add_service echo_service
          |> Server.with_interceptor logging
        in
        (* Auto-detect optimal domain count *)
        Server_multi.serve_multi ~domains:0 ~env server
    ]}

    {b Performance Tuning:}
    - [domains=0]: Auto-detect (recommended_domain_count - 1)
    - [domains=N]: Use exactly N domains
    - Optimal: num_cpus - 1 (leave one for OS/interrupts)

    @see <https://github.com/ocaml-multicore/eio/blob/main/doc/multicore.md> Eio Multicore Guide
    @see <https://v5.ocaml.org/manual/parallelism.html> OCaml 5 Parallelism Manual *)

(** {1 Multi-domain Server} *)

(** Serve with multiple domains.

    Spawns [domains - 1] worker domains plus uses the main domain for serving.
    Each domain binds to the same port using SO_REUSEPORT for kernel-level
    load balancing.

    {b Thread Safety:}
    - Server config is cloned to each domain (no sharing)
    - Services are copied (registered at startup)
    - Interceptors are shared (must be stateless or thread-safe)
    - Shutdown uses atomic flag for cross-domain coordination

    @param domains Number of domains (0 = auto-detect)
    @param env Eio environment (main domain)
    @param server Configured gRPC server

    @raise Invalid_argument if domains < 0 *)
val serve_multi :
  ?domains:int ->
  env:Eio_unix.Stdenv.base ->
  Server.t ->
  unit

(** Shutdown all domains gracefully.

    Sets a global atomic flag that all domains check in their accept loop.
    Blocks until all worker domains have joined.

    @param server Main server instance to shutdown *)
val shutdown : Server.t -> unit
