(** File I/O utilities with resource safety. *)

(** Read entire file contents as a string.

    The input channel is always closed, even if an exception occurs during
    reading (e.g. [really_input_string] raises [End_of_file]).

    @raise Sys_error if the file cannot be opened *)
val read_file : string -> string
