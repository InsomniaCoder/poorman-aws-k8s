#!/usr/bin/env bash
set -euo pipefail

# Bootstrap ArgoCD and the cluster-apps App of Apps.
# Run once after the core Terraform stack is applied and KUBECONFIG is set.
# Safe to re-run — all operations are idempotent.
#
# Required env vars:
#   KUBECONFIG            path to kubeconfig  (~/.kube/poorman-k8s.yaml)
#   CLOUDFLARE_API_TOKEN  Zone:DNS:Edit token
#
# Optional env vars (default: read from live/eu-south-2/env.hcl):
#   DOMAIN / DOMAIN_NAME  your Cloudflare-managed domain
#   REPO_URL              HTTPS URL of your fork
#   GITHUB_TOKEN          git password/token   (omit for public repos)
#   REPO_USERNAME         git username         (default: git)
#   ARGOCD_VERSION        Helm chart version   (default: 7.8.26)
#   TARGET_REVISION       git branch/tag       (default: HEAD)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$SCRIPT_DIR/argocd"
ENV_HCL="$REPO_ROOT/live/eu-south-2/env.hcl"

# ── KUBECONFIG guard (soft — skips when called from terragrunt after_hook) ─────
if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "KUBECONFIG not set — skipping ArgoCD bootstrap. Run ./scripts/bootstrap-argocd.sh manually after exporting KUBECONFIG."
  exit 0
fi

# ── Required env guards ────────────────────────────────────────────────────────
: "${CLOUDFLARE_API_TOKEN:?ERROR: CLOUDFLARE_API_TOKEN is not set.}"

# ── Resolve domain and repo_url (env vars take priority over env.hcl) ──────────
# env.hcl now uses get_env() so we can't grep a plain string from it.
# Resolution order: DOMAIN → DOMAIN_NAME → error
export DOMAIN="${DOMAIN:-${DOMAIN_NAME:-}}"
export REPO_URL="${REPO_URL:-${REPO_URL:-}}"
: "${DOMAIN:?ERROR: set DOMAIN or DOMAIN_NAME in your environment.}"
: "${REPO_URL:?ERROR: set REPO_URL in your environment.}"

REPO_USERNAME="${REPO_USERNAME:-git}"
REPO_PASSWORD="${GITHUB_TOKEN:-}"
ARGOCD_VERSION="${ARGOCD_VERSION:-7.8.26}"
export TARGET_REVISION="${TARGET_REVISION:-HEAD}"

echo "==> Using kubeconfig: $KUBECONFIG"
kubectl cluster-info --request-timeout=5s > /dev/null

# ── Namespaces ─────────────────────────────────────────────────────────────────
echo "==> Applying namespaces"
kubectl apply -f "$MANIFESTS_DIR/namespaces.yaml"

# ── Cloudflare secrets ─────────────────────────────────────────────────────────
echo "==> Creating Cloudflare API token secrets"
for ns in cert-manager external-dns; do
  kubectl create secret generic cloudflare-api-token \
    --namespace "$ns" \
    --from-literal=api-token="$CLOUDFLARE_API_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
done

# ── ArgoCD ─────────────────────────────────────────────────────────────────────
echo "==> Installing ArgoCD $ARGOCD_VERSION"
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_VERSION" \
  --namespace argocd \
  --create-namespace \
  --wait \
  --timeout 5m \
  --values <(sed "s|\${DOMAIN}|${DOMAIN}|g" "$MANIFESTS_DIR/argocd-values.yaml")

# ── Repo secret ────────────────────────────────────────────────────────────────
echo "==> Creating ArgoCD repo secret"
kubectl create secret generic repo-poorman-k8s \
  --namespace argocd \
  --from-literal=type=git \
  --from-literal=url="$REPO_URL" \
  --from-literal=username="$REPO_USERNAME" \
  --from-literal=password="$REPO_PASSWORD" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - "argocd.argoproj.io/secret-type=repository" --dry-run=client -o yaml \
  | kubectl apply -f -

# ── App of Apps ────────────────────────────────────────────────────────────────
echo "==> Waiting for ArgoCD CRDs"
kubectl wait --for=condition=established crd/applications.argoproj.io --timeout=120s

echo "==> Bootstrapping cluster-apps Application"
sed -e "s|\${REPO_URL}|${REPO_URL}|g" \
    -e "s|\${TARGET_REVISION}|${TARGET_REVISION}|g" \
    "$MANIFESTS_DIR/cluster-apps.yaml" | kubectl apply -f -

echo ""
echo "==> ArgoCD bootstrap complete."
echo ""
echo "    Initial admin password:"
echo "    kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "    ArgoCD UI: https://argocd.${DOMAIN}"
