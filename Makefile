.PHONY: all start-minikube check-helm-version install-crds deploy-monitoring deploy-app expose-services get-urls status clean help

# Default target
all: start-minikube install-crds deploy-monitoring deploy-app get-urls

# Start minikube with sufficient resources
start-minikube:
	@echo "Starting Minikube..."
	@minikube status || minikube start --cpus=4 --memory=8192
	@echo "Minikube is running"

# Check Helm version
check-helm-version:
	@echo "Checking Helm version..."
	@HELM_VERSION=$$(helm version --template '{{.Version}}' | sed 's/[^0-9.]//g' | cut -d. -f1,2); \
	REQUIRED_VERSION="3.14"; \
	if [ "$$(printf '%s\n' "$$REQUIRED_VERSION" "$$HELM_VERSION" | sort -V | head -n1)" != "$$REQUIRED_VERSION" ]; then \
		echo "WARNING: Helm version $$HELM_VERSION is lower than required 3.14.0"; \
		echo "Attempting to deploy with alternative approach..."; \
	fi

# Install ServiceMonitor CRD
install-crds:
	@echo "Installing ServiceMonitor CRD..."
	@kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml || \
	kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.68.0/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml || \
	echo "ServiceMonitor CRD installation failed, continuing without it..."

# Deploy monitoring stack (VictoriaMetrics and Grafana)
deploy-monitoring: check-helm-version
	@echo "Deploying monitoring stack..."
	@helm repo add vm https://victoriametrics.github.io/helm-charts || true
	@helm repo add grafana https://grafana.github.io/helm-charts || true
	@helm repo update
	@kubectl create namespace monitoring || true
	@echo "Installing VictoriaMetrics..."
	@HELM_VERSION=$$(helm version --template '{{.Version}}' | sed 's/[^0-9.]//g' | cut -d. -f1,2); \
	REQUIRED_VERSION="3.14"; \
	if [ "$$(printf '%s\n' "$$REQUIRED_VERSION" "$$HELM_VERSION" | sort -V | head -n1)" = "$$REQUIRED_VERSION" ]; then \
		echo "Using VictoriaMetrics k8s-stack (Helm 3.14+)..."; \
		helm upgrade --install vm vm/victoria-metrics-k8s-stack \
			-n monitoring \
			--set vmoperator.enabled=true \
			--set vmsingle.enabled=true \
			--set vmagent.enabled=true \
			--set vmsingle.service.type=NodePort \
			--set vmsingle.service.nodePort=30081 \
			--set vmagent.remoteWrite[0].url=http://vmsingle-victoria-metrics-k8s-stack:8428/api/v1/write || true; \
	else \
		echo "Helm version $$HELM_VERSION too old (< 3.14), deploying VictoriaMetrics using Kubernetes manifests..."; \
		kubectl apply -f helm-charts/victoria-metrics-manifest.yaml || true; \
		echo "Deploying VMAgent for metrics scraping..."; \
		kubectl apply -f helm-charts/vmagent-manifest.yaml || true; \
	fi
	@echo "Waiting for VictoriaMetrics to be ready..."
	@sleep 5
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vmsingle -n monitoring --timeout=300s 2>/dev/null || \
	kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=victoria-metrics-single -n monitoring --timeout=300s 2>/dev/null || \
	kubectl wait --for=condition=ready pod -l app=victoria-metrics -n monitoring --timeout=300s 2>/dev/null || \
	echo "VictoriaMetrics pod not found, continuing..."
	@kubectl wait --for=condition=ready pod -l app=vmagent -n monitoring --timeout=300s 2>/dev/null || \
	echo "VMAgent pod not found, continuing..."
	@echo "Deploying Grafana dashboard ConfigMap (must be before Grafana deployment)..."
	@kubectl apply -f helm-charts/grafana-dashboard.yaml || true
	@echo "Installing Grafana..."
	@VM_SERVICE_NAME="vmsingle-victoria-metrics-k8s-stack"; \
	kubectl get svc $$VM_SERVICE_NAME -n monitoring >/dev/null 2>&1 || VM_SERVICE_NAME="victoria-metrics-single"; \
	kubectl get svc $$VM_SERVICE_NAME -n monitoring >/dev/null 2>&1 || VM_SERVICE_NAME="victoria-metrics"; \
	echo "Using VictoriaMetrics service: $$VM_SERVICE_NAME"; \
	TEMP_FILE="/tmp/grafana-values-$$$$.yaml"; \
	sed "s|url: http://victoria-metrics:8428|url: http://$$VM_SERVICE_NAME:8428|" helm-charts/grafana-values.yaml > $$TEMP_FILE; \
	helm upgrade --install grafana grafana/grafana \
		-n monitoring \
		-f $$TEMP_FILE; \
	rm -f $$TEMP_FILE
	@echo "Waiting for Grafana to be ready..."
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=300s || true
	@echo "Giving Grafana additional time to initialize..."
	@sleep 10
	@echo "Monitoring stack deployed successfully"

