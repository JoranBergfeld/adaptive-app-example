# Known limitations and demo tradeoffs

- **Not actual on-premises:** Both clusters are ARO in Azure. The second
  cluster demonstrates different infrastructure recipes; it does not prove
  compatibility with a datacenter or another Kubernetes distribution.
- **No data continuity:** PostgreSQL and Redis are independent. There is no
  replication, backup/restore flow, data migration, or guarantee that orders,
  catalog edits, or carts survive a switch. The catalog is only seeded with
  demo data on each deployment.
- **Platform compatibility is unverified:** Radius 0.60.2 and Dapr 1.19.0 are
  pinned, but their support on ARO, OpenShift SCC behavior, Dapr
  workload-identity authentication, and the Radius Azure recipe pack must be
  validated in the target subscription before presenting the demo.
- **Recipes need a public Git ref:** Radius retrieves the stand-in recipes from
  this repository using `RECIPE_REF`. The ref must exist and be readable from
  the Radius installation. The generic container recipe reference currently
  uses the upstream `latest` tag.
- **Azure PostgreSQL network tradeoff:** The demo recipe enables public
  networking and uses the Azure-services firewall rule (`0.0.0.0`) so ARO can
  reach the server without a private-network design. This is intentionally
  broader than production guidance. TLS is required.
- **Public ARO API endpoints:** Both clusters expose their authenticated
  Kubernetes API endpoints publicly so the operator can administer them without
  adding a VPN or jump host. Protect the admin kubeconfigs and Azure account.
- **Azure Managed Redis authentication/networking:** The managed Redis recipe
  uses its access key over TLS and public networking. Confirm the selected
  Azure region, SKU, API/CLI support, firewall behavior, and Dapr component
  compatibility before deployment.
- **GHCR visibility:** The CI workflow publishes commit-SHA images. Make both
  packages public, or set up pull credentials in both clusters before
  deploying. Image publishing alone does not configure cluster authentication.
- **Manual switching:** Front Door switching is an operator command, not
  automatic health-based failover. The demo assumes a human chooses when to
  switch. The chaos policy is intentionally manual and scoped to the primary
  cluster.
- **Azure cost and cleanup:** Two ARO clusters and managed services can incur
  meaningful charges. `80-reset-demo.sh` removes application data/resources
  but keeps the clusters and platform installations. Use
  `95-destroy-infrastructure.sh` when finished.
