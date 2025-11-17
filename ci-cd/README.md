# CI/CD - GitHub Actions Runner Controller (ARC)

This directory contains the configuration for self-hosted GitHub Actions runners using Actions Runner Controller (ARC).

## Overview

Actions Runner Controller (ARC) enables you to run self-hosted GitHub Actions runners in your Kubernetes cluster. Runners are created on-demand as pods and scale based on workflow demand.

## Files

- `arc-namespaces.yaml` - Namespaces for ARC (arc-systems, arc-runners)
- `arc-controller-values.yaml` - Helm values for ARC controller (empty, uses defaults)
- `arc-runner-set-values.yaml` - Helm values for runner scale set

## Prerequisites

1. **GitHub Personal Access Token (PAT)** or **GitHub App**

   - For PAT: Requires `Administrator` scope with Read & Write (and `Metadata` with Read Only)
   - For GitHub App: Preferred for security, requires app installation. Haven't tried this one

2. **Helm 3.x** installed

3. **Access to GitHub repository** where you want to run actions

## Installation

### Step 1: Create Namespaces

```bash
kubectl apply -f arc-namespaces.yaml
```

### Step 2: Generate GitHub PAT

1. Go to GitHub ~> Settings ~> Developer settings ~> Personal access tokens ~> Tokens (classic or Fine-grained, both work)
2. Click "Generate new token"
3. Give it a name: "K3s Homelab ARC"
4. If classic token, select scopes:
   - `repo` (Full control of private repositories)
   - `workflow` (Update GitHub Action workflows)
5. OR if Fine-grained token: `Administrator` (Read & Write), `Metadata` (Read Only)
6. Generate and copy the token

### Step 3: Install ARC Controller

```bash
# Add Helm repository
helm repo add actions-runner-controller https://actions.github.io/actions-runner-controller
helm repo update

# Install ARC controller
helm install arc \
  --namespace arc-systems \
  --create-namespace \
  actions-runner-controller/gha-runner-scale-set-controller
```

Verify installation:

```bash
kubectl get pods -n arc-systems
```

### Step 4: Configure Runner Set

Edit `arc-runner-set-values.yaml`:

```yaml
githubConfigUrl: https://github.com/YOUR_USERNAME/YOUR_REPO # Update this!

githubConfigSecret:
  github_token: "YOUR_GITHUB_PAT_HERE" # Add your PAT

template:
  spec:
    containers:
      - name: runner
        image: alialjaffer/arc-runner-aws:latest # Update if needed
```

**IMPORTANT**: For prod, use a Kubernetes secret instead of hardcoding the token:

```bash
# Create secret
kubectl create secret generic github-token \
  --namespace arc-runners \
  --from-literal=github_token=YOUR_GITHUB_PAT

# Then update values.yaml to reference the secret
# githubConfigSecret: github-token
```

### Step 5: Install Runner Set

```bash
helm install arc-runner-set-personal-website \
  --namespace arc-runners \
  actions-runner-controller/gha-runner-scale-set \
  --values arc-runner-set-values.yaml
```

Verify installation:

```bash
# Check listener pod
kubectl get pods -n arc-runners

# Check runner scale set status
kubectl get autoscalingrunnerset -n arc-runners
```

## Usage

### In Your GitHub Workflows

Use `runs-on` with your runner set name:

```yaml
name: Build and Deploy
on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: arc-runner-set-personal-website # Your runner set name
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: |
          npm install
          npm run build
```

### Scaling

Runners scale automatically based on workflow demand:

- Minimum runners: 0 (default)
- Maximum runners: Unlimited (default)
- Scaling mode: Pull (default)

Configure scaling in values:

```yaml
minRunners: 1 # Always keep 1 runner ready
maxRunners: 10 # Max 10 concurrent runners
```

## Custom Runner Images

### Why Custom Images?

Custom runner images allow you to

- Pre-install tools and dependencies
- Add specific software versions
- Include private certificates or credentials
- Optimize build times

### Building Custom Images

Base your image on the official GitHub runner:

**Dockerfile example:**

I have provided the [Dockerfile](./Dockerfile) I used for my runner with AWS CLI installed. I highly recommend doing this because it makes workflows much faster.

```dockerfile
FROM ghcr.io/actions/actions-runner:latest

# Install additional tools
RUN sudo apt-get update && \
    sudo apt-get install -y \
    docker.io \
    aws-cli \
    nodejs \
    npm

# Install specific Node version
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && \
    sudo apt-get install -y nodejs

# Clean up
RUN sudo apt-get clean && \
    sudo rm -rf /var/lib/apt/lists/*

USER runner
```

Build and push:

```bash
docker build -t your-registry/arc-runner:latest .
docker push your-registry/arc-runner:latest
```

Update `arc-runner-set-values.yaml`:

```yaml
template:
  spec:
    containers:
      - name: runner
        image: your-registry/arc-runner:latest
```

## Configuration Options

### Repository, Organization, or Enterprise Level

**Repository level** (current setup):

```yaml
githubConfigUrl: https://github.com/username/repo
```

**Organization level**:

