# Bootstrap Runbook

One-time imperative steps to bring up a fresh Talos cluster. After bootstrap, ArgoCD manages everything declaratively from Git.

## Helm values tracking

All Helm chart values are committed to Git alongside their ArgoCD Applications. Nothing is managed outside of the repo.

| Component | Values file |
|-----------|-------------|
| Cilium (bootstrap) | `kubernetes/bootstrap/cilium/values.yaml` |
| ArgoCD (bootstrap) | `kubernetes/bootstrap/argocd/values.yaml` |
| Sealed Secrets | `kubernetes/infrastructure/sealed-secrets/values.yaml` |
| cert-manager | `kubernetes/infrastructure/cert-manager/values.yaml` |
| MetalLB | `kubernetes/infrastructure/metallb/values.yaml` |
| Longhorn | `kubernetes/infrastructure/longhorn/values.yaml` |
| ExternalDNS | `kubernetes/infrastructure/external-dns/values.yaml` |
| kube-prometheus-stack | `kubernetes/infrastructure/monitoring/values.yaml` |
| Loki | `kubernetes/infrastructure/loki/values.yaml` |
| Thanos | `kubernetes/infrastructure/thanos/values.yaml` |
| Grafana Alloy | `kubernetes/infrastructure/alloy/values.yaml` |

Cilium and ArgoCD are bootstrap-installed imperatively (their Helm releases are not managed by ArgoCD). Values are tracked in `kubernetes/bootstrap/`. Everything else is fully ArgoCD-managed.

---

## Before you start

```bash
export KUBECONFIG=~/.kube/homelab-talos
```

---

## Step 1 - Talos extensions + CNI switch

### 1a. Generate installer image with extensions (Talos Image Factory)

Worker nodes need `iscsi-tools` (Longhorn), `util-linux-tools` (Longhorn), `intel-ucode` (M920q), and `i915` (Intel iGPU / Quick Sync):

```bash
# Worker schematic (iscsi + util-linux + intel-ucode + i915)
WORKER_ID=$(curl -sS -X POST https://factory.talos.dev/schematics \
  -H 'Content-Type: application/json' \
  -d '{"customization":{"systemExtensions":{"officialExtensions":["siderolabs/iscsi-tools","siderolabs/util-linux-tools","siderolabs/intel-ucode","siderolabs/i915-ucode","siderolabs/i915"]}}}' \
  | jq -r '.id')

# Control plane schematic (intel-ucode only)
CP_ID=$(curl -sS -X POST https://factory.talos.dev/schematics \
  -H 'Content-Type: application/json' \
  -d '{"customization":{"systemExtensions":{"officialExtensions":["siderolabs/intel-ucode"]}}}' \
  | jq -r '.id')
```

### 1b. Patch machine config (disable default CNI + kube-proxy)

```bash
cat > /tmp/cp-patch.yaml << 'EOF'
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
machine:
  kubelet:
    extraArgs:
      rotate-server-certificates: "true"
EOF

cat > /tmp/worker-patch.yaml << 'EOF'
cluster:
  proxy:
    disabled: true
machine:
  kubelet:
    extraArgs:
      rotate-server-certificates: "true"
EOF

talosctl patch machineconfig -n 192.168.8.100 -m no-reboot --patch-file /tmp/cp-patch.yaml
talosctl patch machineconfig -n 192.168.8.101 -m no-reboot --patch-file /tmp/worker-patch.yaml
talosctl patch machineconfig -n 192.168.8.102 -m no-reboot --patch-file /tmp/worker-patch.yaml
```

### 1c. Upgrade nodes with extensions

```bash
# Upgrade workers (includes iscsi-tools for Longhorn + GPU extensions)
for node in 192.168.8.101 192.168.8.102; do
  talosctl upgrade -n $node --image "factory.talos.dev/installer/${WORKER_ID}:v1.13.7"
done

# Upgrade control plane (intel-ucode only)
talosctl upgrade -n 192.168.8.100 --image "factory.talos.dev/installer/${CP_ID}:v1.13.7"
```

Nodes will reboot into NotReady state. That's expected until Cilium is deployed.

## Step 2 - Install Gateway API CRDs

This has to happen before Cilium starts its Gateway controller.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/experimental-install.yaml
```

## Step 3 - Install Cilium

```bash
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --version 1.17.3 \
  --namespace kube-system \
  --values kubernetes/bootstrap/cilium/values.yaml
```

Wait for nodes to come Ready:
```bash
kubectl wait --for=condition=Ready nodes --all --timeout=300s
```

## Step 4 - Install ArgoCD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd --version 7.9.0 \
  --namespace argocd --create-namespace \
  --values kubernetes/bootstrap/argocd/values.yaml
```

## Step 5 - Install Sealed Secrets Controller

```bash
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.38.4/controller.yaml
```

Fetch the public cert for sealing secrets:
```bash
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  > pub-sealed-secrets.pem
```

## Step 6 - Seal all secrets and commit

For each secret template in `templates/`, fill in real values and seal:

```bash
# Example: catus-locatus app secret
kubectl create secret generic catus-locatus-secrets \
  --from-literal=DATABASE_URL=... \
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
```

## Step 7 - Bootstrap App-of-Apps

```bash
# Create the longhorn namespace with privileged PodSecurity label (needed for Longhorn)
kubectl create namespace longhorn-system
kubectl label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=latest

# Create service account required by Longhorn pre-upgrade hook
kubectl create serviceaccount longhorn-service-account -n longhorn-system

# Install Longhorn with --no-hooks to bypass pre-upgrade check on fresh install
helm repo add longhorn https://charts.longhorn.io
helm install longhorn longhorn/longhorn --version 1.8.1 \
  --namespace longhorn-system --no-hooks \
  --values kubernetes/infrastructure/longhorn/values.yaml

# Apply ArgoCD projects and root App-of-Apps
kubectl apply -f kubernetes/argocd/projects/
kubectl apply -f kubernetes/argocd/apps/infrastructure.yaml
kubectl apply -f kubernetes/argocd/apps/workloads.yaml
```

ArgoCD syncs everything from Git. Watch progress:
```bash
kubectl -n argocd get applications -w
```

## Step 8 - Create MinIO buckets

After MinIO is running in `catus-locatus`, create the observability buckets:

```bash
kubectl run mc --image=minio/mc --rm -it --restart=Never -- \
  /bin/sh -c "
    mc alias set minio http://minio.catus-locatus.svc.cluster.local:9000 \$MINIO_ROOT_USER \$MINIO_ROOT_PASSWORD && \
    mc mb minio/thanos && \
    mc mb minio/loki && \
    mc mb minio/velero
  "
```

## Step 9 - Talos config encryption (optional but recommended)

```bash
# Generate age key
age-keygen -o homelab.age

# Update .sops.yaml with the public key, then encrypt:
sops --encrypt talos/clusterconfig/k8s-homelab-controlplane.yaml \
  > talos/clusterconfig/k8s-homelab-controlplane.sops
sops --encrypt talos/clusterconfig/k8s-homelab-worker.yaml \
  > talos/clusterconfig/k8s-homelab-worker.sops

# Store homelab.age securely (NOT in Git)
```
