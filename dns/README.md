# DNS (Pi-hole)

This directory contains the Pi-hole deployment for network-wide ad blocking and DNS management.

## Overview

Pi-hole is a network-level ad blocker that acts as a DNS sinkhole. It blocks ads and tracking domains before they even reach your devices.

## Files

- `pihole-namespace.yaml` - Pi-hole namespace
- `pihole-configmap.yaml` - Custom dnsmasq configuration
- `pihole-deployment.yaml` - Pi-hole deployment
- `pihole-service-dns.yaml` - DNS service (NodePort)
- `pihole-service-web.yaml` - Web UI service (LoadBalancer)

## Installation

### Prerequisites

- MetalLB installed and configured (for LoadBalancer service)
- Available external IP in MetalLB pool

### Step 1: Configure

**IMPORTANT**: Edit `pihole-deployment.yaml` before deploying!

Update these environment variables:

```yaml
env:
  - name: TZ
    value: Asia/Riyadh # Change to your timezone

  - name: WEBPASSWORD
    value: "CHANGE_ME" # Set a secure password!

  - name: ServerIP
    value: "192.168.68.40" # Update with your LoadBalancer IP
```

### Step 2: Deploy

```bash
# Deploy all Pi-hole resources
kubectl apply -f pihole-namespace.yaml
kubectl apply -f pihole-configmap.yaml
kubectl apply -f pihole-deployment.yaml
kubectl apply -f pihole-service-dns.yaml
kubectl apply -f pihole-service-web.yaml
```

Or deploy all at once:

```bash
kubectl apply -f .
```

### Step 3: Verify

```bash
# Check pod status
kubectl get pods -n pihole

# Check services
kubectl get svc -n pihole

# Get external IPs
kubectl get svc -n pihole -o wide
```

Expected output:

```
NAME         TYPE           CLUSTER-IP      EXTERNAL-IP     PORT(S)
pihole-dns   NodePort       10.43.30.138    <none>          53:30053/TCP,53:30053/UDP
pihole-web   LoadBalancer   10.43.130.138   192.168.68.40   80:XXXXX/TCP
```

## Accessing Pi-hole

### Web Interface

Access the Pi-hole admin panel:

```
http://192.168.68.40/admin
```

Login with the password you set in `WEBPASSWORD`.

### DNS Service

Pi-hole DNS is available on:

- **LoadBalancer IP**: `192.168.68.40:53` (if supported by your load balancer)
- **NodePort**: `<any-node-ip>:30053`
- **Control Plane NodePort**: `192.168.68.67:30053`

## Configuration

### Setting Pi-hole as Your DNS Server

#### Option 1: Configure on Router

Set your router's DNS to point to Pi-hole:

- Primary DNS: `192.168.68.67` (control plane IP on NodePort 30053)
- Or use LoadBalancer IP if DNS works: `192.168.68.40`

This will apply to all devices on your network.

#### Option 2: Configure Per Device

On individual devices, set DNS to:

- `192.168.68.67` (or any node IP with NodePort)
- Port: `30053` (if your device supports custom DNS ports)

### Custom DNS Settings

Edit `pihole-configmap.yaml` to customize dnsmasq:

```yaml
data:
  02-custom.conf: |
    # Custom dnsmasq config
    cache-size=10000

    # Add custom DNS records
    address=/myapp.local/192.168.68.45

    # Add more configurations here
```

Apply changes:

```bash
kubectl apply -f pihole-configmap.yaml
kubectl rollout restart deployment pihole -n pihole
```

### Upstream DNS Servers

Edit the `PIHOLE_DNS_` environment variable in `pihole-deployment.yaml`:

```yaml
- name: PIHOLE_DNS_
  value: "8.8.8.8;8.8.4.4" # Google DNS
  # Or use:
  # value: "1.1.1.1;1.0.0.1"  # Cloudflare DNS
  # value: "9.9.9.9;149.112.112.112"  # Quad9 DNS
```

## Storage

Currently, Pi-hole does NOT use persistent storage. Data (blocklists, settings, etc.) will be lost if the pod restarts.

### Adding Persistent Storage

I plan to do this later, but I really don't care if query data is lost right now

Create a PVC and mount it:

**Create `pihole-pvc.yaml`:**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pihole-data
  namespace: pihole
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: local-path
```

**Update `pihole-deployment.yaml`:**

```yaml
volumeMounts:
  - name: pihole-data
    mountPath: /etc/pihole
    subPath: pihole
  - name: pihole-data
    mountPath: /etc/dnsmasq.d
    subPath: dnsmasq.d
  - name: custom-dnsmasq
    mountPath: /etc/dnsmasq.d/02-custom.conf
    subPath: 02-custom.conf

