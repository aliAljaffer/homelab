# Backup and Restore

Honestly, if there's one thing you do for this cluster, make it these backups. Lose the Sealed Secrets key and every `.sealed.yaml` file in this repo is gone forever. Same with the SOPS age key - no key, no Talos machine configs.

**WARNING:** Loss of the Sealed Secrets key makes all `.sealed.yaml` files in this repository unreadable.

**WARNING:** Loss of the SOPS age key makes all encrypted Talos machine configs unreadable. You cannot rebuild the cluster without it.

---

## Quick reference

| Term | Meaning |
|---|---|
| Sealed Secrets key | The cluster private key that decrypts SealedSecret resources |
| SOPS age key | The age private key that decrypts `*.sops` files in `talos/clusterconfig/` |
| ArgoCD | The GitOps controller that applies all manifests to the cluster |
| Longhorn | The distributed storage system that holds all persistent volumes |

---

## Backups

### Sealed Secrets key

Do this right after you first install the cluster, and again after every rebuild. You need `kubectl` access and somewhere secure to store the key - 1Password works great here.

1. Set the kubeconfig.

   ```bash
   export KUBECONFIG=~/.kube/homelab-talos
   ```

2. Export the active Sealed Secrets private key.

   ```bash
   kubectl get secret \
     -n kube-system \
     -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
     -o yaml > sealed-secrets-master-key.yaml
   ```

3. Open `sealed-secrets-master-key.yaml` and confirm it is not empty.

4. Copy `sealed-secrets-master-key.yaml` to your secure storage.

5. Delete the local copy.

   ```bash
   rm sealed-secrets-master-key.yaml
   ```

Done. The key is safely stored and gone from disk.

---

### SOPS age key

One-time thing unless you rotate the key. The file you're looking for is `~/homelab.age`. If it doesn't exist, run `age-keygen -o ~/homelab.age` first and update `.sops.yaml` with the public key.

1. Open `~/homelab.age` and confirm it has a line starting with `AGE-SECRET-KEY-`.

2. Copy `~/homelab.age` to the same secure place as the Sealed Secrets key.

3. Don't delete `~/homelab.age` from your local machine - you still need it for SOPS operations.

That's it!

---

### Application data (Velero)

Run this daily, or at minimum before upgrading any stateful app. Velero covers `catus-locatus` and `obsidian-sync`. The `monitoring` namespace is excluded because Thanos already stores metrics permanently in MinIO.

Make sure Velero is installed and the `velero` MinIO bucket exists before you start.

1. Set the kubeconfig.

   ```bash
   export KUBECONFIG=~/.kube/homelab-talos
   ```

2. Start a backup.

   ```bash
   velero backup create homelab-$(date +%Y%m%d) \
     --include-namespaces catus-locatus \
     --wait
   ```

3. Confirm the status is `Completed`.

   ```bash
   velero backup get
   ```

4. If it shows `PartiallyFailed` or `Failed`, check why.

   ```bash
   velero backup describe homelab-$(date +%Y%m%d) --details
   ```

The backup lands in the `velero` MinIO bucket.

---

### Longhorn snapshots

Do this before Longhorn or node upgrades. Open the Longhorn UI at `https://longhorn.alialjaffer.com`, go to **Volume**, and for each volume click **Create Snapshot**. Takes 2 minutes.

---

## Restore

### Sealed Secrets key on a new cluster

**Do this before ArgoCD syncs anything.** If ArgoCD syncs first, all SealedSecrets will fail to unseal and you will have to re-sync them manually after. Not fun.

Make sure the Sealed Secrets controller is running and you have `sealed-secrets-master-key.yaml` from your secure storage.

1. Copy `sealed-secrets-master-key.yaml` from your secure storage to your local machine.

2. Apply the key.

   ```bash
   kubectl apply -f sealed-secrets-master-key.yaml
   ```

3. Restart the controller so it picks up the restored key.

   ```bash
   kubectl rollout restart deployment/sealed-secrets-controller -n kube-system
   ```

4. Wait for it to be ready.

   ```bash
   kubectl rollout status deployment/sealed-secrets-controller -n kube-system
   ```

5. Delete the local copy.

   ```bash
   rm sealed-secrets-master-key.yaml
   ```

6. Check that SealedSecrets are readable.

   ```bash
   kubectl get sealedsecret -A
   ```

   The `AGE` column must show a value. A blank means the controller did not unseal the secret.

All SealedSecrets are now readable. ArgoCD can sync.

---

### Decrypt and apply SOPS-encrypted Talos machine configs

Use this when you need to re-apply a machine config after a node rebuild or config change.

You need `homelab.age` on your local machine, and both `sops` and `talosctl` installed.

**Note:** Each node has its own file in `talos/clusterconfig/`. Only the secret values are encrypted - the cluster structure is readable without decryption.

