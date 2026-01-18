(** High-Performance Buffer Pool for Zero-Copy gRPC.

    Inspired by:
    - Rust tonic's `bytes::Bytes` (reference-counted, zero-copy)
    - Go's sync.Pool (object reuse)
    - Zig's explicit allocators (deterministic memory)

    {b Key Benefits:}
    - Eliminates allocation overhead in hot path
    - Reduces GC pressure through buffer reuse
    - Power-of-2 sizing for optimal cache alignment
    - Thread-local pools for lock-free access

    {b Architecture:}
    {v
    ┌─────────────────────────────────────────────────────────┐
    │                    Buffer Pool                          │
    ├─────────────────────────────────────────────────────────┤
    │  Size Class 256B:   [buf][buf][buf][buf]...            │
    │  Size Class 1KB:    [buf][buf][buf]...                 │
    │  Size Class 4KB:    [buf][buf]...                      │
    │  Size Class 16KB:   [buf]...                           │
    │  Size Class 64KB:   [buf]...                           │
    └─────────────────────────────────────────────────────────┘
    v}

    @since 0.4.0
*)

(** Size classes for buffer pooling.
    Power-of-2 sizes aligned to cache lines (64B on most CPUs). *)
let size_classes = [|
  256;     (* Small messages, headers *)
  1024;    (* Typical unary request *)
  4096;    (* Medium messages *)
  16384;   (* Large messages *)
  65536;   (* Streaming chunks *)
|]

(** Maximum buffers per size class *)
let max_pooled = 64

(** Find appropriate size class for requested size *)
let size_class_index requested_size =
  let rec find i =
    if i >= Array.length size_classes then None
    else if size_classes.(i) >= requested_size then Some i
    else find (i + 1)
  in
  find 0

(** Per-size-class buffer pool *)
module SizeClassPool = struct
  type t = {
    size : int;
    mutable buffers : Bytes.t list;
    mutable count : int;
    (* Statistics *)
    mutable hits : int;
    mutable misses : int;
  }

  let create size = {
    size;
    buffers = [];
    count = 0;
    hits = 0;
    misses = 0;
  }

  let acquire pool =
    match pool.buffers with
    | buf :: rest ->
        pool.buffers <- rest;
        pool.count <- pool.count - 1;
        pool.hits <- pool.hits + 1;
        buf
    | [] ->
        pool.misses <- pool.misses + 1;
        Bytes.create pool.size

  let release pool buf =
    if Bytes.length buf = pool.size && pool.count < max_pooled then begin
      pool.buffers <- buf :: pool.buffers;
      pool.count <- pool.count + 1
    end
    (* Otherwise, let GC collect it *)

  let stats pool =
    let total = pool.hits + pool.misses in
    let hit_rate = if total > 0 then float pool.hits /. float total else 0.0 in
    (pool.hits, pool.misses, hit_rate)
end

(** Global buffer pool (per-domain in multi-domain setup) *)
type t = {
  pools : SizeClassPool.t array;
}

let create () = {
  pools = Array.map SizeClassPool.create size_classes;
}

(** Thread-local pool using Domain.DLS *)
let domain_local_pool = Domain.DLS.new_key create

let get_pool () = Domain.DLS.get domain_local_pool

(** Acquire a buffer of at least the requested size.
    Returns a buffer from the pool if available, or allocates a new one. *)
let acquire size =
  let pool = get_pool () in
  match size_class_index size with
  | Some idx -> SizeClassPool.acquire pool.pools.(idx)
  | None ->
      (* Size too large for pooling, allocate directly *)
      Bytes.create size

(** Release a buffer back to the pool.
    The buffer should not be used after this call. *)
let release buf =
  let pool = get_pool () in
  let size = Bytes.length buf in
  match size_class_index size with
  | Some idx when size_classes.(idx) = size ->
      SizeClassPool.release pool.pools.(idx) buf
  | _ -> ()  (* Not a pooled size, let GC handle it *)

