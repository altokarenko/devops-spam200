.PHONY: all start-minikube check-helm-version install-crds deploy-monitoring deploy-app deploy-argocd configure-argocd-app expose-services get-urls get-argocd-url status clean help

# ArgoCD Git repository URL (set via environment variable or Makefile variable)
ARGOCD_GIT_REPO_URL ?= https://github.com/altokarenko/devops-spam200.git

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
			-f values-vm-stack.yaml || true; \
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
	kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=vmsingle -n monitoring --timeout=300s 2>/dev/null || \
	kubectl wait --for=condition=ready pod -l app=victoria-metrics -n monitoring --timeout=300s 2>/dev/null || \
	echo "VictoriaMetrics pod not found, continuing..."
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vmagent -n monitoring --timeout=300s 2>/dev/null || \
	kubectl wait --for=condition=ready pod -l app=vmagent -n monitoring --timeout=300s 2>/dev/null || \
	echo "VMAgent pod not found, continuing..."
	@echo "Deploying Grafana dashboard ConfigMap..."
	@kubectl apply -f helm-charts/grafana-dashboard.yaml || true
	@echo "Waiting for vmoperator to be ready (may take time for image pull)..."
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=victoria-metrics-operator -n monitoring --timeout=600s 2>/dev/null || \
	echo "vmoperator pod not ready yet, continuing..."
	@echo "Waiting for vm-grafana to be ready..."
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=300s 2>/dev/null || \
	kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=vm -l app.kubernetes.io/name=grafana -n monitoring --timeout=300s 2>/dev/null || \
	echo "vm-grafana pod not found, continuing..."
	@echo "Giving vm-grafana additional time to initialize and discover dashboard..."
	@sleep 15
	@echo "Monitoring stack deployed successfully"

# Deploy spam2000 application (direct Helm deployment)
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

# Deploy ArgoCD
deploy-argocd: check-helm-version
	@echo "Deploying ArgoCD..."
	@helm repo add argo https://argoproj.github.io/argo-helm || true
	@helm repo update
	@kubectl create namespace argocd || true
	@echo "Installing ArgoCD..."
	@helm upgrade --install argocd argo/argo-cd \
		-n argocd \
		-f argocd-values.yaml \
		--wait \
		--timeout=600s
	@echo "Waiting for ArgoCD server to be ready..."
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s || true
	@echo "ArgoCD deployed successfully"

# Configure ArgoCD Application for spam2000
configure-argocd-app: deploy-argocd
	@echo "Configuring ArgoCD Application for spam2000..."
	@if [ -z "$(ARGOCD_GIT_REPO_URL)" ] || [ "$(ARGOCD_GIT_REPO_URL)" = "https://github.com/your-org/spam2000-gitops.git" ]; then \
		echo "ERROR: ARGOCD_GIT_REPO_URL is not set or is using the default placeholder."; \
		echo "Please set ARGOCD_GIT_REPO_URL environment variable or update the Makefile variable."; \
		echo "Example: export ARGOCD_GIT_REPO_URL=https://github.com/your-org/spam2000-gitops.git"; \
		echo "Or: make configure-argocd-app ARGOCD_GIT_REPO_URL=https://github.com/your-org/spam2000-gitops.git"; \
		exit 1; \
	fi
	@echo "Using Git repository: $(ARGOCD_GIT_REPO_URL)"
	@ARGOCD_GIT_REPO_URL="$(ARGOCD_GIT_REPO_URL)" envsubst < argocd-apps/spam2000-application.yaml | kubectl apply -f -
	@echo "ArgoCD Application configured successfully"
	@echo "Waiting for ArgoCD to sync the application..."
	@sleep 10
	@kubectl wait --for=condition=healthy application/spam2000 -n argocd --timeout=300s || echo "Application sync may take longer..."

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
	echo "Grafana (vm-grafana): http://$$MINIKUBE_IP:30082"; \
	echo ""; \
	echo "Grafana credentials:"; \
	echo "  Username: admin"; \
	echo "  Password: admin"; \
	echo "=========================================="

# Get ArgoCD access URL and credentials
get-argocd-url:
	@echo ""
	@echo "=========================================="
	@echo "ArgoCD Access Information:"
	@echo "=========================================="
	@MINIKUBE_IP=$$(minikube ip); \
	echo "Minikube IP: $$MINIKUBE_IP"; \
	echo ""; \
	echo "ArgoCD UI: http://$$MINIKUBE_IP:30083"; \
	echo ""; \
	echo "Getting ArgoCD admin password..."; \
	@ARGOCD_PASSWORD=$$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "Password not available yet. Wait a few moments and try again."); \
	echo "ArgoCD credentials:"; \
	echo "  Username: admin"; \
	echo "  Password: $$ARGOCD_PASSWORD"; \
	echo ""; \
	echo "To retrieve password later, run:"; \
	echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"; \
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
	@if kubectl get namespace argocd >/dev/null 2>&1; then \
		echo "ArgoCD Pods:"; \
		kubectl get pods -n argocd; \
		echo ""; \
		echo "ArgoCD Applications:"; \
		kubectl get applications -n argocd; \
		echo ""; \
	fi
	@echo "Services:"
	@kubectl get svc spam2000
	@echo ""
	@kubectl get svc -n monitoring
	@if kubectl get namespace argocd >/dev/null 2>&1; then \
		echo ""; \
		kubectl get svc -n argocd; \
	fi

# Clean up all deployments
clean:
	@echo "Cleaning up deployments..."
	@helm uninstall spam2000 || true
	@helm uninstall vm -n monitoring || true
	@helm uninstall argocd -n argocd || true
	@kubectl delete -f helm-charts/victoria-metrics-manifest.yaml 2>/dev/null || true
	@kubectl delete -f helm-charts/vmagent-manifest.yaml 2>/dev/null || true
	@kubectl delete -f helm-charts/grafana-dashboard.yaml 2>/dev/null || true
	@kubectl delete application spam2000 -n argocd 2>/dev/null || true
	@kubectl delete namespace monitoring || true
	@kubectl delete namespace argocd || true
	@echo "Cleanup complete. Run 'minikube stop' to stop Minikube if needed."

# Help target
help:
	@echo "Available targets:"
	@echo "  all                  - Complete deployment (default)"
	@echo "  start-minikube       - Start Minikube cluster"
	@echo "  check-helm-version   - Check if Helm version is compatible"
	@echo "  install-crds         - Install ServiceMonitor CRD"
	@echo "  deploy-monitoring    - Deploy VictoriaMetrics and Grafana"
	@echo "  deploy-app           - Deploy spam2000 application (direct Helm)"
	@echo "  deploy-argocd        - Deploy ArgoCD GitOps controller"
	@echo "  configure-argocd-app - Configure ArgoCD Application for spam2000"
	@echo "  expose-services      - Ensure all services are NodePort"
	@echo "  get-urls             - Display access URLs"
	@echo "  get-argocd-url       - Display ArgoCD UI access URL and credentials"
	@echo "  status               - Show deployment status"
	@echo "  clean                - Remove all deployments"
	@echo "  help                 - Show this help message"
	@echo ""
	@echo "ArgoCD GitOps:"
	@echo "  To use ArgoCD for GitOps, set ARGOCD_GIT_REPO_URL environment variable:"
	@echo "    export ARGOCD_GIT_REPO_URL=https://github.com/your-org/spam2000-gitops.git"
	@echo "    make deploy-argocd configure-argocd-app"

