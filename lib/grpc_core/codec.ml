(** Compression codecs for gRPC.

    Inspired by Rust tonic's codec design and joprice's ocaml-grpc gzip branch. *)

type encoder = string -> (string, string) result
type decoder = string -> (string, string) result

type t = {
  name : string;
  encoder : encoder;
  decoder : decoder;
}

(** Identity codec - no compression *)
let identity : t = {
  name = "identity";
  encoder = Result.ok;
  decoder = Result.ok;
}

(** Gzip codec using decompress library *)
module Gzip = struct
  let encoder ?(level = 4) str =
    let i = De.bigstring_create De.io_buffer_size in
    let o = De.bigstring_create De.io_buffer_size in
    let w = De.Lz77.make_window ~bits:15 in
    let q = De.Queue.create 0x1000 in
    let r = Buffer.create 0x1000 in
    let p = ref 0 in
    let time () = Int32.of_float (Unix.gettimeofday ()) in
    let cfg = Gz.Higher.configuration Gz.Unix time in
    let refill buf =
      let len = min (String.length str - !p) De.io_buffer_size in
      Bigstringaf.blit_from_string str ~src_off:!p buf ~dst_off:0 ~len;
      p := !p + len;
      len
    in
    let flush buf len =
      let s = Bigstringaf.substring buf ~off:0 ~len in
      Buffer.add_string r s
    in
    try
      Gz.Higher.compress ~w ~q ~level ~refill ~flush () cfg i o;
      Ok (Buffer.contents r)
    with exn ->
      Error (Printexc.to_string exn)

  let decoder str =
    let i = De.bigstring_create De.io_buffer_size in
    let o = De.bigstring_create De.io_buffer_size in
    let r = Buffer.create 0x1000 in
    let p = ref 0 in
    let refill buf =
      let len = min (String.length str - !p) De.io_buffer_size in
      Bigstringaf.blit_from_string str ~src_off:!p buf ~dst_off:0 ~len;
      p := !p + len;
      len
    in
    let flush buf len =
      let s = Bigstringaf.substring buf ~off:0 ~len in
      Buffer.add_string r s
    in
    match Gz.Higher.uncompress ~refill ~flush i o with
    | Ok _metadata -> Ok (Buffer.contents r)
    | Error (`Msg err) -> Error err
end

let gzip ?(level = 4) () : t = {
  name = "gzip";
  encoder = Gzip.encoder ~level;
  decoder = Gzip.decoder;
}

(** Zstd codec - Compact Protocol v4

    Faster and better compression than gzip.
    Recommended for LLM-to-LLM communication. *)
module Zstd_codec = struct
  let encoder ?(level = 3) str =
    try
      Ok (Zstd.compress ~level str)
    with Zstd.Error msg ->
      Error ("Zstd compression failed: " ^ msg)

  let decoder str =
    try
      (* Estimate decompressed size - typically 3-10x compressed *)
      let estimated_size = max 4096 (String.length str * 8) in
      Ok (Zstd.decompress estimated_size str)
    with Zstd.Error msg ->
      Error ("Zstd decompression failed: " ^ msg)
end

let zstd ?(level = 3) () : t = {
  name = "zstd";
  encoder = Zstd_codec.encoder ~level;
  decoder = Zstd_codec.decoder;
}

(** Normalize encoding names to compare safely *)
let normalize_name s =
  s |> String.trim |> String.lowercase_ascii

(** Parse grpc-accept-encoding header into normalized list *)
let parse_accept (header : string) : string list =
  header
  |> String.split_on_char ','
  |> List.map normalize_name
  |> List.filter (fun s -> s <> "")

(** Find codec by name in supported list *)
let find_by_name ~supported name =
  let name = normalize_name name in
  List.find_opt (fun c -> normalize_name c.name = name) supported

(** Negotiate codec based on accept-encoding header *)
let negotiate ~supported ~accepted : t =
  let accepted = String.split_on_char ',' accepted |> List.map String.trim in
  List.find_opt (fun codec -> List.mem codec.name accepted) supported
  |> Option.value ~default:identity

(** Check if codec is identity (no compression) *)
let is_identity codec = codec.name = "identity"
