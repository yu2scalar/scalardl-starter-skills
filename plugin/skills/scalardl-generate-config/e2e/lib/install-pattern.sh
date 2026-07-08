#!/usr/bin/env bash
# L3 helm install for one pattern.
#
# Plan reference: docs/plan-009-auto-e2e-test-harness.md W5 + D11 + D12.
#
# Usage:
#   bash lib/install-pattern.sh <pattern-name> <bundle-dir>
#
# Behaviour:
#   1. Best-effort cleanup of any prior run of this pattern (idempotent).
#   2. Start host Docker postgres container(s):
#        always         pg-ledger-<pattern>   on host port 5432 / db "ledger"
#        auditor=true   pg-auditor-<pattern>  on host port 5433 / db "auditor"
#      Per D12, two separate containers when Auditor=Yes (independent fault
#      domains).
#   3. Write env.sh next to the bundle with DB credentials + license key
#      (sourced from $E2E_LICENSE_KEY). HMAC keys are left empty so
#      start-scalardl.sh auto-generates them via `openssl rand`.
#   4. cd into bundle dir and run:
#        bash scripts/init-schemas.sh
#        bash scripts/start-scalardl.sh
#   5. For envoy-loadbalancer patterns, wait up to 60s for the LoadBalancer
#      external IP and sed-patch ledger.as.client.properties /
#      auditor.as.client.properties to replace the placeholder.
#
# Exit 0 on success (Server pods Ready); non-zero on any failure. Teardown
# on failure is the caller's responsibility (run.sh installs an EXIT trap
# unless --no-cleanup is given).

set -uo pipefail

PATTERN_NAME="${1:?pattern name required}"
BUNDLE_DIR="${2:?bundle dir required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PATTERN_FILE="${E2E_DIR}/patterns/${PATTERN_NAME}.json"
[ -f "${PATTERN_FILE}" ] || { echo "ERROR: pattern not found: ${PATTERN_FILE}" >&2; exit 2; }
[ -d "${BUNDLE_DIR}" ]   || { echo "ERROR: bundle dir not found: ${BUNDLE_DIR}" >&2; exit 2; }

# Per-pattern naming (mirrors teardown-pattern.sh)
NAMESPACE="${PATTERN_NAME}"
PG_LEDGER_CONTAINER="pg-ledger-${PATTERN_NAME}"
PG_AUDITOR_CONTAINER="pg-auditor-${PATTERN_NAME}"

# --- read pattern axes --------------------------------------------------

AUDITOR="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("context",{}).get("auditor", False))' "${PATTERN_FILE}")"
HMAC_PATTERN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("context",{}).get("hmacPattern", False))' "${PATTERN_FILE}")"
ENVOY_LB="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("context",{}).get("envoyLoadBalancer", False))' "${PATTERN_FILE}")"

# --- step 1: best-effort cleanup (idempotent) ---------------------------

echo "[install-pattern] Pre-install cleanup of any prior ${PATTERN_NAME} run..."
bash "${SCRIPT_DIR}/teardown-pattern.sh" "${PATTERN_NAME}" || true

# --- step 2: postgres container(s) --------------------------------------

# Read postgresDockerImage from e2e-config.local.json, fall back to postgres:15.
CFG_FILE="${E2E_DIR}/e2e-config.local.json"
PG_IMAGE="postgres:15"
if [ -f "${CFG_FILE}" ]; then
  PG_IMAGE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("postgresDockerImage","postgres:15"))' "${CFG_FILE}" 2>/dev/null || echo postgres:15)"
fi

# Random per-pattern password (kept in env.sh, never committed).
PG_LEDGER_PASSWORD="$(openssl rand -hex 16)"
PG_AUDITOR_PASSWORD="$(openssl rand -hex 16)"

echo "[install-pattern] Starting host Docker postgres for Ledger (port 5432, db=ledger, image=${PG_IMAGE})..."
docker run -d \
  --name "${PG_LEDGER_CONTAINER}" \
  -e POSTGRES_PASSWORD="${PG_LEDGER_PASSWORD}" \
  -e POSTGRES_DB=ledger \
  -p 5432:5432 \
  "${PG_IMAGE}" >/dev/null

if [ "${AUDITOR}" = "True" ] || [ "${AUDITOR}" = "true" ]; then
  echo "[install-pattern] Starting host Docker postgres for Auditor (port 5433, db=auditor)..."
  docker run -d \
    --name "${PG_AUDITOR_CONTAINER}" \
    -e POSTGRES_PASSWORD="${PG_AUDITOR_PASSWORD}" \
    -e POSTGRES_DB=auditor \
    -p 5433:5432 \
    "${PG_IMAGE}" >/dev/null
fi

