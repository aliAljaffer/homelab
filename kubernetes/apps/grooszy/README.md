# grooszy

Private expense analysis application on Kubernetes.

## Required Secrets

The following Kubernetes Secrets must be created and sealed before deploying:

### grooszy-postgres

PostgreSQL credentials for the CNPG cluster bootstrap. Create with:

```
kubectl create secret generic grooszy-postgres \
  --from-literal=username=grooszy \
  --from-literal=password=GENERATED_PASSWORD \
  -n grooszy --dry-run=client -o yaml | \
  kubeseal -f - > grooszy-postgres.sealed.yaml
```

### grooszy-api

API environment variables. Create with:

```
kubectl create secret generic grooszy-api \
  --from-literal=DATABASE_URL='postgres://grooszy:PASSWORD@grooszy-db-rw.grooszy.svc.cluster.local:5432/grooszy?sslmode=require' \
  --from-literal=OIDC_ISSUER='https://KEYCLOAK_URL/realms/homelab' \
  --from-literal=OIDC_OWNER_SUBJECT='USER_SUBJECT_FROM_KEYCLOAK' \
  --from-literal=MAX_UPLOAD_BYTES=16777216 \
  --from-literal=EXPENSE_EXPLAIN_PROVIDER='' \
  --from-literal=EXPENSE_EXPLAIN_BASE_URL='' \
  --from-literal=EXPENSE_EXPLAIN_MODEL='' \
  --from-literal=EXPENSE_EXPLAIN_API_KEY='' \
  --from-literal=EXPENSE_EXPLAIN_TIMEOUT=30 \
  -n grooszy --dry-run=client -o yaml | \
  kubeseal -f - > grooszy-api.sealed.yaml
```

## Images

- API: `ghcr.io/alialjaffer/grooszy-api@sha256:CHANGEME`
- Web: `ghcr.io/alialjaffer/grooszy-web@sha256:CHANGEME`

## Deployment

Add this folder to ArgoCD or deploy manually:

```
kubectl kustomize kubernetes/apps/grooszy | kubectl apply -f -
```

## Backups

CNPG is configured with scheduled volume snapshots at 00:02 UTC daily.

## Network Policy

Cilium network policies restrict:
- Web ingress: homelab-gateway only
- Web egress: API, Keycloak, DNS
- API ingress: Web, Prometheus scraping
- API egress: CNPG, Valkey, Keycloak, DNS
- Database ingress: API, Prometheus (CNPG exporter), CNPG operator
