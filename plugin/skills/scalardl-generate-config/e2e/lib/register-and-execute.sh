#!/usr/bin/env bash
# L4 register + execute for one pattern.
#
# Plan reference: docs/plan-009-auto-e2e-test-harness.md W6 + D8.
#
# Preconditions:
#   - L3 install completed (lib/install-pattern.sh): Ledger/Auditor pods
#     Ready, env.sh written in bundle, admin properties placeholders sed-
#     patched with real LoadBalancer external IPs.
#   - scalardl-client SDK CLI on PATH (preflight check 6).
#   - bundle has sample/schema.json + sample/prebuilt/com/example/{contracts,
#     functions}/*.class (W3 artifacts).
#
# Steps (per plan-009 D8 + plan-010 client identity):
#   1. Pre-create smoke.smoke_assets in Ledger's host Docker postgres via
#      ghcr.io/scalar-labs/scalardb-schema-loader (docker run, --add-host
#      host.docker.internal:host-gateway for Linux compat).
#   2. register-cert (DS) or register-secret (HMAC) for the **admin** identity
#      on Ledger via ledger.as.client.properties; same on Auditor when
#      Auditor=Yes (admin runs register-contract / register-function).
#   2c. register-cert / register-secret for the **runtime client** identity
#       on Ledger via client.properties (plan-010 — separate entity for
#       execute-contract). For HMAC, client.properties has the
#       CLIENT_HMAC_SECRET_KEY already sed-patched by install-pattern.sh.
#   3. register-contract SmokeAsset on Ledger (+ Auditor when applicable) —
#      via admin identity (ledger.as.client.properties).
#   4. register-function SmokeAssetFunction on Ledger — via admin identity.
#   5. execute SmokeAsset with function-id SmokeAssetFunction via
#      **client.properties** (runtime client identity, plan-010).
#   6. Verify:
#        - execute exit 0
#        - response JSON has/lacks "proof" field per proofEnabled
#        - smoke.smoke_assets row count == 1 in Ledger's postgres
#
# Caveat (2026-05-11): scalardl-client CLI flags are based on the modern
# `scalardl <subcommand>` reference (docs/scalardl-command-reference.mdx).
# If your SDK is older (3.6.x style: scalardl-java-client-sdk/bin/...), flag
# names may differ — user feedback during W6 verification will refine these.

set -uo pipefail

PATTERN_NAME="${1:?pattern name required}"
BUNDLE_DIR="${2:?bundle dir required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILL_DIR="$(cd "${E2E_DIR}/.." && pwd)"

PATTERN_FILE="${E2E_DIR}/patterns/${PATTERN_NAME}.json"
CFG_FILE="${E2E_DIR}/e2e-config.local.json"
SAMPLE_DIR="${E2E_DIR}/sample"

# --- read pattern axes + config ----------------------------------------

ctx_bool () {
  python3 -c '
import json,sys
v = json.load(open(sys.argv[1])).get("context",{}).get(sys.argv[2], False)
print("true" if v else "false")
' "${PATTERN_FILE}" "$1"
}

AUDITOR="$(ctx_bool auditor)"
DS_PATTERN="$(ctx_bool dsPattern)"
HMAC_PATTERN="$(ctx_bool hmacPattern)"
PROOF_ENABLED="$(ctx_bool proofEnabled)"

SCALARDL_VERSION="3.13.0"
# scalardb-schema-loader image is from the ScalarDB project (NOT ScalarDL).
# Its tag matches the ScalarDB version that ScalarDL X.Y.Z internally depends
# on, NOT ScalarDL X.Y.Z. For ScalarDL 3.13.0, scalarDbVersion = 3.17.2
# (verified at ScalarDL Core commit aaefabb / `git show 3.13.0:build.gradle`).
SCALARDB_VERSION="3.17.2"
SCALARDL_CLIENT_BIN="scalardl"
SAMPLE_CONTRACT_CLASS="SmokeAsset"
SAMPLE_FUNCTION_CLASS="SmokeAssetFunction"
SAMPLE_ASSET_ID="smoke-asset-1"

