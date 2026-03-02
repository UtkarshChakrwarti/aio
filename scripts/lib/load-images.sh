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

_get_image_ref_from_tar() {
    # Extract the full image reference (e.g. "apache/airflow:3.0.0-python3.12")
    # from the Docker-format manifest.json embedded in the tar.
    tar xf "$1" --to-stdout manifest.json 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['RepoTags'][0])" 2>/dev/null
}

_get_kind_nodes() {
    kind get nodes --name "$CLUSTER_NAME" 2>/dev/null
}

_load_tar_into_node() {
    local tar_file="$1"
    local node="$2"
    local base_name="$3"
    local platform="$4"

    cat "$tar_file" \
        | docker exec -i "$node" \
            ctr --namespace=k8s.io images import \
                --digests \
                --snapshotter=overlayfs \
                --base-name "$base_name" \
                --platform "$platform" \
                - >/dev/null 2>&1
}

load_all_images() {
    log_info "Loading container images into Kind cluster '${CLUSTER_NAME}'..."

    if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        log_error "Kind cluster '${CLUSTER_NAME}' does not exist"
        return 1
    fi

    # Detect host platform for ctr import (Kind nodes match host arch)
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
    esac
    local platform="linux/${arch}"

    local nodes=()
    while IFS= read -r node; do
        [ -n "$node" ] && nodes+=("$node")
    done < <(_get_kind_nodes)

    if [ "${#nodes[@]}" -eq 0 ]; then
        log_error "No Kind nodes found for cluster '${CLUSTER_NAME}'"
        return 1
    fi

    local loaded=0 skipped=0 failed=0

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

        # Extract image ref and derive base-name (ref without :tag)
        local image_ref base_name
        image_ref="$(_get_image_ref_from_tar "$tar_file")"
        if [ -z "$image_ref" ]; then
            log_error "  ${name} — cannot read image ref from tar"
            ((failed++)) || true
            continue
        fi
        base_name="${image_ref%%:*}"

        # Load into every Kind node via ctr import (handles OCI + Docker tars)
        local node_ok=true
        for node in "${nodes[@]}"; do
            if ! _load_tar_into_node "$tar_file" "$node" "$base_name" "$platform"; then
                log_error "  ${name} — failed to load into node ${node}"
                node_ok=false
                break
            fi
        done

        if $node_ok; then
            log_success "  ${name} loaded (${image_ref})"
            ((loaded++)) || true
        else
            ((failed++)) || true
        fi
    done

    if [ "$failed" -gt 0 ] || [ "$skipped" -gt 0 ]; then
        log_warning "${loaded} images loaded, ${skipped} skipped, ${failed} failed"
        [ "$failed" -gt 0 ] && return 1
    else
        log_success "All ${loaded} images loaded from local tars"
    fi
}
