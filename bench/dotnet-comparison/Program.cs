using Echo;
using Grpc.Core;
using Microsoft.AspNetCore.Server.Kestrel.Core;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddGrpc();

builder.WebHost.ConfigureKestrel(options =>
{
    options.ListenAnyIP(50099, listenOptions =>
    {
        listenOptions.Protocols = HttpProtocols.Http2;
    });
});

var app = builder.Build();

app.MapGrpcService<EchoServiceImpl>();

app.MapGet("/", () => "grpc-dotnet echo server");

app.Run();

class EchoServiceImpl : EchoService.EchoServiceBase
{
    public override Task<EchoResponse> Echo(EchoRequest request, ServerCallContext context)
    {
        return Task.FromResult(new EchoResponse { Message = request.Message });
    }
}