if [ -f "${CFG_FILE}" ]; then
  SCALARDL_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("scalardlSdkVersion","3.13.0"))' "${CFG_FILE}" 2>/dev/null || echo 3.13.0)"
  SCALARDB_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("scalardbSchemaLoaderVersion","3.17.2"))' "${CFG_FILE}" 2>/dev/null || echo 3.17.2)"
  SCALARDL_CLIENT_BIN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("scalardlClientBinPath","scalardl"))' "${CFG_FILE}" 2>/dev/null || echo scalardl)"
  SAMPLE_CONTRACT_CLASS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sampleContractClassName","SmokeAsset"))' "${CFG_FILE}" 2>/dev/null || echo SmokeAsset)"
  SAMPLE_FUNCTION_CLASS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sampleFunctionClassName","SmokeAssetFunction"))' "${CFG_FILE}" 2>/dev/null || echo SmokeAssetFunction)"
  SAMPLE_ASSET_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sampleAssetId","smoke-asset-1"))' "${CFG_FILE}" 2>/dev/null || echo smoke-asset-1)"
fi

CONTRACT_ID="${SAMPLE_CONTRACT_CLASS}"
FUNCTION_ID="${SAMPLE_FUNCTION_CLASS}"
CONTRACT_CLASS_FQN="com.example.contracts.${SAMPLE_CONTRACT_CLASS}"
FUNCTION_CLASS_FQN="com.example.functions.${SAMPLE_FUNCTION_CLASS}"
CONTRACT_CLASS_FILE="${SAMPLE_DIR}/prebuilt/com/example/contracts/${SAMPLE_CONTRACT_CLASS}.class"
FUNCTION_CLASS_FILE="${SAMPLE_DIR}/prebuilt/com/example/functions/${SAMPLE_FUNCTION_CLASS}.class"

[ -f "${CONTRACT_CLASS_FILE}" ] || { echo "ERROR: Contract .class missing: ${CONTRACT_CLASS_FILE}" >&2; exit 2; }
[ -f "${FUNCTION_CLASS_FILE}" ] || { echo "ERROR: Function .class missing: ${FUNCTION_CLASS_FILE}" >&2; exit 2; }

# Source env.sh from bundle (DB credentials etc.)
# shellcheck source=/dev/null
source "${BUNDLE_DIR}/env.sh"

LOG_PREFIX="${BUNDLE_DIR}/l4"
mkdir -p "${LOG_PREFIX}"

# --- step 1: pre-create smoke.smoke_assets in Ledger's postgres --------

echo "[L4] Step 1: scalardb-schema-loader smoke schema (Ledger postgres)..."

TMP_SCHEMA_DIR="$(mktemp -d -t scalardl-e2e-schema-XXXX)"
trap '[ -d "${TMP_SCHEMA_DIR}" ] && rm -rf "${TMP_SCHEMA_DIR}"' EXIT

# mktemp's default 0700 perms block reads from the docker container's non-root
# user (the scalardb-schema-loader image runs as a non-root UID, yielding
# AccessDeniedException on /work/*). Open up read perms on the dir + files.
chmod 755 "${TMP_SCHEMA_DIR}"

cp "${SAMPLE_DIR}/schema.json" "${TMP_SCHEMA_DIR}/schema.json"
cat > "${TMP_SCHEMA_DIR}/scalardb.properties" <<EOF
scalar.db.contact_points=jdbc:postgresql://host.docker.internal:5432/ledger
scalar.db.username=${LEDGER_DB_USERNAME}
scalar.db.password=${LEDGER_DB_PASSWORD}
scalar.db.storage=jdbc
EOF
chmod 644 "${TMP_SCHEMA_DIR}/schema.json" "${TMP_SCHEMA_DIR}/scalardb.properties"

