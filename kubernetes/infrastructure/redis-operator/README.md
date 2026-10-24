# redis-operator

OT-CONTAINER-KIT redis-operator with a Valkey instance. Chosen over the
official valkey-operator: a more mature operator whose `Redis` CR also runs
Valkey images. Valkey is the BSD-licensed Linux Foundation fork (Redis changed
to a restricted license in 2024).

## Components

- `redis-operator` Helm chart (namespace `redis-operator`), controller
  metrics on `:8080`, exposed through the `redis-operator-metrics` Service the
  chart does not create itself.
- `valkey.yaml` - a standalone Valkey instance (CR kind `Redis`, apiVersion
  `redis.redis.opstreelabs.in/v1beta2`). The CRD requires an explicit
  `redisExporter.image` (no operator fallback exists). No password:
  cluster-internal only. If anything ever needs to be exposed outside the
  cluster (Ingress, LoadBalancer, port-forward by a third party), first set
  `kubernetesConfig.redisSecret`.

## Metrics

`servicemonitors.yaml` labels everything `release: monitoring` so the
kube-prometheus-stack Prometheus picks it up, and Thanos ships it:

- `redis-operator` monitor: the operator's own metrics.
- `valkey-instances` monitor: selects every `<cr-name>-metrics` Service the
  operator auto-creates for any instance in any namespace (oliver006
  redis_exporter, `redis_exporter_*` metrics). New instances in app
  namespaces need no extra monitor.

Useful queries: `redis_up`, `redis_memory_used_bytes`,
`redis_connected_clients`, `redis_commands_processed_total`. A Grafana
dashboard for redis_exporter is a TODO if needed.
