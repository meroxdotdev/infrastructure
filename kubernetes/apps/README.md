# Kubernetes Apps Directory

This directory contains all application deployments managed by FluxCD, organized by namespace.

## Structure

```
apps/
├── cert-manager/          # Certificate management
├── default/               # User applications (dashboard, media stack)
├── flux-system/           # FluxCD operator and instance
├── kube-system/           # Core Kubernetes system components
├── network/               # Networking components (DNS, tunnels, gateways)
├── observability/         # Monitoring and logging stack
└── storage/               # Storage solutions (Longhorn)
```

## Organization Principles

### Namespace Organization
- **cert-manager**: Certificate management and TLS
- **default**: User-facing applications (homepage, media stack)
- **flux-system**: FluxCD GitOps tooling
- **kube-system**: Core Kubernetes infrastructure components
- **network**: Network-related services (DNS, tunnels, gateways)
- **observability**: Monitoring, logging, and dashboards
- **storage**: Storage solutions

### App Structure
Each app follows a consistent structure:
```
<app-name>/
├── app/
│   ├── helmrelease.yaml   # Helm release configuration
│   ├── kustomization.yaml # Kustomize resources
│   └── [other resources]  # PVCs, secrets, configs, etc.
└── ks.yaml                # Flux Kustomization resource
```

### Configuration Standards

1. **Schema URLs**: All `ks.yaml` files use the standardized FluxCD community schema:
   ```yaml
   # yaml-language-server: $schema=https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/kustomization-kustomize-v1.json
   ```

2. **Decryption**: Apps with SOPS-encrypted secrets include decryption configuration:
   ```yaml
   decryption:
     provider: sops
     secretRef:
       name: sops-age
   ```

3. **Common Metadata**: All apps include consistent labels:
   ```yaml
   commonMetadata:
     labels:
       app.kubernetes.io/name: *app
   ```

4. **Dependencies**: Apps declare dependencies using `dependsOn`:
   ```yaml
   dependsOn:
     - name: longhorn
       namespace: longhorn-system
   ```

## Default Namespace Apps

### Dashboard
- **homepage**: Unified dashboard for all services

### Media Stack
- **jellyfin**: Media server
- **jellyseerr**: Media request management
- **prowlarr**: Indexer manager
- **qbittorrent**: BitTorrent client
- **radarr**: Movie collection manager
- **sonarr**: TV series collection manager

## Best Practices

1. **Consistency**: All apps follow the same structure and patterns
2. **Documentation**: Comments in kustomization files group related apps
3. **Clean Code**: No commented-out code in production files
4. **Dependencies**: Explicit dependency declarations for proper ordering
5. **Secrets**: SOPS encryption for all sensitive data

## Recent Improvements

- ✅ Standardized all schema URLs to FluxCD community schemas
- ✅ Added decryption configuration where needed
- ✅ Cleaned up commented-out code
- ✅ Improved organization with logical grouping and comments
- ✅ Consistent kustomization patterns across all namespaces

