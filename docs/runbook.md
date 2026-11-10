# Demo runbook

## One-time setup

1. Make sure the current GitHub `main` contains this project and CI has
   published both `ghcr.io/joranbergfeld/adaptive-app-example/shop-api` and
   `.../shop-web` at the commit SHA. Set the packages to public, or configure
   image pull secrets in the clusters.
2. Copy `.env.example` to `.env`; configure the Azure subscription, region,
   resource group, ARO service-principal values, globally unique Key Vault and
   Front Door names, and a public `RECIPE_REF`. Use the ARO service principal
   for Azure CLI sign-in when running scripts that set or delete Key Vault
   secrets. The infrastructure deployment also requires permission to create
   role assignments.
3. If available, provide a Red Hat pull-secret file. Check ARO quota and the
   availability of ARO and the managed services in the region. The
   infrastructure template uses 3 worker nodes per cluster.
4. Sign in with an identity that can create resources and role assignments in
   the subscription, then run `scripts/00-check-prerequisites.sh` and
   `scripts/10-apply-infrastructure.sh`. It registers the required Azure
   resource providers and chooses the newest ARO version exposed by the
   regional Azure CLI command unless `OPENSHIFT_VERSION` is set.
5. Run `scripts/20-get-cluster-credentials.sh`. It saves mode-600 kubeconfigs
   and creates the explicit contexts `aro-demo` and `onprem-demo` under
   `.secrets/`.
   Before running the remaining scripts, sign in to Azure CLI as the ARO
   service principal; it has the resource-group Contributor and Key Vault
   Secrets Officer roles required by the demo.
6. Run `scripts/30-bootstrap-clusters.sh` and `scripts/40-configure-radius.sh`.
   This installs Dapr and Radius separately on each ARO cluster and
   CloudNativePG on the stand-in target.
7. Deploy the first target with `scripts/50-deploy-target.sh aro`, warm the
   second with `scripts/55-warm-standby.sh`, then set the active origin with
   `scripts/90-switch-traffic.sh aro`.

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

## Troubleshooting boundaries

The bootstrap scripts stop on errors rather than treating an incomplete
deployment as successful. Check the generated Radius resources, Dapr component
status, ARO pod events, and Azure resource deployment output. ARO compatibility
and service-specific recipe details are not guaranteed; see
[known limitations](limitations.md). Never troubleshoot by widening the
chaos-role permissions or running the fault command against `onprem-demo`.