if ! docker run --rm \
    --add-host=host.docker.internal:host-gateway \
    -v "${TMP_SCHEMA_DIR}:/work:ro" \
    "ghcr.io/scalar-labs/scalardb-schema-loader:${SCALARDB_VERSION}" \
    --config /work/scalardb.properties \
    --schema-file /work/schema.json \
    > "${LOG_PREFIX}/01-scalardb-schema-loader-ledger.log" 2>&1; then
  echo "ERROR: scalardb-schema-loader failed for Ledger. See ${LOG_PREFIX}/01-scalardb-schema-loader-ledger.log" >&2
  tail -30 "${LOG_PREFIX}/01-scalardb-schema-loader-ledger.log" >&2 || true
  exit 1
fi
echo "  ✓ smoke.smoke_assets created in Ledger postgres"

# --- step 2: register-cert / register-secret ---------------------------

# scalardl CLI must run from inside BUNDLE_DIR because the properties files
# reference cert paths as ./cert/ledger-cert.pem / ./cert/client-cert.pem etc.
# (relative). Switch cwd now; commands below issue absolute paths for
# properties + class files.
cd "${BUNDLE_DIR}"

LEDGER_PROPS="${BUNDLE_DIR}/ledger.as.client.properties"
AUDITOR_PROPS="${BUNDLE_DIR}/auditor.as.client.properties"
CLIENT_PROPS="${BUNDLE_DIR}/client.properties"

# Pre-flight: ensure placeholders were sed-patched in ACTIVE (non-comment) lines.
# `<LEDGER_EXTERNAL_IP>` appears in How-to comments of the rendered properties
# files (legitimately, as documentation); only un-substituted occurrences on
# active lines indicate a missing sed.
__has_active_placeholder () {
  local file="$1" placeholder="$2"
  grep -vE '^[[:space:]]*#' "${file}" | grep -q "${placeholder}"
}

if __has_active_placeholder "${LEDGER_PROPS}" "<LEDGER_EXTERNAL_IP>"; then
  echo "ERROR: ledger.as.client.properties still has <LEDGER_EXTERNAL_IP> placeholder (non-comment line)." >&2
  echo "       install-pattern.sh should have sed-patched this — was external IP not retrieved?" >&2
  exit 1
fi
# plan-010: client.properties must also be sed-patched.
if [ ! -f "${CLIENT_PROPS}" ]; then
  echo "ERROR: client.properties not found (plan-010 — should be emitted by skill)." >&2
  exit 1
fi
if __has_active_placeholder "${CLIENT_PROPS}" "<LEDGER_EXTERNAL_IP>"; then
  echo "ERROR: client.properties still has <LEDGER_EXTERNAL_IP> placeholder (non-comment line)." >&2
  echo "       install-pattern.sh should have sed-patched this for client.properties too." >&2
  exit 1
fi
# plan-010: HMAC pattern's client.properties must have CLIENT_HMAC_SECRET_KEY replaced.
if [ "${HMAC_PATTERN}" = "true" ] && __has_active_placeholder "${CLIENT_PROPS}" "<CLIENT_HMAC_SECRET_KEY>"; then
  echo "ERROR: client.properties still has <CLIENT_HMAC_SECRET_KEY> placeholder (non-comment line)." >&2
  echo "       install-pattern.sh should have generated + sed-patched this." >&2
  exit 1
fi

if [ "${DS_PATTERN}" = "true" ]; then
  REGISTER_CMD="register-cert"
else
  REGISTER_CMD="register-secret"
fi

echo "[L4] Step 2: ${REGISTER_CMD} for Ledger Server entity (one-time, via ledger.as.client.properties)..."
if ! "${SCALARDL_CLIENT_BIN}" "${REGISTER_CMD}" --properties "${LEDGER_PROPS}" \
    > "${LOG_PREFIX}/02-${REGISTER_CMD}-ledger-server.log" 2>&1; then
  echo "ERROR: ${REGISTER_CMD} for Ledger Server entity failed. See ${LOG_PREFIX}/02-${REGISTER_CMD}-ledger-server.log" >&2
  tail -30 "${LOG_PREFIX}/02-${REGISTER_CMD}-ledger-server.log" >&2 || true
  exit 1
