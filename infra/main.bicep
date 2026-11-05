targetScope = 'resourceGroup'

@description('Short unique prefix, 3-12 lowercase letters/digits.')
@minLength(3)
@maxLength(12)
param prefix string

param location string = resourceGroup().location

@description('Stage 1 creates shared infrastructure only. Stage 2 (true) also deploys the container app.')
param deployApp bool = false

@description('Full image reference, e.g. <acr>.azurecr.io/worker:<sha>. Required when deployApp is true.')
param image string = ''

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

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: '${prefix}acr${uniq}'
  location: location
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
}

resource pullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-pull-id'
  location: location
}

var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: acr
  name: guid(acr.id, pullIdentity.id, acrPullRoleId)
  properties: {
    principalId: pullIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
  }
}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${prefix}-env'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

resource worker 'Microsoft.App/containerApps@2024-03-01' = if (deployApp) {
  name: '${prefix}-worker'
  location: location
  dependsOn: [acrPull]
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${pullIdentity.id}': {} }
  }
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: pullIdentity.id
        }
      ]
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

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output serviceBusNamespace string = sbNamespace.name
output queueName string = queueName
output appName string = '${prefix}-worker'
output appFqdn string = deployApp ? worker.properties.configuration.ingress.fqdn : ''
