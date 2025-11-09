.PHONY: all start-minikube install-crds deploy-monitoring deploy-argocd deploy-app configure-argocd-app get-urls status clean help

ARGOCD_GIT_REPO_URL ?= https://github.com/altokarenko/devops-spam200.git

all: start-minikube install-crds deploy-monitoring deploy-argocd deploy-app configure-argocd-app get-urls

start-minikube:
	@echo "Starting Minikube..."
	@minikube status || minikube start --cpus=4 --memory=8192
	@echo "Minikube is running"

install-crds:
	@echo "Installing ServiceMonitor CRD..."
	@kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml || \
	kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.68.0/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml || \
	echo "ServiceMonitor CRD installation failed, continuing without it..."

deploy-monitoring:
	@echo "Deploying monitoring stack..."
	@helm repo add vm https://victoriametrics.github.io/helm-charts || true
	@helm repo add grafana https://grafana.github.io/helm-charts || true
	@helm repo update
	@kubectl create namespace monitoring || true
	@echo "Generating random password for Grafana..."
	@if [ ! -f .grafana-password ]; then \
		GRAFANA_PASSWORD=$$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16); \
		echo $$GRAFANA_PASSWORD > .grafana-password; \
		echo "Grafana password generated and saved to .grafana-password"; \
	else \
		echo "Using existing Grafana password from .grafana-password"; \
	fi
	@GRAFANA_PASSWORD=$$(cat .grafana-password); \
	echo "Installing VictoriaMetrics..."; \
	HELM_VERSION=$$(helm version --template '{{.Version}}' | sed 's/[^0-9.]//g' | cut -d. -f1,2); \
	REQUIRED_VERSION="3.14"; \
	if [ "$$(printf '%s\n' "$$REQUIRED_VERSION" "$$HELM_VERSION" | sort -V | head -n1)" != "$$REQUIRED_VERSION" ]; then \
		echo "ERROR: Helm version $$HELM_VERSION is lower than required 3.14.0"; \
		echo "Please upgrade Helm to version 3.14 or higher"; \
		exit 1; \
	fi; \
	echo "Using VictoriaMetrics k8s-stack (Helm 3.14+)..."; \
	helm upgrade --install vm vm/victoria-metrics-k8s-stack \
		-n monitoring \
		-f values-vm-stack.yaml \
		--set grafana.adminPassword=$$GRAFANA_PASSWORD || true
	@echo "Waiting for VictoriaMetrics to be ready..."
	@sleep 5
	@echo "Checking pod status..."
	@for i in 1 2 3 4 5; do \
		if kubectl get pods -n monitoring -l app.kubernetes.io/name=vmsingle 2>/dev/null | grep -q Running; then \
			echo "VictoriaMetrics pod is running"; \
			break; \
		fi; \
		echo "Waiting for VictoriaMetrics... (attempt $$i/5)"; \
		sleep 5; \
	done
	@for i in 1 2 3 4 5; do \
		if kubectl get pods -n monitoring -l app.kubernetes.io/name=vmagent 2>/dev/null | grep -q Running; then \
			echo "VMAgent pod is running"; \
			break; \
		fi; \
		echo "Waiting for VMAgent... (attempt $$i/5)"; \
		sleep 5; \
	done
	@echo "Deploying Grafana dashboard ConfigMap..."
	@kubectl apply -f helm-charts/grafana-dashboard.yaml || true
	@echo "Waiting for vmoperator to be ready (may take time for image pull)..."
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		if kubectl get pods -n monitoring -l app.kubernetes.io/name=victoria-metrics-operator 2>/dev/null | grep -q Running; then \
			echo "vmoperator pod is running"; \
			break; \
		fi; \
		echo "Waiting for vmoperator... (attempt $$i/10)"; \
		sleep 10; \
	done
	@echo "Waiting for vm-grafana to be ready..."
	@for i in 1 2 3 4 5 6; do \
		if kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana 2>/dev/null | grep -q Running || \
		   kubectl get pods -n monitoring -l app.kubernetes.io/instance=vm -l app.kubernetes.io/name=grafana 2>/dev/null | grep -q Running; then \
			echo "Grafana pod is running"; \
			break; \
		fi; \
		echo "Waiting for Grafana... (attempt $$i/6)"; \
		sleep 10; \
	done
	@echo "Giving components additional time to initialize..."
	@echo "Waiting for monitoring stack to fully stabilize (this may take 2-3 minutes)..."
	@sleep 120
	@echo "Monitoring stack deployed successfully"

