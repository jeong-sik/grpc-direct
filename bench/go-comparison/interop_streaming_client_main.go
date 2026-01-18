//go:build interop_client
// +build interop_client

package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/encoding/gzip"
	"google.golang.org/grpc/status"
)

var (
	addr         = flag.String("addr", "127.0.0.1:50051", "Server address")
	enableTLS    = flag.Bool("tls", false, "Enable TLS")
	caFile       = flag.String("ca", "", "CA cert file (PEM)")
	serverName   = flag.String("server-name", "localhost", "TLS server name")
	enableGzip   = flag.Bool("gzip", false, "Enable gzip compression")
	message      = flag.String("message", "hello", "Message payload")
	streamCount  = flag.Int("stream-count", 100, "Expected server-streaming count")
	cancelAfter  = flag.Int("cancel-after", 5, "Cancel bidi after N responses")
	goawayWait   = flag.Bool("wait-goaway", false, "Wait for server shutdown (expects connection close)")
)

func dial() (*grpc.ClientConn, error) {
	opts := []grpc.DialOption{}
	if !*enableTLS {
		opts = append(opts, grpc.WithTransportCredentials(insecure.NewCredentials()))
	} else {
		if *caFile == "" {
			return nil, fmt.Errorf("--ca is required when --tls is set")
		}
		caPEM, err := os.ReadFile(*caFile)
		if err != nil {
			return nil, err
		}
		roots := x509.NewCertPool()
		if !roots.AppendCertsFromPEM(caPEM) {
			return nil, fmt.Errorf("failed to parse CA cert")
		}
		creds := credentials.NewTLS(&tls.Config{
			RootCAs:    roots,
			ServerName: *serverName,
		})
		opts = append(opts, grpc.WithTransportCredentials(creds))
	}
	if *enableGzip {
		opts = append(opts, grpc.WithDefaultCallOptions(grpc.UseCompressor(gzip.Name)))
	}
	return grpc.Dial(*addr, opts...)
}

func testUnary(client InteropServiceClient) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	resp, err := client.Unary(ctx, &Payload{Message: *message})
	if err != nil {
		return err
	}
	log.Printf("unary resp: %s", resp.Message)
	return nil
}

func testServerStreaming(client InteropServiceClient) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	stream, err := client.ServerStream(ctx, &Payload{Message: *message})
	if err != nil {
		return err
	}
	count := 0
	for {
		resp, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		_ = resp.Message
		count++
	}
	log.Printf("server streaming recv count: %d", count)
	if count == 0 {
		return fmt.Errorf("server streaming returned 0 messages")
	}
	if count != *streamCount {
		log.Printf("server streaming count mismatch: expected %d, got %d", *streamCount, count)
	}
	return nil
}

func testClientStreaming(client InteropServiceClient) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	stream, err := client.ClientStream(ctx)
	if err != nil {
		return err
	}
	for i := 0; i < 3; i++ {
		msg := fmt.Sprintf("%s-%d", *message, i)
		if err := stream.Send(&Payload{Message: msg}); err != nil {
			return err
		}
	}
	resp, err := stream.CloseAndRecv()
	if err != nil {
		return err
	}
	log.Printf("client streaming resp: %s", resp.Message)
	return nil
}

func testBidiStreaming(client InteropServiceClient) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	stream, err := client.BidiStream(ctx)
	if err != nil {
		return err
	}

	for i := 0; i < 3; i++ {
		msg := fmt.Sprintf("%s-%d", *message, i)
		if err := stream.Send(&Payload{Message: msg}); err != nil {
			return err
		}
	}
	if err := stream.Send(&Payload{Message: "__END__"}); err != nil {
		return err
	}
	if err := stream.CloseSend(); err != nil {
		return err
	}

	count := 0
	for {
		resp, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		count++
		log.Printf("bidi resp: %s", resp.Message)
	}
	if count == 0 {
		return fmt.Errorf("bidi streaming returned 0 messages")
	}
	return nil
}

func testCancelBidi(client InteropServiceClient) error {
	ctx, cancel := context.WithCancel(context.Background())
	stream, err := client.BidiStream(ctx)
	if err != nil {
		cancel()
		return err
	}

	for i := 0; i < 50; i++ {
		msg := fmt.Sprintf("%s-%d", *message, i)
		if err := stream.Send(&Payload{Message: msg}); err != nil {
			cancel()
			return err
		}
	}

	recvCount := 0
	for {
		_, err := stream.Recv()
		if err != nil {
			st, ok := status.FromError(err)
			if ok && (st.Code() == codes.Canceled || st.Code() == codes.Unavailable) {
				log.Printf("bidi cancel expected: %s", st.Code())
				return nil
			}
			if err == io.EOF {
				return fmt.Errorf("bidi cancel got EOF without cancel")
			}
			return err
		}
		recvCount++
		if recvCount >= *cancelAfter {
			cancel()
			return nil
		}
	}
}

func testGoawayWait(client InteropServiceClient) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	stream, err := client.ServerStream(ctx, &Payload{Message: *message})
	if err != nil {
		return err
	}
	for {
		_, err := stream.Recv()
		if err != nil {
			log.Printf("goaway/close observed: %v", err)
			return nil
		}
	}
}

func main() {
	flag.Parse()

	conn, err := dial()
	if err != nil {
		log.Fatalf("dial failed: %v", err)
	}
	defer conn.Close()

	client := NewInteropServiceClient(conn)

	if err := testUnary(client); err != nil {
		log.Fatalf("unary failed: %v", err)
	}
	if err := testServerStreaming(client); err != nil {
		log.Fatalf("server streaming failed: %v", err)
	}
	if err := testClientStreaming(client); err != nil {
		log.Fatalf("client streaming failed: %v", err)
	}
	if err := testBidiStreaming(client); err != nil {
		log.Fatalf("bidi streaming failed: %v", err)
	}
	if err := testCancelBidi(client); err != nil {
		log.Fatalf("bidi cancel failed: %v", err)
	}
	if *goawayWait {
		if err := testGoawayWait(client); err != nil {
			log.Fatalf("goaway wait failed: %v", err)
		}
	}

	log.Printf("interop streaming suite complete")
}
