# ziti-operator

Deploys the community OpenZiti operator (`ziti-operator` v0.1.2,
`ghcr.io/alialjaffer/charts/ziti-operator`) into `ziti-operator-system`. The
operator reconciles `ZitiApp`, `ZitiIdentity`, `ZitiRouter`, and related CRDs
against the controller installed by the `ziti` app.

- Ordering: sync-wave `3`, after the `ziti` app (wave `2`) that creates the
  controller it connects to.
- Connection: `ZitiConnection/default` targets
  `https://ziti-controller-mgmt.ziti.svc:443/edge/management/v1`.
- RBAC: cluster-wide (default).

## Secret: `ziti-operator-credential` (not in git)

The connection authenticates with the controller admin user. Create the Secret
out-of-band so the password never lands in git (the `.gitignore` blocks raw
secrets anyway):

```sh
kubectl create namespace ziti-operator-system

kubectl -n ziti-operator-system create secret generic ziti-operator-credential \
  --from-literal=username=admin \
  --from-literal=password="$(kubectl -n ziti get secret ziti-controller-admin-secret \
    -o jsonpath='{.data.admin-password}' | base64 -d)"
```

The chart's `ZitiConnection` is a Helm post-install hook, so it is not tracked
by Argo. Re-running the app (or `helm upgrade`) recreates it; if it goes
missing, re-sync or create it from `config/samples` in the operator repo.

A future improvement: replace the static admin password with a dedicated
least-privilege Ziti identity, or a certificate-login Secret issued by
`ZitiCA`.
