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
- Permission to create applications and service principals in Microsoft Entra
  ID (or an existing service principal). `05-create-service-principal.sh`
  creates one without role assignments and saves its credentials privately
  under `.secrets/`. The infrastructure deployment grants it Contributor at
  the demo resource-group scope and Key Vault Secrets Officer on the demo vault.
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

## Running on Windows

Use **PowerShell 7.3 or later** (`pwsh`), not Windows PowerShell 5.1. Every Bash
operation has a native `.ps1` equivalent; no WSL, Bash, `jq`, `openssl`, or
`curl` is needed for the PowerShell scripts. Install the same platform CLIs
listed above and use Docker Desktop with Linux containers for the local demo.

From the repository root, copy `.env.example` with
`Copy-Item .env.example .env` (only if you have not created `.env` yet), edit the
Azure settings, then run:

```powershell
az login
.\scripts\00-check-prerequisites.ps1
.\scripts\05-create-service-principal.ps1
.\scripts\05-create-service-principal.ps1 -Target onprem
.\scripts\10-apply-infrastructure.ps1
.\scripts\20-get-cluster-credentials.ps1
.\scripts\25-login-service-principal.ps1
.\scripts\30-bootstrap-clusters.ps1
.\scripts\40-configure-radius.ps1
.\scripts\50-deploy-target.ps1 -Target aro
.\scripts\55-warm-standby.ps1
.\scripts\90-switch-traffic.ps1 -Target aro
```

Use `.\scripts\60-failover.ps1` and `.\scripts\70-failback.ps1` to switch targets.
The PowerShell scripts read the same `.env` and saved service-principal JSON,
use Windows kubeconfig path separators, and restrict secret-file access to your
Windows account. See [the Windows runbook](docs/windows.md) for permissions,
configuration, and cleanup. The Azure/ARO compatibility limitations apply on
Windows too.

## Deploy and operate

The infrastructure script provisions **both** ARO clusters and supporting
resources; it can take a long time and incur Azure charges. Review
[the runbook](docs/runbook.md) before running commands.

```bash
scripts/00-check-prerequisites.sh
scripts/05-create-service-principal.sh
scripts/05-create-service-principal.sh onprem
scripts/10-apply-infrastructure.sh
scripts/20-get-cluster-credentials.sh
scripts/30-bootstrap-clusters.sh
scripts/40-configure-radius.sh
scripts/50-deploy-target.sh aro
scripts/55-warm-standby.sh
scripts/90-switch-traffic.sh aro
```

Leave the `ARO_SERVICE_PRINCIPAL_*` and `ONPREM_SERVICE_PRINCIPAL_*` fields blank
in `.env` to use generated credentials; ARO requires a unique principal per
cluster. Script `05` defaults to `aro`; run it again with target `onprem`.
Later scripts load `.secrets/service-principal.json` and
`.secrets/onprem-service-principal.json` automatically. Rerunning `05` for a
target reuses its saved principal without rotating its password. Existing complete,
distinct credentials in `.env` remain supported. Generated passwords expire after
one year. Keep the saved files secure: secrets cannot be retrieved again
from Azure. Resource-group deletion does not delete the Entra application or
service principals; remove those dedicated identities separately when retiring
the demo.

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
