#include <grpcpp/grpcpp.h>
#include "echo.grpc.pb.h"

#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>

using grpc::Server;
using grpc::ServerBuilder;
using grpc::ServerContext;
using grpc::Status;

class EchoServiceImpl final : public echo::EchoService::Service {
 public:
  Status Echo(ServerContext* context, const echo::EchoRequest* request,
              echo::EchoResponse* response) override {
    response->set_message(request->message());
    return Status::OK;
  }
};

int main() {
  const char* port_env = std::getenv("PORT");
  int port = port_env ? std::atoi(port_env) : 50099;
  std::string server_address = "0.0.0.0:" + std::to_string(port);

  EchoServiceImpl service;

  ServerBuilder builder;
  builder.AddListeningPort(server_address, grpc::InsecureServerCredentials());
  builder.RegisterService(&service);

  std::unique_ptr<Server> server(builder.BuildAndStart());
  std::cout << "grpc-cpp echo server on :" << port << std::endl;
  server->Wait();
  return 0;
}
