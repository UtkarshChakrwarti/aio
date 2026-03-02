#!/bin/bash

# Teardown should never abort halfway — clean up as much as possible.
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CLUSTER_NAME="gitops-poc"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT_FORWARD_RUNTIME_DIR="${REPO_ROOT}/.runtime/port-forward"

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

main() {
    log_info "Tearing down AIO GitOps POC environment..."

    # ── Stop screen sessions ────────────────────────────────────────────────
    if command -v screen >/dev/null 2>&1; then
        log_info "Stopping detached port-forward screen sessions..."
        screen -ls 2>/dev/null | grep -oE 'gitops-pf-[^ ]+' | while read -r session; do
            screen -S "$session" -X quit >/dev/null 2>&1 || true
        done
    fi

    # ── Kill kubectl port-forwards ──────────────────────────────────────────
    log_info "Stopping port-forwards..."
    pkill -f "kubectl port-forward" 2>/dev/null && log_success "Port-forwards stopped" || \
        log_warning "No kubectl port-forwards running"

    # ── Delete kind cluster ─────────────────────────────────────────────────
    if command -v kind &>/dev/null || [ -x "${REPO_ROOT}/.bin/kind" ]; then
        export PATH="${REPO_ROOT}/.bin:${PATH}"
        log_info "Deleting kind cluster: ${CLUSTER_NAME}"
        if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
            if kind delete cluster --name "$CLUSTER_NAME"; then
                log_success "Kind cluster deleted"
            else
                log_error "Failed to delete cluster via kind — force-removing Docker containers"
                docker ps -a --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" -q 2>/dev/null | \
                    xargs -r docker rm -f 2>/dev/null || true
                log_warning "Force-removed Docker containers for cluster ${CLUSTER_NAME}"
            fi
        else
            log_warning "Kind cluster '${CLUSTER_NAME}' not found"
        fi

        # Clean orphaned Docker network if no kind clusters remain
        if [ -z "$(kind get clusters 2>/dev/null)" ]; then
            docker network rm kind 2>/dev/null && log_info "Removed orphaned 'kind' Docker network" || true
        fi
    else
        log_warning "kind not found — cannot delete cluster. Run: docker rm -f \$(docker ps -aq --filter label=io.x-k8s.kind.cluster=${CLUSTER_NAME})"
    fi

    # ── Remove kubectl config leftovers ─────────────────────────────────────
    log_info "Cleaning kubectl config entries..."
    kubectl config delete-context "kind-${CLUSTER_NAME}" 2>/dev/null || true
    kubectl config delete-cluster "kind-${CLUSTER_NAME}" 2>/dev/null || true
    kubectl config unset "users.kind-${CLUSTER_NAME}" 2>/dev/null || true

    # ── Clean up credential and temp files ──────────────────────────────────
    log_info "Cleaning up credential and temp files..."
    rm -f "$REPO_ROOT/.mysql-credentials.txt" \
          "$REPO_ROOT/.airflow-credentials.txt" \
          "$REPO_ROOT/.argocd-credentials.txt"
    rm -rf "$REPO_ROOT/.runtime"
    log_success "Cleanup complete"

    log_success "Environment fully torn down"
}

main "$@"
