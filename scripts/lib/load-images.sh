#!/bin/bash
# Load all container image tars from images/ into the Kind cluster.

IMAGES_DIR="${REPO_ROOT}/images"

_is_lfs_pointer() {
    local file="$1"
    # LFS pointer files are tiny text files (~130 bytes)
    [ "$(wc -c < "$file" | tr -d ' ')" -lt 1000 ]
}

load_kindest_node_image() {
    local tar_file="${IMAGES_DIR}/kindest-node-${KIND_NODE_VERSION}.tar"

    if docker image inspect "kindest/node:${KIND_NODE_VERSION}" &>/dev/null; then
        log_info "kindest/node:${KIND_NODE_VERSION} already in Docker cache"
        return 0
    fi

    if [ ! -f "$tar_file" ]; then
        log_warning "kindest/node tar not found — Kind will pull it (needs internet)"
        return 0
    fi

    if _is_lfs_pointer "$tar_file"; then
        log_warning "kindest/node tar is an LFS pointer — run 'git lfs pull' first, or Kind will pull it"
        return 0
    fi

    log_info "Loading kindest/node:${KIND_NODE_VERSION} from local tar..."
    docker load -i "$tar_file" >/dev/null 2>&1
    log_success "kindest/node:${KIND_NODE_VERSION} loaded into Docker"
}

load_all_images() {
    log_info "Loading container images into Kind cluster '${CLUSTER_NAME}'..."

    if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        log_error "Kind cluster '${CLUSTER_NAME}' does not exist"
        return 1
    fi

    local loaded=0 skipped=0

    for tar_file in "${IMAGES_DIR}"/*.tar; do
        [ -f "$tar_file" ] || continue
        local name
        name="$(basename "$tar_file" .tar)"

        # Skip kindest-node (loaded into Docker daemon, not Kind cluster)
        [[ "$name" == kindest-node-* ]] && continue

        if _is_lfs_pointer "$tar_file"; then
            log_warning "  ${name} — LFS pointer, skipping (run 'git lfs pull')"
            ((skipped++)) || true
            continue
        fi

        if kind load image-archive "$tar_file" --name "$CLUSTER_NAME" >/dev/null 2>&1; then
            log_success "  ${name} loaded"
            ((loaded++)) || true
        else
            log_warning "  ${name} — failed to load (cluster will pull from registry)"
            ((skipped++)) || true
        fi
    done

    if [ "$skipped" -gt 0 ]; then
        log_warning "${loaded} images loaded, ${skipped} skipped (will pull from registry if needed)"
    else
        log_success "All ${loaded} images loaded from local tars"
    fi
}
