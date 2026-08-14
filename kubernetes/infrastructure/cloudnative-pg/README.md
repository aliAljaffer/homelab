# cloudnative-pg

- `podmonitor.yaml`: CloudNativePG's chart has no ServiceMonitor toggle and Cluster CRs don't create one either; PodMonitor targets the metrics port each pod already exposes.
