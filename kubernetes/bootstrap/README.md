# Bootstrap Runbook

One-time imperative steps to bring up a fresh Talos cluster. After bootstrap,
ArgoCD manages everything declaratively from Git.

## Prerequisites

```bash
export KUBECONFIG=~/.kube/homelab-talos
```

---

## Step 1 — Talos CNI: Replace Flannel with Cilium

The cluster must be reconfigured to disable the default CNI before Cilium can take over.

```bash
# Apply CNI=none + kube-proxy disabled to control plane
talosctl -n 192.168.8.100 machineconfig apply --mode=reboot \
  --config-patch '[{"op":"add","path":"/cluster/network/cni","value":{"name":"none"}},{"op":"add","path":"/cluster/proxy","value":{"disabled":true}}]'

# Apply same patch + Longhorn extensions to each worker
for node in 192.168.8.101 192.168.8.102 192.168.8.103; do
  talosctl -n $node machineconfig apply --mode=reboot \
    --config-patch '[
      {"op":"add","path":"/cluster/proxy","value":{"disabled":true}},
      {"op":"add","path":"/machine/install/extensions","value":[
        {"image":"ghcr.io/siderolabs/iscsi-tools:v0.1.6"},
        {"image":"ghcr.io/siderolabs/util-linux-tools:v2.40.2"}
      ]}
    ]'
done
```

Nodes will enter NotReady state — expected until Cilium is deployed.

## Step 2 — Install Gateway API CRDs

Must happen before Cilium starts its Gateway controller.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

## Step 3 — Install Cilium

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium --version 1.17.3 \
  --namespace kube-system \
  --values kubernetes/bootstrap/cilium/values.yaml
```

Wait for all nodes to return Ready:
```bash
kubectl wait --for=condition=Ready nodes --all --timeout=300s
cilium status --wait
```

## Step 4 — Install ArgoCD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd --version 7.9.0 \
  --namespace argocd --create-namespace \
  --values kubernetes/bootstrap/argocd/values.yaml
```

## Step 5 — Install Sealed Secrets Controller

```bash
kubectl kustomize --enable-helm kubernetes/bootstrap/sealed-secrets | kubectl apply -f -
```

Save the public certificate (used to seal new secrets):
```bash
kubeseal --fetch-cert \
  --controller-name sealed-secrets-controller \
  --controller-namespace kube-system \
  > pub-sealed-secrets.pem
```

## Step 6 — Seal All Secrets and Commit

For each secret template in `templates/`, fill in real values and seal:

```bash
# Example: catus-locatus app secret
kubectl create secret generic catus-locatus-secrets \
  --from-literal=DATABASE_URL=... \
  --from-literal=... \
  --dry-run=client -o yaml \
  | kubeseal --cert pub-sealed-secrets.pem -o yaml \
  > kubernetes/apps/catus-locatus/secrets.sealed.yaml

# Thanos objectstore (MinIO credentials)
kubectl create secret generic thanos-objstore-secret \
  --namespace monitoring \
  --from-literal=objstore.yml="$(cat <<EOF
type: S3
config:
  bucket: thanos
  endpoint: minio.catus-locatus.svc.cluster.local:9000
  access_key: MINIO_ACCESS_KEY
  secret_key: MINIO_SECRET_KEY
  insecure: true
  http_config:
    insecure_skip_verify: true
EOF
)" \
  --dry-run=client -o yaml \
  | kubeseal --cert pub-sealed-secrets.pem -o yaml \
  > kubernetes/infrastructure/monitoring/thanos-objstore.sealed.yaml

# Route53 credentials for cert-manager
kubectl create secret generic route53-credentials \
  --namespace cert-manager \
  --from-literal=account-access-key=AWS_ACCESS_KEY_ID \
  --from-literal=secret-access-key=AWS_SECRET_ACCESS_KEY \
  --dry-run=client -o yaml \
  | kubeseal --cert pub-sealed-secrets.pem -o yaml \
  > kubernetes/infrastructure/cert-manager/route53-credentials.sealed.yaml

# Loki MinIO credentials
kubectl create secret generic loki-minio-secret \
  --namespace monitoring \
  --from-literal=AWS_ACCESS_KEY_ID=MINIO_ACCESS_KEY \
  --from-literal=AWS_SECRET_ACCESS_KEY=MINIO_SECRET_KEY \
  --dry-run=client -o yaml \
  | kubeseal --cert pub-sealed-secrets.pem -o yaml \
  > kubernetes/infrastructure/loki/loki-minio.sealed.yaml
```

Commit all `.sealed.yaml` files to Git (they are safe to commit).

## Step 7 — Bootstrap App-of-Apps

```bash
# Create ArgoCD projects first
kubectl apply -f kubernetes/argocd/projects/

# Apply the root App-of-Apps Applications
kubectl apply -f kubernetes/argocd/apps/infrastructure.yaml
kubectl apply -f kubernetes/argocd/apps/workloads.yaml
```

ArgoCD will now sync everything from Git. Watch progress:
```bash
kubectl -n argocd get applications -w
```

## Step 8 — Create MinIO Buckets

After MinIO is running in catus-locatus, create the observability buckets:

```bash
kubectl run mc --image=minio/mc --rm -it --restart=Never -- \
  /bin/sh -c "
    mc alias set minio http://minio.catus-locatus.svc.cluster.local:9000 \$MINIO_ROOT_USER \$MINIO_ROOT_PASSWORD && \
    mc mb minio/thanos && \
    mc mb minio/loki && \
    mc mb minio/velero
  "
```

## Step 9 — Talos Config Encryption (optional but recommended)

Encrypt your generated Talos machine configs with SOPS:

```bash
# Generate age key if you don't have one
age-keygen -o homelab.age

# Update .sops.yaml with the public key from homelab.age
# Then encrypt:
sops --encrypt talos/clusterconfig/k8s-homelab-controlplane.yaml \
  > talos/clusterconfig/k8s-homelab-controlplane.sops
sops --encrypt talos/clusterconfig/k8s-homelab-worker.yaml \
  > talos/clusterconfig/k8s-homelab-worker.sops

# Store homelab.age securely (NOT in Git)
```
