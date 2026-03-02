#!/bin/bash
# Auto-install kind, kubectl, argocd to .bin/ if not on PATH.
# Detects OS and architecture automatically.

KIND_VERSION="v0.27.0"
KUBECTL_VERSION="v1.35.0"
ARGOCD_VERSION="v3.3.2"

detect_platform() {
    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"

    case "$arch" in
        x86_64)        arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)
            log_error "Unsupported architecture: $arch"
            return 1
            ;;
    esac

    echo "${os}/${arch}"
}

_tool_url() {
    local tool="$1" os="$2" arch="$3"
    case "$tool" in
        kind)
            echo "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-${os}-${arch}"
            ;;
        kubectl)
            echo "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${os}/${arch}/kubectl"
            ;;
        argocd)
            echo "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-${os}-${arch}"
            ;;
    esac
}

bootstrap_tools() {
    local bin_dir="${REPO_ROOT}/.bin"
    mkdir -p "$bin_dir"
    export PATH="${bin_dir}:${PATH}"

    local platform
    platform="$(detect_platform)" || return 1
    local os="${platform%%/*}"
    local arch="${platform##*/}"

    for tool in kind kubectl argocd; do
        if command -v "$tool" &>/dev/null; then
            continue
        fi

        local dest="${bin_dir}/${tool}"
        if [ -x "$dest" ]; then
            continue
        fi

        local url
        url="$(_tool_url "$tool" "$os" "$arch")"
        log_info "Downloading ${tool} (${os}/${arch})..."
        if curl -fsSL "$url" -o "$dest"; then
            chmod +x "$dest"
            log_success "${tool} installed to .bin/"
        else
            log_error "Failed to download ${tool} from ${url}"
            return 1
        fi
    done

    log_success "All tools ready (kind, kubectl, argocd)"
}
