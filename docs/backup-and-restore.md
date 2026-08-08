# Backup and Restore Procedures

**Document type:** Maintenance procedures  
**Cluster:** k8s-homelab (Talos Linux)  
**Applies to:** All cluster operators

---

## Warning

> **WARNING:** Loss of the Sealed Secrets key makes all `.sealed.yaml` files in this repository unreadable. You must back up this key before you decommission or rebuild the cluster.

> **WARNING:** Loss of the SOPS age key makes all encrypted Talos machine configs unreadable. You cannot rebuild the cluster without this key.

---

## Terminology

| Term | Meaning |
|---|---|
| Sealed Secrets key | The cluster private key that decrypts SealedSecret resources |
| SOPS age key | The age private key that decrypts `*.sops` files in `talos/clusterconfig/` |
| ArgoCD | The GitOps controller that applies all manifests to the cluster |
| Longhorn | The distributed storage system that holds all persistent volumes |

---

## 1. Backup Procedures

### 1.1 Back Up the Sealed Secrets Key

**When to do this procedure:** After you install the cluster for the first time. Do this procedure again after each cluster rebuild.

**Time required:** 5 minutes

**Before you start:** Make sure you have `kubectl` access to the cluster and a secure storage location (for example, 1Password or an encrypted external drive).

**Procedure:**

1. Set the kubeconfig to the Talos cluster.

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

3. Open the output file `sealed-secrets-master-key.yaml` and confirm it is not empty.

4. Copy `sealed-secrets-master-key.yaml` to your secure storage location.

5. Delete the local copy of the file.

   ```bash
   rm sealed-secrets-master-key.yaml
   ```

**Result:** The Sealed Secrets private key is stored in your secure location. The file no longer exists on disk.

---

### 1.2 Back Up the SOPS Age Key

**When to do this procedure:** After you generate the age key. Do this procedure only once unless you rotate the key.

**Time required:** 2 minutes

**Before you start:** Make sure the file `homelab.age` exists on your local machine. If it does not exist, run `age-keygen -o ~/homelab.age` first. Update `.sops.yaml` in the repository with the public key from `homelab.age`.

**Procedure:**

1. Open `~/homelab.age` and confirm it contains a private key line that starts with `AGE-SECRET-KEY-`.

2. Copy `~/homelab.age` to your secure storage location. Store it next to the Sealed Secrets key from procedure 1.1.

3. Do not delete `~/homelab.age` from your local machine. You need it for future SOPS operations.

**Result:** The SOPS age key is stored in your secure location and remains available on your local machine.

---

### 1.3 Back Up Application Data (Velero)

**When to do this procedure:** On a scheduled basis (recommended: daily). Also do this before you upgrade a stateful application.

**Time required:** 5–30 minutes, depending on data volume.

**Before you start:** Make sure Velero is installed in the cluster and the `velero` MinIO bucket exists.

> **Note:** Velero backs up Longhorn volumes for these namespaces: `catus-locatus`, `obsidian-sync`. It does not back up `monitoring` because Thanos stores metrics in MinIO permanently.

**Procedure:**

1. Set the kubeconfig to the Talos cluster.

   ```bash
   export KUBECONFIG=~/.kube/homelab-talos
   ```

2. Start a backup of all stateful namespaces.

   ```bash
   velero backup create homelab-$(date +%Y%m%d) \
     --include-namespaces catus-locatus,obsidian-sync \
     --wait
   ```

3. Confirm the backup status is `Completed`.

   ```bash
   velero backup get
   ```

4. If the status is `PartiallyFailed` or `Failed`, run the following command to see the reason.

   ```bash
   velero backup describe homelab-$(date +%Y%m%d) --details
   ```

**Result:** A backup of all persistent volume data exists in the `velero` MinIO bucket.

---

### 1.4 Back Up Longhorn Volume Snapshots

**When to do this procedure:** Before you perform Longhorn or node upgrades.

**Time required:** 2 minutes to start. Snapshot creation runs in the background.

**Procedure:**

1. Open the Longhorn UI at `https://longhorn.alialjaffer.com`.

2. Go to **Volume**.

3. For each volume in the list, select the volume and click **Create Snapshot**.

4. Confirm each snapshot appears in the **Snapshot** section of the volume detail page.

**Result:** Point-in-time snapshots exist for all Longhorn volumes.

---

## 2. Restore Procedures

### 2.1 Restore the Sealed Secrets Key to a New Cluster

**When to do this procedure:** After you rebuild the cluster from scratch. Do this procedure before you apply any ArgoCD applications.

> **CAUTION:** You must do this procedure before ArgoCD syncs. If ArgoCD syncs first, all SealedSecrets will fail to unseal and you must re-sync them manually afterward.

**Time required:** 3 minutes

**Before you start:** Make sure the Sealed Secrets controller is running. Make sure you have the backup file `sealed-secrets-master-key.yaml` from procedure 1.1.

**Procedure:**

1. Copy `sealed-secrets-master-key.yaml` from your secure storage location to your local machine.

2. Apply the key to the cluster.

   ```bash
   kubectl apply -f sealed-secrets-master-key.yaml
   ```

3. Restart the Sealed Secrets controller so it loads the restored key.

   ```bash
   kubectl rollout restart deployment/sealed-secrets-controller -n kube-system
   ```

