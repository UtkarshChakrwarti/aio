# AIO — All-in-One GitOps POC

Self-contained, multi-namespace Apache Airflow 3.0 on Kubernetes with Argo CD GitOps.
**Only Docker is required** — everything else is auto-installed.

## Quick Start

```bash
git clone https://github.com/UtkarshChakrwarti/aio.git
cd aio
git lfs pull        # download bundled container images
make dev-up         # ~5-10 min on first run
```

## Prerequisites

- **Docker Desktop** or **Colima** (`colima start`)
- **Git LFS** (`brew install git-lfs && git lfs install`)

That's it. `kind`, `kubectl`, and `argocd` are auto-installed to `.bin/` on first run.

## Services

| Service     | URL                        | Credentials  |
|-------------|----------------------------|--------------|
| Airflow UI  | http://localhost:8090      | admin/admin  |
| Argo CD UI  | https://localhost:8080     | admin/admin  |
| MySQL       | 127.0.0.1:3306             | see .mysql-credentials.txt |
| Prometheus  | http://localhost:9090      | —            |
| Grafana     | http://localhost:3000      | admin/admin  |

## Architecture

```
Kind Cluster (gitops-poc)
├── control-plane
├── worker-1 (airflow-core)     ← scheduler, webserver, triggerer, dag-processor, git-sync
│                                  + ArgoCD, ingress-nginx, MySQL, Prometheus, Grafana
└── worker-2 (airflow-user)     ← KubernetesExecutor task pods
```

Argo CD syncs from this repo's `k8s/` directory (App-of-Apps pattern).
DAGs are git-synced from [remote_airflow](https://github.com/UtkarshChakrwarti/remote_airflow).

## Make Targets

```
make dev-up          Start the full environment
make dev-down        Tear down completely
make status          Show cluster health
make logs            Tail component logs
make airflow-ui      Open Airflow in browser
make argocd-ui       Open Argo CD in browser
make save-images     (Maintainer) Pull & save all images for LFS
make help            Show all targets
```

## Offline / Air-gapped Usage

All container images are bundled as `.tar` files in `images/` via Git LFS.
On `make dev-up`, they are loaded directly into the Kind cluster — no registry pulls needed.

If you cloned without LFS, run `git lfs pull` before `make dev-up`.

## For Maintainers

To update bundled images after a version bump:

```bash
make save-images     # pulls all images, saves to images/*.tar
git add images/
git commit -m "chore: update bundled images"
git push
```