fi
echo "  ✓ ${REGISTER_CMD} for Ledger Server entity succeeded"

if [ "${AUDITOR}" = "true" ]; then
  echo "[L4] Step 2b: ${REGISTER_CMD} for Auditor Server entity (one-time, via auditor.as.client.properties)..."
  if ! "${SCALARDL_CLIENT_BIN}" "${REGISTER_CMD}" --properties "${AUDITOR_PROPS}" \
      > "${LOG_PREFIX}/02b-${REGISTER_CMD}-auditor-server.log" 2>&1; then
    echo "ERROR: ${REGISTER_CMD} for Auditor Server entity failed. See ${LOG_PREFIX}/02b-${REGISTER_CMD}-auditor-server.log" >&2
    tail -30 "${LOG_PREFIX}/02b-${REGISTER_CMD}-auditor-server.log" >&2 || true
    exit 1
  fi
  echo "  ✓ ${REGISTER_CMD} for Auditor Server entity succeeded"
fi

# 3-entity model: register the runtime client identity (this is the entity that
# will OWN the Contracts/Functions and CALL execute-contract).
echo "[L4] Step 2c: ${REGISTER_CMD} for runtime client entity (via client.properties)..."
if ! "${SCALARDL_CLIENT_BIN}" "${REGISTER_CMD}" --properties "${CLIENT_PROPS}" \
    > "${LOG_PREFIX}/02c-${REGISTER_CMD}-client.log" 2>&1; then
  echo "ERROR: ${REGISTER_CMD} for client entity failed. See ${LOG_PREFIX}/02c-${REGISTER_CMD}-client.log" >&2
  tail -30 "${LOG_PREFIX}/02c-${REGISTER_CMD}-client.log" >&2 || true
  exit 1
fi
echo "  ✓ ${REGISTER_CMD} for client entity succeeded"

# --- step 3: register-contract (via client.properties — Contracts are
#             entity-scoped per ScalarDL ContractEntry.Key, so the executing
#             entity must self-register). When Auditor=Yes, the client SDK has
#             auditor.enabled=true and a single register-contract is fanned
#             out by the SDK to both Ledger and Auditor (DefaultClient-
#             ServiceHandler.registerCertificate at L58-61 / equivalent for
#             register-contract). ---------------------------------------

echo "[L4] Step 3: register-contract ${CONTRACT_ID} (via client.properties)..."
if ! "${SCALARDL_CLIENT_BIN}" register-contract --properties "${CLIENT_PROPS}" \
    --contract-id "${CONTRACT_ID}" \
    --contract-binary-name "${CONTRACT_CLASS_FQN}" \
    --contract-class-file "${CONTRACT_CLASS_FILE}" \
    > "${LOG_PREFIX}/03-register-contract-client.log" 2>&1; then
  echo "ERROR: register-contract via client failed. See ${LOG_PREFIX}/03-register-contract-client.log" >&2
  tail -30 "${LOG_PREFIX}/03-register-contract-client.log" >&2 || true
  exit 1
fi
echo "  ✓ register-contract succeeded"

# Auditor=Yes: no separate Auditor-side register-contract needed — the SDK
# cross-validates against the Auditor on every privileged call when
# scalar.dl.client.auditor.enabled=true in client.properties.
if false; then
  : "(Auditor=Yes: register-contract is fanned out by the SDK to both Ledger and Auditor when auditor.enabled=true)"
fi

# --- step 4: register-function (via client.properties — Functions are global
#             in ScalarDL, FunctionEntry has no entityId in its Key, but we
#             still register via the client identity for consistency with the
#             3-entity model). ----------------------------------------------

