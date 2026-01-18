const grpc = require('@grpc/grpc-js');
const protoLoader = require('@grpc/proto-loader');
const path = require('path');

const port = process.env.PORT || '50099';
const PROTO_PATH = path.resolve(__dirname, '../../bench/go-comparison/echo.proto');

const packageDef = protoLoader.loadSync(PROTO_PATH, {
  keepCase: true,
  longs: String,
  enums: String,
  defaults: true,
  oneofs: true,
});

const echoPkg = grpc.loadPackageDefinition(packageDef).echo;

function Echo(call, callback) {
  callback(null, { message: call.request.message });
}

function main() {
  const server = new grpc.Server();
  server.addService(echoPkg.EchoService.service, { Echo });
  server.bindAsync(`0.0.0.0:${port}`,
    grpc.ServerCredentials.createInsecure(),
    () => {
      server.start();
      console.log(`node grpc-js echo server on :${port}`);
    }
  );
}

main();
