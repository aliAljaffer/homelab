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
- LLM: Hindsight sends every call to `http://127.0.0.1:8899/v1`, a sidecar running
  `llm-router.py`. The router replaces the fixed model name `free` with the first
  free OpenCode model that answers and fails over on errors. It is a sidecar
  because Hindsight already runs one pod and the router only sees Hindsight's
  requests.
- Free model list: `free-models-sync` runs every two days at 06:00 UTC. It reads
  the Go and OpenCode catalogs at `https://opencode.ai/inference/.../v1/models`
  and treats every zero-priced chat model as a candidate. It validates the
  response shape and each candidate's fields, then probes each with a small JSON
  request. Only candidates that pass the probe are written to the
  `hindsight-free-models` ConfigMap; the router reloads it without a restart. The
  current working models (`hungerg-free`, `beam-free`, `hy4-flash-free`) go first,
  and other valid free models follow. `deepseek-v4.1-flash` on Go is not used: it
  is included in the Go subscription but draws down the monthly allowance. The
  free `deepseek-v4.1-flash-free` is probed; today it returns
  `FreeUsageLimitError`, so it is left out until that changes.
- The router sends `x-opencode-session`, which OpenCode Go requires. Hindsight
  does not need to know about the header because its base URL is local.
- Vision support is mixed across the free set (`beam-free` is text-only), so
  `HINDSIGHT_API_LLM_VISION=false` refuses image attachments rather than risking
  a text-only model.
- `HINDSIGHT_API_RETAIN_MAX_COMPLETION_TOKENS=32000`: the free catalog includes
  models with a 32k output cap, and a retain asks for the configured budget, so
  32k avoids a 64k request against a 32k model. It is still well above the default
  3000-token chunk.
- The sidecar uses the same `hindsight-api` image as the API container. Bump both
  image tags together when the chart version changes.
- Retain policy: `HINDSIGHT_API_RETAIN_EXTRACTION_MODE=custom`. `HINDSIGHT_API_RETAIN_CUSTOM_INSTRUCTIONS`
  in the chart values is the allow and deny list for what becomes a memory. Edit it there.
  A bank-level override in the API takes precedence over it. The `ali` bank overrides only
  `retain_strategies`.
- memory-store sync: the `memory-store-sync` CronJob runs daily at 03:00 UTC. It clones
  `Azm-Tech/azm-sre-memory-store` with the `memory-store-deploy-key` deploy key. It retains each entry
  as the document `memory-store/<path>`, tagged `source:memory-store`. It uses the `memory-store`
  retain strategy (verbatim), which it sets on the bank on every run, so the strict policy does not
  drop them. It resends only files whose sha256 changed, and deletes documents whose file is gone.
- Embeddings and reranking run locally inside the `hindsight-api` image. No embedding API is needed.

## Auth

The API requires `Authorization: Bearer <HINDSIGHT_API_TENANT_API_KEY>`. The built-in
`ApiKeyTenantExtension` enforces it. The API accepts traffic only from the `hermes` and `tailscale`
namespaces and from the control plane. The tailnet name is `hindsight`.

The UI is on the tailnet as `hindsight-ui`. Log in with `HINDSIGHT_CP_ACCESS_KEY`. The UI calls the
API with `HINDSIGHT_CP_DATAPLANE_API_KEY`, which has the same value as the tenant key.

The source values for every secret are in `~/docs/hindsight/secrets.json` on the personal laptop.

## Free model list

The router reads `/models/models.json`, mounted from the `hindsight-free-models` ConfigMap. The
ConfigMap is not in Git: the `free-models-sync` CronJob owns it, so an Argo sync cannot revert the
last probe result. Inspect it with:

```
kubectl -n hindsight get configmap hindsight-free-models \
  -o jsonpath='{.data.models\.json}' | jq
```

The router reads the ConfigMap through the Kubernetes API, so it picks up a ConfigMap that did not
exist when the pod started and later CronJob updates without a restart. The `hindsight`
ServiceAccount can get only this ConfigMap. The router falls back to its built-in list when the
ConfigMap or the API is unavailable, so a fresh install works before the first CronJob run. If the
catalogs return no free chat models, or none pass the probe, the CronJob leaves the ConfigMap alone
and the router keeps the last validated list. Force a refresh with:

```
kubectl -n hindsight create job --from=cronjob/free-models-sync free-models-sync-manual
```

The CronJob reads `HINDSIGHT_API_LLM_API_KEY` from `hindsight-env`. Its ServiceAccount can create
ConfigMaps in `hindsight` and get or patch only `hindsight-free-models`.

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

Mint a dedicated OpenCode Console API key for Hindsight. Do not reuse the `hermes` token. The API
container, the router sidecar and the `free-models-sync` CronJob all read it from this secret.

```
kubectl create secret generic hindsight-env \
  --from-literal=postgres-password=GENERATED_PASSWORD \
  --from-literal=HINDSIGHT_API_LLM_API_KEY=OPENCODE_API_KEY \
  --from-literal=HINDSIGHT_API_TENANT_API_KEY=TENANT_KEY \
  --from-literal=HINDSIGHT_CP_DATAPLANE_API_KEY=TENANT_KEY \
  --from-literal=HINDSIGHT_CP_ACCESS_KEY=UI_ACCESS_KEY \
  -n hindsight --dry-run=client -o yaml | \
  kubeseal -f - > hindsight-env.sealed.yaml
```
