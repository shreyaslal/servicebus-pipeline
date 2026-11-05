# Service Bus Pipeline

A C# worker that publishes to and consumes from an Azure Service Bus queue, deployed to Azure Container Apps with Bicep, a GitHub Actions pipeline, and queue-depth autoscaling (KEDA).

```
POST /publish ──► Service Bus queue "orders" ──► Consumer (async processor, 16 concurrent)
                         │                          ├─ success        → Complete
                         │                          ├─ transient fail → Abandon → redelivered
                         ▼                          └─ poison / 5th failure → Dead-letter queue
                  KEDA scales replicas 1..10 on active message count
```

## What it demonstrates

| Area | Implementation |
| --- | --- |
| Async consumer | `ServiceBusProcessor`, manual settlement, 16 concurrent calls per replica |
| Retries | SDK exponential retry for transport errors; abandon-and-redeliver for handler failures |
| Dead-lettering | Malformed or invalid messages dead-lettered at once; handler failures dead-lettered after `maxDeliveryCount = 5` |
| Infrastructure as code | `infra/main.bicep`: namespace, queue, ACR, Log Analytics, Container Apps environment, app |
| Pipeline | build, test, two-stage deploy, `/health` check (`.github/workflows/ci-cd.yml`) |
| Autoscaling | KEDA `azure-servicebus` rule, target 20 messages per replica, 1..10 replicas |
| Tests | `dotnet test`: 8 tests on the retry and dead-letter decision logic |

## Run the tests

```bash
dotnet test
```

## Deploy

1. Create a GitHub repo and push this folder.
2. Create an Entra app registration with a federated credential for the repo (GitHub OIDC) and give it `Contributor` and `User Access Administrator` on a subscription or resource group scope.
3. In GitHub, set secrets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, variables `PREFIX` (3-12 lowercase letters or digits), `RESOURCE_GROUP`, optional `LOCATION`, and an environment named `azure`.
4. Push to `main`. The pipeline tests, provisions, builds the image in ACR, deploys the app, and checks `/health`.

## Measure it

```bash
scripts/measure.sh <resource-group> <prefix> 5000
```

Then open Azure Portal, the Container App, **Metrics**, add `Replica Count`. In a second chart on the Service Bus namespace add `Active Messages`. Set the time range to the test window and screenshot both.

## Results

Fill this in from your own run. Do not use numbers you did not measure.

| Metric | Value |
| --- | --- |
| Messages | _from measure.sh_ |
| Drain time | _from measure.sh_ |
| Throughput | _from measure.sh_ |
| Peak replicas | _from measure.sh_ |
| First scale-up | _from measure.sh_ |

![Replica count and active messages](docs/scale-up.png)

## Design notes and trade-offs

- The app and the KEDA rule use a queue-scoped shared access key, held as a Container Apps secret. A managed identity would remove the key; the app already supports it (`SERVICEBUS_FQDN` with `DefaultAzureCredential`).
- Processing is simulated with `PROCESSING_DELAY_MS` (default 200 ms) so a backlog builds and autoscaling is observable. Send `?failRate=0.05` to `/publish` to see messages reach the dead-letter queue.
- `/metrics` counters are per replica and in memory. Use Service Bus metrics for fleet-wide numbers.
- Delivery is at least once. Handlers must be idempotent.

## Clean up

```bash
az group delete -n <resource-group> --yes
```
