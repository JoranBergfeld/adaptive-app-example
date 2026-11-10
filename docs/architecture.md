# Architecture

## Request path

```mermaid
flowchart LR
  browser[Browser] --> afd[Azure Front Door]
  afd -->|only enabled origin| router[ARO router]
  router --> web[Shop storefront]
  web -->|same-origin /api proxy| api[FastAPI API]
  api --> dapr[Dapr sidecar]
  dapr --> redis[Cluster-local Redis]
  api -->|password from Dapr secret store| pg[Cluster PostgreSQL]
```

Front Door has one origin group and two origins, initially disabled until a
target has been deployed. `scripts/90-switch-traffic.sh` enables exactly one
origin and disables the other. The target's ARO route serves the storefront;
the storefront proxies `/api/*` to the API service so the browser uses one
origin.

## Platform placement

```mermaid
flowchart TB
  subgraph azure[Azure subscription]
    afd[Azure Front Door]
    subgraph targetA[Managed-services target: ARO]
      radA[Radius installation and aro environment]
      daprA[Dapr]
      apiA[Shop API and web]
      pgA[Azure Database for PostgreSQL]
      redisA[Azure Managed Redis]
      kv[Azure Key Vault]
      radA --> apiA
      apiA --> daprA
      daprA --> redisA
      daprA --> kv
      apiA --> pgA
    end
    subgraph targetB[On-premises-style stand-in: another ARO]
      radB[Separate Radius installation and onprem environment]
      daprB[Dapr]
      apiB[Same Shop API and web]
      pgB[CloudNativePG]
      redisB[Ephemeral Redis pod]
      radB --> apiB
      apiB --> daprB
      daprB --> redisB
      apiB --> pgB
    end
    afd --> targetA
    afd -. explicit switch .-> targetB
  end
```

The “on-premises-style” label describes only the recipe choice in the demo; that
cluster is also hosted in Azure. The same application Bicep is deployed to two
independent Radius environments. Radius is installed in each cluster because
the generic Kubernetes provider targets the cluster where that Radius
installation runs.

## State and secrets

- Each PostgreSQL target receives its own copy of the small product catalog.
- Dapr state management stores the cart in each target's Redis. There is no
  shared Redis and no synchronization.
- The API retrieves the PostgreSQL password through Dapr. The ARO target reads
  Key Vault using workload identity; the stand-in uses Dapr's Kubernetes
  secret store and a namespace-scoped read permission.
- Azure PostgreSQL is seeded from `app/api/init.sql` by a short-lived,
  restricted `psql` pod after the database resource is ready. The
  CloudNativePG recipe initializes the same SQL independently.

Failover changes traffic destination only. It is expected that carts differ
between clusters and database changes made in one target do not appear in the
other.
