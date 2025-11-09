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
2. Install ServiceMonitor CRD
3. Deploy VictoriaMetrics and Grafana monitoring stack
4. Deploy ArgoCD GitOps controller
5. Configure ArgoCD Application for spam2000 (GitOps)
6. Display access URLs

The spam2000 application is managed via GitOps through ArgoCD, which monitors the Git repository and automatically syncs changes.

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
- **Password**: Randomly generated during deployment

The password is automatically generated and saved to `.grafana-password` file in the project root. To retrieve it:

```bash
cat .grafana-password
```

Or use:
```bash
make get-urls
```

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

- `make` or `make all` - Complete deployment including ArgoCD and GitOps (default)
- `make start-minikube` - Start Minikube cluster with recommended resources
- `make install-crds` - Install ServiceMonitor CRD
- `make deploy-monitoring` - Deploy VictoriaMetrics and Grafana
- `make deploy-argocd` - Deploy ArgoCD GitOps controller
- `make configure-argocd-app` - Configure ArgoCD Application for spam2000
- `make get-urls` - Display access URLs and credentials for all services
- `make status` - Show deployment status (pods, services, ArgoCD applications)
- `make clean` - Remove all deployments and clean up
- `make help` - Show all available targets

## Project Structure

```
devops-spam200/
├── Makefile                          # Main orchestration file
├── README.md                         # This file
├── argocd-values.yaml                # ArgoCD Helm chart values
├── values-vm-stack.yaml              # VictoriaMetrics stack values
├── argocd-apps/                      # ArgoCD Application manifests
│   └── spam2000-application.yaml     # ArgoCD Application for spam2000
└── helm-charts/
    ├── spam2000/                     # Application Helm chart (GitOps managed)
    │   ├── Chart.yaml
    │   ├── values.yaml
    │   └── templates/
    │       ├── deployment.yaml
    │       ├── service.yaml
    │       ├── servicemonitor.yaml
    │       └── _helpers.tpl
    └── grafana-dashboard.yaml        # Grafana dashboard ConfigMap
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

This project uses GitOps deployment with ArgoCD. The spam2000 application is automatically managed via ArgoCD, which monitors the Git repository and syncs changes.

### Git Repository Configuration

By default, ArgoCD is configured to monitor: `https://github.com/altokarenko/devops-spam200.git`

To use a different repository:
```bash
make ARGOCD_GIT_REPO_URL=https://github.com/your-org/spam2000-gitops.git
```

### Git Repository Structure

Your Git repository should have the following structure:
```
your-gitops-repo/
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

### ArgoCD Features

- **Auto-sync**: Enabled by default - changes in Git are automatically deployed
- **Self-heal**: Enabled - ArgoCD will revert manual changes to match Git state
- **Prune**: Enabled - resources removed from Git are automatically deleted

### Working with ArgoCD

- **View applications**: Access ArgoCD UI at `http://<minikube-ip>:30083`
- **Check sync status**: `kubectl get applications -n argocd`
- **Manual sync**: Use ArgoCD UI or CLI to trigger manual sync if needed
- **View application details**: `kubectl describe application spam2000 -n argocd`

## Notes

- All services use NodePort type for browser access
- Services are deployed in the `default` namespace (application) and `monitoring` namespace (observability stack)
- The deployment assumes the spam2000 application exposes metrics at `/metrics` endpoint (Prometheus format)
- If metrics are not automatically discovered, check if ServiceMonitor CRD is installed and the application exposes metrics
- Victoria Metrics stack is deployed via Makefile and is NOT managed by ArgoCD
- ArgoCD only manages the spam2000 application
