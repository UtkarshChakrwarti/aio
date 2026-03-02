#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="gitops-poc"
ARGOCD_NAMESPACE="argocd"
MYSQL_NAMESPACE="mysql"
AIRFLOW_CORE_NAMESPACE="airflow-core"
AIRFLOW_USER_NAMESPACE="airflow-user"
MONITORING_NAMESPACE="airflow-core"
KIND_NODE_VERSION="v1.35.0"

# Argo CD apps will sync from this repo's own GitHub remote
# Override with: REPO_URL=https://github.com/you/aio.git make dev-up
REPO_URL="${REPO_URL:-$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "https://github.com/UtkarshChakrwarti/aio.git")}"
DAG_REPO_URL="${DAG_REPO_URL:-https://github.com/UtkarshChakrwarti/remote_airflow.git}"
GIT_REVISION="${GIT_REVISION:-main}"

ARGO_APP_WAIT_TIMEOUT_SEC="${ARGO_APP_WAIT_TIMEOUT_SEC:-900}"
MYSQL_READY_TIMEOUT_SEC="${MYSQL_READY_TIMEOUT_SEC:-600}"
AIRFLOW_READY_TIMEOUT_SEC="${AIRFLOW_READY_TIMEOUT_SEC:-900}"
MONITORING_READY_TIMEOUT_SEC="${MONITORING_READY_TIMEOUT_SEC:-300}"
PORT_FORWARD_RUNTIME_DIR="${REPO_ROOT}/.runtime/port-forward"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Source helper libraries
source "${REPO_ROOT}/scripts/lib/bootstrap-tools.sh"
source "${REPO_ROOT}/scripts/lib/load-images.sh"

# ─── Utility ─────────────────────────────────────────────────────────────────

wait_for_service() {
    local namespace="$1"
    local service="$2"
    local timeout_sec="$3"
    local deadline=$((SECONDS + timeout_sec))
    while true; do
        if kubectl get service "$service" -n "$namespace" &>/dev/null; then
            return 0
        fi
        if [ $SECONDS -ge $deadline ]; then
            log_error "Timed out waiting for service ${service} in namespace ${namespace}"
            return 1
        fi
        sleep 2
    done
}

retry() {
    local max_attempts="${1:-3}"
    local delay="${2:-5}"
    shift 2
    local attempt=1
    while true; do
        if "$@"; then
            return 0
        fi
        if [ "$attempt" -ge "$max_attempts" ]; then
            log_error "Command failed after ${max_attempts} attempts: $*"
            return 1
        fi
        log_warning "Attempt ${attempt}/${max_attempts} failed, retrying in ${delay}s..."
        sleep "$delay"
        ((attempt++))
    done
}

ensure_argocd_healthy() {
    log_info "Ensuring Argo CD core components are healthy..."

    # Phase 1: Wait for any in-progress rollouts to settle
    log_info "Waiting for Argo CD rollouts to complete..."
    kubectl rollout status deployment/argocd-server -n "$ARGOCD_NAMESPACE" --timeout=180s >/dev/null 2>&1 || true
    kubectl rollout status deployment/argocd-repo-server -n "$ARGOCD_NAMESPACE" --timeout=180s >/dev/null 2>&1 || true
    kubectl rollout status statefulset/argocd-application-controller -n "$ARGOCD_NAMESPACE" --timeout=180s >/dev/null 2>&1 || true

    # Phase 2: Check if components are actually ready; restart only if still broken
    local components=(
        "deployment/argocd-server"
        "deployment/argocd-repo-server"
        "statefulset/argocd-application-controller"
    )
    local recovery_needed=false

    for workload in "${components[@]}"; do
        local ready
        ready="$(kubectl get "$workload" -n "$ARGOCD_NAMESPACE" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
        ready="${ready:-0}"

        if [ "$ready" -eq 0 ]; then
            log_warning "${workload} has 0 ready replicas — force restarting..."
            kubectl rollout restart "$workload" -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1 || true
            recovery_needed=true
        fi
    done

    if $recovery_needed; then
        log_info "Waiting for Argo CD components to recover..."
        kubectl rollout status deployment/argocd-server -n "$ARGOCD_NAMESPACE" --timeout=180s >/dev/null 2>&1 || true
        kubectl rollout status deployment/argocd-repo-server -n "$ARGOCD_NAMESPACE" --timeout=180s >/dev/null 2>&1 || true
        kubectl rollout status statefulset/argocd-application-controller -n "$ARGOCD_NAMESPACE" --timeout=180s >/dev/null 2>&1 || true

        for workload in "${components[@]}"; do
            local ready
            ready="$(kubectl get "$workload" -n "$ARGOCD_NAMESPACE" \
                -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
            ready="${ready:-0}"
            if [ "$ready" -eq 0 ]; then
                log_error "${workload} is still not ready after recovery attempt"
                kubectl get pods -n "$ARGOCD_NAMESPACE" --no-headers || true
                return 1
            fi
        done
        log_success "Argo CD components recovered"
    else
        log_success "All Argo CD components are healthy"
    fi
}

