# falco

- `namespace.yaml`: Falco's driver needs BPF/SYS_RESOURCE/PERFMON/SYS_PTRACE, which the cluster-wide PodSecurity baseline default blocks. Namespace labels override it (same pattern as `monitoring/namespace.yaml`).
- `values.yaml`: `driver.kind: modern_ebpf` is the only viable driver on Talos, an immutable OS with no kernel module loading, so `kmod` is a non-starter. Needs kernel >= 5.8 with BTF, which Talos ships by default. Talos issue falcosecurity/libs#2736 (secureboot defaults to `lockdown=confidentiality`, breaking modern_ebpf's `bpf_probe_read` fallback) does not apply here, `cat /sys/kernel/security/lockdown` on this cluster's nodes reads "none".
