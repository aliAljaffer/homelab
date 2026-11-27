# oci-capacity-watcher

A one-minute CronJob that keeps trying to launch the Oracle Always Free
`VM.Standard.A1.Flex` instance in Riyadh AD-1 until capacity appears, then
emails once through the `mail` namespace SMTP relay.

## What it launches

| Setting | Value |
|---|---|
| Shape | `VM.Standard.A1.Flex` |
| Size | 2 OCPU / 12 GB |
| Region / AD | `me-riyadh-1` / `AD-1` |
| VCN / subnet | `my-vcn` / `pub-subnet` |
| Boot volume | 100 GB |
| Public IPv4 | assigned |
| SSH key | `oci-machine.pub` (mounted from a ConfigMap) |

The image is a plain `python:3.12-slim` plus the pinned `oci` SDK. The script is
mounted from a ConfigMap, so changing `oci_retry.py` does not need an image
rebuild.

## Idempotency

The instance is tagged `oci-capacity-watcher=created` at launch. After the email
is accepted by the relay, the tag is changed to `notified`. Every run first
looks for a non-terminated instance with the configured display name:

- no instance → make one launch attempt
- instance tagged `created` → retry the email, then tag it `notified`
- instance tagged `notified` → do nothing

That means no PVC or local state file is needed, and a crash between launch and
email cannot create a second instance.

After the alert is sent, the job patches its own CronJob to `suspend: true`
using the `oci-capacity-watcher` ServiceAccount. The Role only allows `patch`
on this one CronJob. The `workloads` ApplicationSet ignores
`CronJob.spec.suspend`, so ArgoCD self-heal does not undo the suspension. To
re-arm after terminating the instance:

```bash
kubectl -n oci-capacity-watcher patch cronjob oci-capacity-watcher \
  --type merge -p '{"spec":{"suspend":false}}'
```

## Build

```bash
docker build -t harbor.alialjaffer.com/mirror/oci-capacity-watcher:0.1.0 .
docker push harbor.alialjaffer.com/mirror/oci-capacity-watcher:0.1.0
```

Then pin the pushed digest in `cronjob.yaml`.

## OCI credentials

The `oci-capacity-watcher` Secret is a SealedSecret in this namespace. It holds
`config`, `oci_api_key.pem`, and `compartment-id`. To rotate the API key:

```bash
sed 's|^key_file=.*|key_file=/oci/oci_api_key.pem|' ~/.oci/config > /tmp/config
kubectl create secret generic oci-capacity-watcher -n oci-capacity-watcher \
  --from-file=config=/tmp/config \
  --from-file=oci_api_key.pem="$HOME/.oci/oci_api_key.pem" \
  --from-literal=compartment-id="$(grep '^OCI_COMPARTMENT_ID=' ~/oci-capacity/config.env | cut -d= -f2-)" \
  --dry-run=client -o yaml \
  | kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller -o yaml \
  > oci-capacity-watcher.sealed.yaml
```

## Operations

```bash
kubectl -n oci-capacity-watcher get cronjob,jobs,pods
kubectl -n oci-capacity-watcher logs job/$(kubectl -n oci-capacity-watcher get jobs \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
```

Pause it without deleting anything:

```bash
kubectl -n oci-capacity-watcher patch cronjob oci-capacity-watcher \
  --type merge -p '{"spec":{"suspend":true}}'
```

The `smtp-relay` CiliumNetworkPolicy allows ingress from this namespace on port
587. The relay itself is in the `mail` namespace and needs no credentials from
inside the cluster.

The job logs and exits quietly when OCI returns `Out of host capacity`; it does
not send failure email, so a long wait produces no inbox noise.