4. Wait for the controller to become ready.

   ```bash
   kubectl rollout status deployment/sealed-secrets-controller -n kube-system
   ```

5. Delete the local copy of `sealed-secrets-master-key.yaml`.

   ```bash
   rm sealed-secrets-master-key.yaml
   ```

6. Verify that at least one SealedSecret is readable by checking its status.

   ```bash
   kubectl get sealedsecret -A
   ```

   The `AGE` column must show a value. A blank value means the controller did not unseal the secret.

**Result:** All SealedSecrets in the cluster are readable. ArgoCD can now sync applications.

---

### 2.2 Restore SOPS-Encrypted Talos Machine Configs

**When to do this procedure:** When you need to rebuild or re-apply Talos machine configurations and the plaintext configs are not available.

**Time required:** 5 minutes

**Before you start:** Make sure `homelab.age` is on your local machine. Make sure `sops` is installed.

**Procedure:**

1. Go to the `talos/clusterconfig/` directory.

   ```bash
   cd talos/clusterconfig/
   ```

2. Decrypt the control plane config.

   ```bash
   SOPS_AGE_KEY_FILE=~/homelab.age \
     sops --decrypt k8s-homelab-controlplane.sops \
     > k8s-homelab-controlplane.yaml
   ```

3. Decrypt the worker config.

   ```bash
   SOPS_AGE_KEY_FILE=~/homelab.age \
     sops --decrypt k8s-homelab-worker.sops \
     > k8s-homelab-worker.yaml
   ```

4. Apply the configs to the cluster nodes. Replace the IP addresses with your node addresses.

   ```bash
   talosctl apply-config -n 192.168.8.100 -f k8s-homelab-controlplane.yaml
   talosctl apply-config -n 192.168.8.101 -f k8s-homelab-worker.yaml
   talosctl apply-config -n 192.168.8.102 -f k8s-homelab-worker.yaml
   talosctl apply-config -n 192.168.8.103 -f k8s-homelab-worker.yaml
   ```

5. Delete the plaintext files.

   ```bash
   rm k8s-homelab-controlplane.yaml k8s-homelab-worker.yaml
   ```

**Result:** The Talos machine configurations are applied to all nodes. The plaintext files are removed from disk.

---

### 2.3 Restore Application Data from Velero

**When to do this procedure:** When a namespace loses data and you need to restore from a Velero backup.

**Time required:** 5–30 minutes, depending on data volume.

**Before you start:** Make sure the target namespace exists. Make sure the Longhorn storage class is available.

> **CAUTION:** Restoring into an existing namespace overwrites current data. Scale down the application deployments before you restore.

**Procedure:**

1. Scale down all deployments in the affected namespace. Replace `<namespace>` with the actual namespace name.

   ```bash
   kubectl scale deploy --all -n <namespace> --replicas=0
   kubectl scale statefulset --all -n <namespace> --replicas=0
   ```

2. List the available backups.

   ```bash
   velero backup get
   ```

3. Start the restore from the backup you want. Replace `<backup-name>` with the name from step 2.

   ```bash
   velero restore create \
     --from-backup <backup-name> \
     --include-namespaces <namespace> \
     --wait
   ```

4. Confirm the restore status is `Completed`.

   ```bash
   velero restore get
   ```

5. Scale the deployments back up.

   ```bash
   kubectl scale deploy --all -n <namespace> --replicas=1
   kubectl scale statefulset --all -n <namespace> --replicas=1
   ```

6. Verify the application is running.

   ```bash
   kubectl get pods -n <namespace>
   ```

**Result:** Application data is restored to the state at the time of the backup.

---

### 2.4 Full Cluster Recovery from Scratch

**When to do this procedure:** When all cluster nodes are lost and you must rebuild the entire cluster.

**Time required:** 1–3 hours

**Before you start:** You must have all of the following items before you start:
- The Sealed Secrets private key (`sealed-secrets-master-key.yaml`) from your secure storage
- The SOPS age key (`homelab.age`) on your local machine
- Access to this Git repository
- Physical access to the M920q Tiny nodes

**Procedure:**

1. Reinstall Talos Linux on all nodes following the official Talos documentation.

2. Bootstrap the Talos cluster following the procedure in `kubernetes/bootstrap/README.md`.

   > **Note:** Stop at Step 4 (ArgoCD). Do not apply the App-of-Apps yet.

3. Restore the Sealed Secrets key using procedure 2.1 of this document.

4. Continue the bootstrap from Step 7 onward in `kubernetes/bootstrap/README.md`.

5. Wait for all ArgoCD applications to reach `Synced / Healthy` status.

   ```bash
   kubectl get applications -n argocd -w
   ```

6. Restore application data from Velero using procedure 2.3 of this document.

7. Confirm all services are accessible at their expected URLs.

   | Service | URL |
   |---|---|
   | ArgoCD | `https://argocd.alialjaffer.com` |
   | Grafana | `https://grafana.alialjaffer.com` |
   | Longhorn | `https://longhorn.alialjaffer.com` |
   | Pihole | `https://pihole.alialjaffer.com` |

**Result:** The cluster is fully operational. All applications are running. All data is restored.
