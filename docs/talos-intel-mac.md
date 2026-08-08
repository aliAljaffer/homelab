# Talos on Intel Mac

> **Tested on WSL2 successfully.** Talos 1.13.8 with custom GNU ld kernel built and installed on a MacBook Pro Mid-2012 (Ivy Bridge, 13"). Node joined a Talos cluster as control plane.

## The problem

Talos 1.13.0 and later do not boot on Intel Macs. The boot process stops at the Talos logo with no kernel output. The regression was introduced in 1.13.0-alpha2 when the kernel build switched from GNU ld to Clang+LLD (LLVM ThinLTO). Apple's EFI firmware rejects the PE binary produced by LLD.

**Affected hardware:** Any Intel Mac with Apple EFI firmware — Mac Mini 2012/2014, MacBook Pro 2012, MacBook Air, and others.

**Not affected:** Standard x86 machines (Dell, Lenovo, etc.) which accept the LLD-compiled kernel without issue.

**Confirmed unresolved in:** v1.13.0 through v1.13.8 (standard factory images do not boot on affected hardware).

**Source:** siderolabs/talos issue [#13231](https://github.com/siderolabs/talos/issues/13231). Full credit to GitHub user [`virtualm2000`](https://github.com/virtualm2000) who identified the LLD regression, narrowed it to the alpha1/alpha2 boundary, and worked out the complete rebuild procedure. This document is a cleaned-up version of their findings.

> **Important caveat:** the kernel rebuild in Step 2 is confirmed working (by the upstream issue reporters) only on Mac Mini and iMac hardware. On at least one 13" Mid-2012 MacBook Pro, the kernel fix alone was **not** sufficient — the machine still hung at the boot logo afterward. The actual mechanism there turned out to be unrelated to the kernel: `systemd-boot`/the UKI EFI path itself hangs on that machine's firmware, regardless of how the kernel was compiled. See [Step 7](#step-7--if-it-still-hangs-after-the-kernel-fix-macbook-pro) if you hit this.

---

## Practical alternative: use Talos 1.12.7

If you only need this machine as a **worker node**, use the last working release (v1.12.7) from the standard Image Factory. No custom build required.

Talos 1.12.7 bundles Kubernetes 1.35.x. A 1.35.x kubelet is one minor version behind a 1.36.x apiserver, which is within the supported Kubernetes skew policy. The node joins and works normally.

This is not an option for control plane nodes — all control plane nodes must run the same Kubernetes version.

Generate the 1.12.7 image at `https://factory.talos.dev/` with your required extensions, write it with Rufus, and proceed directly to joining the cluster.

---

## The fix (for control plane nodes or 1.13.x requirement)

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

## Step 3 — Extensions

Only extensions that ship `.ko` kernel module files need rebuilding against the patched kernel. Examples include `i915`, `zfs`, and `nvidia`. Extensions that provide userspace binaries only (no kernel modules) work with the standard images from `ghcr.io/siderolabs` regardless of how the kernel was compiled.

For Intel Mac hardware, all three required extensions are userspace-only. No rebuilding is needed.

| Extension | Contains kernel modules? | Source |
|---|---|---|
| `iscsi-tools` | No — provides `iscsiadm` binary | Use `ghcr.io/siderolabs/iscsi-tools` |
| `util-linux-tools` | No — provides `lsblk` and friends | Use `ghcr.io/siderolabs/util-linux-tools` |
| `intel-ucode` | No — provides firmware blobs | Use `ghcr.io/siderolabs/intel-ucode` |

Use the standard images directly in the profile in Step 5. You do not need to clone the extensions repository or run any build commands for this hardware.

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
   First, look up the exact tag that was pushed for your kernel build — the Makefile appends a commit hash, so it is never just `-dirty`:

   ```bash
   curl -s http://127.0.0.1:5005/v2/talos/pkgs/kernel/tags/list
   # example output: {"name":"talos/pkgs/kernel","tags":["v1.13.0-55-gf677246-dirty"]}
   ```

   Use that tag in `PKG_KERNEL` and `PKGS`:

   First, look up the exact tag that was pushed for your kernel build:

   ```bash
   curl -s http://127.0.0.1:5005/v2/talos/pkgs/kernel/tags/list
   # example: {"name":"talos/pkgs/kernel","tags":["v1.13.0-55-gf677246-dirty"]}
   ```

   Then run the build. Only `PKG_KERNEL` points to the local registry. All other packages come from the official `ghcr.io/siderolabs/pkgs` images. Do not set `PKGS` or `PKGS_PREFIX` — doing so would redirect every package lookup to the local registry, and only the kernel is there.

   ```bash
   KERNEL_TAG=$(curl -s http://127.0.0.1:5005/v2/talos/pkgs/kernel/tags/list | python3 -c "import json,sys; print(json.load(sys.stdin)['tags'][0])")

   sudo -E make kernel initramfs imager installer-base \
     REGISTRY=127.0.0.1:5005/talos \
     USERNAME=imager \
     PUSH=true \
     TAG=v1.13.8 \
     PKG_KERNEL=127.0.0.1:5005/talos/pkgs/kernel:${KERNEL_TAG} \
     PLATFORM=linux/amd64 \
     INSTALLER_ARCH=amd64
   ```

   > **Note:** `TAG` is the Talos release version for the output images. `PKG_KERNEL` is the stamped git-describe tag from the pkgs build, which always includes a commit hash.

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
       - imageRef: ghcr.io/siderolabs/iscsi-tools:v0.2.0
       - imageRef: ghcr.io/siderolabs/util-linux-tools:2.41.4
       - imageRef: ghcr.io/siderolabs/intel-ucode:20250211
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

3. Write the ISO to a USB drive.

   **Option A — from WSL2 using `dd`:** Replace `/dev/sdX` with your USB device (check with `lsblk`).

   ```bash
   sudo dd if=_out/metal-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

   **Option B — using Rufus on Windows:** If the USB drive does not appear in `lsblk`, copy the ISO to the Windows filesystem and use Rufus to write it.

   ```bash
   cp _out/metal-amd64.iso /mnt/c/Users/$USER/Downloads/talos-macbook.iso
   ```

   Then open Rufus on Windows, select the ISO from `Downloads`, and write it to the USB drive.

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

---

## Step 7 — If it still hangs after the kernel fix (MacBook Pro)

Confirmed on a 13" Mid-2012 MacBook Pro (integrated graphics only, `MacBookPro9,2`). After completing Steps 1–6 with a verified-correct kernel (GCC + GNU ld, matching the known-working toolchain byte-for-byte), the machine still froze at the exact same screen — `systemd-stub`'s own status line, "Talos Linux, Built by Sidero".

### Diagnosing it

Add these to `extraKernelArgs` and regenerate the ISO to rule the kernel in or out:

```yaml
customization:
  extraKernelArgs:
    - net.ifnames=0
    - earlyprintk=efi,keep
    - console=tty0
    - loglevel=7
    - ignore_loglevel
```

If the screen is **identical with or without** these — no extra text, nothing — the freeze is happening before the kernel ever executes a single instruction. `earlyprintk`/`loglevel` are kernel parameters; they can only have an effect once Linux itself starts running. Since `systemd-stub` printed its own status line successfully (proving the firmware loaded and executed the EFI binary fine — this is not a "malformed PE binary rejected by firmware" problem), the hang is inside `systemd-stub`/`systemd-boot` itself, before handoff to the kernel.

`efi=novamap` (a legitimate kernel parameter — "do not call `SetVirtualAddressMap()`", a standard workaround for firmware that hangs around `ExitBootServices`) is worth trying too, but did not help in this case, consistent with the hang being pre-kernel.

**A useful cross-check if the Mac dual-boots Linux already:** if another distro (e.g. Ubuntu) boots fine on the same hardware via its own GRUB, that proves the firmware can run non-Apple EFI binaries in general — it isolates the problem to Talos's specific `systemd-boot` + UKI implementation, not "old Mac firmware can't run Linux."

### The fix: use GRUB instead of systemd-boot

Talos supports GRUB as an alternate bootloader (confirmed in `pkg/machinery/imager/imageropts`: bootloader kinds are `none`, `dual-boot`, `sd-boot`, `grub`), and Talos's GRUB does install in real UEFI mode (`x86_64-efi` platform, not just legacy BIOS) — this is a different code path from `systemd-boot` entirely and worked immediately.

**Important limitation:** this can *only* be set via the **imager's disk-image mode**, not via machine config or any `talosctl apply-config` flag. Talos's real installer (triggered by `apply-config` doing a fresh install) hardcodes the bootloader choice in `bootloader.NewAuto()`:

```go
func NewAuto() Bootloader {
    if sdboot.IsUEFIBoot() {
        return sdboot.New()
    }
    return grub.NewConfig()
}
```

On UEFI hardware this always picks `sd-boot` — there is no override. `dual-boot` mode exists but explicitly errors ("installation is not implemented") outside of image mode. So GRUB has to be baked into a pre-built disk image and `dd`'d onto the disk directly; you cannot get there through a normal `apply-config`-triggered install.

1. Build a **disk image** (not an ISO) with `bootloader: grub`:

   ```yaml
   # profile-grub-image.yaml
   arch: amd64
   platform: metal
   secureboot: false
   version: v1.13.8
   input:
     kernel:
       path: /usr/install/amd64/vmlinuz
     initramfs:
       path: /usr/install/amd64/initramfs.xz
     baseInstaller:
       imageRef: 127.0.0.1:5005/talos/imager/installer-base:v1.13.8
     systemExtensions:
       - imageRef: ghcr.io/siderolabs/iscsi-tools:v0.2.0
       - imageRef: ghcr.io/siderolabs/util-linux-tools:2.41.4
       - imageRef: ghcr.io/siderolabs/intel-ucode:20250211
   output:
     kind: image
     outFormat: raw
     imageOptions:
       diskSize: 1306525696
       diskFormat: raw
       bootloader: grub
   customization:
     extraKernelArgs:
       - net.ifnames=0
   ```

   Note `sdStub`/`sdBoot` are dropped from `input` — not needed for the `grub` bootloader kind.

   ```bash
   mkdir -p _out
   cat profile-grub-image.yaml | docker run --rm -i --network=host \
     -v $PWD/_out:/out \
     127.0.0.1:5005/talos/imager/imager:v1.13.8 -
   ```

   This produces `_out/metal-amd64.raw` (a few GB — Talos grows the partitions to fill the real disk on first boot, so the exact `diskSize` here doesn't need to match the target disk).

2. **Write it to the disk from external media, not from the OS running on that disk.** Boot a plain Linux rescue/live USB (a second USB stick, separate from the Talos installer one — an Ubuntu Desktop live image works fine), then:

   ```bash
   # verify the checksum matches before writing — a corrupted/truncated
   # transfer here produces a garbage partition table that LOOKS like it
   # wrote successfully but silently corrupts the FAT/xfs filesystems
   sha256sum metal-amd64.raw   # compare against the source before dd

   sudo dd if=metal-amd64.raw of=/dev/sda bs=4M status=progress oflag=sync
   sync
   ```

   Reboot, remove the USB, hold Option, select the internal disk.

### A second pitfall: GRUB hardcodes `hd0`

Talos's GRUB build (`internal/app/machined/pkg/runtime/v1alpha1/bootloader/grub/install.go`) invokes `grub-mkimage` with a **hardcoded** prefix:

```go
const grubPrefix = "(hd0,gpt3)/grub" // EFI, BIOS, BOOT
```

This assumes the boot disk is always BIOS/EFI disk number 0. On hardware where firmware enumerates the internal disk as `hd1` (as on this MacBook Pro, once the USB sticks were removed), GRUB cannot find its own `grub.cfg` and drops to an interactive `grub>` rescue prompt on every cold boot — it only proceeds if someone is physically present to type:

```
ls (hd1,gpt3)/
set root=(hd1,gpt3)
configfile /grub/grub.cfg
```

That's fine for a one-off recovery, but unacceptable for a node that needs to survive an unattended reboot (Talos upgrade, power blip, etc).

**The fix:** rebuild just the GRUB EFI binary (`BOOTX64.EFI`) with an embedded early config that searches for the boot partition by filesystem UUID instead of assuming a fixed disk number — the same technique a normal `grub-install` uses, which is why Ubuntu's own GRUB isn't affected by this. Use Talos's **own** `installer-base` image to do this (not the host distro's `grub-install` — its `grub-probe`/`xfs.mod` may be too old to recognize the newer XFS on-disk features Talos's `mkfs.xfs` uses, e.g. `bigtime`/`nrext64`, and will fail with `error: unknown filesystem`):

1. Get the boot partition's UUID (from the rescue live session, with the target disk unmounted from Talos but attached):

   ```bash
   sudo blkid /dev/sda3   # the BOOT partition (xfs, label "BOOT")
   ```

2. Build a corrected image using Talos's own `grub-mkimage`, reusing its exact module list (from `install.go`) but with an embedded config performing a UUID search instead of a static prefix:

   ```bash
   mkdir -p grubfix
   cat > grubfix/early.cfg <<'EOF'
   search --no-floppy --fs-uuid --set=root <BOOT-PARTITION-UUID>
   set prefix=($root)/grub
   EOF

   docker run --rm \
     -v "$PWD/grubfix:/out" \
     --entrypoint grub-mkimage \
     127.0.0.1:5005/talos/imager/installer-base:v1.13.8 \
     --format x86_64-efi \
     --output /out/BOOTX64.efi \
     --prefix '(hd0,gpt3)/grub' \
     --config /out/early.cfg \
     --compression xz \
     part_gpt ext2 fat xfs normal configfile linux boot search search_fs_uuid search_fs_file ls cat echo test help reboot halt all_video
   ```

   The `--prefix` here is just a build-time fallback default; the embedded `--config` script runs first at boot and overrides it dynamically via the UUID search, so it works regardless of what disk number the firmware assigns.

3. From the rescue live session, drop the fixed binary in place (this only replaces the boot loader binary — Talos's own generated `grub.cfg` menu is untouched):

   ```bash
   sudo mount /dev/sda1 /mnt/efi
   sudo cp BOOTX64.efi /mnt/efi/EFI/boot/BOOTX64.EFI
   sudo umount /mnt/efi
   sync
   ```

4. Reboot, remove all USB media, hold Option, select the internal disk. It should now boot straight to the Talos GRUB menu with no manual intervention, and survive unattended reboots normally.