wait_for_argocd_app() {
    local app="$1"
    local timeout_sec="${2:-$ARGO_APP_WAIT_TIMEOUT_SEC}"
    local deadline=$((SECONDS + timeout_sec))
    local repo_server_restarted=false

    log_info "Waiting for Argo CD app '${app}' to be Synced/Healthy..."
    while true; do
        local sync_status health_status operation_phase condition_message

        sync_status="$(kubectl get app "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")"
        health_status="$(kubectl get app "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")"
        operation_phase="$(kubectl get app "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
        condition_message="$(kubectl get app "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.conditions[0].message}' 2>/dev/null || true)"

        if [ "$sync_status" = "Synced" ] && [ "$health_status" = "Healthy" ] && [ "$operation_phase" != "Running" ]; then
            log_success "Argo CD app '${app}' is Synced/Healthy"
            return 0
        fi

        # Detect dead repo-server and restart it (once per wait)
        if [ "$sync_status" = "Unknown" ] && [[ "$condition_message" == *"connection refused"* ]]; then
            if ! $repo_server_restarted; then
                log_warning "Argo CD repo-server appears down — restarting..."
                kubectl rollout restart deployment/argocd-repo-server -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1 || true
                kubectl wait --for=condition=available --timeout=90s \
                    deployment/argocd-repo-server -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1 || true
                repo_server_restarted=true
            fi
            kubectl annotate app -n "$ARGOCD_NAMESPACE" "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
        fi

        if [ $SECONDS -ge $deadline ]; then
            log_error "Timed out waiting for Argo CD app '${app}' (sync=${sync_status}, health=${health_status}, op=${operation_phase})"
            kubectl get app "$app" -n "$ARGOCD_NAMESPACE" -o wide || true
            return 1
        fi
        sleep 5
    done
}

# ─── Port-forward ────────────────────────────────────────────────────────────

start_port_forward() {
    local name="$1"
    local namespace="$2"
    local service="$3"
    local local_port="$4"
    local remote_port="$5"

    mkdir -p "$PORT_FORWARD_RUNTIME_DIR"
    local pid_file="${PORT_FORWARD_RUNTIME_DIR}/${name}.pid"
    local log_file="${PORT_FORWARD_RUNTIME_DIR}/${name}.log"
    local session_file="${PORT_FORWARD_RUNTIME_DIR}/${name}.session"
    local session_name="gitops-pf-${name}"
    local pf_cmd
    pf_cmd="kubectl port-forward -n ${namespace} svc/${service} ${local_port}:${remote_port} --address 0.0.0.0"

    # Clean up old port-forwards
    if [ -f "$pid_file" ]; then
        local old_pid
        old_pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [ -n "${old_pid}" ] && kill -0 "${old_pid}" 2>/dev/null; then
            kill "${old_pid}" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    fi
    if [ -f "$session_file" ]; then
        local old_session
        old_session="$(cat "$session_file" 2>/dev/null || true)"
        if [ -n "${old_session}" ] && command -v screen >/dev/null 2>&1; then
            screen -S "${old_session}" -X quit >/dev/null 2>&1 || true
        fi
        rm -f "$session_file"
    fi

    pkill -f "kubectl port-forward -n ${namespace} svc/${service} ${local_port}:${remote_port}" 2>/dev/null || true
    wait_for_service "$namespace" "$service" 120 || return 1

    : >"$log_file"
    if command -v screen >/dev/null 2>&1; then
        screen -S "$session_name" -X quit >/dev/null 2>&1 || true
        screen -dmS "$session_name" bash -lc "while true; do $pf_cmd >> \"$log_file\" 2>&1; echo \"[WARN] port-forward ${name} exited, retrying in 2s\" >> \"$log_file\"; sleep 2; done"
        echo "$session_name" > "$session_file"
    else
        nohup bash -lc "$pf_cmd" >"$log_file" 2>&1 </dev/null &
        local pf_pid=$!
        echo "$pf_pid" > "$pid_file"
        disown "$pf_pid" 2>/dev/null || true
    fi

    local deadline=$((SECONDS + 20))
    while true; do
        local active_pid
        active_pid="$(lsof -nP -t -iTCP:"$local_port" -sTCP:LISTEN 2>/dev/null | head -n 1 || true)"
        if [ -n "${active_pid}" ]; then
            echo "$active_pid" > "$pid_file"
            return 0
        fi
        if [ $SECONDS -ge $deadline ]; then
            log_error "Failed to keep port-forward alive for ${name} on localhost:${local_port}"
            tail -n 20 "$log_file" 2>/dev/null || true
            return 1
        fi
        sleep 1
    done
}

