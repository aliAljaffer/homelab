# Thanos

Object storage config lives in the sealed `thanos-objstore-secret` (GCS bucket
`alialjaffer-homelab`). See `kubernetes/infrastructure/monitoring/README.md` for
the long-term-storage design and the Aug–Oct 2026 metrics-loss incident.

## Compactor storage is resized by hand

`compactor.persistence.size` in `values.yaml` is the size a **fresh install**
provisions. It does **not** resize an existing volume:

- `spec.volumeClaimTemplates` is immutable on a live StatefulSet, so ArgoCD
  cannot apply a size change to the running `thanos-compactor` STS. The field is
  listed under `ignoreDifferences` in
  `kubernetes/argocd/apps/infrastructure/thanos.yaml` so a values bump keeps the
  app Synced instead of failing the forbidden patch.
- Longhorn supports online volume expansion, so the fix is a live PVC patch plus
  a pod restart (the restart is what runs `resize2fs`):

  ```bash
  kubectl -n monitoring patch pvc data-thanos-compactor-0 \
    -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'
  kubectl -n monitoring delete pod thanos-compactor-0
  kubectl -n monitoring get pvc data-thanos-compactor-0   # CAPACITY should now match REQ
  ```

On 2026-10-16 the compactor filled its original 10Gi and halted with
`compaction: ...: preallocate: no space left on device`, which stops all
downsampling and retention. It was expanded to 50Gi (6.2G in use). If a fresh
install is ever needed, the StatefulSet must be deleted (PVCs are orphaned and
safe) so the new `volumeClaimTemplates` size takes effect.
