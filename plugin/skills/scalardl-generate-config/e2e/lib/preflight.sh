#!/usr/bin/env bash
# Pre-flight check for plan-009 E2E auto harness.
#
# Plan reference: docs/plan-009-auto-e2e-test-harness.md "Pre-conditions"
#
# Verifies user-side environment is ready before any pattern starts. Each
# missing item is reported with a concrete repair command, then preflight
# exits non-zero. Environment provisioning (minikube start, kubectl install,
# helm install, etc.) is **NOT** in scope (plan-009 D9 / D10): user is
# responsible.
#
# Usage:
#   source lib/preflight.sh          # exports CFG_*, PREFLIGHT_FAILED counter
#   run_preflight                    # runs all checks
#   exit "${PREFLIGHT_FAILED:-1}"    # 0 = all green
#
# Or run via top-level: bash run.sh --layer preflight

set -uo pipefail   # don't use -e here: each check needs to keep running

# --- repo / bundle paths -----------------------------------------------------

PREFLIGHT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "${PREFLIGHT_DIR}/.." && pwd)"
SKILL_DIR="$(cd "${E2E_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SKILL_DIR}/../.." && pwd)"

CFG_FILE="${E2E_DIR}/e2e-config.local.json"

# Trial PEM SHA-256 (recorded at plan-009 W1 commit). Re-compute if you intentionally
# refresh references/license-pem/trial-cert.pem from upstream; do NOT change to silence
# this check.
TRIAL_PEM_SHA256_EXPECTED="c1b479758afcb7a446dff6f5c07b7e9dcec03e61ab3a12d6e4b18b408ce5b66e"

# --- helper ------------------------------------------------------------------

PREFLIGHT_FAILED=0
PREFLIGHT_PASSED=0

# colors (avoided when stdout is not a TTY, e.g. CI logs)
if [ -t 1 ]; then
  CRESET=$'\e[0m'; CGREEN=$'\e[32m'; CRED=$'\e[31m'; CBOLD=$'\e[1m'
else
  CRESET=''; CGREEN=''; CRED=''; CBOLD=''
fi

ok () {
  PREFLIGHT_PASSED=$((PREFLIGHT_PASSED + 1))
  printf '  %s✓ %s%s\n' "${CGREEN}" "$*" "${CRESET}"
}

ng () {
  PREFLIGHT_FAILED=$((PREFLIGHT_FAILED + 1))
  printf '  %s✗ %s%s\n' "${CRED}" "$*" "${CRESET}"
}

# Print a repair command in red, suitable for "run this and retry" guidance.
hint () {
  printf '    %s→ %s%s\n' "${CRED}" "$*" "${CRESET}"
}

# --- 1. e2e-config.local.json present + valid JSON ---------------------------

check_cfg_file () {
  if [ ! -f "${CFG_FILE}" ]; then
    ng "e2e-config.local.json not found"
    hint "cp e2e-config.local.json.example e2e-config.local.json"
    hint "\$EDITOR e2e-config.local.json   # adjust kubectlContext / paths as needed"
    return 1
  fi
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${CFG_FILE}" 2>/dev/null; then
    ng "e2e-config.local.json present but invalid JSON"
    hint "python3 -m json.tool < ${CFG_FILE}    # locate the syntax error"
    return 1
  fi
  ok "e2e-config.local.json present and parses as JSON"
}

# Read a top-level string field from CFG_FILE. Echoes value (empty if missing).
cfg_get () {
  local key="$1"
  python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2], ""); print(v if v is not None else "")' \
    "${CFG_FILE}" "${key}" 2>/dev/null
}

# --- 2. kubectl reachable to cluster -----------------------------------------

check_kubectl () {
  if ! command -v kubectl >/dev/null 2>&1; then
    ng "kubectl not on PATH"
    hint "Install kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl/"
    return 1
  fi
  if ! kubectl get pods -A >/dev/null 2>&1; then
    ng "kubectl cannot reach a cluster (kubectl get pods -A failed)"
    hint "Start minikube: minikube start"
    hint "Or set the right context: kubectl config use-context <ctx>"
    return 1
  fi
  ok "kubectl reaches cluster"
}

# --- 3. minikube tunnel running (LoadBalancer support) -----------------------

