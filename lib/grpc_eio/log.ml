let emit level msg = Eio.traceln "[%s] %s" level msg
let debug fmt = Printf.ksprintf (emit "DEBUG") fmt
let info fmt = Printf.ksprintf (emit "INFO") fmt
let warn fmt = Printf.ksprintf (emit "WARN") fmt
let error fmt = Printf.ksprintf (emit "ERROR") fmt
