# Running the demo from Windows

Use **PowerShell 7.3+** (`pwsh`). The scripts do not require WSL or Git Bash.
Windows PowerShell 5.1 is not supported. The same app, manifests, Radius
definitions, and `.env` configuration are used by both script sets.

## Prerequisites and configuration

Install PowerShell 7, Git, Azure CLI (with ARO and Redis Enterprise commands
available), Radius CLI 0.60.2, Dapr CLI 1.19.0, Helm, `kubectl`, and `oc`.
For the local app, also install Docker Desktop and select **Linux containers**.
The PowerShell scripts use built-in JSON, HTTP, cryptography, and filesystem
APIs instead of `jq`, `curl`, `openssl`, `sed`, or other Unix tools.

Run commands from the repository root. If you have not configured the demo yet:

```powershell
Copy-Item .env.example .env
notepad .env
```

Set the Azure subscription, region, resource group, and globally unique vault
and Front Door names. Leave `ARO_SERVICE_PRINCIPAL_*` and
`ONPREM_SERVICE_PRINCIPAL_*` blank to generate separate principals.
Set `AZURE_TENANT_ID` if using existing principals.
The generated credentials already include their tenant.

The PowerShell `.env` reader accepts `NAME=value`, blank lines, comments on
their own lines, and values enclosed in matching single or double quotes.
Values are literal: do not use shell expressions, variable substitutions,
`export`, or trailing inline comments. Windows paths and spaces are supported:

```text
RED_HAT_PULL_SECRET_FILE="C:\Users\Demo User\Downloads\pull-secret.txt"
```

Do not overwrite an existing `.env` or commit it. The `.secrets` directory is
Git-ignored; PowerShell disables inherited access rules and restricts access to
your Windows account. Use a local filesystem supporting Windows ACLs (normally
NTFS), not a shared folder with different permission semantics. Only access
rules are changed, not file ownership or audit rules; no `SeSecurityPrivilege`
or administrator elevation is required to protect files you own.

If execution policy blocks locally reviewed scripts, use your organization's
approved policy/process. Do not disable execution policy machine-wide.

## Provision and deploy

First sign in with an Azure identity that can register resource providers,
create resources and role assignments, and create Entra applications and
service principals:

```powershell
az login
.\scripts\00-check-prerequisites.ps1
.\scripts\05-create-service-principal.ps1
.\scripts\05-create-service-principal.ps1 -Target onprem
.\scripts\10-apply-infrastructure.ps1
.\scripts\20-get-cluster-credentials.ps1
```

Script `05` creates a dedicated principal per target with a one-year password
but no role assignments. The default target is `aro`; `-Target onprem` creates
the second cluster's separate identity. Credentials are stored in
`.secrets/service-principal.json` and `.secrets/onprem-service-principal.json`
and reused on subsequent runs without rotating passwords. ARO does not allow
two clusters to share a service principal. Keep the original primary principal
when upgrading a partially deployed demo; only add the onprem principal.
Explicit credentials must supply all three fields for each target, with distinct
client and object IDs.

Script `10` grants both cluster principals resource-group Contributor, and
the primary principal vault Secrets Officer for the later demo scripts. It also
resolves the tenant-local object ID of the ARO resource provider (application ID
`f1dd0a37-89c6-4e07-bcd1-ffd3d43d8875`) and assigns it Network Contributor on
each cluster VNet before cluster creation. Directory lookup permission is required
for this step. This provider identity is separate from both cluster principals.
If Azure reports provider permissions immediately after new role assignments,
allow time for Azure RBAC propagation. A cluster whose initial creation reached
`Failed` cannot be redeployed in place: ARO requires deleting that failed cluster
before recreating it. Inspect the failed deployment and cluster first, then
explicitly approve any cluster deletion; do not delete the whole demo resource
group, remove credentials, or automatically delete a cluster after an update failure.
Script `10` then deploys
both ARO clusters and supporting services. This takes time and incurs charges.
Cluster DNS labels use `aro-<hash>`, with a stable hash derived from the resource
group and cluster names. The letter prefix is required by ARO for new clusters.
Each cluster also specifies a separate managed resource-group ID in the same
subscription, named `aro-managed-<hash>`. ARO creates and manages those groups;
do not pre-create them or use the demo resource group as their ID. No domain
or managed resource-group setting is required in `.env`. Front Door's route is
deferred until script `90` enables an application origin.
Both clusters explicitly set `encryptionAtHost: Disabled` on master and worker
profiles; this field cannot be omitted with the selected ARO API version.
Azure managed-disk encryption at rest remains enabled.

Run `.\scripts\09-check-capacity.ps1` to check the configured region without
creating or deleting Azure resources. It reads the VM sizes and worker counts
from the compiled template and configured size overrides, checks current subscription SKU location restrictions,
and compares the additional nodes against regional and VM-family CPU quota.
With the default topology, two new clusters need 72 vCPUs. Existing successful
clusters with matching topology are not counted again; failed clusters are
conservatively counted in full. Topology changes to successful clusters require
a separate capacity assessment. Zone-only restrictions are not blockers because
this template does not request availability zones.

