using System.Text.Json;
using ServiceBusPipeline;
using Xunit;

public class MessageHandlerTests
{
    private static string ValidBody(string item = "widget", int quantity = 1) =>
        JsonSerializer.Serialize(new OrderMessage(Guid.NewGuid(), item, quantity, DateTimeOffset.UtcNow), Json.Options);

    private static MessageHandler Handler(Func<OrderMessage, CancellationToken, Task>? work = null, int max = 5) =>
        new(work ?? ((_, _) => Task.CompletedTask), max);

    [Fact]
    public async Task ValidMessage_IsCompleted()
    {
        var result = await Handler().HandleAsync(ValidBody(), 1, CancellationToken.None);
        Assert.Equal(Disposition.Complete, result.Disposition);
    }

    [Fact]
    public async Task MalformedJson_IsDeadLetteredImmediately()
    {
        var result = await Handler().HandleAsync("{not json", 1, CancellationToken.None);
        Assert.Equal(Disposition.DeadLetter, result.Disposition);
        Assert.Equal("MalformedJson", result.Reason);
    }

    [Theory]
    [InlineData("", 1)]
    [InlineData("widget", 0)]
    [InlineData("widget", -3)]
    public async Task InvalidOrder_IsDeadLettered(string item, int quantity)
    {
        var result = await Handler().HandleAsync(ValidBody(item, quantity), 1, CancellationToken.None);
        Assert.Equal(Disposition.DeadLetter, result.Disposition);
        Assert.Equal("InvalidOrder", result.Reason);
    }

    [Fact]
    public async Task ProcessingFailure_BelowMaxDelivery_IsRetried()
    {
        var handler = Handler((_, _) => throw new InvalidOperationException("boom"));
        var result = await handler.HandleAsync(ValidBody(), 2, CancellationToken.None);
        Assert.Equal(Disposition.Retry, result.Disposition);
    }

    [Fact]
    public async Task ProcessingFailure_AtMaxDelivery_IsDeadLettered()
    {
        var handler = Handler((_, _) => throw new InvalidOperationException("boom"), max: 5);
        var result = await handler.HandleAsync(ValidBody(), 5, CancellationToken.None);
        Assert.Equal(Disposition.DeadLetter, result.Disposition);
        Assert.Equal("MaxDeliveryAttemptsExceeded", result.Reason);
    }

    [Fact]
    public async Task Cancellation_Propagates()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        var handler = Handler(async (_, ct) => await Task.Delay(1000, ct));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => handler.HandleAsync(ValidBody(), 1, cts.Token));
    }
}
