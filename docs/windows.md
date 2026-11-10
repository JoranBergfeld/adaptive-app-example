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
and Front Door names. Leave the three `ARO_SERVICE_PRINCIPAL_*` fields blank
to generate a principal. Set `AZURE_TENANT_ID` if using an existing principal.
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
.\scripts\10-apply-infrastructure.ps1
.\scripts\20-get-cluster-credentials.ps1
```

Script `05` creates a dedicated principal with a one-year password but no role
assignments. Credentials are stored in `.secrets/service-principal.json` and
reused on subsequent runs without rotating the password. Script `10` grants
the resource-group Contributor and vault Secrets Officer roles, then deploys
both ARO clusters and supporting services. This takes time and incurs charges.
Cluster DNS labels are generated deterministically from the resource group
and cluster names; no domain setting is required in `.env`. Front Door's route
is deferred until script `90` enables an application origin.

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

If script `10` reports an empty `properties.clusterProfile.domain` or asks for
an enabled Front Door origin, use the updated templates and scripts together
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