| File | Node |
|---|---|
| `talos/clusterconfig/k8s-homelab-cp0.sops.yaml` | ⚠️ STALE — see note below |
| `talos/clusterconfig/k8s-homelab-wrk0.sops.yaml` | wrk0 - 192.168.8.101 |
| `talos/clusterconfig/k8s-homelab-wrk1.sops.yaml` | wrk1 - 192.168.8.102 |

> **⚠️ cp0 topology change (2026-08-08):** control plane moved from the M920q (was `cp0`, 192.168.8.100, now repurposed as `wrk3`) to the MacBook Pro (`cp0`, 192.168.8.99). `k8s-homelab-cp0.sops.yaml` still contains the **old M920q's** config (wrong disk, wrong hardware) — do not apply it as-is. It needs regenerating via `talhelper genconfig` against an updated `talconfig.yaml`, and there's no SOPS file yet for `wrk3`. The Mac also requires a non-standard install (custom kernel + GRUB bootloader instead of systemd-boot) — see `docs/talos-intel-mac.md` before reinstalling it via any standard flow, or it will silently regress to the boot hang that doc describes.

1. Set the age key path.

   ```bash
   export SOPS_AGE_KEY_FILE=~/homelab.age
   ```

2. Apply the config for each node. This decrypts inline without writing plaintext to disk.

   **Do not run the `cp0` command below until `k8s-homelab-cp0.sops.yaml` has been regenerated** — see the warning above.

   ```bash
   sops --decrypt talos/clusterconfig/k8s-homelab-cp0.sops.yaml \
     | talosctl apply-config -n 192.168.8.99 --file /dev/stdin

   sops --decrypt talos/clusterconfig/k8s-homelab-wrk0.sops.yaml \
     | talosctl apply-config -n 192.168.8.101 --file /dev/stdin

   sops --decrypt talos/clusterconfig/k8s-homelab-wrk1.sops.yaml \
     | talosctl apply-config -n 192.168.8.102 --file /dev/stdin
   ```

3. If you need the plaintext on disk for inspection, decrypt it and delete it when done.

   ```bash
   sops --decrypt talos/clusterconfig/k8s-homelab-cp0.sops.yaml \
     > /tmp/cp0-config.yaml
   # inspect, then:
   rm /tmp/cp0-config.yaml
   ```

Machine configs applied. No plaintext written to disk.

---

### Restore application data from Velero

Use this when a namespace loses data and you need to restore from backup.

**CAUTION:** Restoring into an existing namespace overwrites current data. Scale down the application deployments first.

Make sure the target namespace exists and the Longhorn storage class is available.

1. Scale down all deployments in the affected namespace.

   ```bash
   kubectl scale deploy --all -n <namespace> --replicas=0
   kubectl scale statefulset --all -n <namespace> --replicas=0
   ```

2. List the available backups.

   ```bash
   velero backup get
   ```

3. Start the restore from the backup you want.

   ```bash
   velero restore create \
     --from-backup <backup-name> \
     --include-namespaces <namespace> \
     --wait
   ```

4. Confirm the status is `Completed`.

   ```bash
   velero restore get
   ```

5. Scale deployments back up.

   ```bash
   kubectl scale deploy --all -n <namespace> --replicas=1
   kubectl scale statefulset --all -n <namespace> --replicas=1
   ```

6. Verify the app is running.

   ```bash
   kubectl get pods -n <namespace>
   ```

Data restored to the state at the time of backup.

---

### Full cluster recovery from scratch

This is the nuclear option - all nodes lost, rebuilding everything. Budget 1 to 3 hours depending on how fast everything syncs.

Before you start, you need all of these:
- `sealed-secrets-master-key.yaml` from your secure storage
- `homelab.age` on your local machine
- Access to this Git repo
- Physical access to the M920q Tiny nodes

1. Reinstall Talos Linux on all nodes (follow the official Talos docs).

2. Bootstrap the Talos cluster following `kubernetes/bootstrap/README.md`. Stop at Step 4. Do not apply the App-of-Apps yet.

3. Restore the Sealed Secrets key using the procedure above.

4. Continue from Step 7 in `kubernetes/bootstrap/README.md`.

5. Wait for all ArgoCD applications to hit `Synced / Healthy`.

   ```bash
   kubectl get applications -n argocd -w
   ```

6. Restore application data from Velero using the procedure above.

7. Confirm all services are accessible.

   | Service | URL |
   |---|---|
   | ArgoCD | `https://argocd.alialjaffer.com` |
   | Grafana | `https://grafana.alialjaffer.com` |
   | Longhorn | `https://longhorn.alialjaffer.com` |
   | Pihole | `https://pihole.alialjaffer.com` |

Cluster is fully back up. Everything running.