# ─── Docker check (only prerequisite) ───────────────────────────────────────

check_docker() {
    log_info "Checking Docker daemon..."
    if ! docker info &>/dev/null; then
        log_error "Docker daemon is not running."
        log_error "Start Docker Desktop or run: colima start"
        return 1
    fi
    log_success "Docker daemon is running"
}

check_port_conflicts() {
    log_info "Checking for port conflicts (80, 443)..."
    local has_conflict=false
    for port in 80 443; do
        local pids
        pids="$(lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
        [ -z "$pids" ] && continue

        local pid proc_cmdline
        pid="$(echo "$pids" | head -n1)"
        proc_cmdline="$(ps -p "$pid" -o args= 2>/dev/null || echo "unknown")"

        # If port is held by Colima/Docker/lima SSH tunnels, the cause is
        # leftover containers (e.g. a previous Kind cluster). Clean those up
        # instead of killing the tunnel (which would break Docker).
        if echo "$proc_cmdline" | grep -qiE 'colima|lima|docker'; then
            log_warning "Port ${port} held by Docker/Colima — cleaning up leftover containers..."
            # Remove any old Kind cluster that may still be forwarding ports
            local old_clusters
            old_clusters="$(kind get clusters 2>/dev/null || true)"
            if [ -n "$old_clusters" ]; then
                while IFS= read -r cluster; do
                    [ -n "$cluster" ] || continue
                    log_warning "  Deleting leftover Kind cluster: ${cluster}"
                    kind delete cluster --name "$cluster" 2>/dev/null || true
                done <<< "$old_clusters"
                sleep 2
            fi
            # Also stop any stray Docker containers binding these ports
            local container_id
            container_id="$(docker ps --format '{{.ID}} {{.Ports}}' 2>/dev/null \
                | grep ":${port}->" | awk '{print $1}' || true)"
            if [ -n "$container_id" ]; then
                log_warning "  Stopping container ${container_id} on port ${port}"
                docker stop "$container_id" 2>/dev/null || true
                docker rm -f "$container_id" 2>/dev/null || true
                sleep 1
            fi
        else
            # Non-Docker process — safe to kill
            log_warning "Port ${port} in use by '${proc_cmdline}' (PID ${pid}) — killing to free it"
            echo "$pids" | xargs kill 2>/dev/null || true
            sleep 1
            local remaining
            remaining="$(lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
            if [ -n "$remaining" ]; then
                echo "$remaining" | xargs kill -9 2>/dev/null || true
                sleep 1
            fi
        fi
        has_conflict=true
    done

    if $has_conflict; then
        for port in 80 443; do
            if lsof -nP -t -iTCP:"$port" -sTCP:LISTEN &>/dev/null; then
                log_error "Port ${port} is still in use. Free it manually and retry."
                log_error "  Tip: lsof -iTCP:${port} -sTCP:LISTEN"
                return 1
            fi
        done
        log_success "Freed conflicting ports"
    else
        log_success "Ports 80 and 443 are available"
    fi
}

# ─── Kind cluster ────────────────────────────────────────────────────────────

create_kind_cluster() {
    log_info "Creating kind cluster: $CLUSTER_NAME"
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        log_warning "Kind cluster '${CLUSTER_NAME}' already exists, skipping"
        return 0
    fi

    local kind_config="${REPO_ROOT}/.runtime/kind-config.yaml"
    mkdir -p "$(dirname "$kind_config")"
    cat > "$kind_config" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
    labels:
      ingress-ready: "true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
  - role: worker
  - role: worker
EOF
    kind create cluster --config "$kind_config" --image "kindest/node:${KIND_NODE_VERSION}" || {
        log_error "Failed to create cluster"
        return 1
    }
    kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null 2>&1
    log_success "Kind cluster created"
}

# ─── Node Pools / Taints ────────────────────────────────────────────────────

