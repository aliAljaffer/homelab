# Monitoring

This directory contains the monitoring stack (Prometheus + Grafana) for the homelab cluster.

## Components

### Prometheus

Prometheus is an open-source monitoring and alerting toolkit for collecting and storing time-series metrics.

**Files:**

- `prometheus-configmap.yaml` - Prometheus configuration
- `prometheus-deployment.yaml` - Prometheus server deployment
- `prometheus-service.yaml` - Prometheus ClusterIP service

### Grafana

Grafana is an open-source analytics and monitoring solution for visualizing time-series data.

**Files:**

- `grafana-configmap.yaml` - Grafana datasource configuration
- `grafana-deployment.yaml` - Grafana deployment
- `grafana-service.yaml` - Grafana LoadBalancer service
- `grafana-pvc.yaml` - Persistent storage for Grafana

## Installation

### Quick Deploy

Deploy the entire monitoring stack:

```bash
# Create namespace
kubectl apply -f namespace.yaml

# Deploy Prometheus
kubectl apply -f prometheus-configmap.yaml
kubectl apply -f prometheus-deployment.yaml
kubectl apply -f prometheus-service.yaml

# Deploy Grafana
kubectl apply -f grafana-configmap.yaml
kubectl apply -f grafana-alerting-configmap.yaml
kubectl apply -f grafana-pvc.yaml
kubectl apply -f grafana-deployment.yaml
kubectl apply -f grafana-service.yaml
```

Or deploy all at once:

```bash
kubectl apply -f .
```

### Verification

```bash
# Check pods are running
kubectl get pods -n monitoring

# Check services
kubectl get svc -n monitoring

# Get Grafana external IP
kubectl get svc grafana -n monitoring
```

## Configuration

### Prometheus

The Prometheus configuration is stored in `prometheus-configmap.yaml`.

**Current scrape targets:**

- Prometheus itself (localhost:9090)
- Control plane node (192.168.68.67:9100)

**Adding more targets:**

Edit `prometheus-configmap.yaml` and add new jobs:

```yaml
scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "control-plane"
    static_configs:
      - targets: ["192.168.68.67:9100"]

  - job_name: "gpu-node" # Add new target
    static_configs:
      - targets: ["192.168.68.56:9100"]
```

Then apply the changes:

```bash
kubectl apply -f prometheus-configmap.yaml
kubectl rollout restart deployment prometheus-server -n monitoring
```

### Grafana

**Default credentials:**

