# Talos on Intel Mac

## The problem

Talos 1.13.0 and later do not boot on Intel Macs. The boot process stops at the Talos logo with no kernel output. The regression was introduced in 1.13.0-alpha2 when the kernel build switched from GNU ld to Clang+LLD (LLVM ThinLTO). Apple's EFI firmware rejects the PE binary produced by LLD.

**Affected hardware:** Any Intel Mac with Apple EFI firmware — Mac Mini 2012/2014, MacBook Pro 2012, MacBook Air, and others.

**Not affected:** Standard x86 machines (Dell, Lenovo, etc.) which accept the LLD-compiled kernel without issue.

**Confirmed unresolved in:** v1.13.0 through v1.13.8 (standard factory images do not boot on affected hardware).

**Source:** siderolabs/talos issue [#13231](https://github.com/siderolabs/talos/issues/13231). Full credit to GitHub user [`virtualm2000`](https://github.com/virtualm2000) who identified the LLD regression, narrowed it to the alpha1/alpha2 boundary, and worked out the complete rebuild procedure. This document is a cleaned-up version of their findings.

---

## The fix

Rebuild the Talos kernel with `LLVM: 1` removed from the build config and ThinLTO disabled. The resulting kernel is compiled by Clang with GNU ld instead of LLD, which Apple's EFI accepts.

**Time required:** 1 to 2 hours (mostly waiting for compilation).

**Before you start:** Make sure you have Docker installed with BuildKit support, at least 20 GB of free disk space, and a stable internet connection.

> **WSL2 note:** If you are building on WSL2 with Docker Desktop, you may see the error `error getting credentials: docker-credential-desktop.exe: executable file not found in $PATH`. This happens because Docker's config inside WSL2 points to a Windows credential helper. Fix it before starting:
>
> ```bash
> cat ~/.docker/config.json | python3 -c "
> import json, sys
> c = json.load(sys.stdin)
> c.pop('credsStore', None)
> print(json.dumps(c, indent=2))
> " > /tmp/docker-config.json && mv /tmp/docker-config.json ~/.docker/config.json
> ```
>
> Then run `docker login 127.0.0.1:5005` before proceeding.

---

## Step 1 — Prepare the build environment

1. Start a local Docker registry.

   ```bash
   docker run -d -p 5005:5000 --restart=always --name registry registry:2
   ```

   This registry runs on `127.0.0.1:5005` (loopback only). It has no authentication. If `docker login` asks for a username and password, enter any value. The registry ignores credentials entirely.

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

3. Regenerate the kernel config. This applies the changes from step 2 and sets all options to their defaults without prompting.

   ```bash
   sudo -E make kernel-olddefconfig PLATFORM=linux/amd64
   ```

   No editor opens. Removing `LLVM: 1` in step 2 is enough — the build system automatically sets `CONFIG_LTO_NONE=y` as a result.

4. Build the kernel and push it to your local registry.

   ```bash
   sudo -E make kernel \
     REGISTRY=127.0.0.1:5005/talos \
     USERNAME=pkgs \
     PUSH=true \
     PLATFORM=linux/amd64
   ```

   > **WSL2 pitfall — silent push failure:** On WSL2, the buildx builder is created per user. If `sudo -E make kernel` runs as root but the builder was created as your regular user, the push silently succeeds in the build log but nothing lands in the registry. After the build finishes, confirm the image is there before continuing:
   >
   > ```bash
   > curl -s http://127.0.0.1:5005/v2/_catalog
   > # expected: {"repositories":["talos/pkgs/kernel"]}
   > ```
   >
   > If the catalog is empty, recreate the buildx builder as root and re-run:
   >
   > ```bash
   > sudo docker buildx create \
   >   --driver docker-container \
   >   --driver-opt network=host \
   >   --name local \
   >   --buildkitd-flags '--allow-insecure-entitlement security.insecure' \
   >   --use
   > sudo -E make kernel \
   >   REGISTRY=127.0.0.1:5005/talos \
   >   USERNAME=pkgs \
   >   PUSH=true \
   >   PLATFORM=linux/amd64
   > ```

---

## Step 3 — Rebuild any required extensions

Extensions that ship kernel modules must be rebuilt against the patched kernel. Extensions that do not ship kernel modules can use the standard images from `ghcr.io/siderolabs` without rebuilding.

For Intel Mac hardware, rebuild `iscsi-tools` and `util-linux-tools` (both required for Longhorn). Do not try to build `i915` — it requires `linux-firmware` as a dependency, which is a separate large build. The 2012 MacBook Pro GPU is not supported by Kubernetes GPU drivers anyway.

```bash
cd ..
git clone https://github.com/siderolabs/extensions.git
cd extensions
git checkout v1.13.0
for ext in iscsi-tools util-linux-tools; do
  sudo -E make $ext \
    TAG=v1.13.0 \
    REGISTRY=127.0.0.1:5005/talos \
    USERNAME=extensions \
    PUSH=true \
    PLATFORM=linux/amd64 \
    PKGS=v1.13.0-dirty \
    PKGS_PREFIX=127.0.0.1:5005/talos/pkgs
done
cd ..
```

Use the standard `ghcr.io/siderolabs/intel-ucode` image directly in the profile — no rebuild needed.

---

## Step 4 — Build the Talos installer and imager

1. Clone the Talos repository and check out the version you are targeting.

   ```bash
   git clone https://github.com/siderolabs/talos.git
   cd talos
   git checkout v1.13.8
   ```

2. Build the kernel artifacts, initramfs, imager, and installer base.

   ```bash
   sudo -E make kernel initramfs imager installer-base \
     REGISTRY=127.0.0.1:5005/talos \
     USERNAME=imager \
     PUSH=true \
     TAG=v1.13.8 \
     PKG_KERNEL=127.0.0.1:5005/talos/pkgs/kernel:v1.13.0-dirty \
     PLATFORM=linux/amd64 \
     INSTALLER_ARCH=amd64 \
     PKGS=v1.13.0-dirty \
     PKGS_PREFIX=127.0.0.1:5005/talos/pkgs
   ```

   > **Note:** The kernel tag carries the suffix `-dirty` because the Makefile stamps non-release builds. The installer tag should match the Talos version you checked out.

---

## Step 5 — Generate the ISO

1. Write an imager profile for your hardware. Add the extensions you need. Below is an example for a 2012 MacBook Pro (Ivy Bridge, no supported discrete GPU driver):

   ```yaml
   # profile.yaml
   arch: amd64
   platform: metal
   secureboot: false
   version: v1.13.8
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
       imageRef: 127.0.0.1:5005/talos/imager/installer-base:v1.13.8
     systemExtensions:
       - imageRef: 127.0.0.1:5005/talos/extensions/iscsi-tools:v1.13.0
       - imageRef: 127.0.0.1:5005/talos/extensions/util-linux-tools:v1.13.0
       - imageRef: ghcr.io/siderolabs/intel-ucode:20250211   # no kernel modules, use standard image
   output:
     kind: iso
     outFormat: raw
   customization:
     extraKernelArgs:
       - net.ifnames=0
   ```

2. Generate the ISO.

   ```bash
   mkdir -p _out
   cat profile.yaml | sudo -E docker run --rm -i --network=host \
     -v $PWD/_out:/out \
     127.0.0.1:5005/talos/imager/imager:v1.13.8 -
   ```

3. Write the ISO to a USB drive. Replace `/dev/sdX` with your USB device.

   ```bash
   sudo dd if=_out/metal-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

---

## Step 6 — Boot and install

1. Insert the USB drive into the Mac.

2. Power on and hold **Option (Alt)** to open the boot picker.

3. Select the EFI boot entry for the USB drive.

4. Once Talos is running from USB, generate a machine config and apply it.

   ```bash
   talosctl gen config <cluster-name> https://<control-plane-ip>:6443
   talosctl apply-config --insecure -n <mac-ip> --file controlplane.yaml
   # or for a worker:
   talosctl apply-config --insecure -n <mac-ip> --file worker.yaml
   ```

   Refer to the [official Talos installation docs](https://www.talos.dev/latest/talos-guides/install/bare-metal-platforms/iso/) for full details on machine config generation and cluster bootstrapping.
