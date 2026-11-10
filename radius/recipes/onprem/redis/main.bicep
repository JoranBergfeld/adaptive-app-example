extension kubernetes with {
  kubeConfig: ''
  namespace: context.runtime.kubernetes.namespace
} as kubernetes

@description('Radius-provided information about the resource and its Environment.')
param context object

var resourceName = context.resource.name
var namespace = context.runtime.kubernetes.namespace
var port = 6379
var labels = {
  'app.kubernetes.io/name': resourceName
}

resource redis 'apps/Deployment@v1' = {
  metadata: {
    name: resourceName
    namespace: namespace
    labels: labels
  }
  spec: {
    replicas: 1
    strategy: {
      type: 'Recreate'
    }
    selector: {
      matchLabels: labels
    }
    template: {
      metadata: {
        labels: labels
      }
      spec: {
        containers: [
          {
            name: 'redis'
            image: 'redis:7.4.2-alpine'
            args: [
              '--appendonly'
              'no'
              '--save'
              ''
            ]
            ports: [
              {
                containerPort: port
              }
            ]
            resources: {
              requests: {
                cpu: '25m'
                memory: '64Mi'
              }
              limits: {
                memory: '128Mi'
              }
            }
          }
        ]
      }
    }
  }
}

resource service 'core/Service@v1' = {
  metadata: {
    name: resourceName
    namespace: namespace
    labels: labels
  }
  spec: {
    type: 'ClusterIP'
    selector: labels
    ports: [
      {
        port: port
        targetPort: port
      }
    ]
  }
}

output result object = {
  resources: [
    '/planes/kubernetes/local/namespaces/${namespace}/providers/core/Service/${service.metadata.name}'
    '/planes/kubernetes/local/namespaces/${namespace}/providers/apps/Deployment/${redis.metadata.name}'
  ]
  values: {
    host: '${resourceName}.${namespace}.svc.cluster.local'
    port: port
  }
}