configure_node_pools() {
    log_info "Configuring node pools for Airflow (core/user)..."

    workers=()
    while IFS= read -r node; do
        workers+=("$node")
    done < <(kubectl get nodes -o name | sed 's|node/||' | grep 'worker' | sort)

    if [ "${#workers[@]}" -eq 0 ]; then
        log_error "No worker nodes found to label/taint"
        return 1
    fi

    local core_node="${workers[0]}"
    kubectl label node "$core_node" airflow-node-pool=core workload=airflow-core --overwrite >/dev/null

    if [ "${#workers[@]}" -ge 2 ]; then
        local user_node="${workers[1]}"
        kubectl label node "$user_node" airflow-node-pool=user workload=airflow-user --overwrite >/dev/null

        kubectl taint node "$core_node" dedicated- >/dev/null 2>&1 || true
        kubectl taint node "$user_node" dedicated- >/dev/null 2>&1 || true

        kubectl taint node "$core_node" dedicated=airflow-core:NoSchedule --overwrite >/dev/null
        kubectl taint node "$user_node" dedicated=airflow-user:NoSchedule --overwrite >/dev/null
        log_success "Node pool configured: core=${core_node}, user=${user_node}"
    else
        log_warning "Only one worker node found; cannot enforce separate user node pool"
    fi
}

patch_platform_workloads_for_core_taint() {
    log_info "Patching platform workloads to tolerate dedicated=airflow-core taint..."
    local ns
    for ns in "$ARGOCD_NAMESPACE" ingress-nginx; do
        if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
            continue
        fi

        while IFS= read -r workload; do
            [ -n "${workload:-}" ] || continue
            kubectl -n "$ns" patch "$workload" --type merge \
                -p '{"spec":{"template":{"spec":{"nodeSelector":{"workload":"airflow-core"},"tolerations":[{"key":"dedicated","operator":"Equal","value":"airflow-core","effect":"NoSchedule"}]}}}}' \
                >/dev/null 2>&1 || true
        done < <(kubectl -n "$ns" get deployment,statefulset -o name 2>/dev/null || true)
    done

    # Wait for patched workloads to finish rolling out
    log_info "Waiting for patched workloads to stabilize..."
    kubectl rollout status deployment/argocd-server -n "$ARGOCD_NAMESPACE" --timeout=180s >/dev/null 2>&1 || true
    kubectl rollout status deployment/argocd-repo-server -n "$ARGOCD_NAMESPACE" --timeout=180s >/dev/null 2>&1 || true
    kubectl rollout status statefulset/argocd-application-controller -n "$ARGOCD_NAMESPACE" --timeout=180s >/dev/null 2>&1 || true

    log_success "Platform workload patch complete"
}

# ─── Ingress NGINX (from local manifest) ────────────────────────────────────

install_ingress_nginx() {
    if kubectl get ns ingress-nginx &>/dev/null; then
        log_warning "ingress-nginx already installed, skipping"
        return 0
    fi
    log_info "Installing ingress-nginx from local manifest..."
    kubectl apply -f "${REPO_ROOT}/manifests/ingress-nginx-kind.yaml" || {
        log_error "Failed to install ingress-nginx"; return 1
    }
    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=300s 2>/dev/null || log_warning "Timeout on ingress-nginx, continuing..."
    log_success "ingress-nginx installed"
}

# ─── Argo CD (from local manifest) ─────────────────────────────────────────

install_argocd() {
    if kubectl get ns "$ARGOCD_NAMESPACE" &>/dev/null && \
       kubectl get deployment argocd-server -n "$ARGOCD_NAMESPACE" &>/dev/null; then
        log_warning "Argo CD already installed, skipping"
        return 0
    fi
    log_info "Installing Argo CD from local manifest..."
    kubectl create namespace "$ARGOCD_NAMESPACE" 2>/dev/null || true
    kubectl apply -n "$ARGOCD_NAMESPACE" \
        --server-side --force-conflicts \
        -f "${REPO_ROOT}/manifests/argocd-install.yaml" || {
        log_error "Failed to install Argo CD"; return 1
    }
    kubectl wait --for=condition=available --timeout=300s \
        deployment/argocd-server \
        deployment/argocd-repo-server \
        -n "$ARGOCD_NAMESPACE" 2>/dev/null || \
        log_warning "Timeout waiting for Argo CD deployments, continuing..."
    kubectl rollout status statefulset/argocd-application-controller \
        -n "$ARGOCD_NAMESPACE" --timeout=300s 2>/dev/null || \
        log_warning "Timeout on Argo CD application-controller, continuing..."

    log_info "Setting Argo CD admin password to 'admin'..."
    kubectl patch secret argocd-secret -n "$ARGOCD_NAMESPACE" \
        -p '{"stringData": {"admin.password": "$2b$12$oLr8O3sm54Tg00GUsSMhaOI5ipi2.Wb9wIihPERpczpQFb4oOa3MG", "admin.passwordMtime": "'$(date +%FT%T%Z)'"}}' || true

    log_success "Argo CD installed"
}