check_minikube_tunnel () {
  # We treat 'minikube tunnel' as a soft check. The hard signal is whether any
  # LoadBalancer service in the cluster ever got an EXTERNAL-IP. Since the
  # harness will create fresh LBs per pattern, we accept either:
  #   (a) a running 'minikube tunnel' process, OR
  #   (b) at least one Service with type=LoadBalancer that already has an IP
  if pgrep -f 'minikube tunnel' >/dev/null 2>&1; then
    ok "minikube tunnel process detected"
    return 0
  fi
  local lb_count
  lb_count=$(kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' 2>/dev/null | grep -c .)
  if [ "${lb_count:-0}" -gt 0 ]; then
    ok "LoadBalancer services have external IPs (minikube tunnel likely active)"
    return 0
  fi
  ng "minikube tunnel not detected (no process, no existing LB with external IP)"
  hint "In another terminal: minikube tunnel  (sudo password may be required)"
  hint "Skip-check workaround: set E2E_SKIP_TUNNEL_CHECK=1 if your cluster provides LB without minikube tunnel"
  return 1
}

# --- 4. helm CLI -------------------------------------------------------------

check_helm () {
  if ! command -v helm >/dev/null 2>&1; then
    ng "helm not on PATH"
    hint "Install Helm: https://helm.sh/docs/intro/install/"
    return 1
  fi
  if ! helm version --short >/dev/null 2>&1; then
    ng "helm command present but 'helm version' failed"
    hint "Reinstall helm or check version compatibility"
    return 1
  fi
  ok "helm CLI works ($(helm version --short 2>/dev/null))"
}

# --- 5. helm scalar-labs chart repo registered -------------------------------

check_helm_repo () {
  if helm repo list -o json 2>/dev/null | python3 -c '
import json,sys
rows = json.load(sys.stdin)
sys.exit(0 if any(r.get("name") == "scalar-labs" for r in rows) else 1)
'; then
    ok "helm chart repo 'scalar-labs' registered"
  else
    ng "helm chart repo 'scalar-labs' not registered"
    hint "helm repo add scalar-labs https://scalar-labs.github.io/helm-charts && helm repo update"
    return 1
  fi
}

# --- 6. scalardl-client CLI --------------------------------------------------

check_scalardl_client () {
  local bin
  bin=$(cfg_get scalardlClientBinPath)
  bin="${bin:-scalardl}"
  if ! command -v "${bin}" >/dev/null 2>&1 && [ ! -x "${bin}" ]; then
    ng "scalardl CLI not found (looked for: ${bin})"
    hint "Install scalardl-java-client-sdk-<version>/bin/scalardl and put it on PATH"
    hint "Or set scalardlClientBinPath in e2e-config.local.json to its absolute path"
    return 1
  fi
  # Modern CLI (3.10+) uses positional subcommands; running with no args prints
  # the subcommand list (and exits 2 — that's expected). The signal we want is
  # "Usage: scalardl" or a subcommand list in the output.
  local out
  out="$("${bin}" 2>&1 || true)"
  if echo "${out}" | grep -qE "Usage:\s*scalardl|register-cert|execute-contract"; then
    ok "scalardl CLI works (${bin})"
  else
    ng "scalardl present but does not look like the expected CLI"
    hint "Output excerpt:"
    echo "${out}" | head -5 | sed 's/^/    /'
    return 1
  fi
}

# --- 7. Docker daemon --------------------------------------------------------

check_docker () {
  if ! command -v docker >/dev/null 2>&1; then
    ng "docker not on PATH"
    hint "Install Docker: https://docs.docker.com/engine/install/"
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    ng "docker daemon not running (or current user lacks permission)"
    hint "Start Docker daemon: sudo systemctl start docker"
    hint "Or add user to docker group: sudo usermod -aG docker \$USER && newgrp docker"
    return 1
  fi
  ok "docker daemon running"
}

# --- 8. Trial PEM SHA matches recorded -----------------------------------

check_trial_pem () {
  local pem="${SKILL_DIR}/references/license-pem/trial-cert.pem"
  if [ ! -f "${pem}" ]; then
    ng "bundled trial PEM missing: ${pem}"
    hint "PEM is bundled; re-copy from scalardb-skills/references/license-pem/ if missing"
    return 1
  fi
  local actual
  actual=$(sha256sum "${pem}" | awk '{print $1}')
  if [ "${actual}" = "${TRIAL_PEM_SHA256_EXPECTED}" ]; then
    ok "trial PEM SHA-256 matches recorded value"
  else
    ng "trial PEM SHA-256 mismatch"
    hint "expected: ${TRIAL_PEM_SHA256_EXPECTED}"
    hint "actual:   ${actual}"
    hint "If you intentionally refreshed the PEM, update TRIAL_PEM_SHA256_EXPECTED in lib/preflight.sh"
    return 1
  fi
}

# --- 9. License env vars (Ledger and Auditor get SEPARATE trial keys per --
# Scalar Inc.'s license model: each token is signed for one product_name
# = "ScalarDL Ledger" or "ScalarDL Auditor". A Ledger token cannot
# authenticate the Auditor pod and vice versa).

check_license_env () {
  local have_specific=0 have_legacy=0
  [ -n "${E2E_LEDGER_LICENSE_KEY:-}" ]  && have_specific=$((have_specific + 1))
  [ -n "${E2E_AUDITOR_LICENSE_KEY:-}" ] && have_specific=$((have_specific + 1))
  [ -n "${E2E_LICENSE_KEY:-}" ]         && have_legacy=1

  if [ "${have_specific}" = "2" ]; then
    ok "E2E_LEDGER_LICENSE_KEY + E2E_AUDITOR_LICENSE_KEY both set (preferred)"
    return 0
  fi

  if [ "${have_specific}" = "1" ]; then
    if [ -z "${E2E_LEDGER_LICENSE_KEY:-}" ]; then
      ng "E2E_LEDGER_LICENSE_KEY is missing (E2E_AUDITOR_LICENSE_KEY alone is insufficient)"
    else
      ng "E2E_AUDITOR_LICENSE_KEY is missing — Auditor=Yes patterns (p5/p6/p8) will fail license check"
    fi
    hint "Set both:"
    hint "  export E2E_LEDGER_LICENSE_KEY='<Ledger trial token>'"
    hint "  export E2E_AUDITOR_LICENSE_KEY='<Auditor trial token>'"
    return 1
  fi

  if [ "${have_legacy}" = "1" ]; then
    ok "E2E_LICENSE_KEY set (legacy/single-token mode — assumed for both Ledger and Auditor)"
    hint "NOTE: Scalar Inc. issues SEPARATE trial keys per product. A single token works"
    hint "      only if your token's product_name matches both Ledger and Auditor (rare)."
    hint "      For Auditor=Yes patterns (p5/p6/p8), prefer setting:"
    hint "        export E2E_LEDGER_LICENSE_KEY='...'   E2E_AUDITOR_LICENSE_KEY='...'"
    return 0
  fi

  ng "no license env vars set (need E2E_LEDGER_LICENSE_KEY + E2E_AUDITOR_LICENSE_KEY, or legacy E2E_LICENSE_KEY)"
  hint "export E2E_LEDGER_LICENSE_KEY='<your-Ledger-trial-token-from-Scalar-Inc>'"
  hint "export E2E_AUDITOR_LICENSE_KEY='<your-Auditor-trial-token-from-Scalar-Inc>'"
  hint "(NEVER commit these values to git — keep them in a private env file)"
  return 1
}

# --- entrypoint --------------------------------------------------------------

run_preflight () {
  printf '%spreflight check (plan-009 W1):%s\n' "${CBOLD}" "${CRESET}"

  check_cfg_file        || true
  # If cfg file is broken, downstream checks that read it (scalardl_client path)
  # may still work with defaults — keep going.
  check_kubectl         || true
  if [ "${E2E_SKIP_TUNNEL_CHECK:-0}" = "1" ]; then
    ok "minikube tunnel check skipped (E2E_SKIP_TUNNEL_CHECK=1)"
  else
    check_minikube_tunnel || true
  fi
  check_helm            || true
  check_helm_repo       || true
  check_scalardl_client || true
  check_docker          || true
  check_trial_pem       || true
  check_license_env     || true

  printf '\n%spreflight: %d passed, %d failed%s\n' \
    "${CBOLD}" "${PREFLIGHT_PASSED}" "${PREFLIGHT_FAILED}" "${CRESET}"
}

# Allow direct invocation: `bash lib/preflight.sh`
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  run_preflight
  exit "${PREFLIGHT_FAILED}"
fi
