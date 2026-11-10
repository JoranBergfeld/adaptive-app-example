# Adaptive Shop: a two-cluster demo

Adaptive Shop is a deliberately small demo of moving one application between
two Kubernetes clusters that provide different platform services. Both clusters
are Azure Red Hat OpenShift (ARO). The second is an Azure-hosted
on-premises-style stand-in; this project does not deploy to or claim to represent
a real on-premises cluster.

The same FastAPI API and storefront run on both targets. Dapr provides Redis
cart state and access to database passwords. Radius deploys the application
through a separate installation and environment in each cluster. Azure Front
Door sends traffic to one explicitly enabled origin.

**This is a demo, not a continuity or disaster-recovery solution.** PostgreSQL
products are initialized separately in each cluster. Redis carts are local to
each cluster. Deploy, failover, and failback do not replicate or migrate either
database or Redis state.

## What is deployed

| Target | Runtime | PostgreSQL | Redis | Secrets |
| --- | --- | --- | --- | --- |
| Azure-managed-services (`aro`) | ARO | Azure Database for PostgreSQL Flexible Server | Azure Managed Redis | Dapr Azure Key Vault component |
| On-premises-style (`onprem`) | A second ARO cluster in Azure | CloudNativePG | Ephemeral Redis pod | Dapr Kubernetes secret store |

Azure Cache for Redis is not used because it is unavailable to new customers;
Azure Managed Redis is the managed-service substitute. See
[the architecture](docs/architecture.md) and
[known limitations](docs/limitations.md) for network, platform-support, and
data-scope details.

## Local demo

Requirements: Docker with the Compose plugin.

```bash
cp .env.example .env
docker compose up --build
```

Open <http://localhost:8081>. The app API is available at
<http://localhost:8081/api/healthz>. Stop the services with
`docker compose down`; add `--volumes` if you also want to remove local
PostgreSQL and Dapr secret data.

## Azure demo prerequisites

- An Azure subscription with ARO, Azure Database for PostgreSQL Flexible
  Server, Azure Managed Redis, Key Vault, and Front Door quota and resource
  providers available in the chosen region.
- An Azure service principal for ARO with its client ID, client secret, and
  object ID. The infrastructure deployment grants it Contributor at the demo
  resource-group scope and Key Vault Secrets Officer on the demo vault.
- An Azure deployment identity with resource-provider registration and role
  assignment permissions. Use the ARO service principal for later management
  scripts that write or delete demo Key Vault secrets.
- A Red Hat pull secret is recommended. The ARO versions are selected from
  those available in the chosen region at deployment time.
- Azure CLI with the `aro` extension, `rad` 0.60.2, Dapr CLI 1.19.0, Helm,
  `kubectl`, `oc`, `jq`, `git`, `curl`, `openssl`, and Docker.
- Public GitHub Container Registry packages for `shop-api` and `shop-web`.
  The workflow publishes commit-SHA tags from pushes to `main`. Make both
  packages public in GitHub Packages before deploying, or configure image pull
  credentials in both clusters.
- A public branch or tag containing this repository's Radius recipes. Set
  `RECIPE_REF` to that ref; it defaults to `main`.

Copy `.env.example` to `.env` and set the Azure values, including globally
unique `KEY_VAULT_NAME` and `FRONT_DOOR_PROFILE_NAME`. Set
`RED_HAT_PULL_SECRET_FILE` to a local file path if using a Red Hat pull secret.
Never commit `.env`, kubeconfigs, or files under `.secrets/`.

## Deploy and operate

The infrastructure script provisions **both** ARO clusters and supporting
resources; it can take a long time and incur Azure charges. Review
[the runbook](docs/runbook.md) before running commands.

```bash
scripts/00-check-prerequisites.sh
scripts/10-apply-infrastructure.sh
scripts/20-get-cluster-credentials.sh
scripts/30-bootstrap-clusters.sh
scripts/40-configure-radius.sh
scripts/50-deploy-target.sh aro
scripts/55-warm-standby.sh
scripts/90-switch-traffic.sh aro
```

`scripts/60-failover.sh` deploys the app to the on-premises-style target and
switches Front Door to it. `scripts/70-failback.sh` deploys the app to the ARO
target and switches back. Both are explicit human-invoked scripts; neither
transfers data. `scripts/80-reset-demo.sh` removes demo applications and
Key Vault demo secrets while retaining the cluster infrastructure.

`scripts/95-destroy-infrastructure.sh` permanently deletes the entire configured
resource group after requiring its exact name as confirmation. This includes
both clusters and all supporting resources.

For fault injection, follow `.github/instructions/chaos-demo.instructions.md`.
It limits the fault to an ingress-denying NetworkPolicy in `aro-demo`, requires
explicit user approval before the exact command, grants only narrow
namespace-scoped permissions to the `chaos-operator` service account there,
and makes the `onprem-demo` service account read-only. Do not use the fault
command as a production test.

## Validation

CI runs Ruff, API tests, image builds, shell and infrastructure checks, and
publishes commit-SHA images on pushes to `main`. Azure resource provisioning and
the full two-cluster flow are not run by CI. The platform and service
compatibility caveats are listed in [known limitations](docs/limitations.md).
