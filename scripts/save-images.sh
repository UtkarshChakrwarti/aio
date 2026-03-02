#!/bin/bash
# Maintainer script: pull all container images and save as tars for Git LFS.
# Run this once, then: git add images/*.tar && git commit && git push

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGES_DIR="${SCRIPT_DIR}/images"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# Single source of truth for all images to bundle
declare -a IMAGE_LIST=(
    # tar-name|full-image-reference
    "kindest-node-v1.35.0|kindest/node:v1.35.0"
    "airflow-3.0.0-python3.12|apache/airflow:3.0.0-python3.12"
    "git-sync-v4.2.3|registry.k8s.io/git-sync/git-sync:v4.2.3"
    "mysql-8.0|mysql:8.0"
    "kube-state-metrics-v2.13.0|registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0"
    "prometheus-v2.53.0|prom/prometheus:v2.53.0"
    "grafana-11.1.4|grafana/grafana:11.1.4"
    "argocd-v3.3.2|quay.io/argoproj/argocd:v3.3.2"
    "dex-v2.43.0|ghcr.io/dexidp/dex:v2.43.0"
    "redis-8.2.3-alpine|public.ecr.aws/docker/library/redis:8.2.3-alpine"
    "ingress-nginx-controller-v1.14.3|registry.k8s.io/ingress-nginx/controller:v1.14.3"
    "ingress-nginx-certgen-v1.6.7|registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.7"
)

main() {
    if ! docker info &>/dev/null; then
        log_error "Docker daemon is not running"
        exit 1
    fi

    mkdir -p "$IMAGES_DIR"
    local total="${#IMAGE_LIST[@]}"
    local count=0

    for entry in "${IMAGE_LIST[@]}"; do
        local tar_name="${entry%%|*}"
        local image="${entry##*|}"
        local tar_file="${IMAGES_DIR}/${tar_name}.tar"
        ((count++)) || true

        echo ""
        log_info "[${count}/${total}] ${image}"

        if [ -f "$tar_file" ] && [ "$(wc -c < "$tar_file" | tr -d ' ')" -gt 1000 ]; then
            log_info "  Already saved: ${tar_name}.tar ($(du -sh "$tar_file" | cut -f1))"
            continue
        fi

        # Skip pull if image already in local Docker cache
        if docker image inspect "$image" &>/dev/null; then
            log_info "  Already in Docker cache, skipping pull"
        else
            log_info "  Pulling..."
            if ! docker pull "$image"; then
                log_error "  Failed to pull ${image}"
                continue
            fi
        fi

        log_info "  Saving to ${tar_name}.tar..."
        docker save "$image" -o "$tar_file"
        log_success "  Saved: ${tar_name}.tar ($(du -sh "$tar_file" | cut -f1))"
    done

    echo ""
    log_success "All images saved to ${IMAGES_DIR}/"
    echo ""
    log_info "Next steps:"
    log_info "  git add images/*.tar"
    log_info "  git commit -m 'chore: bundle container image tars'"
    log_info "  git push"
}

main "$@"
