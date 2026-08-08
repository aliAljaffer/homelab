# Talos on Intel Mac (mid-2012 MacBook Pro)

## The problem

Talos 1.13.0 and later do not boot on Intel Macs. The boot process stops at the Talos logo with no kernel output. The regression was introduced in 1.13.0-alpha2 when the kernel build switched from GNU ld to Clang+LLD (LLVM ThinLTO). Apple's EFI firmware rejects the PE binary produced by LLD.

**Affected hardware:** Any Intel Mac with Apple EFI firmware — Mac Mini 2012/2014, MacBook Pro 2012, and others.

**Not affected:** Standard x86 machines (Dell, Lenovo, etc.) which accept the LLD-compiled kernel without issue.

**Source:** siderolabs/talos issue #13231. Full credit to GitHub user [`virtualm2000`](https://github.com/virtualm2000) who identified the LLD regression, narrowed it to the alpha1/alpha2 boundary, and worked out the complete rebuild procedure. This document is a cleaned-up version of their findings.

---

## The fix

Rebuild the Talos kernel with `LLVM: 1` removed from the build config and LTO disabled. The resulting kernel is compiled by Clang with GNU ld instead of LLD, which Apple's EFI accepts.

**Time required:** 1 to 2 hours (mostly waiting for compilation).

**Before you start:** Make sure you have Docker installed with BuildKit support, at least 20 GB of free disk space, and a stable internet connection.

---

## Step 1 — Prepare the build environment

1. Start a local Docker registry.

   ```bash
   docker run -d -p 5005:5000 --restart=always --name registry registry:2
   ```

2. Create a BuildKit builder with insecure permissions (required for Talos kernel builds).

   ```bash
   docker buildx create \
     --driver docker-container \
     --driver-opt network=host \
     --name local \
     --buildkitd-flags '--allow-insecure-entitlement security.insecure' \
     --use
   ```

---

## Step 2 — Build the kernel without LLD

1. Clone the Talos packages repository and check out the 1.13 release branch.

   ```bash
   git clone https://github.com/siderolabs/pkgs.git
   cd pkgs
   git checkout release-1.13
   ```

2. Remove the `LLVM: 1` line from the kernel build config.

   ```bash
   sed -i '/^\s*LLVM: 1/d' kernel/build/pkg.yaml
   ```

3. Update the kernel config to disable ThinLTO.

   ```bash
   sudo -E make kernel-olddefconfig PLATFORM=linux/amd64
   ```

   When the config editor opens, find `CONFIG_LTO_CLANG_THIN` and disable it. Set `CONFIG_LTO_NONE=y`.

4. Build the kernel and push it to your local registry.

   ```bash
   sudo -E make kernel \
     REGISTRY=127.0.0.1:5005/talos \
     USERNAME=pkgs \
     PUSH=true \
     PLATFORM=linux/amd64
   ```

   > **Note:** If you need the `i915` extension (for Intel iGPU on other nodes), rebuild it against this kernel. The 2012 MacBook Pro GT 650M does not need it.

   ```bash
   cd ..
   git clone https://github.com/siderolabs/extensions.git
   cd extensions
   git checkout v1.13.0
   sudo -E make iscsi-tools util-linux-tools intel-ucode \
     TAG=v1.13.0 \
     REGISTRY=127.0.0.1:5005/talos \
     USERNAME=extensions \
     PUSH=true \
     PLATFORM=linux/amd64 \
     PKGS=v1.13.0-dirty \
     PKGS_PREFIX=127.0.0.1:5005/talos/pkgs
   cd ..
   ```

---

## Step 3 — Build the Talos installer and imager

1. Clone the Talos repository and check out v1.13.7.

   ```bash
   git clone https://github.com/siderolabs/talos.git
   cd talos
   git checkout v1.13.7
   ```

2. Build the kernel artifacts, initramfs, imager, and installer base.

   ```bash
   sudo -E make kernel initramfs imager installer-base \
     REGISTRY=127.0.0.1:5005/talos \
     USERNAME=imager \
     PUSH=true \
     TAG=v1.13.7 \
     PKG_KERNEL=127.0.0.1:5005/talos/pkgs/kernel:v1.13.0-dirty \
     PLATFORM=linux/amd64 \
     INSTALLER_ARCH=amd64 \
     PKGS=v1.13.0-dirty \
     PKGS_PREFIX=127.0.0.1:5005/talos/pkgs
   ```

   > **Note:** The kernel tag uses `v1.13.0-dirty` because the Makefile stamps non-official builds. The installer tag is `v1.13.7` matching the actual Talos version.

---

## Step 4 — Generate the ISO

1. Write the imager profile. These are the extensions for the MacBook (no i915 — the GT 650M is not supported by modern nvidia or i915 drivers in Kubernetes).

   ```bash
   cat > profile.yaml << 'EOF'
   arch: amd64
   platform: metal
   secureboot: false
   name: talos-macbook-pro-2012
   version: v1.13.7
   input:
     kernel:
       path: /usr/install/amd64/vmlinuz
     initramfs:
       path: /usr/install/amd64/initramfs.xz
     sdStub:
       path: /usr/install/amd64/systemd-stub.efi
     sdBoot:
       path: /usr/install/amd64/systemd-boot.efi
     baseInstaller:
       imageRef: 127.0.0.1:5005/talos/imager/installer-base:v1.13.7
     systemExtensions:
       - imageRef: 127.0.0.1:5005/talos/extensions/iscsi-tools:v1.13.0
       - imageRef: 127.0.0.1:5005/talos/extensions/util-linux-tools:v1.13.0
       - imageRef: 127.0.0.1:5005/talos/extensions/intel-ucode:v1.13.0
   output:
     kind: iso
     outFormat: raw
   customization:
     extraKernelArgs:
       - net.ifnames=0
   EOF
   ```

2. Generate the ISO.

   ```bash
   mkdir -p _out
   cat profile.yaml | sudo -E docker run --rm -i --network=host \
     -v $PWD/_out:/out \
     127.0.0.1:5005/talos/imager/imager:v1.13.7 -
   ```

   The ISO is written to `./_out/talos-macbook-pro-2012.iso`.

3. Write the ISO to a USB drive. Replace `/dev/sdX` with your USB device.

   ```bash
   sudo dd if=_out/talos-macbook-pro-2012.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

---

## Step 5 — Boot and install

1. Insert the USB drive into the MacBook Pro.

2. Power on the MacBook and hold **Option (Alt)** to enter the boot picker.

3. Select the EFI boot entry for the USB drive.

4. Talos boots to a minimal shell. Install to the internal SSD.

   ```bash
   talosctl apply-config --insecure -n <macbook-ip> --file /path/to/macbook-config.yaml
   ```

   Generate the config first using `talosctl gen config` or by decrypting and adapting `talos/clusterconfig/k8s-homelab-wrk0.sops.yaml`.

---

## Joining the cluster

Once Talos is installed on the MacBook, add it to the cluster following the procedure in `kubernetes/bootstrap/README.md`. If adding it as a control plane node, generate a controlplane config (not a worker config) and ensure the machine config includes `controlPlane: true`.

Update `talos/talconfig.yaml` to add the new node entry and encrypt a new `.sops.yaml` for it.