- Username: `admin`
- Password: `admin` (you'll be prompted to change on first login)

**Accessing Grafana:**

```bash
# Get the external IP
kubectl get svc grafana -n monitoring

# In this setup, Grafana should be available at:
# http://192.168.68.45:3000
```

**Pre-configured datasource:**

- Prometheus is automatically configured as the default datasource
- URL: `http://prometheus-service:9090`

## Storage

Grafana uses a 1Gi PersistentVolumeClaim (PVC) for storing:

- Dashboards
- User data
- Plugins
- Settings

The PVC uses the `local-path` storage class (K3s default).

**Backup Grafana data:**

```bash
# Get the pod name
GRAFANA_POD=$(kubectl get pod -n monitoring -l app=grafana -o jsonpath="{.items[0].metadata.name}")

# Backup Grafana data
kubectl exec -n monitoring $GRAFANA_POD -- tar czf /tmp/grafana-backup.tar.gz /var/lib/grafana
kubectl cp monitoring/$GRAFANA_POD:/tmp/grafana-backup.tar.gz ./grafana-backup.tar.gz
```

## Dashboards

### Importing Dashboards

1. Access Grafana web UI
2. Go to **Dashboards** → **Import**
3. Enter a dashboard ID from [Grafana Dashboards](https://grafana.com/grafana/dashboards/)

**Recommended dashboards:**

- **Node Exporter Full** (ID: 1860) - For node metrics
- **Kubernetes Cluster Monitoring** (ID: 7249)
- **NVIDIA GPU Metrics** (ID: 14574) - For GPU monitoring

### Creating Custom Dashboards

Grafana dashboards are persisted in the PVC, so they'll survive pod restarts.

## Monitoring Targets

### Setting up Node Exporter

To monitor your nodes, install node-exporter on each node:

```bash
# On each node, install node_exporter
# Ubuntu/Debian:
sudo apt-get install prometheus-node-exporter

# Fedora:
sudo dnf install golang-github-prometheus-node-exporter

# Start and enable
sudo systemctl start node_exporter
sudo systemctl enable node_exporter
```

Or deploy as a DaemonSet:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: node-exporter
  template:
    metadata:
      labels:
        app: node-exporter
    spec:
      hostNetwork: true
      hostPID: true
      containers:
        - name: node-exporter
          image: prom/node-exporter:latest
          args:
            - --path.procfs=/host/proc
            - --path.sysfs=/host/sys
          ports:
            - containerPort: 9100
          volumeMounts:
            - name: proc
              mountPath: /host/proc
              readOnly: true
            - name: sys
              mountPath: /host/sys
              readOnly: true
      volumes:
        - name: proc
          hostPath:
            path: /proc
        - name: sys
          hostPath:
            path: /sys
```

## Resource Usage

**Prometheus:**

- CPU Request: 250m
- Memory Request: 256Mi
- CPU Limit: 500m
- Memory Limit: 512Mi

**Grafana:**

- CPU Request: 250m
- Memory Request: 750Mi

**Storage:**

- Grafana PVC: 1Gi

## Troubleshooting

### Prometheus not scraping targets

```bash
# Check Prometheus logs
kubectl logs -n monitoring -l app=prometheus-server

# Check if targets are reachable
kubectl exec -n monitoring -it deployment/prometheus-server -- wget -O- http://192.168.68.67:9100/metrics

# Check Prometheus targets in UI
kubectl port-forward -n monitoring svc/prometheus-service 9090:9090
# Visit http://localhost:9090/targets
```

### Grafana not accessible

```bash
# Check pod status
kubectl get pods -n monitoring -l app=grafana

# Check service
kubectl get svc grafana -n monitoring

# Check logs
kubectl logs -n monitoring -l app=grafana

# Port-forward if LoadBalancer is not working
kubectl port-forward -n monitoring svc/grafana 3000:3000
# Visit http://localhost:3000
```

### Grafana can't connect to Prometheus

```bash
# Test connectivity from Grafana pod
GRAFANA_POD=$(kubectl get pod -n monitoring -l app=grafana -o jsonpath="{.items[0].metadata.name}")
kubectl exec -n monitoring $GRAFANA_POD -- wget -O- http://prometheus-service:9090/api/v1/status/config

# Check Prometheus service
kubectl get svc prometheus-service -n monitoring
kubectl get endpoints prometheus-service -n monitoring
```

### PVC stuck in Pending

```bash
# Check PVC status
kubectl get pvc -n monitoring
kubectl describe pvc grafana-pvc -n monitoring

# Check local-path provisioner
kubectl get pods -n kube-system | grep local-path-provisioner
kubectl logs -n kube-system -l app=local-path-provisioner
```

## Metrics Retention

By default, Prometheus stores metrics for 15 days. To change this:

Edit `prometheus-deployment.yaml` and add the `--storage.tsdb.retention.time` flag:

```yaml
containers:
  - name: prometheus-server
    image: prom/prometheus:latest
    args:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=30d # Change retention period
```

## Scaling

### Prometheus

For larger deployments, consider:

- Increasing resources in `prometheus-deployment.yaml`
- Adding a PVC for persistent storage
- Using Thanos or Cortex for long-term storage

### Grafana

Grafana can be scaled horizontally:

```bash
kubectl scale deployment grafana -n monitoring --replicas=2
```

Note: Multiple replicas require shared storage or an external database.

## Alerting (Optional)

To add alerting with Alertmanager:

1. Deploy Alertmanager
2. Configure alert rules in Prometheus
3. Set up notification channels (email, Slack, PagerDuty, etc.)

Example alert rule:

```yaml
groups:
  - name: node_alerts
    rules:
      - alert: HighMemoryUsage
        expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100 > 90
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage on {{ $labels.instance }}"
```

## References

- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/grafana/latest/)
- [Prometheus Exporters](https://prometheus.io/docs/instrumenting/exporters/)
- [Grafana Dashboards Library](https://grafana.com/grafana/dashboards/)