# Wait pg_isready (up to 60s each)
__wait_pg () {
  local container="$1" host_port="$2"
  local i
  for i in $(seq 1 30); do
    if docker exec "${container}" pg_isready -U postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "ERROR: ${container} did not become ready in 60s" >&2
  docker logs --tail=30 "${container}" >&2 || true
  return 1
}

__wait_pg "${PG_LEDGER_CONTAINER}" 5432 || exit 1
if [ "${AUDITOR}" = "True" ] || [ "${AUDITOR}" = "true" ]; then
  __wait_pg "${PG_AUDITOR_CONTAINER}" 5433 || exit 1
fi

# --- step 3: write env.sh -----------------------------------------------

# Resolve per-Server license keys with backward-compat:
#   prefer specific (E2E_{LEDGER,AUDITOR}_LICENSE_KEY) → fallback to single
#   E2E_LICENSE_KEY → error.
# Per Scalar Inc.'s license model, Ledger and Auditor get SEPARATE trial
# tokens (signed for product_name = "ScalarDL Ledger" / "ScalarDL Auditor"
# respectively). Using one Ledger token for the Auditor pod will fail the
# Auditor pod's startup license check.
RESOLVED_LEDGER_LICENSE_KEY="${E2E_LEDGER_LICENSE_KEY:-${E2E_LICENSE_KEY:-}}"
RESOLVED_AUDITOR_LICENSE_KEY="${E2E_AUDITOR_LICENSE_KEY:-${E2E_LICENSE_KEY:-}}"

if [ -z "${RESOLVED_LEDGER_LICENSE_KEY}" ]; then
  echo "ERROR: no Ledger license token available." >&2
  echo "       Set either:" >&2
  echo "         export E2E_LEDGER_LICENSE_KEY='<Ledger trial token>'" >&2
  echo "         export E2E_AUDITOR_LICENSE_KEY='<Auditor trial token>'   (when Auditor=Yes)" >&2
  echo "       or the single legacy:" >&2
  echo "         export E2E_LICENSE_KEY='<token>'   (used for both — Auditor patterns will likely fail)" >&2
  exit 1
fi

if [ "${AUDITOR}" = "True" ] || [ "${AUDITOR}" = "true" ]; then
  if [ -z "${RESOLVED_AUDITOR_LICENSE_KEY}" ]; then
    echo "ERROR: pattern ${PATTERN_NAME} has Auditor=Yes but no Auditor license token." >&2
    echo "       Set E2E_AUDITOR_LICENSE_KEY (preferred) or E2E_LICENSE_KEY (fallback)." >&2
    exit 1
  fi
  if [ -z "${E2E_AUDITOR_LICENSE_KEY:-}" ] && [ -n "${E2E_LICENSE_KEY:-}" ]; then
    echo "WARNING: using E2E_LICENSE_KEY as Auditor token (fallback)." >&2
    echo "         Auditor pod will likely fail license check unless this token's product_name == 'ScalarDL Auditor'." >&2
    echo "         Recommend setting E2E_AUDITOR_LICENSE_KEY separately." >&2
  fi
fi

ENV_SH="${BUNDLE_DIR}/env.sh"
cat > "${ENV_SH}" <<EOF
#!/usr/bin/env bash
# Generated by lib/install-pattern.sh for ${PATTERN_NAME}.
# Sourced by start-scalardl.sh / init-schemas.sh in this bundle.

export NAMESPACE="${NAMESPACE}"
export SCALARDL_VERSION="\${SCALARDL_VERSION:-3.13.0}"

# License keys (per-Server tokens from E2E_{LEDGER,AUDITOR}_LICENSE_KEY)
export LEDGER_LICENSE_KEY='${RESOLVED_LEDGER_LICENSE_KEY}'
export AUDITOR_LICENSE_KEY='${RESOLVED_AUDITOR_LICENSE_KEY}'

# Auto-load LICENSE_CHECK_CERT_PEM from bundled PEM with ACTUAL newlines
# (literal-\\n form broke the Auditor's X509 parser — see env-template.sh
# comment in the skill template).
if [ -z "\${LICENSE_CHECK_CERT_PEM:-}" ] && [ -f ./license-pem/trial-cert.pem ]; then
  export LICENSE_CHECK_CERT_PEM="\$(cat ./license-pem/trial-cert.pem)"
fi

# Backend DB credentials (host Docker postgres started by install-pattern.sh)
export LEDGER_DB_USERNAME=postgres
export LEDGER_DB_PASSWORD='${PG_LEDGER_PASSWORD}'
EOF

if [ "${AUDITOR}" = "True" ] || [ "${AUDITOR}" = "true" ]; then
  cat >> "${ENV_SH}" <<EOF
export AUDITOR_DB_USERNAME=postgres
export AUDITOR_DB_PASSWORD='${PG_AUDITOR_PASSWORD}'
EOF
fi

