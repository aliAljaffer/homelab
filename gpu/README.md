# GPU Support

This directory contains the NVIDIA Device Plugin for enabling GPU support in the Kubernetes cluster.

## Overview

The NVIDIA Device Plugin for Kubernetes enables GPU support for containerized workloads. It allows pods to request and use NVIDIA GPUs.

## Files

- `nvidia-device-plugin.yaml` - NVIDIA Device Plugin DaemonSet

## Prerequisites

### On the GPU Node

1. **NVIDIA Drivers** must be installed on the host:

   ```bash
   # Fedora
   sudo dnf install akmod-nvidia xorg-x11-drv-nvidia-cuda

   # Ubuntu
   sudo apt-get install nvidia-driver-535  # Or latest version
   ```

2. **NVIDIA Container Toolkit** must be installed:

   ```bash
   # Add repository
   distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
   curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | sudo apt-key add -
   curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

   # Install
   sudo apt-get update
   sudo apt-get install -y nvidia-container-toolkit

   # Configure containerd
   sudo nvidia-ctk runtime configure --runtime=containerd
   sudo systemctl restart containerd
   ```

3. **GPU Node Taint** (optional but recommended):

   ```bash
   # Taint the GPU node to dedicate it for GPU workloads only
   kubectl taint nodes <gpu-node-name> gpu=nvidia:NoSchedule
   ```

### Verification

Verify GPU is detected on the host:

```bash
nvidia-smi
```

Expected output should show your GPU(s).

## Installation

### Step 1: Configure

Edit `nvidia-device-plugin.yaml` and update:

```yaml
nodeSelector:
  kubernetes.io/hostname: fedora  # Change to your GPU node hostname
```

```yaml
volumes:
  - name: nvidia-libs
    hostPath:
      path: /opt/nvidia-libs  # Update if your NVIDIA libs are elsewhere
```

To find your NVIDIA library path:

```bash
# On the GPU node
find /usr -name "libnvidia-ml.so*" 2>/dev/null
# Common paths:
# - /usr/lib/x86_64-linux-gnu
# - /usr/lib64
# - /opt/nvidia-libs
```

### Step 2: Deploy

```bash
kubectl apply -f nvidia-device-plugin.yaml
```

### Step 3: Verify

```bash
# Check DaemonSet
kubectl get daemonset nvidia-device-plugin -n kube-system

# Check pod is running
kubectl get pods -n kube-system | grep nvidia

# Verify GPU is available in the cluster
kubectl describe node <gpu-node-name> | grep nvidia.com/gpu
```

Expected output should show:
```
nvidia.com/gpu: 1  # Or the number of GPUs you have
```

## Testing GPU Support

### Simple GPU Test

Create a test pod to verify GPU access:

**test-gpu.yaml:**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
spec:
  restartPolicy: OnFailure
  containers:
    - name: cuda-test
      image: nvidia/cuda:12.2.0-base-ubuntu22.04
      command:
        - nvidia-smi
      resources:
        limits:
          nvidia.com/gpu: 1
  # If you tainted your GPU node:
  tolerations:
    - key: gpu
      operator: Equal
      value: nvidia
      effect: NoSchedule
```

Deploy and check:

```bash
kubectl apply -f test-gpu.yaml
kubectl logs gpu-test
```

You should see `nvidia-smi` output showing your GPU.

### PyTorch GPU Test

Test with PyTorch:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pytorch-gpu-test
spec:
  restartPolicy: OnFailure
  containers:
    - name: pytorch
      image: pytorch/pytorch:latest
      command:
        - python
        - -c
        - |
          import torch
          print(f"PyTorch version: {torch.__version__}")
          print(f"CUDA available: {torch.cuda.is_available()}")
          print(f"CUDA version: {torch.version.cuda}")
          if torch.cuda.is_available():
              print(f"GPU: {torch.cuda.get_device_name(0)}")
              print(f"GPU Count: {torch.cuda.device_count()}")
      resources:
        limits:
          nvidia.com/gpu: 1
  tolerations:
    - key: gpu
      operator: Equal
      value: nvidia
      effect: NoSchedule
```

```bash
kubectl apply -f pytorch-gpu-test.yaml
kubectl logs pytorch-gpu-test
```

## Using GPUs in Your Workloads

### Resource Requests

To use a GPU in your pod, add resource limits:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-gpu-app
spec:
  containers:
    - name: my-container
      image: my-gpu-image:latest
      resources:
        limits:
          nvidia.com/gpu: 1  # Request 1 GPU
  # If GPU node is tainted:
  tolerations:
    - key: gpu
      operator: Equal
      value: nvidia
      effect: NoSchedule
