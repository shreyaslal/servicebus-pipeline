using System.Text.Json;
using Azure.Messaging.ServiceBus;

namespace ServiceBusPipeline;

public sealed class Publisher
{
    private readonly ServiceBusSender _sender;
    private readonly Counters _counters;

    public Publisher(ServiceBusClient client, IConfiguration config, Counters counters)
    {
        _sender = client.CreateSender(config["QUEUE_NAME"] ?? "orders");
        _counters = counters;
    }

    public async Task<int> PublishAsync(int count, double failRate, CancellationToken ct)
    {
        var sent = 0;
        var batch = await _sender.CreateMessageBatchAsync(ct);
        for (var i = 0; i < count; i++)
        {
            var item = Random.Shared.NextDouble() < failRate ? "fail" : "widget";
            var order = new OrderMessage(Guid.NewGuid(), item, 1, DateTimeOffset.UtcNow);
            var message = new ServiceBusMessage(JsonSerializer.Serialize(order, Json.Options)) { MessageId = order.Id.ToString() };

            if (!batch.TryAddMessage(message))
            {
                await _sender.SendMessagesAsync(batch, ct);
                sent += batch.Count;
                batch.Dispose();
                batch = await _sender.CreateMessageBatchAsync(ct);
                if (!batch.TryAddMessage(message)) throw new InvalidOperationException("Message too large for an empty batch");
            }
        }

        if (batch.Count > 0)
        {
            await _sender.SendMessagesAsync(batch, ct);
            sent += batch.Count;
        }
        batch.Dispose();
        _counters.Published(sent);
        return sent;
    }
}