deploy-app: deploy-monitoring
	@echo "Deploying spam2000 application..."
	@helm upgrade --install spam2000 ./helm-charts/spam2000 \
		-n default \
		--create-namespace || true
	@echo "Waiting for spam2000 pods to be ready..."
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		if kubectl get pods -l app.kubernetes.io/name=spam2000 -n default 2>/dev/null | grep -q Running; then \
			echo "spam2000 pod is running"; \
			break; \
		fi; \
		echo "Waiting for spam2000 pod... (attempt $$i/10)"; \
		sleep 5; \
	done
	@echo "spam2000 application deployed successfully"

deploy-argocd: deploy-app
	@echo "Deploying ArgoCD..."
	@helm repo add argo https://argoproj.github.io/argo-helm || true
	@helm repo update
	@kubectl create namespace argocd || true
	@echo "Cleaning up any existing ArgoCD installation..."
	@helm uninstall argocd -n argocd 2>/dev/null || true
	@kubectl delete svc argocd-server -n argocd 2>/dev/null || true
	@sleep 3
	@echo "Installing ArgoCD as ClusterIP first..."
	@helm upgrade --install argocd argo/argo-cd \
		-n argocd \
		-f argocd-values.yaml \
		--timeout=600s || true
	@echo "Waiting for ArgoCD server service to be created..."
	@for i in 1 2 3 4 5; do \
		if kubectl get svc argocd-server -n argocd >/dev/null 2>&1; then \
			break; \
		fi; \
		echo "Waiting for service... (attempt $$i/5)"; \
		sleep 2; \
	done
	@echo "Patching ArgoCD server service to use NodePort 30083..."
	@kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"NodePort","ports":[{"name":"http","port":80,"targetPort":8080,"nodePort":30083,"protocol":"TCP"},{"name":"https","port":443,"targetPort":8080,"nodePort":30084,"protocol":"TCP"}]}}' || \
	(echo "Trying alternative patch method..." && \
	kubectl get svc argocd-server -n argocd -o yaml | sed 's/type: ClusterIP/type: NodePort/' | \
	sed '/nodePort:/d' | \
	sed '/- name: http/a\    nodePort: 30083' | \
	sed '/- name: https/a\    nodePort: 30084' | \
	kubectl apply -f -) || \
	echo "Warning: Could not patch service. You may need to manually set NodePort."
	@echo "Waiting for ArgoCD server to be ready..."
	@for i in 1 2 3 4 5 6; do \
		if kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server 2>/dev/null | grep -q Running; then \
			echo "ArgoCD server pod is running"; \
			break; \
		fi; \
		echo "Waiting for ArgoCD server... (attempt $$i/6)"; \
		sleep 10; \
	done
	@echo "Waiting for ArgoCD repo-server to be ready..."
	@for i in 1 2 3 4 5 6 7 8; do \
		if kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server 2>/dev/null | grep -q "Running" && \
		   kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q "true"; then \
			echo "ArgoCD repo-server pod is ready"; \
			break; \
		fi; \
		echo "Waiting for ArgoCD repo-server... (attempt $$i/8)"; \
		sleep 10; \
	done
	@echo "Giving ArgoCD components additional time to initialize..."
	@sleep 15
	@echo "ArgoCD deployed successfully"


