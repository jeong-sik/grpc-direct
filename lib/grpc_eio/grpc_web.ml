(** gRPC-Web framing and base64 utilities. *)

type mode =
  | Binary
  | Text

type frame =
  | Message of string
  | Trailers of (string * string) list

let content_type = function
  | Binary -> "application/grpc-web+proto"
  | Text -> "application/grpc-web-text+proto"

let mode_of_content_type (content_type : string) =
  let ct = String.lowercase_ascii content_type in
  if String.starts_with ~prefix:"application/grpc-web-text" ct then Ok Text
  else if String.starts_with ~prefix:"application/grpc-web" ct then Ok Binary
  else Error (Printf.sprintf "Invalid content-type for gRPC-Web: %s" content_type)

let percent_encode s =
  let buf = Buffer.create (String.length s * 3) in
  String.iter (fun c ->
    let code = Char.code c in
    if (code >= 0x20 && code <= 0x7E && c <> '%') then
      Buffer.add_char buf c
    else
      Buffer.add_string buf (Printf.sprintf "%%%02X" code)
  ) s;
  Buffer.contents buf

let percent_decode s =
  let len = String.length s in
  let buf = Buffer.create len in
  let rec loop i =
    if i >= len then Ok (Buffer.contents buf)
    else
      match s.[i] with
      | '%' when i + 2 < len ->
          let hex = String.sub s (i + 1) 2 in
          (try
             let code = int_of_string ("0x" ^ hex) in
             Buffer.add_char buf (Char.chr code);
             loop (i + 3)
           with _ ->
             Error (Printf.sprintf "Invalid percent-encoding: %%%s" hex))
      | '%' -> Error "Invalid percent-encoding: trailing %"
      | c ->
          Buffer.add_char buf c;
          loop (i + 1)
  in
  loop 0

let encode_trailers (trailers : (string * string) list) =
  let buf = Buffer.create 128 in
  List.iter (fun (k, v) ->
    Buffer.add_string buf k;
    Buffer.add_string buf ": ";
    Buffer.add_string buf v;
    Buffer.add_string buf "\r\n"
  ) trailers;
  Buffer.contents buf

let decode_trailers (payload : string) =
  let lines = String.split_on_char '\n' payload in
  let trim_cr s =
    if String.length s > 0 && s.[String.length s - 1] = '\r' then
      String.sub s 0 (String.length s - 1)
    else s
  in
  lines
  |> List.filter_map (fun line ->
    let line = trim_cr line |> String.trim in
    if line = "" then None
    else
      match String.index_opt line ':' with
      | None -> None
      | Some idx ->
          let key = String.sub line 0 idx |> String.trim |> String.lowercase_ascii in
          let value =
            String.sub line (idx + 1) (String.length line - idx - 1)
            |> String.trim
          in
          Some (key, value))

let decode_u32_be s off =
  (Char.code s.[off] lsl 24)
  lor (Char.code s.[off + 1] lsl 16)
  lor (Char.code s.[off + 2] lsl 8)
  lor Char.code s.[off + 3]

let encode_u32_be len =
  let buf = Bytes.create 4 in
  Bytes.set buf 0 (Char.chr ((len lsr 24) land 0xFF));
  Bytes.set buf 1 (Char.chr ((len lsr 16) land 0xFF));
  Bytes.set buf 2 (Char.chr ((len lsr 8) land 0xFF));
  Bytes.set buf 3 (Char.chr (len land 0xFF));
  buf

let encode_trailer_frame payload =
  let len = String.length payload in
  let buf = Bytes.create (5 + len) in
  Bytes.set buf 0 (Char.chr 0x80);
  Bytes.blit (encode_u32_be len) 0 buf 1 4;
  Bytes.blit_string payload 0 buf 5 len;
  Bytes.to_string buf

let encode_frame = function
  | Message frame -> frame
  | Trailers trailers -> encode_trailer_frame (encode_trailers trailers)

