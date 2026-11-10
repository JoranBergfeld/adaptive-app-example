# Demo runbook

For native Windows/PowerShell commands, follow [the Windows runbook](windows.md).
The steps below use Bash; each operation also has a `.ps1` equivalent.

## One-time setup

1. Make sure the current GitHub `main` contains this project and CI has
   published both `ghcr.io/joranbergfeld/adaptive-app-example/shop-api` and
   `.../shop-web` at the commit SHA. Set the packages to public, or configure
   image pull secrets in the clusters.
2. Copy `.env.example` to `.env`; configure the Azure subscription, region,
   resource group, globally unique Key Vault and Front Door names, and a public
   `RECIPE_REF`. Leave the three `ARO_SERVICE_PRINCIPAL_*` fields blank to
   generate credentials, or supply all three for an existing principal.
   Use the ARO service principal
   for Azure CLI sign-in when running scripts that set or delete Key Vault
   secrets. The infrastructure deployment also requires permission to create
   role assignments.
3. If available, provide a Red Hat pull-secret file. Check ARO quota and the
   availability of ARO and the managed services in the region. The
   infrastructure template uses 3 worker nodes per cluster.
4. Sign in with an identity that can create resources and role assignments in
   the subscription and create applications/service principals in Microsoft
   Entra ID, then run `scripts/00-check-prerequisites.sh`,
   `scripts/05-create-service-principal.sh`, and
   `scripts/10-apply-infrastructure.sh`. Script `05` saves credentials in
   `.secrets/service-principal.json` with mode 600; later scripts load them
   automatically, and reruns reuse them rather than rotate secrets. If directory
   lookup fails after creation, keep the file and rerun `05` after resolving the
   permission/propagation issue. Script `10` registers the required Azure
   resource providers and chooses the newest ARO version exposed by the
   regional Azure CLI command unless `OPENSHIFT_VERSION` is set.
   Each cluster gets a stable `aro-<hash>` DNS label derived from its resource
   group and cluster name, ensuring that the label starts with a letter. Its
   managed resource-group ID points to a separate `aro-managed-<hash>` group in
   the same subscription, which ARO creates and manages. Do not pre-create these
   groups or reuse the demo resource group for them.
   Both master and worker profiles explicitly set `encryptionAtHost` to
   `Disabled`, as the ARO API rejects an omitted value. This does not disable
   Azure managed-disk encryption at rest.
   Front Door provisioning creates the profile, endpoint, and
   origin group only; Azure requires an enabled origin before a route can be
   created.
5. Run `scripts/20-get-cluster-credentials.sh`. It saves mode-600 kubeconfigs
   and creates the explicit contexts `aro-demo` and `onprem-demo` under
   `.secrets/`.
   Before running the remaining scripts, sign in to Azure CLI as the ARO
   service principal; it has the resource-group Contributor and Key Vault
   Secrets Officer roles required by the demo.

   ```bash
   (
     source scripts/lib/common.sh
     load_config
     az login --service-principal \
       --username "$ARO_SERVICE_PRINCIPAL_CLIENT_ID" \
       --password="$ARO_SERVICE_PRINCIPAL_CLIENT_SECRET" \
       --tenant "$AZURE_TENANT_ID" --output none
     select_subscription
   )
   ```

   For an existing principal, set `AZURE_TENANT_ID` in `.env` as well. Generated
   credentials include the tenant automatically. Allow time for new role
   assignments to propagate before continuing.
6. Run `scripts/30-bootstrap-clusters.sh` and `scripts/40-configure-radius.sh`.
   This installs Dapr and Radius separately on each ARO cluster and
   CloudNativePG on the stand-in target.
7. Deploy the first target with `scripts/50-deploy-target.sh aro`, warm the
   second with `scripts/55-warm-standby.sh`, then set the active origin with
   `scripts/90-switch-traffic.sh aro`. Script `90` enables the selected origin
   before creating or updating the Front Door route.

## Switching demonstration

1. Open the Front Door endpoint printed by the deployment script and add a
   product to the cart. Note the deployment metadata in the storefront.
2. If demonstrating an outage, read
   `.github/instructions/chaos-demo.instructions.md`. Get explicit approval
   for the exact `kubectl create` command before applying the temporary
   NetworkPolicy. Do not run that command automatically.
3. Verify that the Front Door route to the primary is unhealthy/unavailable.
   The chaos policy only blocks ingress in the `shop` namespace on `aro-demo`.
4. Run `scripts/60-failover.sh` explicitly. It deploys to `onprem-demo` and
   switches Front Door; it does not copy data. The product catalog is initialized
   independently and the previous cart will not be present.
5. Remove the fault only with the undo command in the Copilot instructions.
   `scripts/70-failback.sh` can explicitly deploy and switch to the ARO target.
   Changes in the other cluster remain there; failback does not reconcile them.

## Cleanup

- `scripts/80-reset-demo.sh` deletes both Radius applications, OpenShift
  Routes, Dapr app components, app secrets, and demo RBAC. It also deletes
  the two demo secrets from Key Vault. It retains ARO, Radius, Dapr,
  CloudNativePG, databases/caches, Front Door, and other Azure infrastructure.
- `scripts/95-destroy-infrastructure.sh` deletes the complete configured Azure
  resource group after an exact-name confirmation. This is destructive and
  cannot be undone. Verify the resource group before confirming.
- The generated Entra application/service principal is not part of the resource
  group and is not deleted by either script. Delete that dedicated identity
  separately when retiring the demo. Its generated password expires after one
  year; do not delete the saved credentials to rotate it on an existing cluster.

## Troubleshooting boundaries

The bootstrap scripts stop on errors rather than treating an incomplete
deployment as successful. Check the generated Radius resources, Dapr component
status, ARO pod events, and Azure resource deployment output. ARO compatibility
and service-specific recipe details are not guaranteed; see
[known limitations](limitations.md). Never troubleshoot by widening the
chaos-role permissions or running the fault command against `onprem-demo`.
