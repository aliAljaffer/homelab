# harbor

LAN-only Harbor, used as a **pull-through cache** for the whole cluster.

- URL: <https://harbor.alialjaffer.com> (Pi-hole resolves it to the
  `homelab-gateway` at `192.168.8.129`; TLS is the `*.alialjaffer.com`
  certificate on the gateway, so Harbor itself speaks HTTP inside the cluster).
- Admin user: `admin`. The password is in the `harbor-admin` Secret:

  ```bash
  kubectl -n harbor get secret harbor-admin \
    -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d
  ```

  It is the password Harbor was initialised with; changing it in the UI will
  drift from the secret (the chart only uses it on first start).

## Proxy cache projects

`setup-job.yaml` is a PostSync hook that creates the remote registries and
public proxy-cache projects through the Harbor API (Harbor has no declarative
CRD for them). It is idempotent and runs on every sync.

| Project     | Upstream            | Talos mirror URL                          |
| ----------- | ------------------- | ----------------------------------------- |
| `dockerhub` | `docker.io`         | `.../v2/dockerhub/`                       |
| `ghcr`      | `ghcr.io`           | `.../v2/ghcr/`                            |
| `quay`      | `quay.io`           | `.../v2/quay/` (generic `docker-registry`)|
| `k8s`       | `registry.k8s.io`   | `.../v2/k8s/`                             |

The projects are public so containerd can pull anonymously.

## Talos containerd mirrors

Each node config in `talos/clusterconfig/*.sops.yaml` has four
`RegistryMirrorConfig` documents, for example:

```yaml
apiVersion: v1alpha1
kind: RegistryMirrorConfig
name: docker.io
endpoints:
  - url: https://harbor.alialjaffer.com/v2/dockerhub/
    overridePath: true
```

`overridePath: true` makes containerd use the supplied path verbatim, which is
what maps `docker.io/library/nginx` to Harbor's
`/v2/dockerhub/library/nginx`. There is no `skipFallback`, so a down Harbor
falls back to the upstream registry.

Apply after editing:

```bash
SOPS_AGE_KEY_FILE=$HOME/homelab.age sops -d talos/clusterconfig/k8s-homelab-wrk2.sops.yaml > /tmp/wrk2.yaml
talosctl --talosconfig ~/talosconfig apply-config -n 192.168.8.103 -f /tmp/wrk2.yaml --mode=no-reboot
```

## Adding an upstream

1. Add a `ensure_registry` + `ensure_project` pair to `setup-job.yaml`.
   Use `docker-registry` for generic registries (Harbor rejects e.g. the `quay`
   type for proxy cache).
2. Add a `RegistryMirrorConfig` document with
   `url: https://harbor.alialjaffer.com/v2/<project>/` and
   `overridePath: true` to every `talos/clusterconfig/*.sops.yaml`.
3. Re-apply the node configs and re-run the hook (ArgoCD sync).

## Notes

- Registry storage is a 20Gi Longhorn PVC (`persistence` in `values.yaml`).
  Losing it only means re-pulling; database/Redis are also PVC-backed.
- First pull of a new upstream image still crosses the WAN (Harbor fetches it
  once). Every other node then pulls over the LAN. Very large upstream layers
  can race Harbor's proxy-cache manifest commit on a slow upstream; the client
  pull still succeeds via fallback and a retry usually populates the cache.
- Trivy is disabled (`trivy.enabled: false`).
