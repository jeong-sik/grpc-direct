(** Buffer Pool - High-performance ring buffer implementation

    Optimizations over the previous weak-reference design:
    1. Ring buffer: O(1) acquire/release, no list traversal
    2. No Weak refs: Eliminates GC interaction overhead
    3. Pre-allocated slots: Avoids allocation during hot path
    4. Per-domain isolation: Uses Domain.DLS for thread safety

    Based on grpc-go sync.Pool patterns with power-of-2 sizing.
*)

(** Power-of-2 buffer size classes (grpc-go pattern) *)
let size_classes = [| 256; 512; 1024; 2048; 4096; 8192; 16384; 32768 |]

(** Find the smallest size class >= requested size *)
let size_class_index size =
  (* Binary search would be overkill for 8 classes *)
  if size <= 256
  then 0
  else if size <= 512
  then 1
  else if size <= 1024
  then 2
  else if size <= 2048
  then 3
  else if size <= 4096
  then 4
  else if size <= 8192
  then 5
  else if size <= 16384
  then 6
  else 7
;;

(** Ring buffer pool for one size class *)
type ring_pool =
  { size : int (* Buffer size for this pool *)
  ; slots : bytes option array (* Ring buffer slots *)
  ; mutable head : int (* Next slot to fill *)
  ; mutable count : int (* Number of available buffers *)
  ; mutable hits : int
  ; mutable misses : int
  }

(** Maximum buffers per size class - enough for concurrent streams *)
let pool_capacity = 128

(** Create empty ring pool for one size class *)
let create_ring_pool size =
  { size
  ; slots = Array.make pool_capacity None
  ; head = 0
  ; count = 0
  ; hits = 0
  ; misses = 0
  }
;;

(** Domain-local pool state *)
type t =
  { pools : ring_pool array
  ; mutable total_allocated : int
  ; mutable total_recycled : int
  }

(** Create domain-local pool state *)
let create () : t =
  { pools = Array.map create_ring_pool size_classes
  ; total_allocated = 0
  ; total_recycled = 0
  }
;;

(** Domain-Local Storage key for per-domain pools *)
let pool_key : t Domain.DLS.key = Domain.DLS.new_key create

(** Get the domain-local pool *)
let get_pool () = Domain.DLS.get pool_key

(** Acquire a buffer of at least [size] bytes - O(1)

    Returns a buffer from the pool if available, otherwise allocates new.
    The returned buffer may be larger than requested (power-of-2 sized).
*)
let acquire ~size : bytes =
  let pool = get_pool () in
  let idx = size_class_index size in
  let ring = pool.pools.(idx) in
  if ring.count > 0
  then (
    (* Pool hit - take from ring buffer *)
    ring.count <- ring.count - 1;
    let slot_idx = (ring.head - ring.count - 1 + pool_capacity) mod pool_capacity in
    match ring.slots.(slot_idx) with
    | Some buf ->
      ring.slots.(slot_idx) <- None;
      ring.hits <- ring.hits + 1;
      buf
    | None ->
      (* Should not happen, but handle gracefully *)
      ring.misses <- ring.misses + 1;
      pool.total_allocated <- pool.total_allocated + 1;
      Bytes.create ring.size)
  else (
    (* Pool miss - allocate new *)
    ring.misses <- ring.misses + 1;
    pool.total_allocated <- pool.total_allocated + 1;
    Bytes.create ring.size)
;;

(** Release a buffer back to the pool - O(1)

    If pool is full, buffer is simply dropped for GC.
*)
let release buf : unit =
  let pool = get_pool () in
  let size = Bytes.length buf in
  (* Only pool buffers that match our size classes exactly *)
  if size >= 256 && size <= 32768
  then (
    let idx = size_class_index size in
    let ring = pool.pools.(idx) in
    if size = ring.size && ring.count < pool_capacity
    then (
      (* Add to ring buffer *)
      ring.slots.(ring.head) <- Some buf;
      ring.head <- (ring.head + 1) mod pool_capacity;
      ring.count <- ring.count + 1;
      pool.total_recycled <- pool.total_recycled + 1)
    (* If pool is full or size mismatch, drop for GC *))
;;

(** Pre-warm the pool with N buffers per size class - call at startup *)
let prewarm ~count_per_class : unit =
  let pool = get_pool () in
  Array.iter
    (fun ring ->
       let to_add = min count_per_class (pool_capacity - ring.count) in
       for _ = 1 to to_add do
         let buf = Bytes.create ring.size in
         ring.slots.(ring.head) <- Some buf;
         ring.head <- (ring.head + 1) mod pool_capacity;
         ring.count <- ring.count + 1
       done)
    pool.pools
;;

(** Get pool statistics for monitoring *)
type stats =
  { total_allocated : int
  ; total_recycled : int
  ; hit_rate : float
  ; pool_sizes : int array
  }

let stats () : stats =
  let pool = get_pool () in
  let total_hits = Array.fold_left (fun acc p -> acc + p.hits) 0 pool.pools in
  let total_misses = Array.fold_left (fun acc p -> acc + p.misses) 0 pool.pools in
  let total_requests = total_hits + total_misses in
  let hit_rate =
    if total_requests = 0
    then 0.0
    else float_of_int total_hits /. float_of_int total_requests
  in
  let pool_sizes = Array.map (fun p -> p.count) pool.pools in
  { total_allocated = pool.total_allocated
  ; total_recycled = pool.total_recycled
  ; hit_rate
  ; pool_sizes
  }
;;

(** RAII-style buffer usage with automatic release *)
let with_buffer ~size f =
  let buf = acquire ~size in
  Fun.protect ~finally:(fun () -> release buf) (fun () -> f buf)
;;

(** Cstruct wrapper: zero-copy view over pooled buffer *)
module Cstruct_pool = struct
  (** Acquire a Cstruct backed by pooled buffer *)
  let acquire ~size : Cstruct.t =
    let buf = acquire ~size in
    Cstruct.of_bytes buf
  ;;

  (** Release underlying buffer back to pool *)
  let release (cs : Cstruct.t) : unit =
    (* Note: This only works if Cstruct was created from our pool *)
    let buf = Cstruct.to_bytes cs in
    release buf
  ;;

  (** RAII-style Cstruct usage *)
  let with_cstruct ~size f =
    let cs = acquire ~size in
    Fun.protect ~finally:(fun () -> release cs) (fun () -> f cs)
  ;;
end
