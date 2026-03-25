(** gRPC Client using Eio and h2.

    This facade re-exports {!Client_config}, {!Client_connection}, and
    {!Client_streaming} so that the public API remains unchanged:
    [Client.connect], [Client.call_unary], [Client.Credentials], etc. *)

include Client_config
include Client_connection
include Client_streaming
