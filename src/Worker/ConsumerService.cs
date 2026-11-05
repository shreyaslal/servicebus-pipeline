using Azure.Messaging.ServiceBus;

namespace ServiceBusPipeline;

public sealed class ConsumerService : BackgroundService
{
    private readonly ServiceBusClient _client;
    private readonly IConfiguration _config;
    private readonly Counters _counters;
    private readonly ILogger<ConsumerService> _logger;

    public ConsumerService(ServiceBusClient client, IConfiguration config, Counters counters, ILogger<ConsumerService> logger)
    {
        _client = client;
        _config = config;
        _counters = counters;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var queue = _config["QUEUE_NAME"] ?? "orders";
        var delayMs = _config.GetValue("PROCESSING_DELAY_MS", 200);
        var maxDelivery = _config.GetValue("MAX_DELIVERY_COUNT", 5);
        var concurrency = _config.GetValue("MAX_CONCURRENT_CALLS", 16);

        var handler = new MessageHandler(async (order, ct) =>
        {
            await Task.Delay(delayMs, ct);
            if (order.Item == "fail") throw new InvalidOperationException("Simulated processing failure");
        }, maxDelivery);

        await using var processor = _client.CreateProcessor(queue, new ServiceBusProcessorOptions
        {
            AutoCompleteMessages = false,
            MaxConcurrentCalls = concurrency,
            PrefetchCount = concurrency * 2
        });

        processor.ProcessMessageAsync += async args =>
        {
            var result = await handler.HandleAsync(args.Message.Body.ToString(), args.Message.DeliveryCount, args.CancellationToken);
            switch (result.Disposition)
            {
                case Disposition.Complete:
                    await args.CompleteMessageAsync(args.Message, args.CancellationToken);
                    _counters.Completed();
                    break;
                case Disposition.Retry:
                    await args.AbandonMessageAsync(args.Message, cancellationToken: args.CancellationToken);
                    _counters.Retried();
                    break;
                case Disposition.DeadLetter:
                    await args.DeadLetterMessageAsync(args.Message, result.Reason, cancellationToken: args.CancellationToken);
                    _counters.DeadLettered();
                    break;
            }
        };

        processor.ProcessErrorAsync += args =>
        {
            _logger.LogError(args.Exception, "Service Bus error from {Source} on {Entity}", args.ErrorSource, args.EntityPath);
            return Task.CompletedTask;
        };

        await processor.StartProcessingAsync(stoppingToken);
        _counters.ConsumerRunning = true;
        _logger.LogInformation("Consumer started on queue {Queue} with concurrency {Concurrency}", queue, concurrency);

        try { await Task.Delay(Timeout.Infinite, stoppingToken); }
        catch (OperationCanceledException) { }

        _counters.ConsumerRunning = false;
        await processor.StopProcessingAsync();
    }
}
