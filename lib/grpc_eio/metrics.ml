(** gRPC Metrics collection and exposition.

    Provides metrics collection for gRPC calls including:
    - Call counts (by method, status code)
    - Latency histograms
    - Active call gauges
    - Message sizes

    {b Thread Safety:}
    - Single-domain safe: Yes (cooperative scheduling)
    - Multi-domain safe: {b No} - uses mutable fields without synchronization
    - For multi-domain: Migrate Counter/Gauge to [Atomic.t]

    @see {{: https://github.com/ocaml-multicore/eio/blob/main/doc/multicore.md } Eio Multicore Guide}

    Usage:
    {[
      let metrics = Metrics.create () in
      let server = Server.create ()
        |> Server.with_metrics metrics
      in
      (* Expose metrics *)
      Metrics.to_prometheus metrics |> print_endline
    ]} *)

(** Counter for simple incrementing values *)
module Counter = struct
  type t = {
    mutable value : int;
  }

  let create () : t = { value = 0 }
  let inc (c : t) : unit = c.value <- c.value + 1
  let inc_by (c : t) (n : int) : unit = c.value <- c.value + n
  let get (c : t) : int = c.value
  let reset (c : t) : unit = c.value <- 0
end

(** Gauge for values that can go up and down *)
module Gauge = struct
  type t = {
    mutable value : float;
  }

  let create () : t = { value = 0.0 }
  let set (g : t) (v : float) : unit = g.value <- v
  let inc (g : t) : unit = g.value <- g.value +. 1.0
  let dec (g : t) : unit = g.value <- g.value -. 1.0
  let get (g : t) : float = g.value
end

(** Histogram for latency distribution *)
module Histogram = struct
  (* Default buckets in seconds: 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, 10s *)
  let default_buckets = [| 0.005; 0.01; 0.025; 0.05; 0.1; 0.25; 0.5; 1.0; 2.5; 5.0; 10.0 |]

  type t = {
    buckets : float array;
    counts : int array;  (* count per bucket *)
    mutable sum : float;
    mutable count : int;
  }

  let create ?(buckets = default_buckets) () : t = {
    buckets;
    counts = Array.make (Array.length buckets + 1) 0;  (* +1 for +Inf *)
    sum = 0.0;
    count = 0;
  }

  let observe (h : t) (value : float) : unit =
    h.sum <- h.sum +. value;
    h.count <- h.count + 1;
    (* Increment appropriate bucket *)
    let rec find_bucket i =
      if i >= Array.length h.buckets then
        Array.length h.buckets  (* +Inf bucket *)
      else if value <= h.buckets.(i) then i
      else find_bucket (i + 1)
    in
    let bucket_idx = find_bucket 0 in
    (* Increment this and all higher buckets (cumulative) *)
    for i = bucket_idx to Array.length h.counts - 1 do
      h.counts.(i) <- h.counts.(i) + 1
    done

  let get_count (h : t) : int = h.count
  let get_sum (h : t) : float = h.sum
  let get_buckets (h : t) : (float * int) list =
    List.mapi (fun i bound ->
      (bound, h.counts.(i))
    ) (Array.to_list h.buckets)
    @ [(Float.infinity, h.counts.(Array.length h.counts - 1))]

  let reset (h : t) : unit =
    h.sum <- 0.0;
    h.count <- 0;
    Array.fill h.counts 0 (Array.length h.counts) 0
end

(** Per-method metrics *)
type method_metrics = {
  calls_total : Counter.t;
  calls_failed : Counter.t;
  latency : Histogram.t;
  active_calls : Gauge.t;
  request_bytes : Histogram.t;
  response_bytes : Histogram.t;
}

let create_method_metrics () : method_metrics = {
  calls_total = Counter.create ();
  calls_failed = Counter.create ();
  latency = Histogram.create ();
  active_calls = Gauge.create ();
  request_bytes = Histogram.create ~buckets:[| 100.0; 1000.0; 10000.0; 100000.0; 1000000.0 |] ();
  response_bytes = Histogram.create ~buckets:[| 100.0; 1000.0; 10000.0; 100000.0; 1000000.0 |] ();
}

(** Metrics registry *)
type t = {
  methods : (string, method_metrics) Hashtbl.t;
  mutable total_calls : int;
  mutable total_errors : int;
  start_time : float;
}

(** Create a new metrics registry *)
let create () : t = {
  methods = Hashtbl.create 32;
  total_calls = 0;
  total_errors = 0;
  start_time = Unix.gettimeofday ();
}

(** Get or create metrics for a method *)
let get_method (m : t) ~(method_ : string) : method_metrics =
  match Hashtbl.find_opt m.methods method_ with
  | Some mm -> mm
  | None ->
      let mm = create_method_metrics () in
      Hashtbl.replace m.methods method_ mm;
      mm

(** Record a call start *)
let record_call_start (m : t) ~(method_ : string) : unit =
  let mm = get_method m ~method_ in
  m.total_calls <- m.total_calls + 1;
  Counter.inc mm.calls_total;
  Gauge.inc mm.active_calls

(** Record a call end *)
let record_call_end (m : t) ~(method_ : string) ~(latency_sec : float) ~(success : bool)
    ?(request_size : int option) ?(response_size : int option) () : unit =
  let mm = get_method m ~method_ in
  Gauge.dec mm.active_calls;
  Histogram.observe mm.latency latency_sec;
  if not success then begin
    m.total_errors <- m.total_errors + 1;
    Counter.inc mm.calls_failed
  end;
  (match request_size with
   | Some s -> Histogram.observe mm.request_bytes (float_of_int s)
   | None -> ());
  (match response_size with
   | Some s -> Histogram.observe mm.response_bytes (float_of_int s)
   | None -> ())

(** Server-side metrics interceptor *)
let server_interceptor (m : t) : string Interceptor.t =
  Interceptor.make ~name:"metrics" (fun ctx next ->
    let method_ = ctx.Interceptor.method_ in
    record_call_start m ~method_;
    let start = Unix.gettimeofday () in
    try
      let result = next ctx in
      let elapsed = Unix.gettimeofday () -. start in
      record_call_end m ~method_ ~latency_sec:elapsed ~success:true ();
      result
    with exn ->
      let elapsed = Unix.gettimeofday () -. start in
      record_call_end m ~method_ ~latency_sec:elapsed ~success:false ();
      raise exn
  )

(** Client-side metrics interceptor *)
let client_interceptor (m : t) : string Interceptor.t =
  server_interceptor m  (* Same implementation for now *)

(** Get uptime in seconds *)
let uptime (m : t) : float =
  Unix.gettimeofday () -. m.start_time

(** Get total call count *)
let total_calls (m : t) : int = m.total_calls

(** Get total error count *)
let total_errors (m : t) : int = m.total_errors

(** Get error rate (0.0 to 1.0) *)
let error_rate (m : t) : float =
  if m.total_calls = 0 then 0.0
  else float_of_int m.total_errors /. float_of_int m.total_calls

(** Export metrics in Prometheus text format *)
let to_prometheus (m : t) : string =
  let buf = Buffer.create 4096 in
  let add = Buffer.add_string buf in
  let add_histogram_series ~name ~method_ (hist : Histogram.t) =
    let method_label = Printf.sprintf "method=\"%s\"" method_ in
    List.iter (fun (le, count) ->
      let le_str = if Float.is_infinite le then "+Inf" else Printf.sprintf "%.3f" le in
      add (Printf.sprintf "%s_bucket{%s,le=\"%s\"} %d\n" name method_label le_str count)
    ) (Histogram.get_buckets hist);
    add (Printf.sprintf "%s_sum{%s} %.6f\n" name method_label (Histogram.get_sum hist));
    add (Printf.sprintf "%s_count{%s} %d\n" name method_label (Histogram.get_count hist))
  in

  (* Uptime *)
  add "# HELP grpc_server_uptime_seconds Server uptime in seconds\n";
  add "# TYPE grpc_server_uptime_seconds gauge\n";
  add (Printf.sprintf "grpc_server_uptime_seconds %.3f\n\n" (uptime m));

  (* Total calls *)
  add "# HELP grpc_server_calls_total Total number of gRPC calls\n";
  add "# TYPE grpc_server_calls_total counter\n";
  add (Printf.sprintf "grpc_server_calls_total %d\n" m.total_calls);
  Hashtbl.iter (fun method_ mm ->
    add (Printf.sprintf "grpc_server_calls_total{method=\"%s\"} %d\n"
           method_ (Counter.get mm.calls_total))
  ) m.methods;
  add "\n";

  (* Total errors *)
  add "# HELP grpc_server_calls_failed_total Total number of failed gRPC calls\n";
  add "# TYPE grpc_server_calls_failed_total counter\n";
  add (Printf.sprintf "grpc_server_calls_failed_total %d\n" m.total_errors);
  Hashtbl.iter (fun method_ mm ->
    add (Printf.sprintf "grpc_server_calls_failed_total{method=\"%s\"} %d\n"
           method_ (Counter.get mm.calls_failed))
  ) m.methods;
  add "\n";

  (* Active calls *)
  add "# HELP grpc_server_active_calls Active gRPC calls\n";
  add "# TYPE grpc_server_active_calls gauge\n";
  Hashtbl.iter (fun method_ mm ->
    add (Printf.sprintf "grpc_server_active_calls{method=\"%s\"} %.0f\n"
           method_ (Gauge.get mm.active_calls))
  ) m.methods;
  add "\n";

  (* Per-method latency *)
  add "# HELP grpc_server_call_duration_seconds Duration of gRPC calls\n";
  add "# TYPE grpc_server_call_duration_seconds histogram\n";
  Hashtbl.iter (fun method_ mm ->
    add_histogram_series ~name:"grpc_server_call_duration_seconds" ~method_ mm.latency
  ) m.methods;
  add "\n";

  (* Request sizes *)
  add "# HELP grpc_server_request_bytes Request message size in bytes\n";
  add "# TYPE grpc_server_request_bytes histogram\n";
  Hashtbl.iter (fun method_ mm ->
    add_histogram_series ~name:"grpc_server_request_bytes" ~method_ mm.request_bytes
  ) m.methods;
  add "\n";

  (* Response sizes *)
  add "# HELP grpc_server_response_bytes Response message size in bytes\n";
  add "# TYPE grpc_server_response_bytes histogram\n";
  Hashtbl.iter (fun method_ mm ->
    add_histogram_series ~name:"grpc_server_response_bytes" ~method_ mm.response_bytes
  ) m.methods;
  add "\n";

  Buffer.contents buf

(** Minimal Prometheus /metrics server (HTTP/1.1). *)
let serve_prometheus ?(addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 9464))
    ?(path = "/metrics") ~sw ~env (m : t) : unit =
  let net = Eio.Stdenv.net env in
  let respond flow ~status ~body =
    let headers =
      Printf.sprintf
        "HTTP/1.1 %s\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
        status
        (String.length body)
    in
    let payload = headers ^ body in
    Eio.Flow.write flow [Cstruct.of_string payload]
  in
  let handle_connection flow _addr =
    let reader = Eio.Buf_read.of_flow ~max_size:4096 flow in
    let line_opt =
      try Some (Eio.Buf_read.line reader) with
      | End_of_file -> None
      | _ -> Some ""
    in
    match line_opt with
    | None -> ()
    | Some line ->
        let line = String.trim line in
        let line = if String.ends_with ~suffix:"\r" line then String.sub line 0 (String.length line - 1) else line in
        (match String.split_on_char ' ' line with
         | method_ :: path_ :: _ when method_ = "GET" && path_ = path ->
             respond flow ~status:"200 OK" ~body:(to_prometheus m)
         | method_ :: _ when method_ = "GET" ->
             respond flow ~status:"404 Not Found" ~body:"not found\n"
         | _ ->
             respond flow ~status:"400 Bad Request" ~body:"bad request\n")
  in
  let socket = Eio.Net.listen net ~sw ~backlog:128 ~reuse_addr:true addr in
  while true do
    Eio.Net.accept_fork socket ~sw
      ~on_error:(fun exn ->
        Eio.traceln "Metrics connection error: %s" (Printexc.to_string exn))
      handle_connection
  done

(** Print metrics summary to a log function *)
let log_summary ?(log = print_endline) (m : t) : unit =
  log (Printf.sprintf "gRPC Metrics Summary (uptime: %.1fs)" (uptime m));
  log (Printf.sprintf "  Total calls: %d" m.total_calls);
  log (Printf.sprintf "  Total errors: %d (%.2f%%)" m.total_errors (error_rate m *. 100.0));
  Hashtbl.iter (fun method_ mm ->
    let avg_latency =
      if Histogram.get_count mm.latency = 0 then 0.0
      else Histogram.get_sum mm.latency /. float_of_int (Histogram.get_count mm.latency)
    in
    log (Printf.sprintf "  %s: %d calls, %.3fms avg latency, %d errors"
           method_
           (Counter.get mm.calls_total)
           (avg_latency *. 1000.0)
           (Counter.get mm.calls_failed))
  ) m.methods