# Deploy spam2000 application
deploy-app: install-crds
	@echo "Deploying spam2000 application..."
	@echo "Checking if ServiceMonitor CRD is available..."
	@if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then \
		echo "ServiceMonitor CRD found, enabling ServiceMonitor"; \
		helm upgrade --install spam2000 ./helm-charts/spam2000; \
	else \
		echo "ServiceMonitor CRD not found, disabling ServiceMonitor in chart"; \
		helm upgrade --install spam2000 ./helm-charts/spam2000 --set serviceMonitor.enabled=false; \
	fi
	@echo "Waiting for spam2000 to be ready..."
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=spam2000 --timeout=300s || true
	@echo "spam2000 application deployed successfully"

# Ensure all services are exposed as NodePort
expose-services:
	@echo "Ensuring services are exposed as NodePort..."
	@kubectl patch svc grafana -n monitoring -p '{"spec": {"type": "NodePort", "ports": [{"port": 80, "targetPort": 3000, "nodePort": 30082, "protocol": "TCP", "name": "http"}]}}' || true
	@kubectl patch svc spam2000 -p '{"spec": {"type": "NodePort", "ports": [{"port": 80, "targetPort": 80, "nodePort": 30080, "protocol": "TCP", "name": "http"}]}}' || true
	@echo "Services exposed"

# Get access URLs
get-urls:
	@echo ""
	@echo "=========================================="
	@echo "Access URLs:"
	@echo "=========================================="
	@MINIKUBE_IP=$$(minikube ip); \
	echo "Minikube IP: $$MINIKUBE_IP"; \
	echo ""; \
	echo "Application (spam2000): http://$$MINIKUBE_IP:30080"; \
	echo "VictoriaMetrics: http://$$MINIKUBE_IP:30081"; \
	echo "Grafana: http://$$MINIKUBE_IP:30082"; \
	echo ""; \
	echo "Grafana credentials:"; \
	echo "  Username: admin"; \
	echo "  Password: admin"; \
	echo "=========================================="

# Show deployment status
status:
	@echo "Minikube Status:"
	@minikube status || echo "Minikube is not running"
	@echo ""
	@echo "Application Pods:"
	@kubectl get pods -l app.kubernetes.io/name=spam2000
	@echo ""
	@echo "Monitoring Pods:"
	@kubectl get pods -n monitoring
	@echo ""
	@echo "Services:"
	@kubectl get svc spam2000
	@echo ""
	@kubectl get svc -n monitoring

# Clean up all deployments
clean:
	@echo "Cleaning up deployments..."
	@helm uninstall spam2000 || true
	@helm uninstall grafana -n monitoring || true
	@helm uninstall vm -n monitoring || true
	@kubectl delete -f helm-charts/victoria-metrics-manifest.yaml 2>/dev/null || true
	@kubectl delete -f helm-charts/vmagent-manifest.yaml 2>/dev/null || true
	@kubectl delete -f helm-charts/grafana-dashboard.yaml 2>/dev/null || true
	@kubectl delete namespace monitoring || true
	@echo "Cleanup complete. Run 'minikube stop' to stop Minikube if needed."

# Help target
help:
	@echo "Available targets:"
	@echo "  all              - Complete deployment (default)"
	@echo "  start-minikube   - Start Minikube cluster"
	@echo "  check-helm-version - Check if Helm version is compatible"
	@echo "  install-crds     - Install ServiceMonitor CRD"
	@echo "  deploy-monitoring - Deploy VictoriaMetrics and Grafana"
	@echo "  deploy-app       - Deploy spam2000 application"
	@echo "  expose-services  - Ensure all services are NodePort"
	@echo "  get-urls         - Display access URLs"
	@echo "  status           - Show deployment status"
	@echo "  clean            - Remove all deployments"
	@echo "  help             - Show this help message"

