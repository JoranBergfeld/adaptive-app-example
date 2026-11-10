extension kubernetes with {
  kubeConfig: ''
  namespace: context.runtime.kubernetes.namespace
} as kubernetes

@description('Radius-provided information about the resource and its Environment.')
param context object

var resourceName = context.resource.name
var namespace = context.runtime.kubernetes.namespace
var username = context.resource.properties.username
var password = context.resource.properties.password
var database = context.resource.properties.database

resource credentials 'core/Secret@v1' = {
  metadata: {
    name: '${resourceName}-credentials'
    namespace: namespace
  }
  type: 'kubernetes.io/basic-auth'
  stringData: {
    username: username
    password: password
  }
}

resource cluster 'postgresql.cnpg.io/Cluster@v1' = {
  metadata: {
    name: resourceName
    namespace: namespace
  }
  spec: {
    instances: 1
    imageName: 'ghcr.io/cloudnative-pg/postgresql:17.6'
    bootstrap: {
      initdb: {
        database: database
        owner: username
        secret: {
          name: credentials.metadata.name
        }
      }
    }
    storage: {
      size: '1Gi'
    }
    resources: {
      requests: {
        memory: '256Mi'
      }
    }
  }
}

output result object = {
  resources: [
    '/planes/kubernetes/local/namespaces/${namespace}/providers/postgresql.cnpg.io/Cluster/${cluster.metadata.name}'
  ]
  values: {
    host: '${resourceName}-rw.${namespace}.svc.cluster.local'
    port: 5432
    database: database
  }
}
