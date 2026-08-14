# loki

- `values.yaml`: chart defaults to SimpleScalable. Without `deploymentMode: SingleBinary`, read/write/backend (disabled in this file) are the only serving components, leaving Loki with zero ingest/query capacity despite `singleBinary.replicas: 1`.