let decode_frames_partial (buf : string) =
  let buf_len = String.length buf in
  let rec loop acc offset =
    if buf_len - offset < 5 then Ok (List.rev acc, String.sub buf offset (buf_len - offset))
    else
      let flag = Char.code buf.[offset] in
      let len = decode_u32_be buf (offset + 1) in
      if buf_len - offset < 5 + len then
        Ok (List.rev acc, String.sub buf offset (buf_len - offset))
      else
        let payload = String.sub buf (offset + 5) len in
        let frame =
          if flag land 0x80 <> 0 then
            Trailers (decode_trailers payload)
          else if flag = 0x00 || flag = 0x01 then
            Message (String.sub buf offset (5 + len))
          else
            (* Invalid compression flag per gRPC spec *)
            raise (Failure (Printf.sprintf "Invalid gRPC-Web data flag: 0x%02X" flag))
        in
        loop (frame :: acc) (offset + 5 + len)
  in
  try loop [] 0 with
  | Failure msg -> Error msg

let decode_frames_complete (buf : string) =
  match decode_frames_partial buf with
  | Error e -> Error e
  | Ok (frames, remaining) ->
      if remaining = "" then Ok frames
      else Error "Incomplete gRPC-Web frame at end of stream"

module Base64 = struct
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

  let decode_table =
    let tbl = Array.make 256 (-1) in
    String.iteri (fun i c -> tbl.(Char.code c) <- i) alphabet;
    tbl

  let is_ws = function
    | ' ' | '\r' | '\n' | '\t' -> true
    | _ -> false

  let encode (s : string) =
    let len = String.length s in
    let out = Buffer.create ((len + 2) / 3 * 4) in
    let rec loop i =
      if i + 2 < len then begin
        let b1 = Char.code s.[i] in
        let b2 = Char.code s.[i + 1] in
        let b3 = Char.code s.[i + 2] in
        let n = (b1 lsl 16) lor (b2 lsl 8) lor b3 in
        Buffer.add_char out alphabet.[(n lsr 18) land 0x3F];
        Buffer.add_char out alphabet.[(n lsr 12) land 0x3F];
        Buffer.add_char out alphabet.[(n lsr 6) land 0x3F];
        Buffer.add_char out alphabet.[n land 0x3F];
        loop (i + 3)
      end else if i + 1 < len then begin
        let b1 = Char.code s.[i] in
        let b2 = Char.code s.[i + 1] in
        let n = (b1 lsl 16) lor (b2 lsl 8) in
        Buffer.add_char out alphabet.[(n lsr 18) land 0x3F];
        Buffer.add_char out alphabet.[(n lsr 12) land 0x3F];
        Buffer.add_char out alphabet.[(n lsr 6) land 0x3F];
        Buffer.add_char out '=';
      end else if i < len then begin
        let b1 = Char.code s.[i] in
        let n = b1 lsl 16 in
        Buffer.add_char out alphabet.[(n lsr 18) land 0x3F];
        Buffer.add_char out alphabet.[(n lsr 12) land 0x3F];
        Buffer.add_char out '=';
        Buffer.add_char out '=';
      end
    in
    loop 0;
    Buffer.contents out

  let decode_quad c1 c2 c3 c4 =
    let v1 = decode_table.(Char.code c1) in
    let v2 = decode_table.(Char.code c2) in
    if v1 < 0 || v2 < 0 then Error "Invalid base64 character"
    else
      if c3 = '=' && c4 = '=' then
        let b1 = (v1 lsl 2) lor (v2 lsr 4) in
        Ok (Bytes.init 1 (fun _ -> Char.chr (b1 land 0xFF)))
      else if c4 = '=' then
        let v3 = decode_table.(Char.code c3) in
        if v3 < 0 then Error "Invalid base64 character"
        else
          let b1 = (v1 lsl 2) lor (v2 lsr 4) in
          let b2 = (v2 lsl 4) lor (v3 lsr 2) in
          Ok (Bytes.init 2 (function
            | 0 -> Char.chr (b1 land 0xFF)
            | _ -> Char.chr (b2 land 0xFF)))
      else if c3 = '=' then
        Error "Invalid base64 padding"
      else
        let v3 = decode_table.(Char.code c3) in
        let v4 = decode_table.(Char.code c4) in
        if v3 < 0 || v4 < 0 then Error "Invalid base64 character"
        else
          let b1 = (v1 lsl 2) lor (v2 lsr 4) in
          let b2 = (v2 lsl 4) lor (v3 lsr 2) in
          let b3 = (v3 lsl 6) lor v4 in
          Ok (Bytes.init 3 (function
            | 0 -> Char.chr (b1 land 0xFF)
            | 1 -> Char.chr (b2 land 0xFF)
            | _ -> Char.chr (b3 land 0xFF)))

  let decode (s : string) =
    let filtered =
      let buf = Buffer.create (String.length s) in
      String.iter (fun c -> if not (is_ws c) then Buffer.add_char buf c) s;
      Buffer.contents buf
    in
    let len = String.length filtered in
    if len mod 4 <> 0 then Error "Invalid base64 length"
    else
      let out = Buffer.create (len / 4 * 3) in
      let rec loop i =
        if i >= len then Ok (Buffer.contents out)
        else
          match decode_quad filtered.[i] filtered.[i + 1] filtered.[i + 2] filtered.[i + 3] with
          | Error e -> Error e
          | Ok bytes ->
              Buffer.add_bytes out bytes;
              loop (i + 4)
      in
      loop 0

  module Stream = struct
    type enc_state = { carry : string }

    let enc_init = { carry = "" }

    let encode_chunk (state : enc_state) (chunk : string) =
      let data = state.carry ^ chunk in
      let len = String.length data in
      let full = len - (len mod 3) in
      let out = Buffer.create ((full / 3) * 4) in
      let rec loop i =
        if i + 2 < full then begin
          let b1 = Char.code data.[i] in
          let b2 = Char.code data.[i + 1] in
          let b3 = Char.code data.[i + 2] in
          let n = (b1 lsl 16) lor (b2 lsl 8) lor b3 in
          Buffer.add_char out alphabet.[(n lsr 18) land 0x3F];
          Buffer.add_char out alphabet.[(n lsr 12) land 0x3F];
          Buffer.add_char out alphabet.[(n lsr 6) land 0x3F];
          Buffer.add_char out alphabet.[n land 0x3F];
          loop (i + 3)
        end
      in
      loop 0;
      let carry = if full < len then String.sub data full (len - full) else "" in
      (Buffer.contents out, { carry })

    let encode_final (state : enc_state) =
      let data = state.carry in
      let len = String.length data in
      if len = 0 then ""
      else if len = 1 then
        let b1 = Char.code data.[0] in
        let n = b1 lsl 16 in
        let out = Bytes.create 4 in
        Bytes.set out 0 alphabet.[(n lsr 18) land 0x3F];
        Bytes.set out 1 alphabet.[(n lsr 12) land 0x3F];
        Bytes.set out 2 '=';
        Bytes.set out 3 '=';
        Bytes.to_string out
      else
        let b1 = Char.code data.[0] in
        let b2 = Char.code data.[1] in
        let n = (b1 lsl 16) lor (b2 lsl 8) in
        let out = Bytes.create 4 in
        Bytes.set out 0 alphabet.[(n lsr 18) land 0x3F];
        Bytes.set out 1 alphabet.[(n lsr 12) land 0x3F];
        Bytes.set out 2 alphabet.[(n lsr 6) land 0x3F];
        Bytes.set out 3 '=';
        Bytes.to_string out

    type dec_state = { carry : string; finished : bool }

    let dec_init = { carry = ""; finished = false }

    let decode_chunk (state : dec_state) (chunk : string) =
      let filtered =
        let buf = Buffer.create (String.length chunk + String.length state.carry) in
        String.iter (fun c -> if not (is_ws c) then Buffer.add_char buf c) chunk;
        Buffer.contents buf
      in
      if state.finished && filtered <> "" then
        Error "Unexpected base64 data after padding"
      else
        let data = state.carry ^ filtered in
        let len = String.length data in
        let full = len - (len mod 4) in
        let out = Buffer.create (full / 4 * 3) in
        let rec loop i finished =
          if i >= full then Ok (Buffer.contents out, { carry = String.sub data full (len - full); finished })
          else
            let c1 = data.[i] and c2 = data.[i + 1] and c3 = data.[i + 2] and c4 = data.[i + 3] in
            match decode_quad c1 c2 c3 c4 with
            | Error e -> Error e
            | Ok bytes ->
                Buffer.add_bytes out bytes;
                let has_padding = (c3 = '=') || (c4 = '=') in
                if has_padding && i + 4 < full then
                  Error "Invalid base64 padding placement"
                else
                  loop (i + 4) (finished || has_padding)
        in
        loop 0 state.finished

    let decode_final (state : dec_state) =
      if state.carry <> "" then Error "Incomplete base64 quad"
      else if state.finished then Ok ""
      else Ok ""
  end
end
