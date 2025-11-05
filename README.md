# Spam2000 Minikube Deployment with Monitoring

This project deploys the `andriiuni/spam2000:1.1394.355` application on Minikube using Helm, with VictoriaMetrics for monitoring and Grafana for visualization.

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
3. Deploy the spam2000 application
4. Display access URLs

## Access URLs

After deployment, access the services using the Minikube IP and assigned ports:

- **Application (spam2000)**: `http://<minikube-ip>:30080`
- **VictoriaMetrics**: `http://<minikube-ip>:30081`
- **Grafana**: `http://<minikube-ip>:30082`

To get the Minikube IP and all URLs, run:

```bash
make get-urls
```

### Grafana Credentials

- **Username**: `admin`
- **Password**: `admin`

**Note**: VictoriaMetrics should be automatically configured as a data source in Grafana. If not, you can add it manually:
1. Go to Configuration → Data Sources
2. Add Prometheus data source
3. URL: `http://vmsingle-victoria-metrics-k8s-stack:8429`

## Available Make Targets

- `make` or `make all` - Complete deployment (default)
- `make start-minikube` - Start Minikube cluster with recommended resources
- `make deploy-monitoring` - Deploy VictoriaMetrics and Grafana
- `make deploy-app` - Deploy spam2000 application only
- `make expose-services` - Ensure all services are exposed as NodePort
- `make get-urls` - Display access URLs with Minikube IP
- `make status` - Show deployment status (pods, services)
- `make clean` - Remove all deployments and clean up
- `make help` - Show all available targets

## Project Structure

```
devops-spam200/
├── Makefile                          # Main orchestration file
├── README.md                         # This file
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

## Notes

- All services use NodePort type for browser access
- Services are deployed in the `default` namespace (application) and `monitoring` namespace (observability stack)
- The deployment assumes the spam2000 application exposes metrics at `/metrics` endpoint (Prometheus format)
- If metrics are not automatically discovered, check if ServiceMonitor CRD is installed and the application exposes metrics
