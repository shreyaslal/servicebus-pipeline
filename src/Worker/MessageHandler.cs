using System.Text.Json;

namespace ServiceBusPipeline;

public sealed class MessageHandler
{
    private readonly Func<OrderMessage, CancellationToken, Task> _work;
    private readonly int _maxDeliveryCount;

    public MessageHandler(Func<OrderMessage, CancellationToken, Task> work, int maxDeliveryCount)
    {
        _work = work;
        _maxDeliveryCount = maxDeliveryCount;
    }

    public async Task<HandlingResult> HandleAsync(string body, int deliveryCount, CancellationToken cancellationToken)
    {
        OrderMessage? order;
        try
        {
            order = JsonSerializer.Deserialize<OrderMessage>(body, Json.Options);
        }
        catch (JsonException)
        {
            return new HandlingResult(Disposition.DeadLetter, "MalformedJson");
        }

        if (order is null || string.IsNullOrWhiteSpace(order.Item) || order.Quantity <= 0)
        {
            return new HandlingResult(Disposition.DeadLetter, "InvalidOrder");
        }

        try
        {
            await _work(order, cancellationToken);
            return new HandlingResult(Disposition.Complete);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception)
        {
            return deliveryCount >= _maxDeliveryCount
                ? new HandlingResult(Disposition.DeadLetter, "MaxDeliveryAttemptsExceeded")
                : new HandlingResult(Disposition.Retry);
        }
    }
}
