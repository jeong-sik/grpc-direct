(lang dune 3.0)
(name grpc-direct)
(version 0.1.0)

(generate_opam_files true)

(license BSD-3-Clause)
(authors "Jeong-Sik Yun <vincent.dev@kidsnote.com>")
(maintainers "Jeong-Sik Yun <vincent.dev@kidsnote.com>")
(source (github jeong-sik/grpc-direct))
(documentation "https://github.com/jeong-sik/grpc-direct")

(package
 (name grpc-direct-core)
 (synopsis "Pure OCaml gRPC core library")
 (description "Core gRPC functionality: message framing, compression (gzip, zstd), status codes.
Zero dependencies on runtime systems - works with Eio, Lwt, or Async.")
 (depends
  (ocaml (>= 5.1))
  (dune (>= 3.0))
  (decompress (>= 1.5.0))
  (bigstringaf (>= 0.9.0))
  (zstd (>= 0.4))))

(package
 (name grpc-direct)
 (synopsis "Production-ready gRPC for OCaml 5.x with direct-style Eio effects")
 (description "Modern gRPC for OCaml 5 using direct-style effects with Eio.
Features: Health Check, Retry Policy, Prometheus Metrics, Server Reflection,
Connection Pool, Load Balancer, Native TLS. Zero Lwt/Async dependencies.")
 (depends
  (ocaml (>= 5.1))
  (dune (>= 3.0))
  (grpc-direct-core (= :version))
  (eio (>= 1.0))
 (eio_main (>= 1.0))
 (h2-eio (>= 0.13.0))
 (digestif (>= 1.1.4))
 ca-certs
 (tls-eio (>= 1.0))
 (mirage-crypto-rng-eio (>= 1.0))))

(package
 (name grpc-direct-protoc)
 (synopsis "Protoc plugin for grpc-direct")
 (description "Generate OCaml code from .proto files for grpc-direct")
 (depends
  (ocaml (>= 5.1))
  (dune (>= 3.0))
  (ocaml-protoc-plugin (>= 6.0))))
