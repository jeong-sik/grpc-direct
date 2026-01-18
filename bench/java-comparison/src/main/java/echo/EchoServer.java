package echo;

import io.grpc.Server;
import io.grpc.ServerBuilder;
import io.grpc.stub.StreamObserver;

public final class EchoServer {
    private static final class EchoServiceImpl extends EchoServiceGrpc.EchoServiceImplBase {
        @Override
        public void echo(EchoRequest request, StreamObserver<EchoResponse> responseObserver) {
            EchoResponse response = EchoResponse.newBuilder()
                .setMessage(request.getMessage())
                .build();
            responseObserver.onNext(response);
            responseObserver.onCompleted();
        }
    }

    public static void main(String[] args) throws Exception {
        int port = 50099;
        String envPort = System.getenv("PORT");
        if (envPort != null && !envPort.isBlank()) {
            port = Integer.parseInt(envPort);
        }

        Server server = ServerBuilder.forPort(port)
            .addService(new EchoServiceImpl())
            .build()
            .start();

        System.out.println("grpc-java echo server on :" + port);
        server.awaitTermination();
    }
}