# ─── Namespaces ─────────────────────────────────────────────────────────────

create_namespaces() {
    log_info "Creating namespaces..."
    for ns in "$MYSQL_NAMESPACE" "$AIRFLOW_CORE_NAMESPACE" "$AIRFLOW_USER_NAMESPACE"; do
        kubectl get namespace "$ns" &>/dev/null || kubectl create namespace "$ns"
    done
    log_success "Namespaces ready: $MYSQL_NAMESPACE, $AIRFLOW_CORE_NAMESPACE, $AIRFLOW_USER_NAMESPACE"
}

# ─── MySQL secret ───────────────────────────────────────────────────────────

create_mysql_secret() {
    log_info "Creating MySQL secrets..."
    if kubectl get secret mysql-secret -n "$MYSQL_NAMESPACE" &>/dev/null; then
        log_warning "MySQL secret already exists, skipping"
        AIRFLOW_DB_PASSWORD=$(kubectl get secret mysql-secret -n "$MYSQL_NAMESPACE" \
            -o jsonpath='{.data.airflow-password}' | base64 -d)
        return 0
    fi
    MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(openssl rand -hex 20)}"
    AIRFLOW_DB_PASSWORD="${AIRFLOW_DB_PASSWORD:-$(openssl rand -hex 20)}"

    kubectl create secret generic mysql-secret \
        --from-literal=root-password="$MYSQL_ROOT_PASSWORD" \
        --from-literal=airflow-password="$AIRFLOW_DB_PASSWORD" \
        -n "$MYSQL_NAMESPACE" || { log_error "Failed to create MySQL secret"; return 1; }

    cat > "$REPO_ROOT/.mysql-credentials.txt" <<EOF
# MySQL Credentials (DO NOT COMMIT)
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
AIRFLOW_DB_PASSWORD=$AIRFLOW_DB_PASSWORD
Host: 127.0.0.1
Port: 3306
Root User: root / $MYSQL_ROOT_PASSWORD
Airflow User: airflow / $AIRFLOW_DB_PASSWORD
Database: airflow
EOF
    chmod 600 "$REPO_ROOT/.mysql-credentials.txt"
    log_success "MySQL secret created"
}

# ─── Airflow secret (in BOTH namespaces) ────────────────────────────────────

create_airflow_secret() {
    log_info "Creating Airflow secrets in both namespaces..."
    if kubectl get secret airflow-secret -n "$AIRFLOW_CORE_NAMESPACE" &>/dev/null; then
        log_warning "Airflow secret already exists in $AIRFLOW_CORE_NAMESPACE, skipping"
        return 0
    fi

    # Generate Fernet key: try Python, fall back to openssl
    if command -v python3 &>/dev/null && python3 -c "from cryptography.fernet import Fernet" 2>/dev/null; then
        AIRFLOW_FERNET_KEY="${AIRFLOW_FERNET_KEY:-$(python3 -c \
            'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')}"
    else
        AIRFLOW_FERNET_KEY="${AIRFLOW_FERNET_KEY:-$(openssl rand -base64 32)}"
    fi
    AIRFLOW_WEBSERVER_SECRET_KEY="${AIRFLOW_WEBSERVER_SECRET_KEY:-$(openssl rand -hex 32)}"
    AIRFLOW_API_JWT_SECRET="${AIRFLOW_API_JWT_SECRET:-$(openssl rand -base64 32)}"
    AIRFLOW_ADMIN_PASSWORD="admin"

    SQL_ALCHEMY_CONN="mysql+pymysql://airflow:${AIRFLOW_DB_PASSWORD}@dev-mysql.mysql.svc.cluster.local:3306/airflow"

    kubectl create secret generic airflow-secret \
        --from-literal=AIRFLOW__DATABASE__SQL_ALCHEMY_CONN="$SQL_ALCHEMY_CONN" \
        --from-literal=AIRFLOW__CORE__FERNET_KEY="$AIRFLOW_FERNET_KEY" \
        --from-literal=AIRFLOW__WEBSERVER__SECRET_KEY="$AIRFLOW_WEBSERVER_SECRET_KEY" \
        --from-literal=AIRFLOW__API_AUTH__JWT_SECRET="$AIRFLOW_API_JWT_SECRET" \
        --from-literal=admin-password="$AIRFLOW_ADMIN_PASSWORD" \
        -n "$AIRFLOW_CORE_NAMESPACE" || { log_error "Failed to create Airflow secret in $AIRFLOW_CORE_NAMESPACE"; return 1; }
    log_success "Airflow secret created in $AIRFLOW_CORE_NAMESPACE"

    kubectl create secret generic airflow-secret \
        --from-literal=AIRFLOW__DATABASE__SQL_ALCHEMY_CONN="$SQL_ALCHEMY_CONN" \
        --from-literal=AIRFLOW__CORE__FERNET_KEY="$AIRFLOW_FERNET_KEY" \
        -n "$AIRFLOW_USER_NAMESPACE" || { log_error "Failed to create Airflow secret in $AIRFLOW_USER_NAMESPACE"; return 1; }
    log_success "Airflow secret created in $AIRFLOW_USER_NAMESPACE"

    cat > "$REPO_ROOT/.airflow-credentials.txt" <<EOF
# Airflow Credentials (DO NOT COMMIT)
Airflow UI:   http://localhost:8090
  username:   admin
  password:   $AIRFLOW_ADMIN_PASSWORD
Namespaces:
  Control plane: $AIRFLOW_CORE_NAMESPACE
  Task pods:     $AIRFLOW_USER_NAMESPACE
EOF
    chmod 600 "$REPO_ROOT/.airflow-credentials.txt"
}

