extension radius

@description('The Radius Environment ID. Injected by rad deploy.')
param environment string

@description('Container registry path, for example ghcr.io/owner/adaptive-app-example.')
param imageRegistry string

@description('Immutable application image tag, normally the Git commit SHA.')
param imageTag string

@secure()
@description('Password used by the PostgreSQL instance in this environment.')
param databasePassword string

@description('Deploy the API and storefront after the backing services are ready.')
param deployWorkload bool = true

var environmentName = last(split(environment, '/'))
var isAro = environmentName == 'aro'
var clusterName = isAro ? 'aro-demo' : 'onprem-demo'
var platform = isAro ? 'Azure Red Hat OpenShift' : 'On-premises-style (Azure Red Hat OpenShift)'
var databaseServiceName = isAro ? 'Azure Database for PostgreSQL' : 'CloudNativePG'
var cacheServiceName = isAro ? 'Azure Managed Redis' : 'Redis on Kubernetes'
var secretsServiceName = isAro ? 'Dapr Azure Key Vault' : 'Dapr Kubernetes Secret Store'

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'shop'
  properties: {
    environment: environment
  }
}

resource database 'Radius.Data/postgreSqlDatabases@2025-08-01-preview' = {
  name: 'shop-postgresql'
  properties: {
    environment: environment
    application: app.id
    size: 'S'
    database: 'shop'
    username: 'shopadmin'
    password: databasePassword
  }
}

resource cache 'Radius.Data/redisCaches@2025-08-01-preview' = {
  name: 'shop-cache'
  properties: {
    environment: environment
    application: app.id
    size: 'S'
  }
}

resource api 'Radius.Compute/containers@2025-08-01-preview' = if (deployWorkload) {
  name: 'shop-api'
  properties: {
    environment: environment
    application: app.id
    containers: {
      api: {
        image: '${imageRegistry}/shop-api:${imageTag}'
        ports: {
          http: {
            containerPort: 8080
            protocol: 'TCP'
          }
        }
        env: {
          DATABASE_HOST: {
            value: database.properties.host
          }
          DATABASE_PORT: {
            value: '5432'
          }
          DATABASE_NAME: {
            value: 'shop'
          }
          DATABASE_USER: {
            value: 'shopadmin'
          }
          DATABASE_SSLMODE: {
            value: 'require'
          }
          DATABASE_PASSWORD_SECRET_NAME: {
            value: isAro ? 'shop-db-password' : 'shop-db-credentials'
          }
          DATABASE_PASSWORD_SECRET_KEY: {
            value: isAro ? 'shop-db-password' : 'password'
          }
          DAPR_HTTP_ENDPOINT: {
            value: 'http://localhost:3500'
          }
          DAPR_STATE_STORE: {
            value: 'statestore'
          }
          DAPR_SECRET_STORE: {
            value: isAro ? 'secretstore' : 'kubernetes'
          }
          SHOP_ENVIRONMENT: {
            value: environmentName
          }
          SHOP_CLUSTER_NAME: {
            value: clusterName
          }
          SHOP_PLATFORM: {
            value: platform
          }
          DATABASE_SERVICE_NAME: {
            value: databaseServiceName
          }
          CACHE_SERVICE_NAME: {
            value: cacheServiceName
          }
          SECRETS_SERVICE_NAME: {
            value: secretsServiceName
          }
          IMAGE_REGISTRY: {
            value: 'GitHub Container Registry'
          }
        }
        resources: {
          requests: {
            cpu: '100m'
            memoryInMib: 256
          }
          limits: {
            cpu: '500m'
            memoryInMib: 512
          }
        }
      }
    }
    connections: {
      postgresql: {
        source: database.id
      }
      redis: {
        source: cache.id
      }
    }
    extensions: [
      {
        kind: 'daprSidecar'
        appId: 'shop-api'
        appPort: 8080
      }
      {
        kind: 'manualScaling'
        replicas: 1
      }
    ]
  }
}

resource web 'Radius.Compute/containers@2025-08-01-preview' = if (deployWorkload) {
  name: 'shop-web'
  properties: {
    environment: environment
    application: app.id
    containers: {
      web: {
        image: '${imageRegistry}/shop-web:${imageTag}'
        ports: {
          http: {
            containerPort: 8080
            protocol: 'TCP'
          }
        }
        env: {
          SHOP_API_BASE_URL: {
            value: ''
          }
          SHOP_API_ORIGIN: {
            value: 'http://shop-api-api:8080'
          }
        }
        resources: {
          requests: {
            cpu: '50m'
            memoryInMib: 64
          }
          limits: {
            cpu: '250m'
            memoryInMib: 128
          }
        }
      }
    }
    connections: {
      api: {
        source: api.id
      }
    }
    extensions: [
      {
        kind: 'manualScaling'
        replicas: 1
      }
    ]
  }
}
