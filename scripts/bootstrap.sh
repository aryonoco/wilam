#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# k3s + FluxCD Bootstrap
# ──────────────────────
# Run ONCE after Combustion first boot to stand up the cluster.
# Idempotent — safe to re-run if interrupted.
#
# Prerequisites:
#   • Leap Micro 6.2 provisioned via combustion/script
#   • This repo cloned to the machine
#   • .env file populated (see .env.example)
#
# Usage:
#   cd /path/to/k3s-cluster
#   cp .env.example .env   # then edit
#   ./scripts/bootstrap.sh
#
# shellcheck shell=bash

set -euo pipefail

# ── Constants ───────────────────────────────────────────────────────────────

readonly SCRIPT_NAME="${0##*/}"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

readonly K3S_CONFIG_DIR="/etc/rancher/k3s"
readonly K3S_AUDIT_LOG_DIR="/var/log/kubernetes"
readonly AGE_VERSION="v1.2.1"
readonly SOPS_VERSION="v3.9.4"
readonly AGE_KEY_DIR="${HOME}/.config/sops/age"
readonly AGE_KEY_FILE="${AGE_KEY_DIR}/keys.txt"

# PSA-exempt namespaces — these run privileged workloads by design
readonly -a PSA_EXEMPT_NS=(
    kube-system
    cert-manager
    node-feature-discovery
    intel-device-plugins-gpu
    flux-system
)

# ── Logging & error handling ────────────────────────────────────────────────

