# Catus Locatus

This is the same app found in [catus-locatus-k8s](https://github.com/aliAljaffer/catus-locatus-k8s) but I changed its Azure-specific components to be more suitable for self-hosting:

- Azure Kubernetes Service -> `K3s`
- Azure PostgreSQL Database + PostGIS Extension -> `postgis/postgis` image
- Azure Storage for user image uploads -> `MinIO`
- Azure Container Registry -> Dockerhub (Didn't want to complicate it with a self-hosted registry)
- Exposing services publicly via Ingress -> Exposing services via `cloudflared` Tunnel!

You can visit the app here: [Catus Locatus](https://team4.tuwaiqtracker.com)