(** Get pool statistics for monitoring *)
let stats () =
  let pool = get_pool () in
  Array.mapi (fun i p ->
    let (hits, misses, rate) = SizeClassPool.stats p in
    (size_classes.(i), hits, misses, rate)
  ) pool.pools

(** Print pool statistics *)
let print_stats () =
  Printf.printf "Buffer Pool Statistics:\n";
  Printf.printf "%-10s %10s %10s %10s\n" "Size" "Hits" "Misses" "Hit Rate";
  Printf.printf "%s\n" (String.make 42 '-');
  Array.iter (fun (size, hits, misses, rate) ->
    Printf.printf "%-10d %10d %10d %9.1f%%\n" size hits misses (rate *. 100.0)
  ) (stats ())


(** {1 Slice-Based Zero-Copy API} *)

(** A view into a buffer without copying.
    Similar to Rust's &[u8] or Go's []byte slice. *)
type slice = {
  buffer : Bytes.t;  (* Underlying buffer *)
  off : int;         (* Offset into buffer *)
  len : int;         (* Length of slice *)
  pooled : bool;     (* Whether to release on finalize *)
}

let slice_create ~pooled size =
  let buffer = if pooled then acquire size else Bytes.create size in
  { buffer; off = 0; len = size; pooled }

let slice_of_string s =
  let len = String.length s in
  let slice = slice_create ~pooled:true len in
  Bytes.blit_string s 0 slice.buffer 0 len;
  { slice with len }

let slice_to_string slice =
  Bytes.sub_string slice.buffer slice.off slice.len

let slice_sub slice ~off ~len =
  if off < 0 || len < 0 || off + len > slice.len then
    invalid_arg "Buffer_pool.slice_sub: out of bounds";
  { slice with off = slice.off + off; len }

let slice_release slice =
  if slice.pooled then release slice.buffer

let slice_length slice = slice.len

(** Blit from Bigstringaf directly into slice (for H2 integration) *)
let slice_blit_from_bigstring ~src ~src_off slice ~dst_off ~len =
  Bigstringaf.blit_to_bytes src ~src_off slice.buffer ~dst_off:(slice.off + dst_off) ~len


(** {1 Pooled Message Builder} *)

(** Builder for constructing messages with pooled buffers.
    Automatically grows and manages buffer lifecycle. *)
module Builder = struct
  type t = {
    mutable slice : slice;
    mutable pos : int;
  }

  let create ?(capacity = 1024) () =
    let size_idx = size_class_index capacity |> Option.value ~default:0 in
    let actual_size = size_classes.(size_idx) in
    { slice = slice_create ~pooled:true actual_size; pos = 0 }

  let ensure_capacity builder additional =
    let needed = builder.pos + additional in
    if needed > slice_length builder.slice then begin
      let new_size = max (slice_length builder.slice * 2) needed in
      let new_slice = slice_create ~pooled:true new_size in
      Bytes.blit builder.slice.buffer builder.slice.off
        new_slice.buffer 0 builder.pos;
      slice_release builder.slice;
      builder.slice <- { new_slice with len = new_size }
    end

  let add_string builder s =
    let len = String.length s in
    ensure_capacity builder len;
    Bytes.blit_string s 0 builder.slice.buffer builder.pos len;
    builder.pos <- builder.pos + len

  let add_bytes builder b ~off ~len =
    ensure_capacity builder len;
    Bytes.blit b off builder.slice.buffer builder.pos len;
    builder.pos <- builder.pos + len

  let add_bigstring builder bs ~off ~len =
    ensure_capacity builder len;
    slice_blit_from_bigstring ~src:bs ~src_off:off builder.slice ~dst_off:builder.pos ~len;
    builder.pos <- builder.pos + len

  let contents builder =
    Bytes.sub_string builder.slice.buffer 0 builder.pos

  let to_slice builder =
    { builder.slice with len = builder.pos }

  let release builder =
    slice_release builder.slice
end
