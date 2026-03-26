(** HPACK static table and lookup (RFC 7541 Appendix A)

    The 61 predefined header name-value pairs and O(1) lookup
    structures for both name-only and exact name-value matching. *)

(** Static table (RFC 7541 Appendix A) *)
let static_table =
  [| (* 1-10 *)
     ":authority", ""
   ; ":method", "GET"
   ; ":method", "POST"
   ; ":path", "/"
   ; ":path", "/index.html"
   ; ":scheme", "http"
   ; ":scheme", "https"
   ; ":status", "200"
   ; ":status", "204"
   ; ":status", "206"
   ; (* 11-20 *)
     ":status", "304"
   ; ":status", "400"
   ; ":status", "404"
   ; ":status", "500"
   ; "accept-charset", ""
   ; "accept-encoding", "gzip, deflate"
   ; "accept-language", ""
   ; "accept-ranges", ""
   ; "accept", ""
   ; "access-control-allow-origin", ""
   ; (* 21-30 *)
     "age", ""
   ; "allow", ""
   ; "authorization", ""
   ; "cache-control", ""
   ; "content-disposition", ""
   ; "content-encoding", ""
   ; "content-language", ""
   ; "content-length", ""
   ; "content-location", ""
   ; "content-range", ""
   ; (* 31-40 *)
     "content-type", ""
   ; "cookie", ""
   ; "date", ""
   ; "etag", ""
   ; "expect", ""
   ; "expires", ""
   ; "from", ""
   ; "host", ""
   ; "if-match", ""
   ; "if-modified-since", ""
   ; (* 41-50 *)
     "if-none-match", ""
   ; "if-range", ""
   ; "if-unmodified-since", ""
   ; "last-modified", ""
   ; "link", ""
   ; "location", ""
   ; "max-forwards", ""
   ; "proxy-authenticate", ""
   ; "proxy-authorization", ""
   ; "range", ""
   ; (* 51-61 *)
     "referer", ""
   ; "refresh", ""
   ; "retry-after", ""
   ; "server", ""
   ; "set-cookie", ""
   ; "strict-transport-security", ""
   ; "transfer-encoding", ""
   ; "user-agent", ""
   ; "vary", ""
   ; "via", ""
   ; "www-authenticate", ""
  |]
;;

let static_table_size = Array.length static_table (* 61 *)

(** Static table lookup hashtables for O(1) access *)
let static_name_idx : (string, int) Hashtbl.t = Hashtbl.create 64

let static_pair_idx : (string, int) Hashtbl.t = Hashtbl.create 64

let () =
  (* Build name-only index (first occurrence wins) *)
  for idx = static_table_size - 1 downto 0 do
    let name, _ = static_table.(idx) in
    Hashtbl.replace static_name_idx name (idx + 1)
    (* 1-indexed *)
  done;
  (* Build name+value index for exact matches *)
  for idx = 0 to static_table_size - 1 do
    let name, value = static_table.(idx) in
    if value <> ""
    then (
      let key = name ^ "\x00" ^ value in
      (* Null separator *)
      Hashtbl.add static_pair_idx key (idx + 1))
  done
;;

(** Lookup in static table by name only - O(1) *)
let lookup_name name = Hashtbl.find_opt static_name_idx name

(** Lookup in static table by name and value - O(1) *)
let lookup name value =
  if value = ""
  then None (* Empty values not indexed *)
  else (
    let key = name ^ "\x00" ^ value in
    Hashtbl.find_opt static_pair_idx key)
;;
