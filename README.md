# Spam2000 Minikube Deployment with Monitoring and GitOps

This project deploys the `andriiuni/spam2000:1.1394.355` application on Minikube using Helm, with VictoriaMetrics for monitoring, Grafana for visualization, and ArgoCD for GitOps workflow.

## Prerequisites

- Minikube installed and configured
- Helm 3.x installed
- kubectl configured to work with Minikube
- Make tool installed
- Sufficient system resources (recommended: 4 CPU cores, 8GB RAM)

## Quick Start

Deploy everything with a single command:

```bash
make
```

This will:
1. Start Minikube (if not already running)
2. Deploy VictoriaMetrics and Grafana monitoring stack
3. Deploy the spam2000 application (via direct Helm)
4. Display access URLs

**Note**: For GitOps deployment using ArgoCD, see the [ArgoCD GitOps](#argocd-gitops) section below.

## Access URLs

After deployment, access the services using the Minikube IP and assigned ports:

- **Application (spam2000)**: `http://<minikube-ip>:30080`
- **VictoriaMetrics**: `http://<minikube-ip>:30081`
- **Grafana**: `http://<minikube-ip>:30082`
- **ArgoCD UI**: `http://<minikube-ip>:30083` (if ArgoCD is deployed)

To get the Minikube IP and all URLs, run:

```bash
make get-urls
```

### Grafana Credentials

- **Username**: `admin`
- **Password**: `admin`

### ArgoCD Credentials

To get ArgoCD admin password, run:
```bash
make get-argocd-url
```

Or manually:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

- **Username**: `admin`
- **Password**: (retrieved from secret as shown above)

**Note**: VictoriaMetrics should be automatically configured as a data source in Grafana. If not, you can add it manually:
1. Go to Configuration → Data Sources
2. Add Prometheus data source
3. URL: `http://vmsingle-victoria-metrics-k8s-stack:8429`

## Available Make Targets

- `make` or `make all` - Complete deployment (default)
- `make start-minikube` - Start Minikube cluster with recommended resources
- `make check-helm-version` - Check if Helm version is compatible
- `make install-crds` - Install ServiceMonitor CRD
- `make deploy-monitoring` - Deploy VictoriaMetrics and Grafana
- `make deploy-app` - Deploy spam2000 application only (direct Helm)
- `make deploy-argocd` - Deploy ArgoCD GitOps controller
- `make configure-argocd-app` - Configure ArgoCD Application for spam2000
- `make expose-services` - Ensure all services are exposed as NodePort
- `make get-urls` - Display access URLs with Minikube IP
- `make get-argocd-url` - Display ArgoCD UI access URL and credentials
- `make status` - Show deployment status (pods, services)
- `make clean` - Remove all deployments and clean up
- `make help` - Show all available targets

## Project Structure

```
devops-spam200/
├── Makefile                          # Main orchestration file
├── README.md                         # This file
├── argocd-values.yaml                # ArgoCD Helm chart values
├── argocd-apps/                      # ArgoCD Application manifests
│   └── spam2000-application.yaml     # ArgoCD Application for spam2000
└── helm-charts/
    ├── spam2000/                     # Application Helm chart
    │   ├── Chart.yaml
    │   ├── values.yaml
    │   └── templates/
    │       ├── deployment.yaml
    │       ├── service.yaml
    │       ├── servicemonitor.yaml
    │       └── _helpers.tpl
    └── grafana-values.yaml          # Grafana configuration values
```

## Monitoring Setup

The deployment includes:

- **VictoriaMetrics**: High-performance time-series database for metrics
- **Grafana**: Visualization and dashboarding platform
- **ServiceMonitor**: Automatic discovery of spam2000 metrics (if `/metrics` endpoint exists)

Metrics are automatically scraped by VictoriaMetrics Agent (VMAgent) and forwarded to VictoriaMetrics Single (VMSingle).

## Troubleshooting

### Check deployment status

```bash
make status
```

### View application logs

```bash
kubectl logs -l app.kubernetes.io/name=spam2000
```

### View monitoring stack logs

```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana
kubectl logs -n monitoring -l app.kubernetes.io/name=vmsingle
```

### Restart a component

```bash
# Restart application
kubectl rollout restart deployment spam2000

# Restart Grafana
kubectl rollout restart deployment grafana -n monitoring
```

### Clean up and redeploy

```bash
make clean
make
```

## Customization

### Modify application configuration

Edit `helm-charts/spam2000/values.yaml` to customize:
- Image version
- Replica count
- Resource limits
- Service ports

### Modify monitoring configuration

The monitoring stack uses Helm values passed in the Makefile. You can modify the `deploy-monitoring` target in `Makefile` to adjust:
- Resource allocations
- Service ports
- Retention policies

## ArgoCD GitOps

This project supports GitOps deployment using ArgoCD. ArgoCD will automatically sync the spam2000 application from a Git repository.

### Prerequisites for GitOps

1. A Git repository containing the spam2000 Helm chart
2. The Helm chart should be located at `helm-charts/spam2000/` in the repository
3. The repository should be accessible from the Minikube cluster

### Setting Up ArgoCD GitOps

1. **Deploy ArgoCD**:
   ```bash
   make deploy-argocd
   ```

2. **Configure the Git repository URL**:
   ```bash
   export ARGOCD_GIT_REPO_URL=https://github.com/your-org/spam2000-gitops.git
   ```
   
   Or pass it directly:
   ```bash
   make configure-argocd-app ARGOCD_GIT_REPO_URL=https://github.com/your-org/spam2000-gitops.git
   ```

3. **Configure ArgoCD Application**:
   ```bash
   make configure-argocd-app
   ```

4. **Get ArgoCD access information**:
   ```bash
   make get-argocd-url
   ```

### ArgoCD Features

- **Auto-sync**: Enabled by default - changes in Git are automatically deployed
- **Self-heal**: Enabled - ArgoCD will revert manual changes to match Git state
- **Prune**: Enabled - resources removed from Git are automatically deleted

### Git Repository Structure

Your Git repository should have the following structure:
```
spam2000-gitops/
└── helm-charts/
    └── spam2000/
        ├── Chart.yaml
        ├── values.yaml
        └── templates/
            ├── deployment.yaml
            ├── service.yaml
            ├── servicemonitor.yaml
            └── _helpers.tpl
```

### Working with ArgoCD

- **View applications**: Access ArgoCD UI at `http://<minikube-ip>:30083`
- **Check sync status**: `kubectl get applications -n argocd`
- **Manual sync**: Use ArgoCD UI or CLI to trigger manual sync if needed
- **View application details**: `kubectl describe application spam2000 -n argocd`

### Private Git Repositories

If your Git repository is private, you'll need to configure credentials in ArgoCD:

1. Access ArgoCD UI
2. Go to Settings → Repositories
3. Add your repository with credentials
4. Update the Application manifest to reference the repository

## Notes

- All services use NodePort type for browser access
- Services are deployed in the `default` namespace (application) and `monitoring` namespace (observability stack)
- The deployment assumes the spam2000 application exposes metrics at `/metrics` endpoint (Prometheus format)
- If metrics are not automatically discovered, check if ServiceMonitor CRD is installed and the application exposes metrics
- Victoria Metrics stack is deployed via Makefile and is NOT managed by ArgoCD
- ArgoCD only manages the spam2000 application