# HMAC keys: leave empty; start-scalardl.sh openssl rands them.

chmod +x "${ENV_SH}" || true
echo "[install-pattern] env.sh written: ${ENV_SH}"

# --- step 4: run init-schemas.sh + start-scalardl.sh --------------------

# Run from inside bundle dir (the lifecycle scripts assume bundle root = cwd).
pushd "${BUNDLE_DIR}" >/dev/null

echo "[install-pattern] Running init-schemas.sh..."
if ! bash scripts/init-schemas.sh > install-init-schemas.log 2>&1; then
  echo "ERROR: init-schemas.sh failed for ${PATTERN_NAME}. See ${BUNDLE_DIR}/install-init-schemas.log" >&2
  tail -30 install-init-schemas.log >&2 || true
  popd >/dev/null
  exit 1
fi

echo "[install-pattern] Running start-scalardl.sh..."
if ! bash scripts/start-scalardl.sh > install-start-scalardl.log 2>&1; then
  echo "ERROR: start-scalardl.sh failed for ${PATTERN_NAME}. See ${BUNDLE_DIR}/install-start-scalardl.log" >&2
  tail -50 install-start-scalardl.log >&2 || true
  popd >/dev/null
  exit 1
fi

popd >/dev/null

# --- step 5: external IP retrieval + sed-patch (envoy-loadbalancer only) -
#
# plan-010 (2026-05-11): also patch <LEDGER_EXTERNAL_IP> / <AUDITOR_EXTERNAL_IP>
# in client.properties (the runtime client config used by execute-contract).