```

### Multiple GPUs

To request multiple GPUs:

```yaml
resources:
  limits:
    nvidia.com/gpu: 2  # Request 2 GPUs
```

### GPU Sharing

To enable GPU time-slicing (sharing GPUs across pods), you need additional configuration:

1. Create a ConfigMap for time-slicing config
2. Update the device plugin to use the config
3. Restart the device plugin

See [NVIDIA Time-Slicing Guide](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/gpu-sharing.html) for details.

## Runtime Classes

K3s comes with pre-configured runtime classes for different GPU workloads:

```bash
# List available runtime classes
kubectl get runtimeclass
```

Use them in your pods:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-pod
spec:
  runtimeClassName: nvidia  # Use NVIDIA runtime
  containers:
    - name: cuda
      image: nvidia/cuda:12.2.0-base-ubuntu22.04
      resources:
        limits:
          nvidia.com/gpu: 1
```

## Monitoring GPU Usage

### In the Cluster

Get GPU info from node:

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
```

Check GPU allocation:

```bash
kubectl describe node <gpu-node-name> | grep -A 10 "Allocated resources"
```

### With Prometheus

Deploy NVIDIA DCGM Exporter for Prometheus metrics:

```bash
# Deploy DCGM exporter
kubectl create -f https://raw.githubusercontent.com/NVIDIA/dcgm-exporter/main/deployment/kubernetes/dcgm-exporter.yaml
```

Then import Grafana dashboard #14574 for GPU metrics visualization.

## Troubleshooting

### Device plugin pod not starting

```bash
# Check logs
kubectl logs -n kube-system -l name=nvidia-device-plugin

# Common issues:
# 1. NVIDIA drivers not installed
# 2. NVIDIA container toolkit not configured
# 3. Incorrect library path in volume mount
```

### GPU not detected

```bash
# On GPU node, verify:
nvidia-smi

# Check containerd runtime
sudo nvidia-ctk runtime configure --runtime=containerd --dry-run

# Check kubelet can see the GPU
sudo systemctl restart kubelet
```

### Pod can't access GPU

```bash
# Check pod events
kubectl describe pod <pod-name>

# Verify resource request
kubectl get pod <pod-name> -o yaml | grep nvidia.com/gpu

# Check node has available GPUs
kubectl describe node <gpu-node-name> | grep "nvidia.com/gpu"
```

### Toleration issues

If GPU node is tainted but pod isn't starting:

```bash
# Check node taints
kubectl describe node <gpu-node-name> | grep Taints

# Ensure pod has matching toleration
kubectl get pod <pod-name> -o yaml | grep -A 5 tolerations
```

## GPU Node Maintenance

### Draining GPU Workloads

Before maintenance:

```bash
# Cordon the node
kubectl cordon <gpu-node-name>

# Drain GPU workloads
kubectl drain <gpu-node-name> --ignore-daemonsets --delete-emptydir-data
```

After maintenance:

```bash
# Uncordon the node
kubectl uncordon <gpu-node-name>
```

### Updating NVIDIA Drivers

1. Drain the GPU node
2. Update NVIDIA drivers on the host
3. Restart containerd
4. Restart the device plugin pod
5. Uncordon the node

```bash
kubectl delete pod -n kube-system -l name=nvidia-device-plugin
```

## Advanced Configuration

### GPU Feature Discovery

For automatic GPU feature labeling:

```bash
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/gpu-feature-discovery/main/deployments/static/gpu-feature-discovery-daemonset.yaml
```

This adds labels like:
- `nvidia.com/cuda.driver.major`
- `nvidia.com/cuda.driver.minor`
- `nvidia.com/gpu.product`

### MIG (Multi-Instance GPU)

For GPUs that support MIG (A100, H100):

1. Enable MIG mode on the GPU
2. Create MIG instances
3. Configure device plugin to expose MIG devices

See [NVIDIA MIG Guide](https://docs.nvidia.com/datacenter/cloud-native/kubernetes/mig-k8s.html).

## Current Configuration

- **GPU Node**: fedora (192.168.68.56)
- **GPU Model**: RTX 4070 Ti Super
- **Node Taint**: `gpu=nvidia:NoSchedule`
- **Device Plugin Version**: v0.14.5
- **NVIDIA Library Path**: `/opt/nvidia-libs`

## References

- [NVIDIA Device Plugin GitHub](https://github.com/NVIDIA/k8s-device-plugin)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)
- [Kubernetes Device Plugins](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/)
- [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/getting-started.html)
