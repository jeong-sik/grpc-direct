import os
from concurrent import futures

import grpc

import echo_pb2
import echo_pb2_grpc


class EchoServicer(echo_pb2_grpc.EchoServiceServicer):
    def Echo(self, request, context):
        return echo_pb2.EchoResponse(message=request.message)


def serve() -> None:
    port = int(os.environ.get("PORT", "50099"))
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=32))
    echo_pb2_grpc.add_EchoServiceServicer_to_server(EchoServicer(), server)
    server.add_insecure_port(f"[::]:{port}")
    server.start()
    print(f"python grpcio echo server on :{port}")
    server.wait_for_termination()


if __name__ == "__main__":
    serve()
