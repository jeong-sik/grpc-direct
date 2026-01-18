cmake_minimum_required(VERSION 3.15)
project(grpc_cpp_echo LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Protobuf CONFIG REQUIRED)
find_package(gRPC CONFIG REQUIRED)

set(PROTO_FILE "${CMAKE_CURRENT_SOURCE_DIR}/echo.proto")

get_target_property(PROTOBUF_PROTOC protobuf::protoc LOCATION)
get_target_property(GRPC_CPP_PLUGIN_EXECUTABLE gRPC::grpc_cpp_plugin LOCATION)

set(PROTO_SRCS "${CMAKE_CURRENT_BINARY_DIR}/echo.pb.cc")
set(PROTO_HDRS "${CMAKE_CURRENT_BINARY_DIR}/echo.pb.h")
set(GRPC_SRCS "${CMAKE_CURRENT_BINARY_DIR}/echo.grpc.pb.cc")
set(GRPC_HDRS "${CMAKE_CURRENT_BINARY_DIR}/echo.grpc.pb.h")

add_custom_command(
  OUTPUT "${PROTO_SRCS}" "${PROTO_HDRS}" "${GRPC_SRCS}" "${GRPC_HDRS}"
  COMMAND "${PROTOBUF_PROTOC}"
  ARGS --grpc_out "${CMAKE_CURRENT_BINARY_DIR}"
       --cpp_out "${CMAKE_CURRENT_BINARY_DIR}"
       -I "${CMAKE_CURRENT_SOURCE_DIR}"
       --plugin=protoc-gen-grpc="${GRPC_CPP_PLUGIN_EXECUTABLE}"
       "${PROTO_FILE}"
  DEPENDS "${PROTO_FILE}"
)

add_executable(echo_server echo_server.cc ${PROTO_SRCS} ${GRPC_SRCS})

target_include_directories(echo_server PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")

target_link_libraries(echo_server
  gRPC::grpc++
  protobuf::libprotobuf
)
