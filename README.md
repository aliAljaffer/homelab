# K3s Homelab Cluster

Documenting my resources used in the Homelab cluster I run.

K3s Version: `v1.33.5+k3s1`

## Currently working on:

- ArgoCD installation
- Moving to Gateway API from NGINX Ingress
- SonarQube deployment once I add a beefy Node to the cluster

## Nodes

I use a main control plane node and two _occasionally_ 24/7 running nodes for workloads

### Control Plane

Macbook Pro, Mid-2012

- OS: Ubuntu 24.04
- RAM: 16GB DDR3
- Storage: 240GB SSD
- CPU: Some Intel i5 2.5Ghz

### Worker Node 1 - GPU Node

This is my main PC and the node designated for ML workloads with a `gpu=nvidia` taint.

Build: [PCPartPicker](https://pcpartpicker.com/b/QMRTwP)

- OS: Fedora Workstation 43
- RAM: 32GB
- Storage: 3x 2TB NVMe
- CPU: AMD Ryzen 7 7800x3D
- GPU: RTX 4070 Ti Super

### Worker Node 2 - Just a Worker

Rarely used for K8s workloads, but it's there when needed. Tainted with no tolerated deployments for now.

Macbook Pro M2, 2023

- OS: MacOS Sequoia
- RAM: 16GB
- Storage: 512GB SSD
- CPU: Apple M2 Pro Chip
