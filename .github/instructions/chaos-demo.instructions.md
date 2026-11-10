---
applyTo: "chaos/**"
---

# Controlled demo fault

- Never apply a fault, fail over, or fail back without the user's explicit
  approval. Before applying, show the exact command below and wait for approval.
- The only fault target is context `aro-demo`, namespace `shop`, and the
  `NetworkPolicy` in `chaos/demo-outage.yaml`.
- The `onprem-demo` context is read-only for inspecting pods and deployments.
- Use only the `chaos-operator` service account for the fault command. Do not
  change cluster credentials or broaden RBAC.
- Do not run any failover or failback command. After applying, verify the route
  error and report the result in two sentences.
- Undo only by deleting `demo-outage`; do not delete or alter other resources.

The apply command, only after approval:

```bash
kubectl --context aro-demo --namespace shop \
  --as=system:serviceaccount:shop:chaos-operator \
  create --filename chaos/demo-outage.yaml
```

The only undo command:

```bash
kubectl --context aro-demo --namespace shop \
  --as=system:serviceaccount:shop:chaos-operator \
  delete networkpolicy demo-outage --wait=false
```