echo "[L4] Step 4: register-function ${FUNCTION_ID} (via client.properties)..."
if ! "${SCALARDL_CLIENT_BIN}" register-function --properties "${CLIENT_PROPS}" \
    --function-id "${FUNCTION_ID}" \
    --function-binary-name "${FUNCTION_CLASS_FQN}" \
    --function-class-file "${FUNCTION_CLASS_FILE}" \
    > "${LOG_PREFIX}/04-register-function-client.log" 2>&1; then
  echo "ERROR: register-function failed. See ${LOG_PREFIX}/04-register-function-client.log" >&2
  tail -30 "${LOG_PREFIX}/04-register-function-client.log" >&2 || true
  exit 1
fi
echo "  ✓ register-function succeeded"

# --- step 5: execute Contract + Function -------------------------------

EXECUTE_ARG="$(python3 -c 'import json,sys; print(json.dumps({"asset_id": sys.argv[1], "data": {"v": 1}}))' "${SAMPLE_ASSET_ID}")"

echo "[L4] Step 5: execute-contract ${CONTRACT_ID} with function-id ${FUNCTION_ID} (client identity, plan-010)..."
echo "  argument: ${EXECUTE_ARG}"

# plan-010: execute-contract uses the *runtime client* identity (client.properties),
# not the admin identity. When Auditor=Yes, client.properties has
# auditor.enabled=true so the SDK cross-validates against the Auditor automatically.
if ! "${SCALARDL_CLIENT_BIN}" execute-contract --properties "${CLIENT_PROPS}" \
    --contract-id "${CONTRACT_ID}" \
    --contract-argument "${EXECUTE_ARG}" \
    --function-id "${FUNCTION_ID}" \
    > "${LOG_PREFIX}/05-execute.log" 2>&1; then
  echo "ERROR: execute-contract failed. See ${LOG_PREFIX}/05-execute.log" >&2
  tail -40 "${LOG_PREFIX}/05-execute.log" >&2 || true
  exit 1
fi
echo "  ✓ execute-contract (client identity) exit 0"

# --- step 6: verify --------------------------------------------------

echo "[L4] Step 6: invariant checks..."

# NOTE: ContractExecution.java (scalardl 3.13.0) prints only "Contract result:" /
# "Function result:" JSON to stdout — AssetProofs are returned via the SDK's
# ContractExecutionResult.getLedgerProofs() but NOT printed by the CLI. So a
# stdout grep for "proof" is not a reliable invariant. To verify the
# proof.enabled difference between patterns, inspect Ledger pod logs or use
# `scalardl validate-ledger`. For W6 v1, we just assert execute-contract
# exited 0 and the Function's row landed in ScalarDB.

# 6a: ScalarDB business row (Function output)
PG_LEDGER_CONTAINER="pg-ledger-${PATTERN_NAME}"
ROW_COUNT="$(docker exec "${PG_LEDGER_CONTAINER}" \
  psql -U postgres -d ledger -At \
       -c "SELECT count(*) FROM smoke.smoke_assets WHERE asset_id='${SAMPLE_ASSET_ID}';" 2>/dev/null || echo 0)"

if [ "${ROW_COUNT}" = "1" ]; then
  echo "  ✓ ScalarDB row count: smoke.smoke_assets has 1 row for asset_id=${SAMPLE_ASSET_ID}"
else
  echo "  ✗ ScalarDB row count: expected 1, got ${ROW_COUNT}" >&2
  exit 1
fi

# 6b: proofEnabled difference is NOT asserted from CLI stdout (see NOTE above).
if [ "${PROOF_ENABLED}" = "true" ]; then
  echo "  ⚠ proof.enabled=true: AssetProofs presence is set by helm values; verify via kubectl logs of Ledger pod or 'scalardl validate-ledger' (W6 v1 does not assert this from CLI stdout)"
else
  echo "  ⚠ proof.enabled=false: similar caveat, no stdout signal"
fi

echo "[L4] L4 complete for ${PATTERN_NAME}."
