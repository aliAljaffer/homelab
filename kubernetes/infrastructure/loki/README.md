# loki

- `values.yaml`: chart defaults to SimpleScalable. Without `deploymentMode: SingleBinary`, read/write/backend (disabled in this file) are the only serving components, leaving Loki with zero ingest/query capacity despite `singleBinary.replicas: 1`.

## Gateway DNS gotcha

The nginx gateway resolves target hostnames per request through `kube-dns`, but
it keeps long-lived UDP resolver sockets to whichever CoreDNS pod answered at
startup. If CoreDNS pods are rescheduled, those sockets stay pinned to the old
pod IPs and every gateway request hangs with
`could not be resolved (110: Operation timed out)` until nginx is reloaded:

```sh
kubectl exec -n monitoring deploy/loki-gateway -- nginx -s reload
```

Alloy, Grafana, and the canary therefore push/query `loki.monitoring.svc.cluster.local:3100`
directly. The gateway is only for UI/external access, so a gateway DNS failure
can no longer stall ingest or trip the Loki alerts.
