# catus-locatus

Notes on files where the gotcha isn't obvious from the YAML alone.

- `networkpolicy.yaml`: default-deny CiliumNetworkPolicies, not yet wired into `kustomization.yaml`. Apply only after `policyAuditMode: true` in `kubernetes/bootstrap/cilium/values.yaml` is rolled out and confirmed live, so a mistake here logs instead of dropping real traffic. The `minio-console` HTTPRoute (`httproutes.yaml`) backends to `minio-svc:9001`, but `minio-svc.yaml` only exposes port 9000, so that route has no live endpoint today. The ingress rule for port 9001 is already in place so it starts working the moment the Service is fixed. `cl-fe` has no egress rule to `cl-be` because the frontend calls the backend at a relative `/api/` URL from the browser, not pod-to-pod.
