(** Minimal HTTP/1.1 parser and writer for gRPC-Web.

    Provides low-level request/response reading and writing over
    Eio flows, supporting both content-length and chunked
    transfer-encoding. *)

(** {1 Types} *)

type request =
  { meth : string
  ; target : string
  ; version : string
  ; headers : (string * string) list
  ; body : string
  }

type response =
  { version : string
  ; status_code : int
  ; reason : string
  ; headers : (string * string) list
  ; body : string
  }

(** {1 Header utilities} *)

(** Look up a header value by name (case-insensitive). *)
val header_value : (string * string) list -> string -> string option

(** {1 Reading} *)

(** Parse a complete HTTP/1.1 request from a buffered reader.
    Reads request line, headers, and body (content-length or chunked).
    @raise Failure on malformed input or size limit exceeded. *)
val read_request : Eio.Buf_read.t -> max_header_size:int -> max_body_size:int -> request

(** Parse a complete HTTP/1.1 response from a buffered reader.
    @raise Failure on malformed input or size limit exceeded. *)
val read_response : Eio.Buf_read.t -> max_header_size:int -> max_body_size:int -> response

(** Parse only the response status line and headers, leaving the body
    unread in the buffer.
    Returns [(version, status_code, reason, headers)]. *)
val read_response_head
  :  Eio.Buf_read.t
  -> max_header_size:int
  -> string * int * string * (string * string) list

(** Read the response body in chunks, calling [on_chunk] for each piece.
    Handles both chunked transfer-encoding and content-length. *)
val read_body_chunks
  :  Eio.Buf_read.t
  -> max_body_size:int
  -> (string * string) list
  -> on_chunk:(string -> unit)
  -> unit

(** {1 Writing} *)

(** Write a complete HTTP/1.1 request (request line + headers + body). *)
val write_request
  :  _ Eio.Flow.sink
  -> meth:string
  -> target:string
  -> headers:(string * string) list
  -> body:string
  -> unit

(** Write only the response status line and headers (no body). *)
val write_response_headers
  :  _ Eio.Flow.sink
  -> status:int
  -> reason:string
  -> headers:(string * string) list
  -> unit

(** Write a complete HTTP/1.1 response (status line + headers + body). *)
val write_response
  :  _ Eio.Flow.sink
  -> status:int
  -> reason:string
  -> headers:(string * string) list
  -> body:string
  -> unit

(** Write a single HTTP chunked-encoding frame.
    Does nothing if [data] is empty. *)
val write_chunk : _ Eio.Flow.sink -> string -> unit

(** Write the terminal chunk ([0\r\n\r\n]) to end chunked transfer. *)
val finish_chunked : _ Eio.Flow.sink -> unit