Script `10` repeats this preflight before provider registration or resource-group
creation, then runs ARM provider-level validation before deploying resources.
Use a current Azure CLI supporting `--validation-level Provider`. Checks fail
closed if a SKU or quota is missing or a query fails. They do not reserve capacity,
guarantee ARO allocation, or automatically change region/VM sizes. Restrictions
can change between a check and deployment; CPU quota checks also do not cover
every service quota or temporary upgrade capacity.

Set `ARO_MASTER_VM_SIZE` and `ARO_WORKER_VM_SIZE` in `.env` to try another
[ARO-supported size](https://learn.microsoft.com/azure/openshift/support-policies-v4#supported-virtual-machine-sizes).
For example, `Standard_D8s_v6` masters and `Standard_D4s_v6` workers keep the
same CPU/memory counts as the default v5 pair. Dsv6 requires OpenShift 4.19 or
later; leave `OPENSHIFT_VERSION` blank to select the newest regional version,
or explicitly choose a supported version at least 4.19. Script `10` rejects
older versions for v6 sizes. Both clusters use these settings, and capacity
checks use the selected sizes and VM families. Defaults remain v5; do not
change the master size of an existing successful cluster as a retry mechanism.
SKU listings do not guarantee that ARO itself will accept or allocate the size.

If Azure reports that `Microsoft.Cdn/profiles/afdEndpoints/shop` is unavailable,
set `FRONT_DOOR_ENDPOINT_NAME` in `.env` to an unused name, for example
`adaptive-shop-weu-<unique-suffix>`. Changing only the profile name does not
change the endpoint name. The default remains `shop` for existing deployments;
scripts `10`, `50`, and `90` all use the configured endpoint. Do not change it
for an existing working deployment unless intentionally adding a new endpoint.

Switch Azure CLI to the demo principal, then install the platforms and deploy:

```powershell
.\scripts\25-login-service-principal.ps1
.\scripts\30-bootstrap-clusters.ps1
.\scripts\40-configure-radius.ps1
.\scripts\50-deploy-target.ps1 -Target aro
.\scripts\55-warm-standby.ps1
.\scripts\90-switch-traffic.ps1 -Target aro
```

Allow time for role assignments to propagate if Azure initially denies access.
Make sure CI has published the matching commit-SHA images and that GHCR
packages are public (or configure image-pull credentials). `RECIPE_REF` must
point to a publicly readable ref containing the recipes.

Scripts set `KUBECONFIG` to the two private generated kubeconfigs with the
Windows `;` separator. Contexts are named `aro-demo` and `onprem-demo`, with
distinct user and cluster names. An explicit `KUBECONFIG` in `.env` or the
environment overrides this default.

## Present the demo

Open the printed Front Door URL and add products to the cart. The metadata
identifies the active cluster and backing services.

```powershell
.\scripts\60-failover.ps1
# Later, to return to the managed-services target:
.\scripts\70-failback.ps1
```

These are manual operations. Both clusters are ARO in Azure; the second is only
an on-premises-style stand-in. PostgreSQL and Redis are independent, so switching
does not migrate data or preserve cart continuity. Fault injection remains
separate and requires the explicit approval described in
`../.github/instructions/chaos-demo.instructions.md`; none of the setup scripts
applies the outage policy.

## Local preview and cleanup

The local app uses the same Compose command on Windows:

```powershell
docker compose up --build
# Open http://localhost:8081
docker compose down
```

Use `.\scripts\80-reset-demo.ps1` to remove demo app resources while retaining
the clusters and platform installations. They continue to incur charges.
Use `.\scripts\95-destroy-infrastructure.ps1` to permanently delete the entire
configured Azure resource group, after typing its exact name to confirm.
Neither operation deletes the generated Entra application/service principal;
remove that dedicated identity separately when retiring the demo.

Native-command failures stop scripts rather than appearing as successful
deployments. The full Azure flow still requires a rehearsal in your
subscription; see [known limitations](limitations.md).

If script `10` rejects `properties.clusterProfile.domain` (including a generated
label starting with a digit), reports an empty `properties.clusterProfile.resourceGroupId`,
rejects an empty `properties.masterProfile.encryptionAtHost` or worker-profile equivalent,
or asks for an enabled Front Door origin, use the updated templates and scripts together
and rerun `.\scripts\10-apply-infrastructure.ps1` from that checkout. These are
template errors, not a PowerShell execution-policy or service-principal secret
problem. The deployment uses incremental mode, so do not delete the resource
group or regenerate credentials just to retry. If Azure still rejects a
resource left in a failed state, inspect the deployment operations first:

```powershell
az deployment operation group list --resource-group <your-resource-group> `
  --name adaptive-shop-infrastructure `
  --query "[?properties.provisioningState=='Failed'].{resource:properties.targetResource.resourceName,error:properties.statusMessage}" `
  --output json
```
