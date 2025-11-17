# Networking

This directory contains networking-related manifests for the homelab cluster.

## Components

### MetalLB

MetalLB provides LoadBalancer service support for bare-metal Kubernetes clusters.

**Files:**

- `metallb-ipaddresspool.yaml` - IP address pool configuration
- `metallb-l2advertisement.yaml` - L2 advertisement configuration

**Prerequisites:**

- MetalLB must be installed in your cluster (usually via Helm or kubectl)
- You must have a range of available IPs on your local network

**Installation:**

If MetalLB is not already installed:

```bash
# Install MetalLB using kubectl
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml

# Wait for MetalLB to be ready
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s
```

Then apply the configuration:

```bash
# Update the IP range in metallb-ipaddresspool.yaml to match your network
# Current range: 192.168.68.40-192.168.68.45
kubectl apply -f metallb-ipaddresspool.yaml
kubectl apply -f metallb-l2advertisement.yaml
```

**Configuration:**

Edit `metallb-ipaddresspool.yaml` to change the IP range:

```yaml
spec:
  addresses:
    - 192.168.68.40-192.168.68.45 # Change this to your available IPs
```

**Verification:**

```bash
# Check MetalLB pods
kubectl get pods -n metallb-system

# Check IP pool
kubectl get ipaddresspool -n metallb-system
kubectl describe ipaddresspool default-pool -n metallb-system

# Check L2 advertisement
kubectl get l2advertisement -n metallb-system
```

### Traefik

Traefik is a modern HTTP reverse proxy and load balancer that makes deploying microservices easy.

**Files:**

- `traefik-values.yaml` - Helm chart values

**Prerequisites:**

- Helm 3.x installed
- K3s typically comes with Traefik pre-installed

**Installation:**

If you need to reinstall or customize Traefik:

```bash
# Add Traefik Helm repository
helm repo add traefik https://helm.traefik.io/traefik
helm repo update

# Install or upgrade Traefik
helm upgrade --install traefik traefik/traefik \
  --namespace kube-system \
  --values traefik-values.yaml
```

**Configuration Notes:**

The current configuration includes:

- Prometheus metrics enabled on port 8082
- Rancher mirrored image (for better availability)
- Tolerations for control-plane and master nodes
- Dual-stack IP family support

**Verification:**

```bash
# Check Traefik pod
kubectl get pods -n kube-system | grep traefik

# Check Traefik service
kubectl get svc traefik -n kube-system

# Access Traefik dashboard (if enabled)
kubectl port-forward -n kube-system $(kubectl get pods -n kube-system | grep traefik | awk '{print $1}') 9000:9000
# Then visit http://localhost:9000/dashboard/
```

## Network Architecture

```
Internet
    |
    v
STC Router (192.168.68.1)
    |
    v
MetalLB IP Pool (192.168.68.40-45)
    |
    +-- 192.168.68.40 -> Pi-hole Web UI
    +-- 192.168.68.43 -> Traefik Ingress
    +-- 192.168.68.45 -> Grafana
    +-- 192.168.68.41-42, 44 (Available)
```

## Current IP Allocations

| IP Address    | Service    | Namespace   |
| ------------- | ---------- | ----------- |
| 192.168.68.40 | pihole-web | pihole      |
| 192.168.68.43 | traefik    | kube-system |
| 192.168.68.45 | grafana    | monitoring  |
| 192.168.68.41 | Available  | -           |
| 192.168.68.42 | Available  | -           |
| 192.168.68.44 | Available  | -           |

## Troubleshooting

### MetalLB not assigning IPs

```bash
# Check speaker pods are running on all nodes
kubectl get pods -n metallb-system -o wide

# Check logs
kubectl logs -n metallb-system -l component=speaker

# Ensure L2 advertisement is configured
kubectl get l2advertisement -n metallb-system
```

### Traefik not routing traffic

```bash
# Check Traefik logs
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik

# Check IngressRoute resources
kubectl get ingressroute --all-namespaces

# Verify service endpoints
kubectl get endpoints -n kube-system traefik
```

### LoadBalancer stuck in Pending

```bash
# Check MetalLB controller logs
kubectl logs -n metallb-system -l component=controller

# Verify IP pool has available addresses
kubectl describe ipaddresspool default-pool -n metallb-system
```

## Customization

### Adding More IPs to the Pool

Edit `metallb-ipaddresspool.yaml`:

```yaml
spec:
  addresses:
    - 192.168.68.40-192.168.68.45
    - 192.168.68.50-192.168.68.55 # Add another range
```

Then apply:

```bash
kubectl apply -f metallb-ipaddresspool.yaml
```

### Configuring Traefik Ingress

Create an IngressRoute resource:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: my-app
  namespace: default
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`myapp.local`)
      kind: Rule
      services:
        - name: my-app-service
          port: 80
```

## References

- [MetalLB Configuration](https://metallb.io/configuration/)
- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [K3s Networking](https://docs.k3s.io/networking)