# ─── Bootstrap Argo CD root app ─────────────────────────────────────────────

bootstrap_argocd() {
    log_info "Bootstrapping Argo CD root app (REV=${GIT_REVISION})..."

    if kubectl get application root-app -n "$ARGOCD_NAMESPACE" &>/dev/null; then
        kubectl patch application root-app -n "$ARGOCD_NAMESPACE" \
            --type merge \
            -p "{\"spec\":{\"source\":{\"targetRevision\":\"${GIT_REVISION}\"}}}" || {
            log_error "Failed to patch root-app"; return 1
        }
    else
        kubectl create -n "$ARGOCD_NAMESPACE" -f "$REPO_ROOT/k8s/apps/app-of-apps.yaml" || {
            log_error "Failed to create root-app"; return 1
        }
    fi
    log_success "Argo CD root app bootstrapped"
}

# ─── Patch / create child apps ──────────────────────────────────────────────

patch_child_apps() {
    log_info "Creating/patching child Argo CD apps (REV=${GIT_REVISION})..."
    for app in mysql-app airflow-app monitoring-app; do
        if kubectl get application "$app" -n "$ARGOCD_NAMESPACE" &>/dev/null; then
            kubectl patch application "$app" -n "$ARGOCD_NAMESPACE" \
                --type merge \
                -p "{\"spec\":{\"source\":{\"targetRevision\":\"${GIT_REVISION}\"}}}" || {
                log_error "Failed to patch ${app}"; return 1
            }
        else
            kubectl create -n "$ARGOCD_NAMESPACE" -f "$REPO_ROOT/k8s/apps/${app}.yaml" || {
                log_error "Failed to create ${app}"; return 1
            }
        fi
        log_success "  ${app} ready"
    done
}

refresh_argocd_apps() {
    log_info "Forcing Argo CD refresh..."
    for app in root-app mysql-app airflow-app monitoring-app; do
        kubectl annotate app -n "$ARGOCD_NAMESPACE" "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
    done
}

# ─── Wait functions ──────────────────────────────────────────────────────────

wait_for_mysql_ready() {
    wait_for_argocd_app "mysql-app" "$ARGO_APP_WAIT_TIMEOUT_SEC" || return 1

    log_info "Waiting for MySQL StatefulSet readiness..."
    if kubectl wait --for=condition=ready --timeout="${MYSQL_READY_TIMEOUT_SEC}s" \
        pod/dev-mysql-0 -n "$MYSQL_NAMESPACE" >/dev/null 2>&1; then
        log_success "MySQL is ready"
    else
        log_error "MySQL did not become ready in time"
        kubectl get pods -n "$MYSQL_NAMESPACE" -o wide || true
        return 1
    fi
}