log()  { printf '[%s] %s\n' "${SCRIPT_NAME}" "$*"; }
warn() { printf '[%s] WARN: %s\n' "${SCRIPT_NAME}" "$*" >&2; }
die()  { printf '[%s] FATAL: %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 1; }

# Temp directory for intermediate files (secrets, downloads)
# Cleaned up on exit regardless of success/failure
TMPDIR_WORK=""
_cleanup() {
    if [[ -n "${TMPDIR_WORK}" && -d "${TMPDIR_WORK}" ]]; then
        rm -rf "${TMPDIR_WORK}"
    fi
}
trap _cleanup EXIT
trap 'die "unexpected failure at line ${LINENO} (exit code $?)"' ERR

TMPDIR_WORK="$(mktemp -d -t bootstrap.XXXXXXXXXX)"
readonly TMPDIR_WORK

# ── Environment loading ────────────────────────────────────────────────────

if [[ -f "${REPO_ROOT}/.env" ]]; then
    log "loading environment from ${REPO_ROOT}/.env"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/.env"
else
    log "no .env found — expecting variables already exported"
fi

# ── Validation ──────────────────────────────────────────────────────────────

readonly -a REQUIRED_VARS=(
    DOMAIN
    NAS_IP
    NAS_HTPC_PATH
    NAS_IMMICH_PATH
    NODE_NAME
    ACME_EMAIL
    GITHUB_USER
    GITHUB_REPO
    GITHUB_TOKEN
    PORKBUN_API_KEY
    PORKBUN_SECRET_KEY
)

_missing=()
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        _missing+=("${var}")
    fi
done
if (( ${#_missing[@]} > 0 )); then
    die "missing required variables: ${_missing[*]}
    Copy .env.example to .env and fill in all values."
fi
unset _missing

# Refuse to run as root — k3s install uses sudo internally, and kubeconfig
# must be owned by a regular user for day-2 operations
if (( EUID == 0 )); then
    die "do not run as root — run as your admin user (sudo is used where needed)"
fi

# Verify we can reach the internet (k3s install, age/sops downloads)
if ! curl -sf --max-time 5 -o /dev/null https://get.k3s.io; then
    die "cannot reach https://get.k3s.io — check network connectivity"
fi

log "validation passed"
printf '\n'
log "═══════════════════════════════════════════════════════════════"
log "  k3s + FluxCD Bootstrap"
log "  repo: github.com/${GITHUB_USER}/${GITHUB_REPO}"
log "═══════════════════════════════════════════════════════════════"
printf '\n'

# ── Step 1/9: Personalize repository ─────────────────────────────────────
# Replaces generic placeholders with real values from .env.
# Idempotent — skips if already personalized.

log "▶ Step 1/9: Personalizing repository..."

_personalize_file() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    sed -i \
        -e "s/you@example\.com/${ACME_EMAIL}/g" \
        -e "s/example\.com/${DOMAIN}/g" \
        -e "s/192\.168\.1\.100/${NAS_IP}/g" \
        -e "s|/mnt/nas/media|${NAS_HTPC_PATH}|g" \
        -e "s|/mnt/nas/photos|${NAS_IMMICH_PATH}|g" \
        -e "s/k3s-node/${NODE_NAME}/g" \
        "${file}"
}

if grep -q 'example\.com' "${REPO_ROOT}/infrastructure/certs/cluster-issuer.yaml" 2>/dev/null; then
    log "  replacing placeholders with your values..."
    while IFS= read -r -d '' f; do
        _personalize_file "${f}"
    done < <(find "${REPO_ROOT}" \( -name '*.yaml' -o -name '*.md' \) -not -path '*/.git/*' -print0)
    log "  personalization complete"
else
    log "  already personalized — skipping"
fi

printf '\n'

# ── Step 2/9: k3s server configuration ─────────────────────────────────────
# These files live in /etc (writable overlayfs on Leap Micro) and must exist
# BEFORE k3s starts. Combustion doesn't handle these because they're cluster
# concerns, not OS concerns.

log "▶ Step 2/9: Writing k3s server configuration..."

sudo mkdir -p "${K3S_CONFIG_DIR}" "${K3S_AUDIT_LOG_DIR}"

if [[ -f "${K3S_CONFIG_DIR}/config.yaml" ]]; then
    log "  ${K3S_CONFIG_DIR}/config.yaml already exists — skipping"
else
    sudo tee "${K3S_CONFIG_DIR}/config.yaml" > /dev/null << 'K3SCONF'
write-kubeconfig-mode: "0640"
selinux: true
secrets-encryption: true
kube-apiserver-arg:
  - "audit-log-path=/var/log/kubernetes/audit.log"
  - "audit-log-maxage=30"
  - "audit-log-maxbackup=10"
  - "audit-log-maxsize=100"
  - "admission-control-config-file=/etc/rancher/k3s/psa.yaml"
K3SCONF
    log "  wrote ${K3S_CONFIG_DIR}/config.yaml"
fi

# ── Step 3/9: Pod Security Admission policy ─────────────────────────────────

log "▶ Step 3/9: Writing PSA policy..."

if [[ -f "${K3S_CONFIG_DIR}/psa.yaml" ]]; then
    log "  ${K3S_CONFIG_DIR}/psa.yaml already exists — skipping"
else
    # Build the exemptions list dynamically from our constant array
    _exemptions=""
    for ns in "${PSA_EXEMPT_NS[@]}"; do
        _exemptions+="          - ${ns}"$'\n'
    done

    sudo tee "${K3S_CONFIG_DIR}/psa.yaml" > /dev/null << PSACONF
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: "baseline"
        enforce-version: "latest"
        audit: "restricted"
        audit-version: "latest"
        warn: "restricted"
        warn-version: "latest"
      exemptions:
        namespaces:
${_exemptions}
PSACONF
    unset _exemptions
    log "  wrote ${K3S_CONFIG_DIR}/psa.yaml"
fi

# ── Step 4/9: Install k3s ──────────────────────────────────────────────────

log "▶ Step 4/9: Installing k3s..."

if command -v k3s &>/dev/null; then
    log "  already installed: $(k3s --version 2>/dev/null | head -1)"
else
    curl -sfL https://get.k3s.io | sudo sh -
    log "  k3s installed"
fi

# ── Step 5/9: Configure kubeconfig & wait for ready ─────────────────────────

log "▶ Step 5/9: Configuring kubeconfig..."

mkdir -p "${HOME}/.kube"
# k3s writes kubeconfig as root; copy to user-owned location
sudo cp "${K3S_CONFIG_DIR}/k3s.yaml" "${HOME}/.kube/config"
sudo chown "$(id -u):$(id -g)" "${HOME}/.kube/config"
chmod 600 "${HOME}/.kube/config"
export KUBECONFIG="${HOME}/.kube/config"

# Persist KUBECONFIG for future shells (idempotent append)
if ! grep -qF 'export KUBECONFIG' "${HOME}/.bashrc" 2>/dev/null; then
    printf '\nexport KUBECONFIG=~/.kube/config\n' >> "${HOME}/.bashrc"
fi

log "  waiting for node to reach Ready state (timeout: 120s)..."
if ! kubectl wait --for=condition=Ready node --all --timeout=120s; then
    die "node did not become Ready within 120s — check 'journalctl -u k3s'"
fi
log "  node is Ready"

# ── Step 6/9: Install age + SOPS ───────────────────────────────────────────

log "▶ Step 6/9: Installing age + SOPS..."

if command -v age &>/dev/null; then
    log "  age already installed"
else
    local_tar="${TMPDIR_WORK}/age.tar.gz"
    curl -sfL -o "${local_tar}" \
        "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz"
    sudo tar -C /usr/local/bin -xzf "${local_tar}" --strip-components=1 age/age age/age-keygen
    log "  age ${AGE_VERSION} installed"
fi

if command -v sops &>/dev/null; then
    log "  sops already installed"
else
    local_bin="${TMPDIR_WORK}/sops"
    curl -sfL -o "${local_bin}" \
        "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64"
    sudo install -m 755 "${local_bin}" /usr/local/bin/sops
    log "  sops ${SOPS_VERSION} installed"
fi

# ── Step 7/9: Age keypair + SOPS-encrypted secrets ─────────────────────────

log "▶ Step 7/9: Setting up encryption..."

# Generate or restore age keypair
if [[ -n "${SOPS_AGE_KEY:-}" ]]; then
    # Restoring from backup (disaster recovery)
    mkdir -p "${AGE_KEY_DIR}"
    printf '%s\n' "${SOPS_AGE_KEY}" > "${AGE_KEY_FILE}"
    chmod 600 "${AGE_KEY_FILE}"
    log "  age key restored from SOPS_AGE_KEY env var"
elif [[ -f "${AGE_KEY_FILE}" ]]; then
    log "  age key already exists at ${AGE_KEY_FILE}"
else
    mkdir -p "${AGE_KEY_DIR}"
    age-keygen -o "${AGE_KEY_FILE}" 2>/dev/null
    chmod 600 "${AGE_KEY_FILE}"
    log "  generated new age key at ${AGE_KEY_FILE}"
    warn "BACK UP THIS KEY — without it, secrets in the repo are unrecoverable"
fi

# Extract public key for .sops.yaml creation_rules
AGE_PUBLIC_KEY="$(grep 'public key:' "${AGE_KEY_FILE}" | awk '{print $NF}')"
readonly AGE_PUBLIC_KEY
if [[ -z "${AGE_PUBLIC_KEY}" ]]; then
    die "could not extract public key from ${AGE_KEY_FILE}"
fi
log "  age public key: ${AGE_PUBLIC_KEY}"

# Write .sops.yaml (tells sops which key to encrypt with)
if [[ ! -f "${REPO_ROOT}/.sops.yaml" ]]; then
    cat > "${REPO_ROOT}/.sops.yaml" << SOPSEOF
creation_rules:
  - path_regex: .*\.sops\.ya?ml$
    age: "${AGE_PUBLIC_KEY}"
SOPSEOF
    log "  created ${REPO_ROOT}/.sops.yaml"
fi

export SOPS_AGE_KEY_FILE="${AGE_KEY_FILE}"

# Encrypt Porkbun DNS-01 credentials
_porkbun_file="${REPO_ROOT}/infrastructure/certs/porkbun-secret.sops.yaml"
if [[ -f "${_porkbun_file}" ]] && sops --decrypt "${_porkbun_file}" &>/dev/null; then
    log "  porkbun-secret.sops.yaml already encrypted — skipping"
else
    cat > "${TMPDIR_WORK}/porkbun.yaml" << PBEOF
apiVersion: v1
kind: Secret
metadata:
  name: porkbun-secret
  namespace: cert-manager
type: Opaque
stringData:
  PORKBUN_API_KEY: "${PORKBUN_API_KEY}"
  PORKBUN_SECRET_API_KEY: "${PORKBUN_SECRET_KEY}"
PBEOF
    sops --encrypt "${TMPDIR_WORK}/porkbun.yaml" > "${_porkbun_file}"
    log "  encrypted porkbun-secret.sops.yaml"
fi

# Encrypt Immich PostgreSQL password
_immich_file="${REPO_ROOT}/apps/immich/pg-secret.sops.yaml"
if [[ -f "${_immich_file}" ]] && sops --decrypt "${_immich_file}" &>/dev/null; then
    log "  pg-secret.sops.yaml already encrypted — skipping"
else
    _pg_password="$(openssl rand -base64 32 | tr -d '=/+' | head -c 32)"
    cat > "${TMPDIR_WORK}/immich-pg.yaml" << IMEOF
apiVersion: v1
kind: Secret
metadata:
  name: immich-postgresql
  namespace: immich
type: Opaque
stringData:
  postgresql-password: "${_pg_password}"
IMEOF
    sops --encrypt "${TMPDIR_WORK}/immich-pg.yaml" > "${_immich_file}"
    unset _pg_password
    log "  encrypted pg-secret.sops.yaml"
fi

# Commit encrypted secrets so Flux can pull them
if command -v git &>/dev/null && [[ -d "${REPO_ROOT}/.git" ]]; then
    pushd "${REPO_ROOT}" > /dev/null
    git add -A .sops.yaml \
        infrastructure/certs/porkbun-secret.sops.yaml \
        apps/immich/pg-secret.sops.yaml 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "chore: add SOPS-encrypted secrets [bootstrap]"
        git push origin main
        log "  encrypted secrets committed and pushed"
    else
        log "  no new secrets to commit"
    fi
    popd > /dev/null
fi

# ── Step 8/9: Install Flux CLI ──────────────────────────────────────────────

log "▶ Step 8/9: Installing Flux CLI..."

if command -v flux &>/dev/null; then
    log "  already installed: $(flux version --client 2>/dev/null | head -1)"
else
    curl -sf https://fluxcd.io/install.sh | sudo bash
    log "  Flux CLI installed"
fi

# ── Step 9/9: Bootstrap FluxCD ──────────────────────────────────────────────

log "▶ Step 9/9: Bootstrapping FluxCD..."

# Create the namespace and SOPS decryption secret before Flux starts
# (Flux needs this to decrypt *.sops.yaml files during reconciliation)
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
kubectl -n flux-system create secret generic sops-age \
    --from-file=age.agekey="${AGE_KEY_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f -

flux bootstrap github \
    --owner="${GITHUB_USER}" \
    --repository="${GITHUB_REPO}" \
    --branch=main \
    --path=clusters/conductor \
    --personal \
    --token-auth

# ── Summary ─────────────────────────────────────────────────────────────────

printf '\n'
log "═══════════════════════════════════════════════════════════════"
log "  ✔ Bootstrap complete!"
log ""
log "  FluxCD reconciling from:"
log "    github.com/${GITHUB_USER}/${GITHUB_REPO}/clusters/conductor"
log ""
log "  Monitor:   flux get kustomizations --watch"
log "  All pods:  kubectl get pods -A -w"
log ""
log "  Age key:   ${AGE_KEY_FILE}"
log "  ⚠  Back this up — it decrypts every secret in the repo."
log ""
log "  After pods stabilise:"
log "    1. Get claim token from https://plex.tv/claim"
log "    2. kubectl -n media set env deploy/plex PLEX_CLAIM=claim-xxx"
log "    3. Wait 60 seconds for Plex to register"
log "    4. kubectl -n media set env deploy/plex PLEX_CLAIM-"
log "═══════════════════════════════════════════════════════════════"
