#!/usr/bin/env bash
# Teardown for one pattern's L3+ deployment.
#
# Plan reference: docs/plan-009-auto-e2e-test-harness.md W7.
#
# Removes everything install-pattern.sh provisioned:
#   - Helm releases (Ledger + Auditor + schema-loaders)
#   - Kubernetes namespace (deletes Secrets, PVCs, ConfigMaps along with it)
#   - Host Docker postgres containers (pg-ledger-<p>, pg-auditor-<p>)
#
# Idempotent: --ignore-not-found everywhere, swallows helm "release not found"
# and docker "no such container" errors. Safe to call on a partial install.
#
# Usage:
#   bash lib/teardown-pattern.sh <pattern-name>

set -uo pipefail

PATTERN_NAME="${1:?pattern name required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Per-pattern naming convention (mirrors install-pattern.sh):
NAMESPACE="${PATTERN_NAME}"
LEDGER_RELEASE="${PATTERN_NAME}-ledger"
AUDITOR_RELEASE="${PATTERN_NAME}-auditor"
LEDGER_SCHEMA_RELEASE="${LEDGER_RELEASE}-schema"
AUDITOR_SCHEMA_RELEASE="${AUDITOR_RELEASE}-schema"
PG_LEDGER_CONTAINER="pg-ledger-${PATTERN_NAME}"
PG_AUDITOR_CONTAINER="pg-auditor-${PATTERN_NAME}"

echo "Teardown for ${PATTERN_NAME}..."

# --- kill background port-forward (if any, from install-pattern.sh step 5b) ---
SCRIPT_DIR_TEARDOWN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR_TEARDOWN="$(cd "${SCRIPT_DIR_TEARDOWN}/.." && pwd)"
shopt -s nullglob
PF_PIDS=("${E2E_DIR_TEARDOWN}/e2e-runs"/*-L*/"${PATTERN_NAME}"/port-forward.pid)
for pf_pidfile in "${PF_PIDS[@]}"; do
  pf_pid="$(cat "${pf_pidfile}" 2>/dev/null)"
  if [ -n "${pf_pid}" ] && kill -0 "${pf_pid}" 2>/dev/null; then
    kill "${pf_pid}" 2>/dev/null && echo "  ✓ killed port-forward pid=${pf_pid}" || true
  fi
done
shopt -u nullglob

# --- helm uninstall ---
if command -v helm >/dev/null 2>&1; then
  for rel in "${LEDGER_RELEASE}" "${AUDITOR_RELEASE}" "${LEDGER_SCHEMA_RELEASE}" "${AUDITOR_SCHEMA_RELEASE}"; do
    helm uninstall "${rel}" -n "${NAMESPACE}" >/dev/null 2>&1 && echo "  ✓ helm uninstall ${rel}" || true
  done
fi

# --- delete namespace (drops Secrets, PVCs, ConfigMaps) ---
if command -v kubectl >/dev/null 2>&1; then
  if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found --timeout=120s >/dev/null 2>&1 && \
      echo "  ✓ kubectl delete ns ${NAMESPACE}" || \
      echo "  ! kubectl delete ns ${NAMESPACE} timed out or failed (manual cleanup may be needed)"
  fi
fi

# --- docker rm postgres containers (always last; ns may still be deleting) ---
if command -v docker >/dev/null 2>&1; then
  for c in "${PG_LEDGER_CONTAINER}" "${PG_AUDITOR_CONTAINER}"; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qE "^${c}\$"; then
      docker rm -f "${c}" >/dev/null 2>&1 && echo "  ✓ docker rm -f ${c}" || true
    fi
  done
fi

echo "Teardown done for ${PATTERN_NAME}."
