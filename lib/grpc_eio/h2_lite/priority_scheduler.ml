(** Priority scheduler for HTTP/2 streams (best-effort weighted round-robin).
    Dependencies are parsed separately; scheduling currently uses weights. *)

type node = {
  id : int32;
  mutable weight : int;
  mutable remaining : int;
  queue : Frame.t list Queue.t;
}

type t = {
  nodes : (int32, node) Hashtbl.t;
  mutable active : int32 list;
}

let create () : t =
  { nodes = Hashtbl.create 32; active = [] }

let get_node (t : t) (id : int32) : node =
  match Hashtbl.find_opt t.nodes id with
  | Some node -> node
  | None ->
      let node = { id; weight = 16; remaining = 16; queue = Queue.create () } in
      Hashtbl.add t.nodes id node;
      node

let update_priority (t : t) ~stream_id (priority : Frame.priority_info) =
  let node = get_node t stream_id in
  let weight = priority.weight in
  let weight = if weight < 1 then 1 else if weight > 256 then 256 else weight in
  node.weight <- weight;
  if node.remaining > node.weight then
    node.remaining <- node.weight

let enqueue (t : t) ~stream_id (frames : Frame.t list) =
  if frames <> [] then begin
    let node = get_node t stream_id in
    let was_empty = Queue.is_empty node.queue in
    Queue.add frames node.queue;
    if was_empty then
      t.active <- t.active @ [stream_id]
  end

let has_pending (t : t) =
  t.active <> []

let pop_next (t : t) : Frame.t list option =
  let rec cleanup acc = function
    | [] -> List.rev acc
    | id :: rest ->
        let node = get_node t id in
        if Queue.is_empty node.queue then
          cleanup acc rest
        else
          cleanup (id :: acc) rest
  in
  t.active <- cleanup [] t.active;
  if t.active = [] then
    None
  else begin
    let all_zero =
      List.for_all (fun id -> (get_node t id).remaining <= 0) t.active
    in
    if all_zero then
      List.iter (fun id ->
        let node = get_node t id in
        node.remaining <- node.weight
      ) t.active;

    let rec pick prefix = function
      | [] -> None
      | id :: rest ->
          let node = get_node t id in
          if node.remaining > 0 then begin
            let batch = Queue.take node.queue in
            node.remaining <- node.remaining - 1;
            let new_active =
              if Queue.is_empty node.queue then
                List.rev_append prefix rest
              else
                List.rev_append prefix (rest @ [id])
            in
            t.active <- new_active;
            Some batch
          end else
            pick (id :: prefix) rest
    in
    match pick [] t.active with
    | Some batch -> Some batch
    | None ->
        List.iter (fun id ->
          let node = get_node t id in
          node.remaining <- node.weight
        ) t.active;
        pick [] t.active
  end
