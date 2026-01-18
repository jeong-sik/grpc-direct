//go:build !interop_client
// +build !interop_client

// Go gRPC Echo Server for fair comparison with grpc-eio

package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"

	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"
)

var port = flag.Int("port", 50099, "The server port")

// Simple echo service - echoes back the request
type echoServer struct {
	UnimplementedEchoServiceServer
}

func (s *echoServer) Echo(ctx context.Context, req *EchoRequest) (*EchoResponse, error) {
	return &EchoResponse{Message: req.Message}, nil
}

func main() {
	flag.Parse()

	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", *port))
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	s := grpc.NewServer()
	RegisterEchoServiceServer(s, &echoServer{})
	reflection.Register(s)

	fmt.Printf("\n╔═══════════════════════════════════════════════════════╗\n")
	fmt.Printf("║       grpc-go Echo Server (for comparison)            ║\n")
	fmt.Printf("╚═══════════════════════════════════════════════════════╝\n\n")
	fmt.Printf("Server listening on port %d\n", *port)
	fmt.Printf("Press Ctrl+C to stop\n\n")

	if err := s.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
