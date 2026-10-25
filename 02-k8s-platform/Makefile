# Local Kubernetes platform: kind + Calico + ingress-nginx + metrics-server + Prometheus/Grafana
# + Kyverno + Argo CD, then pulse-api on top. Requires: docker, kind, kubectl, helm.
SHELL   := /bin/bash
CLUSTER := cloudlab
NS      := pulse
VERSION ?= 0.1.0
IMAGE   := pulse-api:$(VERSION)

.PHONY: help
help: ## Show targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: test
test: ## Unit tests with the race detector
	cd app && go test -race -count=1 ./...

.PHONY: lint
lint: ## helm lint + render and schema-validate every manifest
	helm lint charts/pulse-api
	helm template t charts/pulse-api --set image.tag=$(VERSION) | kubeconform -strict -summary -
	helm template t charts/pulse-api -f charts/pulse-api/values-prod.yaml --set image.tag=$(VERSION) \
	  | kubeconform -strict -summary -ignore-missing-schemas -

.PHONY: cluster
cluster: ## Create the 4-node kind cluster with Calico (NetworkPolicy enforcement)
	kind create cluster --config cluster/kind.yaml
	kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml
	kubectl -n kube-system rollout status ds/calico-node --timeout=5m

.PHONY: platform
platform: ## Install ingress, metrics-server, monitoring, Kyverno, Argo CD
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
	helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo add kyverno https://kyverno.github.io/kyverno
	helm repo add argo https://argoproj.github.io/argo-helm
	helm repo update
	helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
	  -n monitoring --create-namespace -f platform/kube-prometheus-stack.values.yaml --wait --timeout 10m
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
	  -n ingress-nginx --create-namespace -f platform/ingress-nginx.values.yaml --wait
	helm upgrade --install metrics-server metrics-server/metrics-server \
	  -n kube-system --set args={--kubelet-insecure-tls} --wait
	helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --wait
	helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --wait
	kubectl apply -f policies/kyverno-baseline.yaml

.PHONY: image
image: ## Build the image and load it into kind (no registry needed)
	docker build -t $(IMAGE) --build-arg VERSION=$(VERSION) app
	kind load docker-image $(IMAGE) --name $(CLUSTER)

.PHONY: deploy
deploy: ## helm upgrade --install pulse-api (from the locally loaded image)
	kubectl create namespace $(NS) --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n $(NS) create secret generic pulse-admin --from-literal=ADMIN_TOKEN=$${ADMIN_TOKEN:-local-chaos-token} \
	  --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install pulse-api charts/pulse-api -n $(NS) \
	  --set image.repository=pulse-api --set image.tag=$(VERSION) --set image.pullPolicy=Never \
	  --set adminTokenSecret=pulse-admin --set serviceMonitor.enabled=true --wait
	kubectl apply -f platform/pulse-alerts.yaml

.PHONY: gitops
gitops: ## Hand pulse-api over to Argo CD (after pushing your image to GHCR)
	kubectl apply -n argocd -f platform/argocd-app.yaml
	@echo "Argo CD admin password:"; kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

.PHONY: load
load: ## 3 minutes of CPU-heavy load from inside the cluster — watch the HPA react
	kubectl -n $(NS) run loadgen --rm -i --restart=Never --image=williamyeh/hey:latest -- \
	  -z 3m -c 40 "http://pulse-api.$(NS).svc/api/v1/work?ms=100"

.PHONY: chaos
chaos: ## Inject 20% errors + 300ms latency (ERROR_RATE=… LATENCY_MS=… to override)
	kubectl -n $(NS) port-forward svc/pulse-api 18080:80 >/dev/null & PF=$$!; sleep 2; \
	curl -s -XPUT localhost:18080/admin/chaos -H "Authorization: Bearer $${ADMIN_TOKEN:-local-chaos-token}" \
	  -d "{\"error_rate\":$${ERROR_RATE:-0.2},\"latency_ms\":$${LATENCY_MS:-300}}"; echo; kill $$PF

.PHONY: drill-zone
drill-zone: ## Simulate losing zone-a: cordon + drain its node, watch PDB + spread keep you up
	NODE=$$(kubectl get nodes -l topology.kubernetes.io/zone=zone-a -o name); \
	kubectl cordon $$NODE && kubectl drain $$NODE --ignore-daemonsets --delete-emptydir-data --timeout=2m; \
	kubectl -n $(NS) get pods -o wide

.PHONY: undrill
undrill: ## Bring zone-a back
	kubectl uncordon $$(kubectl get nodes -l topology.kubernetes.io/zone=zone-a -o name)

.PHONY: down
down: ## Delete the cluster
	kind delete cluster --name $(CLUSTER)
