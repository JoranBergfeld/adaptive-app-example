# Implementation plan

## Goal

Build a small, projector-friendly `shop` demo that deploys the same application
code and `radius/app.bicep` to two Azure Red Hat OpenShift (ARO) clusters. The
second cluster is an on-premises-style stand-in for the demo, not an actual
on-premises environment. Each cluster gets its own Radius control plane and
environment because Radius does not currently provide a generic cross-cluster
OpenShift target. The ARO target uses Azure Database for PostgreSQL and Azure
Managed Redis; the stand-in uses CloudNativePG and in-cluster Redis. A
human-triggered failover deploys the app and changes traffic routing; it does
not migrate database or cart state or promise data continuity.

## Phases

1. **Application and CI** — Create the FastAPI API and single-page storefront.
   Store the product catalog in PostgreSQL and use Redis through Dapr state
   management for the cart and Dapr secret stores for the database password.
   Include UBI 9 Containerfiles suitable for OpenShift restricted-v2, focused
   API unit tests, local development configuration, and CI checks for linting,
   tests, image builds, Bicep, and shell scripts.
2. **Radius and Dapr** — Add the shared Radius application definition, a
   separate Radius installation/environment per ARO cluster, and
   environment-specific recipes. Keep Dapr in scope for Redis state and
   secrets. Use documented resource types and parameters; document unverified
   integration as a limitation rather than claiming compatibility.
3. **Infrastructure** — Add parameterized Azure infrastructure for both ARO
   clusters and the demo's supporting resources. Keep cluster sizing and
   replica counts at the minimum needed for the demo, and make the second
   cluster's Azure-hosted nature explicit. Do not include Azure Arc onboarding:
   this demo does not contain an actual on-premises cluster.
4. **Operations and chaos demo** — Add prerequisite, deploy, warm-standby,
   failover, failback, and reset scripts; the scoped chaos NetworkPolicy and
   RBAC; and Copilot instructions that require explicit approval for the exact
   fault-injection command and prohibit automated failover/failback. Failover
   deploys the app and changes traffic destination only. Database and Redis
   data are not replicated or migrated, and failover makes no data continuity
   claim. Use Front Door for switching with a printed-origin fallback.
5. **Documentation** — Add the README, architecture, honest limitations, and
   demo runbook, including Mermaid diagrams, setup and verification commands,
   technology differences, the absence of data replication/continuity, the
   scope of two Azure-hosted clusters, and unverified support or compatibility
   points.

The user approved the plan and asked to proceed through the complete
implementation without intermediate approval pauses.

## Assumptions

- Both clusters are ARO in Azure. The second is labeled as an
  on-premises-style target for the narrative, not represented as a real
  on-premises environment or proof of portability to one.
- Select the latest ARO/OpenShift version available in the chosen region at
  deployment time. Pin Radius and Dapr versions in scripts and manifests;
  document that ARO support for Radius and Dapr is not verified.
- The product catalog is initialized independently in each cluster. The cart
  uses Redis state through Dapr. Neither database contents nor Redis state are
  replicated or migrated during failover; the demo does not implement backup,
  restore, or data continuity.
- Use GitHub Packages for application images. Keep worker pools and replica
  counts at the minimum required by ARO and the demo, and make deployment and
  cleanup explicit.
- Azure Cache for Redis is no longer available to new customers; use Azure
  Managed Redis on the Azure-managed-services target and document the
  substitution. Keep Azure PostgreSQL network access restricted to Azure
  service access, enforce TLS, and document the remaining demo-only network
  tradeoff.
- Recipe, Radius, Dapr, operator, and platform-specific details must follow
  documented interfaces. Where verification is unavailable, leave a clear TODO
  and document the limitation.

## Verified decisions and limitations

- Both targets are Azure-hosted ARO clusters; no Azure Arc onboarding is
  applicable. The second cluster is only an on-premises-style demo label.
- No PostgreSQL or Redis data is synchronized, copied, backed up, or restored
  during deploy, failover, or failback.
- Radius's current generic Kubernetes provider targets the cluster where that
  Radius installation runs. The demo uses one installation per cluster.
- Radius's documented Kubernetes support matrix does not list ARO, and the
  Dapr/Radius installation security requirements on ARO must be validated in
  the target subscription. No custom SCC is granted automatically.
