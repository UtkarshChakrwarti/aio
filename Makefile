.PHONY: help dev-up dev-down status save-images clean \
       argocd-ui airflow-ui prometheus-ui grafana-ui logs

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

dev-up: ## Start the full AIO environment (only Docker required)
	@echo "Starting AIO GitOps POC environment..."
	@bash scripts/dev-up.sh

dev-down: ## Tear down the environment completely
	@echo "Tearing down AIO environment..."
	@bash scripts/dev-down.sh

status: ## Show cluster component health
	@bash scripts/status.sh

save-images: ## (Maintainer) Pull all images and save to images/*.tar for Git LFS
	@bash scripts/save-images.sh

logs: ## Tail logs from all components
	@echo "=== Argo CD ===" && kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=20 2>/dev/null || true
	@echo "=== MySQL ===" && kubectl logs -n mysql pod/dev-mysql-0 --tail=20 2>/dev/null || true
	@echo "=== Airflow Scheduler ===" && kubectl logs -n airflow-core -l app=airflow-scheduler --tail=20 2>/dev/null || true
	@echo "=== Airflow Webserver ===" && kubectl logs -n airflow-core -l app=airflow-webserver --tail=20 2>/dev/null || true

argocd-ui: ## Open Argo CD UI in browser
	@open https://localhost:8080 2>/dev/null || xdg-open https://localhost:8080 2>/dev/null || echo "Visit: https://localhost:8080"

airflow-ui: ## Open Airflow UI in browser
	@open http://localhost:8090 2>/dev/null || xdg-open http://localhost:8090 2>/dev/null || echo "Visit: http://localhost:8090"

prometheus-ui: ## Open Prometheus UI in browser
	@open http://localhost:9090 2>/dev/null || xdg-open http://localhost:9090 2>/dev/null || echo "Visit: http://localhost:9090"

grafana-ui: ## Open Grafana UI in browser
	@open http://localhost:3000 2>/dev/null || xdg-open http://localhost:3000 2>/dev/null || echo "Visit: http://localhost:3000"

clean: ## Remove generated credential files
	@rm -f .mysql-credentials.txt .airflow-credentials.txt .argocd-credentials.txt
	@echo "Credential files removed"
