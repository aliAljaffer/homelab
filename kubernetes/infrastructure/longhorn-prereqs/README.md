# longhorn-prereqs

- `serviceaccount.yaml`: pre-creates the service account the Longhorn pre-upgrade Helm hook needs. Without it, the hook job fails on fresh installs, the SA only exists after the main chart deploys, a circular dependency.
