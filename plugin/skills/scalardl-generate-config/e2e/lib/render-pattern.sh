#!/usr/bin/env bash
# Render a single pattern's bundle into <output-dir>/scalardl-config/.
#
# Plan reference: docs/plan-009-auto-e2e-test-harness.md W2.
#
# Usage:
#   bash lib/render-pattern.sh <pattern-name> <output-dir>
#
# Example:
#   bash lib/render-pattern.sh p1-noauditor-ds-proof-envoy /tmp/scalardl-e2e/run-foo/p1-noauditor-ds-proof-envoy
#
# Side effects:
#   - Mkdir <output-dir>/scripts and (when licensing) <output-dir>/license-pem
#   - Render every applicable template through smoke/render.py with a context
#     built from lib/defaults.json + patterns/<name>.json
#   - Print rendered file paths
#
# Static checks (yaml parse, properties parse, bash -n, credential invariant,
# boolean lowercase, etc.) are run separately by lib/static-checks.sh, sourced
# from run.sh after render.

set -uo pipefail

PATTERN_NAME="${1:?pattern name required (e.g. p1-noauditor-ds-proof-envoy)}"
OUTPUT_DIR="${2:?output directory required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILL_DIR="$(cd "${E2E_DIR}/.." && pwd)"

RENDER_PY="${SKILL_DIR}/smoke/render.py"
TMPL_DIR="${SKILL_DIR}/templates"
DEFAULTS_FILE="${SCRIPT_DIR}/defaults.json"
PATTERN_FILE="${E2E_DIR}/patterns/${PATTERN_NAME}.json"

# --- input validation -----------------------------------------------------

[ -f "${RENDER_PY}" ]      || { echo "ERROR: render.py missing at ${RENDER_PY}" >&2; exit 2; }
[ -f "${DEFAULTS_FILE}" ]  || { echo "ERROR: defaults.json missing at ${DEFAULTS_FILE}" >&2; exit 2; }
[ -f "${PATTERN_FILE}" ]   || { echo "ERROR: pattern ${PATTERN_NAME} not found at ${PATTERN_FILE}" >&2; exit 2; }

# --- build merged Mustache context ----------------------------------------

# Defaults + pattern.context + generatedAt + namespace fields (= pattern name)
# are merged into a single JSON; rendered output goes to OUTPUT_DIR.
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

CONTEXT_JSON="$(python3 - "${DEFAULTS_FILE}" "${PATTERN_FILE}" "${PATTERN_NAME}" "${GENERATED_AT}" <<'PYEOF'
import json, sys
defaults_path, pattern_path, namespace, generated_at = sys.argv[1:5]

with open(defaults_path) as f:
    ctx = {k: v for k, v in json.load(f).items() if not k.startswith("_comment")}

with open(pattern_path) as f:
    p = json.load(f)

ctx.update(p.get("context", {}))
ctx["ledgerNamespace"]      = namespace
ctx["auditorNamespace"]     = namespace
ctx["kubernetesNamespace"]  = namespace
ctx["generatedAt"]          = generated_at

print(json.dumps(ctx))
PYEOF
)"

if [ -z "${CONTEXT_JSON}" ]; then
  echo "ERROR: failed to build merged context for ${PATTERN_NAME}" >&2
  exit 2
fi

# --- output dirs ----------------------------------------------------------

mkdir -p "${OUTPUT_DIR}/scripts"

# --- render helpers -------------------------------------------------------

# render <tmpl-relative-to-TMPL_DIR> <out-relative-to-OUTPUT_DIR>
render () {
  local tmpl="${TMPL_DIR}/$1"
  local outfile="${OUTPUT_DIR}/$2"
  if [ ! -f "${tmpl}" ]; then
    echo "ERROR: template missing: ${tmpl}" >&2
    return 2
  fi
  python3 "${RENDER_PY}" "${tmpl}" "${CONTEXT_JSON}" > "${outfile}"
  echo "  rendered: $2"
}

ctx_bool () {
  # Echo "true" or "false" for a top-level boolean in CONTEXT_JSON.
  python3 -c '
import json, sys
v = json.loads(sys.argv[1]).get(sys.argv[2], False)
print("true" if v else "false")
' "${CONTEXT_JSON}" "$1"
}

ctx_str () {
  python3 -c '
import json, sys
print(json.loads(sys.argv[1]).get(sys.argv[2], ""))
' "${CONTEXT_JSON}" "$1"
}

# --- decide which optional files render -----------------------------------

AUDITOR="$(ctx_bool auditor)"
DS_PATTERN="$(ctx_bool dsPattern)"
HMAC_PATTERN="$(ctx_bool hmacPattern)"
PROOF_ENABLED="$(ctx_bool proofEnabled)"
LICENSING="$(ctx_bool licensing)"
LICENSE_TYPE="$(ctx_str licenseType)"

# --- always-rendered ------------------------------------------------------

render "values/scalardl-ledger-custom-values.yaml.tmpl"           "scalardl-ledger-custom-values.yaml"
render "values/schema-loader-ledger-custom-values.yaml.tmpl"      "schema-loader-ledger-custom-values.yaml"
render "properties/ledger.as.client.properties.tmpl"              "ledger.as.client.properties"
render "properties/client.properties.tmpl"                        "client.properties"

render "scripts/create-scalardl-secrets.sh.tmpl"                  "scripts/create-scalardl-secrets.sh"
render "scripts/env-template.sh.tmpl"                             "scripts/env-template.sh"
render "scripts/init-schemas.sh.tmpl"                             "scripts/init-schemas.sh"
render "scripts/start-scalardl.sh.tmpl"                           "scripts/start-scalardl.sh"
render "scripts/stop-scalardl.sh.tmpl"                            "scripts/stop-scalardl.sh"

# --- auditor-side ---------------------------------------------------------

if [ "${AUDITOR}" = "true" ]; then
  render "values/scalardl-auditor-custom-values.yaml.tmpl"        "scalardl-auditor-custom-values.yaml"
  render "values/schema-loader-auditor-custom-values.yaml.tmpl"   "schema-loader-auditor-custom-values.yaml"
  render "properties/auditor.as.client.properties.tmpl"           "auditor.as.client.properties"
fi

# --- PKI generation script (DS only, or HMAC+standalone+proof corner) -----

NEED_PKI_SCRIPT="false"
if [ "${DS_PATTERN}" = "true" ]; then
  NEED_PKI_SCRIPT="true"
elif [ "${HMAC_PATTERN}" = "true" ] && [ "${PROOF_ENABLED}" = "true" ]; then
  # Both standalone (Auditor=No) and Auditor=Yes need DS PKI when proof.enabled
  # — AssetProof signing falls back to DS in both cases.
  NEED_PKI_SCRIPT="true"
fi
if [ "${NEED_PKI_SCRIPT}" = "true" ]; then
  render "scripts/generate-server-pki.sh.tmpl"                    "scripts/generate-server-pki.sh"
fi

# --- bundled license PEM (copy, not render) -------------------------------

if [ "${LICENSING}" = "true" ]; then
  mkdir -p "${OUTPUT_DIR}/license-pem"
  cp "${SKILL_DIR}/references/license-pem/${LICENSE_TYPE}-cert.pem" \
     "${OUTPUT_DIR}/license-pem/${LICENSE_TYPE}-cert.pem"
  echo "  copied:   license-pem/${LICENSE_TYPE}-cert.pem"
fi

# --- chmod scripts --------------------------------------------------------

find "${OUTPUT_DIR}/scripts" -name "*.sh" -exec chmod +x {} +

echo "  done — pattern ${PATTERN_NAME} rendered to ${OUTPUT_DIR}"
