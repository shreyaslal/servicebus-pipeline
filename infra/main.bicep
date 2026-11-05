targetScope = 'resourceGroup'

@description('Short unique prefix, 3-12 lowercase letters/digits.')
@minLength(3)
@maxLength(12)
param prefix string

param location string = resourceGroup().location

@description('Public container image, e.g. ghcr.io/<owner>/servicebus-worker:<tag>.')
param image string

@minValue(1)
param minReplicas int = 1

@minValue(1)
param maxReplicas int = 10

@description('KEDA target: average active messages per replica.')
param messagesPerReplica int = 20

var queueName = 'orders'
var uniq = uniqueString(resourceGroup().id, prefix)

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-logs-${uniq}'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource sbNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: '${prefix}-sb-${uniq}'
  location: location
  sku: { name: 'Standard', tier: 'Standard' }
}

resource queue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: sbNamespace
  name: queueName
  properties: {
    lockDuration: 'PT1M'
    maxDeliveryCount: 5
    deadLetteringOnMessageExpiration: true
    defaultMessageTimeToLive: 'PT1H'
  }
}

resource queueRule 'Microsoft.ServiceBus/namespaces/queues/authorizationRules@2022-10-01-preview' = {
  parent: queue
  name: 'app'
  properties: {
    rights: ['Listen', 'Send', 'Manage']
  }
}

// Express environments do not support custom (KEDA) scale rules, so the mode is pinned explicitly.
resource env 'Microsoft.App/managedEnvironments@2026-07-01' = {
  name: '${prefix}-wp-env'
  location: location
  properties: {
    environmentMode: 'WorkloadProfiles'
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

resource worker 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${prefix}-worker'
  location: location
  properties: {
    managedEnvironmentId: env.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
      }
      secrets: [
        {
          name: 'sb-conn'
          value: queueRule.listKeys().primaryConnectionString
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'worker'
          image: image
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'SERVICEBUS_CONNECTION', secretRef: 'sb-conn' }
            { name: 'QUEUE_NAME', value: queueName }
            { name: 'PROCESSING_DELAY_MS', value: '200' }
            { name: 'MAX_CONCURRENT_CALLS', value: '16' }
          ]
          probes: [
            {
              type: 'Liveness'
              httpGet: { path: '/health', port: 8080 }
              initialDelaySeconds: 10
              periodSeconds: 15
            }
            {
              type: 'Readiness'
              httpGet: { path: '/health', port: 8080 }
              initialDelaySeconds: 5
              periodSeconds: 10
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'queue-depth'
            custom: {
              type: 'azure-servicebus'
              metadata: {
                queueName: queueName
                messageCount: string(messagesPerReplica)
              }
              auth: [
                { secretRef: 'sb-conn', triggerParameter: 'connection' }
              ]
            }
          }
        ]
      }
    }
  }
}

output serviceBusNamespace string = sbNamespace.name
output queueName string = queueName
output appName string = worker.name
output appFqdn string = worker.properties.configuration.ingress.fqdn