```yaml
githubConfigUrl: https://github.com/your-org
```

**Enterprise level**:

```yaml
githubConfigUrl: https://github.com/enterprises/your-enterprise
```

### Runner Labels

Add custom labels to target specific runners:

```yaml
template:
  metadata:
    labels:
      runner-type: homelab
      environment: production
```

Use in workflows:

```yaml
jobs:
  build:
    runs-on: [self-hosted, homelab, production]
```

### Resource Limits

Set resource limits for runner pods:

```yaml
template:
  spec:
    containers:
      - name: runner
        image: ghcr.io/actions/actions-runner:latest
        resources:
          requests:
            cpu: 1000m
            memory: 2Gi
          limits:
            cpu: 2000m
            memory: 4Gi
```

### Node Selection

Run runners on specific nodes:

```yaml
template:
  spec:
    nodeSelector:
      kubernetes.io/hostname: fedora
    tolerations:
      - key: gpu
        operator: Equal
        value: nvidia
        effect: NoSchedule
```

## Monitoring

### Check Runner Status

```bash
# Get runner set status
kubectl get autoscalingrunnerset -n arc-runners

# Get current runners
kubectl get pods -n arc-runners

# Watch runner creation
kubectl get pods -n arc-runners -w
```

### Logs

```bash
# Controller logs
kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller

# Listener logs
kubectl logs -n arc-runners -l app.kubernetes.io/component=runner-scale-set-listener

# Runner pod logs
kubectl logs -n arc-runners <runner-pod-name>
```

### GitHub UI

View runners in GitHub:

1. Go to your repository
2. Settings ~> Actions ~> Runners
3. You should see your self-hosted runner(s)

## Troubleshooting

### No runners showing up

```bash
# Check controller logs
kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller

# Check listener logs
kubectl logs -n arc-runners -l app.kubernetes.io/component=runner-scale-set-listener

# Verify GitHub token has correct permissions
# Verify githubConfigUrl is correct
```

### Runner pods failing to start

```bash
# Check pod events
kubectl describe pod -n arc-runners <runner-pod-name>

# Common issues:
# - Image pull errors
# - Insufficient resources
# - Node selector mismatch
```

### Workflow stuck in "Queued"

```bash
# Check if listener is running
kubectl get pods -n arc-runners

# Check runner scale set status
kubectl get autoscalingrunnerset -n arc-runners -o yaml

# Verify webhook/polling is working
kubectl logs -n arc-runners -l app.kubernetes.io/component=runner-scale-set-listener -f
```

### GitHub token expired

```bash
# Update secret
kubectl create secret generic github-token \
  --namespace arc-runners \
  --from-literal=github_token=NEW_TOKEN \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart listener
kubectl rollout restart deployment -n arc-runners
```

## Security Best Practices

1. **Use GitHub Apps instead of PATs** - More secure, better permissions model
2. **Don't commit tokens!!!!!!** - Use Kubernetes secrets
3. **Use private registries** - For custom runner images
4. **Enable network policies** - Restrict runner network access
5. **Use ephemeral runners** - Don't reuse runners (ARC does this by default)
6. **Scan runner images** - For vulnerabilities
7. **Limit workflow permissions** - Use `permissions:` in workflows

## Network Access

Self-hosted runners can access:

- **Cluster services** - Via ClusterIP/DNS
- **Private network** - Your local network resources
- **LoadBalancer IPs** - Services exposed via MetalLB

Example use case: Access Grafana at `http://grafana.monitoring.svc.cluster.local:3000`

## Upgrading

### Upgrade Controller

```bash
helm repo update
helm upgrade arc \
  --namespace arc-systems \
  actions-runner-controller/gha-runner-scale-set-controller
```

### Upgrade Runner Set

```bash
helm upgrade arc-runner-set-personal-website \
  --namespace arc-runners \
  actions-runner-controller/gha-runner-scale-set \
  --values arc-runner-set-values.yaml
```

## Uninstalling

```bash
# Uninstall runner set
helm uninstall arc-runner-set-personal-website -n arc-runners

# Uninstall controller
helm uninstall arc -n arc-systems

# Delete namespaces
kubectl delete namespace arc-runners arc-systems
```

## Multiple Runner Sets

To create additional runner sets for different repositories:

```bash
helm install arc-runner-set-another-repo \
  --namespace arc-runners \
  --set githubConfigUrl="https://github.com/username/another-repo" \
  --set githubConfigSecret.github_token="YOUR_TOKEN" \
  actions-runner-controller/gha-runner-scale-set
```

## Current Configuration

- **Controller**: arc (arc-systems namespace)
- **Runner Set**: arc-runner-set-personal-website (arc-runners namespace)
- **Repository**: aliAljaffer/aliAljaffer.github.io
- **Runner Image**: alialjaffer/arc-runner-aws:latest
- **Scaling**: 0 min, unlimited max

## References

- [Actions Runner Controller Documentation](https://github.com/actions/actions-runner-controller)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Self-hosted Runner Security](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners#self-hosted-runner-security)
- [ARC Helm Chart](https://github.com/actions/actions-runner-controller/tree/master/charts)
