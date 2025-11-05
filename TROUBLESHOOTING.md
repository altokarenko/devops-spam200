# Troubleshooting Guide

## Common Issues and Solutions

### Issue 1: Helm Version Too Low

**Error**: `This chart requires helm version 3.14.0 or higher`

**Solution**: The Makefile now automatically detects Helm version and uses VictoriaMetrics Single standalone if Helm version is too old. To upgrade Helm:

```bash
# Check current version
helm version

# Upgrade Helm (example for Linux)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Issue 2: ServiceMonitor CRD Not Found

**Error**: `no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1"`

**Solution**: The Makefile now automatically installs ServiceMonitor CRD. If it still fails:

1. Manually install the CRD:
```bash
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
```

2. Or disable ServiceMonitor in the chart:
```bash
helm upgrade --install spam2000 ./helm-charts/spam2000 --set serviceMonitor.enabled=false
```

### Issue 3: VictoriaMetrics Not Deployed

**Error**: `no matching resources found` when waiting for vmsingle pod

**Solution**: 
1. Check if VictoriaMetrics was deployed:
```bash
kubectl get pods -n monitoring
kubectl get svc -n monitoring
```

2. Check Helm release status:
```bash
helm list -n monitoring
helm status vm -n monitoring
```

3. If using old Helm version, VictoriaMetrics Single should be deployed instead. Check for `victoria-metrics-single` pod.

### Issue 4: Grafana Not Ready

**Error**: `Readiness probe failed: connection refused`

**Solution**: 
1. Grafana takes time to initialize. Wait a bit longer:
```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=600s
```

2. Check Grafana logs:
```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana
```

3. Check if Grafana pod is running:
```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana
kubectl describe pod -n monitoring -l app.kubernetes.io/name=grafana
```

### Issue 5: Cannot Access Services via Browser

**Solution**:
1. Get Minikube IP:
```bash
minikube ip
```

2. Check service NodePorts:
```bash
kubectl get svc spam2000
kubectl get svc -n monitoring
```

3. Ensure services are NodePort type:
```bash
make expose-services
```

4. If using minikube tunnel (for LoadBalancer):
```bash
minikube tunnel
```

### Issue 6: VictoriaMetrics Datasource Not Working in Grafana

**Solution**:
1. Check VictoriaMetrics service name:
```bash
kubectl get svc -n monitoring | grep victoria
```

2. Manually add datasource in Grafana UI:
   - Go to Configuration → Data Sources
   - Add Prometheus data source
   - URL: `http://vmsingle-victoria-metrics-k8s-stack:8428` or `http://victoria-metrics-single:8428`
   - Access: Proxy

### Clean Deployment Steps

If you encounter persistent issues, try a clean deployment:

```bash
# Clean everything
make clean

# Start fresh
make
```

### Manual Verification Steps

1. Check all pods are running:
```bash
make status
```

2. Check service endpoints:
```bash
kubectl get endpoints -n monitoring
kubectl get endpoints spam2000
```

3. Test application connectivity:
```bash
MINIKUBE_IP=$(minikube ip)
curl http://$MINIKUBE_IP:30080
```

4. Test VictoriaMetrics:
```bash
MINIKUBE_IP=$(minikube ip)
curl http://$MINIKUBE_IP:30081/api/v1/query?query=up
```

5. Test Grafana:
```bash
MINIKUBE_IP=$(minikube ip)
curl http://$MINIKUBE_IP:30082/api/health
```