configure-argocd-app: deploy-argocd deploy-app
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
	@echo "Triggering hard refresh to ensure sync..."
	@sleep 5
	@kubectl patch application spam2000 -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' 2>/dev/null || true
	@echo ""
	@echo "GitOps Configuration:"
	@echo "  - ArgoCD will monitor: $(ARGOCD_GIT_REPO_URL)"
	@echo "  - Helm chart path: helm-charts/spam2000"
	@echo "  - Changes in Git will be automatically synced to the cluster"
	@echo "  - Modify values.yaml in Git to update application configuration"
	@echo ""
	@echo "Waiting for ArgoCD to sync the application (this may take 1-2 minutes)..."
	@for i in 1 2 3 4 5 6 7 8 9 10 11 12; do \
		SYNC_STATUS=$$(kubectl get application spam2000 -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown"); \
		if [ "$$SYNC_STATUS" = "Synced" ]; then \
			echo "Application synced successfully!"; \
			break; \
		fi; \
		echo "Waiting for sync... (attempt $$i/12, current status: $$SYNC_STATUS)"; \
		sleep 10; \
	done
	@echo "Waiting for spam2000 pods to be ready..."
	@for i in 1 2 3 4 5 6; do \
		if kubectl get pods -l app.kubernetes.io/name=spam2000 2>/dev/null | grep -q Running; then \
			echo "spam2000 pod is running"; \
			break; \
		fi; \
		echo "Waiting for spam2000 pod... (attempt $$i/6)"; \
		sleep 10; \
	done
	@echo ""
	@echo "To check application status:"
	@echo "  kubectl get application spam2000 -n argocd"
	@echo "  kubectl describe application spam2000 -n argocd"

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
	if kubectl get namespace argocd >/dev/null 2>&1 && kubectl get svc argocd-server -n argocd >/dev/null 2>&1; then \
		echo "ArgoCD UI: http://$$MINIKUBE_IP:30083"; \
	fi
	@echo ""; \
	echo "Grafana credentials:"; \
	echo "  Username: admin"; \
	if [ -f .grafana-password ]; then \
		GRAFANA_PASSWORD=$$(cat .grafana-password); \
		echo "  Password: $$GRAFANA_PASSWORD"; \
	else \
		echo "  Password: (not generated yet, check Grafana secret)"; \
	fi; \
	if kubectl get namespace argocd >/dev/null 2>&1 && kubectl get secret argocd-initial-admin-secret -n argocd >/dev/null 2>&1; then \
		echo ""; \
		echo "ArgoCD credentials:"; \
		echo "  Username: admin"; \
		ARGOCD_PASSWORD=$$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "Password not available yet"); \
		echo "  Password: $$ARGOCD_PASSWORD"; \
	fi
	@echo "=========================================="

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
		if kubectl get application spam2000 -n argocd >/dev/null 2>&1; then \
			echo ""; \
			echo "spam2000 Application Status:"; \
			kubectl get application spam2000 -n argocd -o wide; \
		fi; \
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

clean:
	@echo "Cleaning up deployments..."
	@helm uninstall spam2000 -n default || true
	@helm uninstall vm -n monitoring || true
	@helm uninstall argocd -n argocd || true
	@kubectl delete -f helm-charts/grafana-dashboard.yaml 2>/dev/null || true
	@kubectl delete application spam2000 -n argocd 2>/dev/null || true
	@kubectl delete namespace monitoring || true
	@kubectl delete namespace argocd || true
	@rm -f .grafana-password
	@echo "Cleanup complete. Run 'minikube stop' to stop Minikube if needed."

help:
	@echo "Available targets:"
	@echo "  all                  - Complete deployment including ArgoCD and GitOps (default)"
	@echo "  start-minikube       - Start Minikube cluster"
	@echo "  install-crds         - Install ServiceMonitor CRD"
	@echo "  deploy-monitoring    - Deploy VictoriaMetrics and Grafana"
	@echo "  deploy-argocd        - Deploy ArgoCD GitOps controller"
	@echo "  deploy-app           - Deploy spam2000 application using Helm"
	@echo "  configure-argocd-app - Configure ArgoCD Application for spam2000"
	@echo "  get-urls             - Display access URLs and credentials for all services"
	@echo "  status               - Show deployment status"
	@echo "  clean                - Remove all deployments"
	@echo "  help                 - Show this help message"
	@echo ""
	@echo "Usage:"
	@echo "  make                    - Deploy everything (recommended)"
	@echo "  make ARGOCD_GIT_REPO_URL=<your-repo-url>  - Deploy with custom Git repo"
	@echo ""
	@echo "Note: spam2000 application is managed via GitOps through ArgoCD"

