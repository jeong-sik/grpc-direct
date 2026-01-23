(** Minimal HTTP/1.1 parser and writer for gRPC-Web. *)

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

let strip_cr line =
  let len = String.length line in
  if len > 0 && line.[len - 1] = '\r' then String.sub line 0 (len - 1) else line
;;

let read_line reader = Eio.Buf_read.line reader |> strip_cr
let header_value headers name = List.assoc_opt (String.lowercase_ascii name) headers

let parse_headers reader ~max_header_size =
  let rec loop acc total =
    let line = read_line reader in
    if line = ""
    then List.rev acc
    else (
      let total = total + String.length line in
      if total > max_header_size then failwith "Header section too large";
      match String.index_opt line ':' with
      | None -> loop acc total
      | Some idx ->
        let key = String.sub line 0 idx |> String.trim |> String.lowercase_ascii in
        let value =
          String.sub line (idx + 1) (String.length line - idx - 1) |> String.trim
        in
        loop ((key, value) :: acc) total)
  in
  loop [] 0
;;

let parse_chunk_size line =
  let trimmed = String.trim line in
  if trimmed = ""
  then None
  else (
    let hex =
      match String.index_opt trimmed ';' with
      | None -> trimmed
      | Some idx -> String.sub trimmed 0 idx
    in
    int_of_string_opt ("0x" ^ hex))
;;

let read_body reader ~max_body_size headers =
  match header_value headers "transfer-encoding" with
  | Some v
    when List.mem
           "chunked"
           (String.split_on_char ',' v
            |> List.map String.trim
            |> List.map String.lowercase_ascii) ->
    let buf = Buffer.create 4096 in
    let total = ref 0 in
    let rec loop () =
      let line = read_line reader in
      match parse_chunk_size line with
      | None -> failwith "Invalid chunk size"
      | Some 0 ->
        let rec drain_trailers () =
          let t = read_line reader in
          if t = "" then () else drain_trailers ()
        in
        drain_trailers ();
        Buffer.contents buf
      | Some n ->
        total := !total + n;
        if !total > max_body_size then failwith "Request body too large";
        let chunk = Eio.Buf_read.take n reader in
        ignore (read_line reader);
        (* consume CRLF *)
        Buffer.add_string buf chunk;
        loop ()
    in
    loop ()
  | _ ->
    (match header_value headers "content-length" with
     | None -> ""
     | Some v ->
       let len = int_of_string v in
       if len > max_body_size then failwith "Request body too large";
       Eio.Buf_read.take len reader)
;;

let read_body_chunks reader ~max_body_size headers ~on_chunk =
  match header_value headers "transfer-encoding" with
  | Some v
    when List.mem
           "chunked"
           (String.split_on_char ',' v
            |> List.map String.trim
            |> List.map String.lowercase_ascii) ->
    let total = ref 0 in
    let rec loop () =
      let line = read_line reader in
      match parse_chunk_size line with
      | None -> failwith "Invalid chunk size"
      | Some 0 ->
        let rec drain_trailers () =
          let t = read_line reader in
          if t = "" then () else drain_trailers ()
        in
        drain_trailers ()
      | Some n ->
        total := !total + n;
        if !total > max_body_size then failwith "Request body too large";
        let chunk = Eio.Buf_read.take n reader in
        ignore (read_line reader);
        on_chunk chunk;
        loop ()
    in
    loop ()
  | _ ->
    (match header_value headers "content-length" with
     | None -> ()
     | Some v ->
       let len = int_of_string v in
       if len > max_body_size then failwith "Request body too large";
       let body = Eio.Buf_read.take len reader in
       on_chunk body)
;;

let read_request reader ~max_header_size ~max_body_size =
  let line = read_line reader in
  match String.split_on_char ' ' line with
  | [ meth; target; version ] ->
    let headers = parse_headers reader ~max_header_size in
    let body = read_body reader ~max_body_size headers in
    { meth; target; version; headers; body }
  | _ -> failwith ("Invalid request line: " ^ line)
;;

let read_response reader ~max_header_size ~max_body_size =
  let line = read_line reader in
  match String.split_on_char ' ' line with
  | version :: status :: rest ->
    let status_code = int_of_string status in
    let reason = String.concat " " rest in
    let headers = parse_headers reader ~max_header_size in
    let body = read_body reader ~max_body_size headers in
    { version; status_code; reason; headers; body }
  | _ -> failwith ("Invalid response line: " ^ line)
;;

let read_response_head reader ~max_header_size =
  let line = read_line reader in
  match String.split_on_char ' ' line with
  | version :: status :: rest ->
    let status_code = int_of_string status in
    let reason = String.concat " " rest in
    let headers = parse_headers reader ~max_header_size in
    version, status_code, reason, headers
  | _ -> failwith ("Invalid response line: " ^ line)
;;

let write_headers headers =
  headers |> List.map (fun (k, v) -> Printf.sprintf "%s: %s\r\n" k v) |> String.concat ""
;;

let write_request flow ~meth ~target ~headers ~body =
  let request_line = Printf.sprintf "%s %s HTTP/1.1\r\n" meth target in
  let header_block = write_headers headers in
  let payload = request_line ^ header_block ^ "\r\n" ^ body in
  Eio.Flow.write flow [ Cstruct.of_string payload ]
;;

let write_response_headers flow ~status ~reason ~headers =
  let status_line = Printf.sprintf "HTTP/1.1 %d %s\r\n" status reason in
  let header_block = write_headers headers in
  let payload = status_line ^ header_block ^ "\r\n" in
  Eio.Flow.write flow [ Cstruct.of_string payload ]
;;

let write_response flow ~status ~reason ~headers ~body =
  write_response_headers flow ~status ~reason ~headers;
  if body <> "" then Eio.Flow.write flow [ Cstruct.of_string body ]
;;

let write_chunk flow data =
  if data <> ""
  then (
    let chunk = Printf.sprintf "%X\r\n%s\r\n" (String.length data) data in
    Eio.Flow.write flow [ Cstruct.of_string chunk ])
;;

let finish_chunked flow = Eio.Flow.write flow [ Cstruct.of_string "0\r\n\r\n" ]