wait_for_monitoring() {
    wait_for_argocd_app "monitoring-app" "$ARGO_APP_WAIT_TIMEOUT_SEC" || return 1

    log_info "Waiting for monitoring deployments..."
    if kubectl wait --for=condition=available --timeout="${MONITORING_READY_TIMEOUT_SEC}s" \
        deployment/kube-state-metrics \
        deployment/prometheus \
        deployment/grafana \
        -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
        log_success "Monitoring stack is ready"
    else
        log_error "Monitoring stack is not fully ready"
        kubectl get pods -n "$MONITORING_NAMESPACE" -o wide || true
        return 1
    fi
}

wait_for_airflow() {
    wait_for_argocd_app "airflow-app" "$ARGO_APP_WAIT_TIMEOUT_SEC" || return 1

    log_info "Waiting for Airflow pods to be ready (cold pull may take several minutes)..."
    if kubectl wait --for=condition=available --timeout="${AIRFLOW_READY_TIMEOUT_SEC}s" \
        deployment/airflow-dag-sync \
        deployment/airflow-dag-processor \
        deployment/airflow-scheduler \
        deployment/airflow-webserver \
        deployment/airflow-triggerer \
        -n "$AIRFLOW_CORE_NAMESPACE" 2>&1 | while read -r line; do
            echo "  ${line}"
        done; then
        log_success "All Airflow components are ready"
    else
        log_error "Some Airflow deployments are not ready"
        kubectl get pods -n "$AIRFLOW_CORE_NAMESPACE" -o wide || true
        return 1
    fi
}

# ─── Demo DAGs ───────────────────────────────────────────────────────────────

bootstrap_demo_dags() {
    local dags=(
        "example_user_namespace"
        "example_core_namespace"
    )
    local scheduler_ref="deploy/airflow-scheduler"
    local ts
    ts="$(date +%s)"

    if ! kubectl wait --for=condition=available --timeout=300s deployment/airflow-scheduler -n "$AIRFLOW_CORE_NAMESPACE" >/dev/null 2>&1; then
        log_warning "Scheduler not ready; skipping demo DAG bootstrap"
        return 1
    fi

    log_info "Unpausing and bootstrapping demo DAG runs..."
    for dag in "${dags[@]}"; do
        local dag_visible=false
        for _ in $(seq 1 30); do
            if kubectl -n "$AIRFLOW_CORE_NAMESPACE" exec "$scheduler_ref" -- airflow dags list 2>/dev/null | awk '{print $1}' | grep -qx "$dag"; then
                dag_visible=true
                break
            fi
            sleep 2
        done

        if ! $dag_visible; then
            log_warning "  DAG not visible yet: ${dag}"
            continue
        fi

        kubectl -n "$AIRFLOW_CORE_NAMESPACE" exec "$scheduler_ref" -- airflow dags unpause "$dag" >/dev/null 2>&1 && \
            log_success "  unpaused: ${dag}" || log_warning "  could not unpause: ${dag}"

        local existing_run
        existing_run="$(kubectl -n "$AIRFLOW_CORE_NAMESPACE" exec "$scheduler_ref" -- \
            airflow dags list-runs "$dag" --no-backfill -o plain 2>/dev/null | awk 'NR==2 {print $2}')"
        if [ -n "${existing_run:-}" ]; then
            log_info "  existing run found for ${dag}; skipping trigger"
            continue
        fi

        kubectl -n "$AIRFLOW_CORE_NAMESPACE" exec "$scheduler_ref" -- airflow dags trigger "$dag" -r "bootstrap_${dag}_${ts}" >/dev/null 2>&1 && \
            log_success "  triggered: ${dag}" || log_warning "  could not trigger: ${dag}"
    done
}

disable_legacy_mixed_demo_dag() {
    local scheduler_ref="deploy/airflow-scheduler"
    if kubectl wait --for=condition=available --timeout=180s deployment/airflow-scheduler -n "$AIRFLOW_CORE_NAMESPACE" >/dev/null 2>&1; then
        if kubectl -n "$AIRFLOW_CORE_NAMESPACE" exec "$scheduler_ref" -- airflow dags list 2>/dev/null | awk '{print $1}' | grep -qx "example_mixed_namespace"; then
            kubectl -n "$AIRFLOW_CORE_NAMESPACE" exec "$scheduler_ref" -- airflow dags pause example_mixed_namespace >/dev/null 2>&1 || true
            log_info "Paused legacy demo DAG: example_mixed_namespace"
        fi
    fi
    kubectl delete pod -n "$AIRFLOW_CORE_NAMESPACE" -l dag_id=example_mixed_namespace --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete pod -n "$AIRFLOW_USER_NAMESPACE" -l dag_id=example_mixed_namespace --ignore-not-found >/dev/null 2>&1 || true
}

