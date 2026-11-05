using Azure.Identity;
using Azure.Messaging.ServiceBus;
using ServiceBusPipeline;

var builder = WebApplication.CreateBuilder(args);

var clientOptions = new ServiceBusClientOptions
{
    TransportType = ServiceBusTransportType.AmqpTcp,
    RetryOptions = new ServiceBusRetryOptions
    {
        Mode = ServiceBusRetryMode.Exponential,
        MaxRetries = 5,
        Delay = TimeSpan.FromMilliseconds(800),
        MaxDelay = TimeSpan.FromSeconds(30)
    }
};

var connection = builder.Configuration["SERVICEBUS_CONNECTION"];
var fqdn = builder.Configuration["SERVICEBUS_FQDN"];
if (string.IsNullOrWhiteSpace(connection) && string.IsNullOrWhiteSpace(fqdn))
    throw new InvalidOperationException("Set SERVICEBUS_CONNECTION or SERVICEBUS_FQDN.");

builder.Services.AddSingleton(_ => string.IsNullOrWhiteSpace(connection)
    ? new ServiceBusClient(fqdn, new DefaultAzureCredential(), clientOptions)
    : new ServiceBusClient(connection, clientOptions));
builder.Services.AddSingleton<Counters>();
builder.Services.AddSingleton<Publisher>();
if (builder.Configuration.GetValue("CONSUMER_ENABLED", true))
    builder.Services.AddHostedService<ConsumerService>();

var app = builder.Build();

app.MapGet("/health", (Counters c) =>
    builder.Configuration.GetValue("CONSUMER_ENABLED", true) && !c.ConsumerRunning
        ? Results.Json(new { status = "starting" }, statusCode: 503)
        : Results.Ok(new { status = "ok" }));

app.MapGet("/metrics", (Counters c) => Results.Ok(c.Snapshot()));

app.MapPost("/publish", async (int count, double? failRate, Publisher publisher, CancellationToken ct) =>
{
    if (count is < 1 or > 100_000) return Results.BadRequest(new { error = "count must be 1..100000" });
    var sent = await publisher.PublishAsync(count, failRate ?? 0, ct);
    return Results.Ok(new { sent });
});

app.Run();

public partial class Program { }
