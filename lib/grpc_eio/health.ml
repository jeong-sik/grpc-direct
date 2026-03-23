(** gRPC Health Checking Protocol (v1) implementation.

    Implements the standard gRPC health checking protocol as defined in:
    https://github.com/grpc/grpc/blob/master/doc/health-checking.md

    {b Thread Safety:}
    - Single-domain safe: Yes (cooperative scheduling)
    - Multi-domain safe: Yes - all mutable state protected by [Eio.Mutex]
    - Uses [Eio.Mutex.use_rw ~protect:true] for writes, [Eio.Mutex.use_ro] for reads

    @see {{: https://github.com/ocaml-multicore/eio/blob/main/doc/multicore.md } Eio Multicore Guide}

    Usage:
    {[
      let health = Health.create () in
      Health.set_status health ~service:"myapp.Greeter" Serving;

      let server = Server.create ()
        |> Server.add_service (Health.to_service health)
        |> Server.serve ~sw ~env
    ]} *)

(** Serving status as defined by gRPC Health Checking Protocol *)
type status =
  | Unknown (** 0 - Status unknown *)
  | Serving (** 1 - Service is healthy and serving *)
  | Not_serving (** 2 - Service is not serving (unhealthy) *)
  | Service_unknown (** 3 - Service name not recognized *)

(** Convert status to integer for wire format *)
let status_to_int = function
  | Unknown -> 0
  | Serving -> 1
  | Not_serving -> 2
  | Service_unknown -> 3
;;

(** Convert integer from wire format to status *)
let _status_of_int = function
  | 0 -> Unknown
  | 1 -> Serving
  | 2 -> Not_serving
  | 3 -> Service_unknown
  | _ -> Unknown
;;

(** Health service state *)
type t =
  { statuses : (string, status) Hashtbl.t
  ; watchers : (string, status Grpc_stream.t list) Hashtbl.t
  ; mutable default_status : status
  ; mutex : Eio.Mutex.t
  }

(** Create a new health service *)
let create ?(default_status = Unknown) () : t =
  { statuses = Hashtbl.create 16
  ; watchers = Hashtbl.create 16
  ; default_status
  ; mutex = Eio.Mutex.create ()
  }
;;

(** Internal: set status and notify watchers. Caller must hold [t.mutex]. *)
let set_status_locked (t : t) ~(service : string) (status : status) : unit =
  Hashtbl.replace t.statuses service status;
  (* Notify all watchers for this service *)
  match Hashtbl.find_opt t.watchers service with
  | None -> ()
  | Some streams -> List.iter (fun stream -> Grpc_stream.add stream status) streams
;;

(** Internal: get status. Caller must hold [t.mutex] (at least read). *)
let get_status_locked (t : t) ~(service : string) : status =
  match Hashtbl.find_opt t.statuses service with
  | Some status -> status
  | None -> if service = "" then t.default_status else Service_unknown
;;

(** Set the health status for a service.

    @param service Service name (empty string for overall server health)
    @param status New status *)
let set_status (t : t) ~(service : string) (status : status) : unit =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    set_status_locked t ~service status)
;;

(** Get the health status for a service.

    @param service Service name (empty string for overall server health)
    @return Current status *)
let get_status (t : t) ~(service : string) : status =
  Eio.Mutex.use_ro t.mutex (fun () -> get_status_locked t ~service)
;;

(** Set the default status for the overall server *)
let set_default_status (t : t) (status : status) : unit =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    t.default_status <- status;
    set_status_locked t ~service:"" status)
;;

(** Mark all services as serving *)
let set_all_serving (t : t) : unit =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    Hashtbl.iter (fun service _ -> set_status_locked t ~service Serving) t.statuses;
    t.default_status <- Serving;
    set_status_locked t ~service:"" Serving)
;;

(** Mark all services as not serving (for graceful shutdown) *)
let set_all_not_serving (t : t) : unit =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    Hashtbl.iter
      (fun service _ -> set_status_locked t ~service Not_serving)
      t.statuses;
    t.default_status <- Not_serving;
    set_status_locked t ~service:"" Not_serving)
;;

(* Wire format helpers for HealthCheckRequest/Response *)
(*
   HealthCheckRequest: { service: string (field 1) }
   HealthCheckResponse: { status: enum (field 1) }

   Simple protobuf encoding:
   - varint tag: (field_num << 3) | wire_type
   - string: length-delimited (wire_type 2)
   - enum: varint (wire_type 0)
*)

(** Decode HealthCheckRequest from protobuf bytes *)
let decode_request (bytes : string) : string =
  if String.length bytes = 0
  then ""
  else (
    (* Simple protobuf parsing for field 1 (string) *)
    let pos = ref 0 in
    let len = String.length bytes in
    let service = ref "" in
    while !pos < len do
      let tag = Char.code bytes.[!pos] in
      incr pos;
      let field_num = tag lsr 3 in
      let wire_type = tag land 0x7 in
      if field_num = 1 && wire_type = 2
      then (
        (* Length-delimited string *)
        let str_len = Char.code bytes.[!pos] in
        incr pos;
        service := String.sub bytes !pos str_len;
        pos := !pos + str_len)
      else
        (* Skip unknown fields *)
        pos := len
    done;
    !service)
;;

(** Encode HealthCheckResponse to protobuf bytes *)
let encode_response (status : status) : string =
  (* Field 1, wire type 0 (varint) *)
  let tag = (1 lsl 3) lor 0 in
  let status_int = status_to_int status in
  String.make 1 (Char.chr tag) ^ String.make 1 (Char.chr status_int)
;;

(** Create Watch stream for a service *)
let watch (t : t) ~(service : string) : status Grpc_stream.t =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    let stream = Grpc_stream.create 8 in
    (* Register watcher *)
    let existing =
      Hashtbl.find_opt t.watchers service |> Option.value ~default:[]
    in
    Hashtbl.replace t.watchers service (stream :: existing);
    (* Send initial status *)
    Grpc_stream.add stream (get_status_locked t ~service);
    stream)
;;

(** Convert health service to a gRPC service.

    Creates a Service.t that can be added to a server with:
    {[ Server.add_service (Health.to_service health) server ]} *)
let to_service (t : t) : Service.t =
  Service.create "grpc.health.v1.Health"
  |> Service.add_unary "Check" (fun request_bytes ->
    let service = decode_request request_bytes in
    let status = get_status t ~service in
    encode_response status)
  |> Service.add_server_streaming "Watch" (fun request_bytes ->
    let service = decode_request request_bytes in
    let stream = watch t ~service in
    (* Map status to encoded response *)
    let response_stream = Grpc_stream.create 8 in
    (* Note: In real implementation, need fiber to pump from one stream to another *)
    (* For now, send initial status and return *)
    let initial_status = Grpc_stream.take stream in
    Grpc_stream.add response_stream (encode_response initial_status);
    response_stream)
;;

(** Register a service name (sets initial status to Unknown) *)
let register_service (t : t) ~(service : string) : unit =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    if not (Hashtbl.mem t.statuses service)
    then Hashtbl.replace t.statuses service Unknown)
;;

(** List all registered services *)
let list_services (t : t) : string list =
  Eio.Mutex.use_ro t.mutex (fun () ->
    Hashtbl.fold (fun k _ acc -> k :: acc) t.statuses [])
;;
