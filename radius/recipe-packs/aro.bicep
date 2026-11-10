extension radius

resource aroRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'shop-aro'
  properties: {
    recipes: {
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/containers:latest'
      }
      'Radius.Data/postgreSqlDatabases': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/db-for-postgre-sql/flexible-server:0.15.2'
        parameters: {
          name: 'pg-{{context.azure.resourceNameHash}}'
          administratorLogin: '{{context.resource.properties.username}}'
          administratorLoginPassword: '{{context.resource.properties.password}}'
          skuName: '{{context.resource.properties.size == "S" ? "Standard_B1ms" : "Standard_D2ds_v5"}}'
          tier: '{{context.resource.properties.size == "S" ? "Burstable" : "GeneralPurpose"}}'
          version: '17'
          availabilityZone: -1
          highAvailability: 'Disabled'
          geoRedundantBackup: 'Disabled'
          storageSizeGB: 32
          publicNetworkAccess: 'Enabled'
          firewallRules: [
            {
              name: 'AllowAzureServices'
              startIpAddress: '0.0.0.0'
              endIpAddress: '0.0.0.0'
            }
          ]
          databases: [
            {
              name: '{{context.resource.properties.database}}'
            }
          ]
          configurations: [
            {
              name: 'require_secure_transport'
              source: 'user-override'
              value: 'ON'
            }
          ]
          enableTelemetry: false
          lock: {
            kind: 'None'
          }
        }
        outputs: {
          host: 'fqdn'
        }
      }
      'Radius.Data/redisCaches': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/cache/redis-enterprise:0.5.1'
        parameters: {
          name: 'amr-{{context.azure.resourceNameHash}}'
          skuName: 'Balanced_B0'
          highAvailability: 'Disabled'
          publicNetworkAccess: 'Enabled'
          database: {
            name: 'default'
            accessKeysAuthentication: 'Enabled'
          }
          enableTelemetry: false
          lock: {
            kind: 'None'
          }
        }
        outputs: {
          host: 'hostName'
          port: 'port'
          secrets: {
            accessKey: 'primaryAccessKey'
            url: 'primaryConnectionString'
          }
        }
      }
    }
  }
}
