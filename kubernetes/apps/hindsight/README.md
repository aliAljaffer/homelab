# hindsight

[Hindsight](https://github.com/vectorize-io/hindsight) (Vectorize, MIT) is the shared long-term
memory store for every Hermes instance: the `hermes` pod, Desktop through `hermes-1`, and each
workstation CLI. All of them write to one memory bank.

## Shape

- This directory is auto-onboarded by the `workloads` ApplicationSet as the `hindsight` Application.
  It holds the namespace, the CNPG cluster, the secrets, the network policy and the tailnet route.
- The Helm chart is a separate Application, `kubernetes/argocd/apps/workloads/hindsight-chart.yaml`
  (`oci://ghcr.io/vectorize-io/charts/hindsight`, pinned to 1.3.0). It renders one API Deployment
  and Service `hindsight-api:8888`, plus the control-plane UI `hindsight-control-plane:3000`.
  The API runs the background worker in-process. The dedicated worker StatefulSet is off.
- `cnpg-cluster.yaml` is a single-instance `hindsight-db` on Longhorn. Hindsight connects to
  `hindsight-db-rw` as the `hindsight` owner. The `vector` extension is created at bootstrap.
- LLM: the `claude-code` provider, which authenticates with a `claude setup-token` token.
  The model is `claude-haiku-5-5`, because extraction runs on every turn.
- Embeddings and reranking run locally inside the `hindsight-api` image. No embedding API is needed.

## Auth

The API requires `Authorization: Bearer <HINDSIGHT_API_TENANT_API_KEY>`. The built-in
`ApiKeyTenantExtension` enforces it. The API accepts traffic only from the `hermes` and `tailscale`
namespaces and from the control plane. The tailnet name is `hindsight`.

The UI is on the tailnet as `hindsight-ui`. Log in with `HINDSIGHT_CP_ACCESS_KEY`. The UI calls the
API with `HINDSIGHT_CP_DATAPLANE_API_KEY`, which has the same value as the tenant key.

The source values for every secret are in `~/docs/hindsight/secrets.json` on the personal laptop.

## Required Secrets

Create and seal both secrets before you commit this directory. Use the same database password in
both secrets.

### hindsight-postgres

The CNPG bootstrap credentials:

```
kubectl create secret generic hindsight-postgres \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=hindsight \
  --from-literal=password=GENERATED_PASSWORD \
  -n hindsight --dry-run=client -o yaml | \
  kubeseal -f - > hindsight-postgres.sealed.yaml
```

### hindsight-env

The chart injects every key in this secret as an environment variable. It also reads
`postgres-password` to build the database URL.

Run `claude setup-token` to mint a dedicated token for Hindsight. Do not reuse the `hermes` token.

```
kubectl create secret generic hindsight-env \
  --from-literal=postgres-password=GENERATED_PASSWORD \
  --from-literal=HINDSIGHT_API_LLM_API_KEY=SETUP_TOKEN \
  --from-literal=HINDSIGHT_API_TENANT_API_KEY=TENANT_KEY \
  --from-literal=HINDSIGHT_CP_DATAPLANE_API_KEY=TENANT_KEY \
  --from-literal=HINDSIGHT_CP_ACCESS_KEY=UI_ACCESS_KEY \
  -n hindsight --dry-run=client -o yaml | \
  kubeseal -f - > hindsight-env.sealed.yaml
```
