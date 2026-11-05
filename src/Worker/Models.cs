using System.Text.Json;

namespace ServiceBusPipeline;

public sealed record OrderMessage(Guid Id, string Item, int Quantity, DateTimeOffset CreatedAt);

public enum Disposition { Complete, Retry, DeadLetter }

public sealed record HandlingResult(Disposition Disposition, string? Reason = null);

public static class Json
{
    public static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web);
}