# ─── Port-forward setup ─────────────────────────────────────────────────────

setup_argocd_portforward() {
    log_info "Starting Argo CD port-forward on localhost:8080..."
    start_port_forward "argocd" "$ARGOCD_NAMESPACE" "argocd-server" "8080" "443" || return 1
    log_success "Argo CD UI available at https://localhost:8080"

    cat > "$REPO_ROOT/.argocd-credentials.txt" <<EOF
# Argo CD Credentials (DO NOT COMMIT)
UI URL: https://localhost:8080
Username: admin
Password: admin
EOF
    chmod 600 "$REPO_ROOT/.argocd-credentials.txt"
}

setup_airflow_portforward() {
    log_info "Starting Airflow port-forward on localhost:8090..."
    start_port_forward "airflow" "$AIRFLOW_CORE_NAMESPACE" "airflow-webserver" "8090" "8080" || return 1
    log_success "Airflow UI available at http://localhost:8090"
}

setup_mysql_portforward() {
    log_info "Starting MySQL port-forward on localhost:3306..."
    start_port_forward "mysql" "$MYSQL_NAMESPACE" "dev-mysql" "3306" "3306" || return 1
    log_success "MySQL DB accessible at 127.0.0.1:3306"
}

setup_prometheus_portforward() {
    log_info "Starting Prometheus port-forward on localhost:${PROMETHEUS_PORT}..."
    start_port_forward "prometheus" "$MONITORING_NAMESPACE" "prometheus" "${PROMETHEUS_PORT}" "9090" || return 1
    log_success "Prometheus available at http://localhost:${PROMETHEUS_PORT}"
}

setup_grafana_portforward() {
    log_info "Starting Grafana port-forward on localhost:${GRAFANA_PORT}..."
    start_port_forward "grafana" "$MONITORING_NAMESPACE" "grafana" "${GRAFANA_PORT}" "3000" || return 1
    log_success "Grafana available at http://localhost:${GRAFANA_PORT} (admin/admin)"
}

# ─── Summary ─────────────────────────────────────────────────────────────────

print_summary() {
    echo ""
    log_success "══════════════════════════════════════════"
    log_success " AIO GitOps POC - Ready!"
    log_success "══════════════════════════════════════════"
    echo ""
    echo "  Argo CD UI   →  https://localhost:8080  (admin/admin)"
    echo "  Airflow UI   →  http://localhost:8090   (admin/admin)"
    echo "  MySQL DB     →  127.0.0.1:3306          (see .mysql-credentials.txt)"
    echo "  Prometheus   →  http://localhost:${PROMETHEUS_PORT}"
    echo "  Grafana      →  http://localhost:${GRAFANA_PORT} (admin/admin)"
    echo ""
    echo "  Namespaces:"
    echo "    airflow-core  →  scheduler, webserver, triggerer, dag-processor, git-sync"
    echo "    airflow-user  →  task pods (KubernetesExecutor target)"
    echo ""
    echo "  make status      – component health"
    echo "  make dev-down    – tear everything down"
    echo ""
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    log_info "Starting AIO GitOps POC (multi-namespace Airflow)..."
    bootstrap_tools             || exit 1
    check_docker                || exit 1
    check_port_conflicts        || exit 1
    load_kindest_node_image     || true
    create_kind_cluster         || exit 1
    load_all_images             || true
    install_ingress_nginx       || exit 1
    install_argocd              || exit 1
    configure_node_pools        || exit 1
    patch_platform_workloads_for_core_taint || true
    create_namespaces           || exit 1
    create_mysql_secret         || exit 1
    create_airflow_secret       || exit 1
    ensure_argocd_healthy       || exit 1
    bootstrap_argocd            || exit 1
    patch_child_apps            || exit 1
    refresh_argocd_apps         || true
    wait_for_mysql_ready        || exit 1
    wait_for_airflow            || exit 1
    disable_legacy_mixed_demo_dag || true
    bootstrap_demo_dags         || true
    if ! wait_for_monitoring; then
        log_warning "Monitoring stack not fully ready — Airflow is functional, monitoring may come up later"
    fi
    setup_argocd_portforward    || exit 1
    setup_airflow_portforward   || exit 1
    setup_mysql_portforward     || exit 1
    setup_prometheus_portforward || exit 1
    setup_grafana_portforward   || exit 1
    print_summary
}

main "$@"
