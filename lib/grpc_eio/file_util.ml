(** File I/O utilities with resource safety.

    All functions guarantee that file handles are closed even when
    exceptions occur during reading. *)

(** Read entire file contents as a string.

    Uses [Fun.protect] to ensure the input channel is closed on exception.
    Raises [Sys_error] if the file cannot be opened. *)
let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
    let len = in_channel_length ic in
    really_input_string ic len)
;;
