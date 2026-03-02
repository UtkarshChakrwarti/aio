#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="gitops-poc"
ARGOCD_NAMESPACE="argocd"
MYSQL_NAMESPACE="mysql"
AIRFLOW_CORE_NAMESPACE="airflow-core"
AIRFLOW_USER_NAMESPACE="airflow-user"
MONITORING_NAMESPACE="airflow-core"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT_FORWARD_RUNTIME_DIR="${SCRIPT_DIR}/.runtime/port-forward"

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_section() {
    echo -e "${CYAN}========== $1 ==========${NC}"
}

check_status() {
    local label=$1
    local namespace=$2
    local resource_type=$3
    local resource_name=$4

    if kubectl get "$resource_type" -n "$namespace" "$resource_name" &> /dev/null; then
        if [ "$resource_type" = "deployment" ] || [ "$resource_type" = "statefulset" ]; then
            local desired
            local ready
            desired=$(kubectl get "$resource_type" -n "$namespace" "$resource_name" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
            ready=$(kubectl get "$resource_type" -n "$namespace" "$resource_name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            desired=${desired:-0}
            ready=${ready:-0}

            if [ "$desired" -gt 0 ] && [ "$ready" = "$desired" ]; then
                echo -e "${GREEN}✓${NC} $label: Ready (${ready}/${desired})"
            elif [ "$ready" -gt 0 ]; then
                echo -e "${YELLOW}?${NC} $label: Partially Ready (${ready}/${desired})"
            else
                echo -e "${RED}✗${NC} $label: Not Ready (${ready}/${desired})"
            fi
            return
        fi

        local ready_cond
        ready_cond=$(kubectl get "$resource_type" -n "$namespace" "$resource_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [ "$ready_cond" = "True" ]; then
            echo -e "${GREEN}✓${NC} $label: Ready"
        elif [ "$ready_cond" = "False" ]; then
            echo -e "${RED}✗${NC} $label: Not Ready"
        else
            echo -e "${YELLOW}?${NC} $label: Unknown"
        fi
    else
        echo -e "${RED}✗${NC} $label: Not Found"
    fi
}

check_http_port_forward() {
    local label="$1"
    local port="$2"
    local url="$3"
    local insecure="${4:-false}"
    local listener
    local http_code

    listener="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 && /kubectl/ {print $2; exit}')"
    if [ -z "${listener:-}" ]; then
        echo -e "${RED}✗${NC} $label: No local listener on :$port"
        return
    fi

    if [ "$insecure" = "true" ]; then
        http_code="$(curl -k -sS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")"
    else
        http_code="$(curl -sS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")"
    fi

    if [ "$http_code" = "000" ]; then
        echo -e "${YELLOW}?${NC} $label: Listener PID ${listener} on :$port, endpoint probe failed"
    else
        echo -e "${GREEN}✓${NC} $label: Listener PID ${listener} on :$port (HTTP ${http_code})"
    fi
}

check_tcp_port_forward() {
    local label="$1"
    local port="$2"
    local listener

    listener="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 && /kubectl/ {print $2; exit}')"
    if [ -n "${listener:-}" ]; then
        echo -e "${GREEN}✓${NC} $label: Listener PID ${listener} on :$port"
    else
        echo -e "${RED}✗${NC} $label: No local listener on :$port"
    fi
}

check_port_forward_runtime_files() {
    if [ ! -d "$PORT_FORWARD_RUNTIME_DIR" ]; then
        return
    fi

    local stale=0
    local pid_file
    for pid_file in "$PORT_FORWARD_RUNTIME_DIR"/*.pid; do
        [ -e "$pid_file" ] || continue
        local pid
        pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [ -z "${pid:-}" ] || ! kill -0 "$pid" 2>/dev/null; then
            stale=$((stale + 1))
        fi
    done

    if [ "$stale" -gt 0 ]; then
        echo -e "${YELLOW}?${NC} Runtime notes: ${stale} stale port-forward PID file(s) detected under $PORT_FORWARD_RUNTIME_DIR"
    fi
}

# Main function
main() {
    # Check if cluster exists
    if ! kind get clusters | grep -q "^$CLUSTER_NAME$"; then
        log_info "Kind cluster '$CLUSTER_NAME' is not running"
        exit 1
    fi

    log_info "Cluster: $CLUSTER_NAME (running)"
    echo ""

    # Argo CD status
    log_section "Argo CD (namespace: $ARGOCD_NAMESPACE)"
    check_status "Server" "$ARGOCD_NAMESPACE" "deployment" "argocd-server"
    check_status "Controller" "$ARGOCD_NAMESPACE" "statefulset" "argocd-application-controller"
    check_status "Repo Server" "$ARGOCD_NAMESPACE" "deployment" "argocd-repo-server"

    # Get application status
    log_info "Applications:"
    kubectl get applications -n "$ARGOCD_NAMESPACE" -o wide || echo "No applications found"
    echo ""

    # MySQL status
    log_section "MySQL (namespace: $MYSQL_NAMESPACE)"
    check_status "MySQL StatefulSet" "$MYSQL_NAMESPACE" "statefulset" "dev-mysql"

    # Show MySQL pod status
    log_info "MySQL Pods:"
    kubectl get pods -n "$MYSQL_NAMESPACE" -o wide || echo "No pods found"
    echo ""

    # Airflow Control Plane status
    log_section "Airflow Control Plane (namespace: $AIRFLOW_CORE_NAMESPACE)"
    check_status "Webserver" "$AIRFLOW_CORE_NAMESPACE" "deployment" "airflow-webserver"
    check_status "Scheduler" "$AIRFLOW_CORE_NAMESPACE" "deployment" "airflow-scheduler"
    check_status "Triggerer" "$AIRFLOW_CORE_NAMESPACE" "deployment" "airflow-triggerer"
    check_status "DAG Processor" "$AIRFLOW_CORE_NAMESPACE" "deployment" "airflow-dag-processor"
    check_status "DAG Sync" "$AIRFLOW_CORE_NAMESPACE" "deployment" "airflow-dag-sync"

    log_info "Airflow Core Pods:"
    kubectl get pods -n "$AIRFLOW_CORE_NAMESPACE" -o wide || echo "No pods found"
    echo ""

    # Airflow User namespace (task pods)
    log_section "Airflow Task Pods (namespace: $AIRFLOW_USER_NAMESPACE)"
    log_info "Task Pods:"
    kubectl get pods -n "$AIRFLOW_USER_NAMESPACE" -o wide 2>/dev/null || echo "No task pods running"
    log_info "Task pods are retained (DELETE_WORKER_PODS=False) so Airflow UI log links remain available."
    echo ""

    # Airflow DAG state
    log_section "Airflow Demo DAGs"
    local demo_dags=(
        "example_user_namespace"
        "example_core_namespace"
    )
    for dag in "${demo_dags[@]}"; do
        echo -e "${CYAN}${dag}${NC}"
        local dag_runs
        local latest_run
        local latest_state
        dag_runs="$(kubectl -n "$AIRFLOW_CORE_NAMESPACE" exec deploy/airflow-scheduler -- \
            airflow dags list-runs "$dag" --no-backfill -o plain 2>/dev/null || true)"
        latest_run="$(echo "$dag_runs" | awk 'NR==2 {print $2}')"
        latest_state="$(echo "$dag_runs" | awk 'NR==2 {print $3}')"

        if [ -n "${latest_run:-}" ] && [ -n "${latest_state:-}" ]; then
            echo "  Latest run: $latest_run (state=$latest_state)"
        else
            echo "  Could not read DAG runs"
        fi
        echo ""
    done
    echo ""

    # Monitoring status
    log_section "Monitoring Stack (namespace: $MONITORING_NAMESPACE)"
    check_status "Kube State Metrics" "$MONITORING_NAMESPACE" "deployment" "kube-state-metrics"
    check_status "Prometheus" "$MONITORING_NAMESPACE" "deployment" "prometheus"
    check_status "Grafana" "$MONITORING_NAMESPACE" "deployment" "grafana"
    log_info "Monitoring Pods:"
    kubectl get pods -n "$MONITORING_NAMESPACE" -o wide 2>/dev/null || echo "Monitoring deployment not ready yet"
    log_info "Monitoring Services:"
    kubectl get svc -n "$MONITORING_NAMESPACE" kube-state-metrics prometheus grafana 2>/dev/null || true
    echo ""

    # Local port-forward status
    log_section "Local Port Forwards"
    if command -v lsof >/dev/null 2>&1; then
        check_http_port_forward "Argo CD UI" "8080" "https://localhost:8080" "true"
        check_http_port_forward "Airflow UI" "8090" "http://localhost:8090"
        check_tcp_port_forward "MySQL TCP" "3306"
        check_http_port_forward "Prometheus UI" "9090" "http://localhost:9090/-/healthy"
        check_http_port_forward "Grafana UI" "3000" "http://localhost:3000/api/health"
        check_port_forward_runtime_files
    else
        log_info "lsof not found; skipping local listener checks"
    fi
    echo ""

    # Node status
    log_section "Cluster Nodes"
    kubectl get nodes -L workload,airflow-node-pool -o wide || echo "No nodes found"
    log_info "Node taints:"
    kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints --no-headers 2>/dev/null || true
    echo ""

    # Ingress status
    log_section "Ingress (if configured)"
    kubectl get ingress -A || echo "No ingresses found"
}

main "$@"