if [ "${ENVOY_LB}" = "True" ] || [ "${ENVOY_LB}" = "true" ]; then
  echo "[install-pattern] Waiting for Envoy LoadBalancer external IP..."

  # Derive release names from the rendered start-scalardl.sh (Mustache-baked
  # LEDGER_RELEASE / AUDITOR_RELEASE, default scalardl-ledger / scalardl-audit
  # but user-customisable via A4a / A4d).
  LEDGER_RELEASE="$(grep -E '^LEDGER_RELEASE=' "${BUNDLE_DIR}/scripts/start-scalardl.sh" | head -1 | sed -E 's/^LEDGER_RELEASE="?([^"]*)"?$/\1/')"
  [ -n "${LEDGER_RELEASE}" ] || LEDGER_RELEASE="scalardl-ledger"
  AUDITOR_RELEASE="$(grep -E '^AUDITOR_RELEASE=' "${BUNDLE_DIR}/scripts/start-scalardl.sh" | head -1 | sed -E 's/^AUDITOR_RELEASE="?([^"]*)"?$/\1/')"
  [ -n "${AUDITOR_RELEASE}" ] || AUDITOR_RELEASE="scalardl-audit"

  __get_external_ip () {
    local svc="$1"
    kubectl get svc "${svc}" -n "${NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null
  }

  __wait_external_ip () {
    local svc="$1" i ip
    for i in $(seq 1 30); do
      ip=$(__get_external_ip "${svc}")
      if [ -n "${ip}" ] && [ "${ip}" != "<pending>" ]; then
        echo "${ip}"
        return 0
      fi
      sleep 2
    done
    return 1
  }

  LEDGER_IP=$(__wait_external_ip "${LEDGER_RELEASE}-envoy") || {
    echo "ERROR: Ledger Envoy LoadBalancer did not get an external IP in 60s" >&2
    echo "       minikube tunnel running? Service expected: ${LEDGER_RELEASE}-envoy in ns ${NAMESPACE}" >&2
    exit 1
  }
  echo "  Ledger external IP: ${LEDGER_IP}"

  AUDITOR_IP=""
  if [ "${AUDITOR}" = "True" ] || [ "${AUDITOR}" = "true" ]; then
    AUDITOR_IP=$(__wait_external_ip "${AUDITOR_RELEASE}-envoy") || {
      echo "ERROR: Auditor Envoy LoadBalancer did not get an external IP in 60s" >&2
      echo "       Service expected: ${AUDITOR_RELEASE}-envoy in ns ${NAMESPACE}" >&2
      exit 1
    }
    echo "  Auditor external IP: ${AUDITOR_IP}"
  fi

  # All three properties files (ledger.as.client / auditor.as.client / client)
  # use the SAME placeholders, since per the reference (~/dl/3.11.dsig) every
  # file connects to Ledger primarily and to Auditor for cross-validation when
  # Auditor=Yes. So we patch <LEDGER_EXTERNAL_IP> in all files, and
  # <AUDITOR_EXTERNAL_IP> in all files when Auditor=Yes. Each sed is a no-op
  # if its placeholder isn't present.
  for pf in "${BUNDLE_DIR}/ledger.as.client.properties" \
            "${BUNDLE_DIR}/auditor.as.client.properties" \
            "${BUNDLE_DIR}/client.properties"; do
    [ -f "${pf}" ] || continue
    sed -i "s/<LEDGER_EXTERNAL_IP>/${LEDGER_IP}/g" "${pf}"
    if [ -n "${AUDITOR_IP}" ]; then
      sed -i "s/<AUDITOR_EXTERNAL_IP>/${AUDITOR_IP}/g" "${pf}"
    fi
  done
fi

# --- step 5b: port-forward mode (envoyLoadBalancer=false) ----------------
#
# When envoy-loadbalancer is NOT used, the chart leaves envoy svc as ClusterIP
# (chart default), so we must `kubectl port-forward` to expose the Ledger
# Envoy on localhost. The rendered properties files have `server.host=localhost`
# baked in (no placeholder to sed). PF is started in background here, PID
# saved into env.sh; teardown-pattern.sh kills it.

if [ "${ENVOY_LB}" != "True" ] && [ "${ENVOY_LB}" != "true" ]; then
  echo "[install-pattern] envoy-loadbalancer=false — starting kubectl port-forward..."

  LEDGER_RELEASE="$(grep -E '^LEDGER_RELEASE=' "${BUNDLE_DIR}/scripts/start-scalardl.sh" | head -1 | sed -E 's/^LEDGER_RELEASE="?([^"]*)"?$/\1/')"
  [ -n "${LEDGER_RELEASE}" ] || LEDGER_RELEASE="scalardl-ledger"

  PF_LOG="${BUNDLE_DIR}/port-forward.log"
  # nohup detaches from this shell so the PF survives install-pattern.sh exit.
  nohup kubectl port-forward "svc/${LEDGER_RELEASE}-envoy" -n "${NAMESPACE}" \
      50051:50051 50052:50052 > "${PF_LOG}" 2>&1 &
  PF_PID=$!
  disown ${PF_PID} 2>/dev/null || true
  echo "${PF_PID}" > "${BUNDLE_DIR}/port-forward.pid"
  echo "[install-pattern] Ledger port-forward pid=${PF_PID} (log: ${PF_LOG})"

  # Wait for the local listener to come up.
  for i in $(seq 1 30); do
    if (echo > /dev/tcp/127.0.0.1/50051) 2>/dev/null; then
      echo "  ✓ Ledger port-forward ready on localhost:50051"
      break
    fi
    sleep 1
    if [ "$i" = "30" ]; then
      echo "ERROR: port-forward did not open localhost:50051 in 30s" >&2
      kill ${PF_PID} 2>/dev/null || true
      tail -20 "${PF_LOG}" >&2 || true
      exit 1
    fi
  done
fi

# --- step 6: HMAC pattern — generate + inject CLIENT_HMAC_SECRET_KEY (plan-010)
#
# client.properties (HMAC pattern) ships with a <CLIENT_HMAC_SECRET_KEY> placeholder
# that must be replaced with a random value before register-secret. We generate it
# here (same approach as start-scalardl.sh for the *server* HMAC keys) and write
# both the env var (for later reference) and the sed-patched client.properties.

if [ "${HMAC_PATTERN}" = "True" ] || [ "${HMAC_PATTERN}" = "true" ]; then
  if [ -f "${BUNDLE_DIR}/client.properties" ] && \
     grep -q '<CLIENT_HMAC_SECRET_KEY>' "${BUNDLE_DIR}/client.properties"; then
    CLIENT_HMAC_SECRET_KEY="$(openssl rand -base64 32)"
    sed -i "s|<CLIENT_HMAC_SECRET_KEY>|${CLIENT_HMAC_SECRET_KEY}|" "${BUNDLE_DIR}/client.properties"
    # Persist into env.sh for register-and-execute.sh to pass to register-secret
    cat >> "${ENV_SH}" <<EOF

# plan-010 runtime client HMAC secret (used by register-secret + execute-contract)
export CLIENT_HMAC_SECRET_KEY='${CLIENT_HMAC_SECRET_KEY}'
EOF
    echo "[install-pattern] CLIENT_HMAC_SECRET_KEY injected into client.properties + env.sh"
  fi
fi

# --- step 7: wait for envoy → backend gRPC health to settle ---------------
#
# `kubectl wait --for=condition=Ready` returns the moment pods report Ready,
# but envoy's gRPC health-check against the Ledger backend cluster runs on its
# own cadence and may briefly report "no healthy upstream" right after pods
# come up. Issuing register-cert/secret too early gets a
# `UNAVAILABLE: no healthy upstream` from envoy. A short settle delay before
# the L4 phase fixes this without depending on chart-internal probe details.

echo "[install-pattern] Waiting for envoy → backend gRPC health to settle (15s)..."
sleep 15

echo "[install-pattern] L3 install complete for ${PATTERN_NAME}."