volumes:
  - name: pihole-data
    persistentVolumeClaim:
      claimName: pihole-data
  - name: custom-dnsmasq
    configMap:
      name: pihole-custom-dnsmasq
```

## Backup and Restore

### Backup Pi-hole Configuration

You can `cronjob` this one ;)

```bash
# Get pod name
PIHOLE_POD=$(kubectl get pod -n pihole -l app=pihole -o jsonpath="{.items[0].metadata.name}")

# Backup Pi-hole data
kubectl exec -n pihole $PIHOLE_POD -- tar czf /tmp/pihole-backup.tar.gz /etc/pihole /etc/dnsmasq.d
kubectl cp pihole/$PIHOLE_POD:/tmp/pihole-backup.tar.gz ./pihole-backup.tar.gz
```

### Restore Pi-hole Configuration

```bash
# Copy backup to pod
kubectl cp ./pihole-backup.tar.gz pihole/$PIHOLE_POD:/tmp/pihole-backup.tar.gz

# Restore
kubectl exec -n pihole $PIHOLE_POD -- tar xzf /tmp/pihole-backup.tar.gz -C /

# Restart Pi-hole
kubectl rollout restart deployment pihole -n pihole
```

## Troubleshooting

### Pi-hole web interface not accessible

```bash
# Check pod logs
kubectl logs -n pihole -l app=pihole

# Check service
kubectl get svc pihole-web -n pihole

# Port-forward if LoadBalancer is not working
kubectl port-forward -n pihole svc/pihole-web 8080:80
# Visit http://localhost:8080/admin
```

### DNS not working

```bash
# Test DNS resolution from a pod
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup google.com 10.43.30.138

# Test from outside the cluster
nslookup google.com 192.168.68.67 -port=30053

# Check Pi-hole logs
kubectl logs -n pihole -l app=pihole -f
```

You can also use the `dig` command to specify a DNS server like: `dig @192.168.68.42 google.com` for troubleshooting

### Pi-hole not blocking ads

1. Check if blocklists are loaded:

   - Go to Pi-hole admin → Tools → Update Gravity
   - Click "Update" to refresh blocklists

2. Verify DNS is actually going through Pi-hole:
   - Visit http://pi.hole/admin in your browser
   - Check the dashboard for query statistics

### Pod stuck in CrashLoopBackOff

```bash
# Check pod events
kubectl describe pod -n pihole -l app=pihole

# Check logs
kubectl logs -n pihole -l app=pihole --previous

# Common issues:
# - Insufficient permissions (requires root or capabilities)
# - Port 53 already in use?
# - Invalid environment variables
```

## Advanced Configuration

### Custom Blocklists

Add custom blocklists via the web UI:

1. Go to **Group Management** → **Adlists**
2. Add your blocklist URLs
3. Update Gravity

### Whitelist/Blacklist

Via web UI:

- **Whitelist**: Domains → Whitelist
- **Blacklist**: Domains → Blacklist

Or use CLI:

```bash
PIHOLE_POD=$(kubectl get pod -n pihole -l app=pihole -o jsonpath="{.items[0].metadata.name}")

# Whitelist
kubectl exec -n pihole $PIHOLE_POD -- pihole -w example.com

# Blacklist
kubectl exec -n pihole $PIHOLE_POD -- pihole -b ads.example.com
```

### Local DNS Records

Add local DNS records via web UI:

1. Go to **Local DNS** → **DNS Records**
2. Add domain and IP

Or edit the ConfigMap:

```yaml
data:
  02-custom.conf: |
    address=/grafana.local/192.168.68.45
    address=/pihole.local/192.168.68.40
```

## Security Best Practices

1. **Use a strong web password** - Don't leave the default!
2. **Enable DNSSEC** - In Pi-hole settings → DNS
3. **Limit query logging** - For privacy (Settings → Privacy)
4. **Regular updates** - Update Pi-hole container image regularly
5. **Use HTTPS** - Consider putting Pi-hole behind a reverse proxy with SSL

## Monitoring

Pi-hole provides metrics that can be scraped by Prometheus:

1. Enable API in Pi-hole settings
2. Use [pihole-exporter](https://github.com/eko/pihole-exporter) to expose metrics

```bash
# Deploy pihole-exporter (example)
kubectl run pihole-exporter -n pihole \
  --image=ekofr/pihole-exporter:latest \
  --env="PIHOLE_HOSTNAME=pihole.pihole.svc.cluster.local" \
  --env="PIHOLE_PASSWORD=your-password"
```

## References

- [Pi-hole Documentation](https://docs.pi-hole.net/)
- [Pi-hole Docker](https://github.com/pi-hole/docker-pi-hole)
- [dnsmasq Documentation](http://www.thekelleys.org.uk/dnsmasq/doc.html)
