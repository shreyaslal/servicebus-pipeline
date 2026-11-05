namespace ServiceBusPipeline;

public sealed class Counters
{
    private long _published, _completed, _retried, _deadLettered;
    public volatile bool ConsumerRunning;

    public void Published(int n) => Interlocked.Add(ref _published, n);
    public void Completed() => Interlocked.Increment(ref _completed);
    public void Retried() => Interlocked.Increment(ref _retried);
    public void DeadLettered() => Interlocked.Increment(ref _deadLettered);

    public object Snapshot() => new
    {
        published = Interlocked.Read(ref _published),
        completed = Interlocked.Read(ref _completed),
        retried = Interlocked.Read(ref _retried),
        deadLettered = Interlocked.Read(ref _deadLettered),
        consumerRunning = ConsumerRunning
    };
}
