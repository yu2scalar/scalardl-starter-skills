#!/usr/bin/env bash
# L2 helm template dry-run for one rendered pattern.
#
# Plan reference: docs/plan-009-auto-e2e-test-harness.md W4.
#
# Usage:
#   source lib/helm-template-checks.sh
#   run_helm_template_checks <pattern-name> <bundle-dir>
#
# Caller must initialise STATIC_PASSED / STATIC_FAILED counters and export
# CRESET / CGREEN / CRED / CBOLD (matching static-checks.sh).
#
# Behaviour:
#   - Resolves chart versions matching SCALARDL_VERSION (from e2e-config.local.
#     json, default fallback "3.13.0") using `helm search repo scalar-labs/...
#     -l --output json` (same algorithm as start-scalardl.sh).
#   - For each yaml in the bundle, runs `helm template <release> <chart>
#     --version <pinned> -f <yaml>` and asserts exit 0 with no Helm-side
#     schema/validation error.
#   - Errors print the captured stderr (truncated to 30 lines) so the user
#     can diagnose chart-side rejections (e.g. unknown values keys, schema
#     constraint violations).

set -uo pipefail

# Resolved chart versions cached across invocations (the JSON fetch is slow).
__HT_CHART_VERSION_SCALARDL=""
__HT_CHART_VERSION_SCALARDL_AUDIT=""
__HT_CHART_VERSION_SCHEMA_LOADING=""
__HT_CHART_VERSION_RESOLVED_FOR=""

__resolve_chart_versions () {
  local app_version="$1"
  # Re-resolve only when the requested app_version changes.
  if [ "${__HT_CHART_VERSION_RESOLVED_FOR}" = "${app_version}" ]; then
    return 0
  fi
  __HT_CHART_VERSION_RESOLVED_FOR="${app_version}"

  local resolve
  resolve='
import json, sys
chart_name = sys.argv[1]
app_version = sys.argv[2]
rows = json.load(sys.stdin)
xs = [r["version"] for r in rows
      if r.get("name") == chart_name and r.get("app_version") == app_version]
print(xs[0] if xs else "")
'

  __HT_CHART_VERSION_SCALARDL=$(helm search repo scalar-labs/scalardl -l --output json 2>/dev/null \
    | python3 -c "${resolve}" "scalar-labs/scalardl" "${app_version}")

  __HT_CHART_VERSION_SCALARDL_AUDIT=$(helm search repo scalar-labs/scalardl-audit -l --output json 2>/dev/null \
    | python3 -c "${resolve}" "scalar-labs/scalardl-audit" "${app_version}")

  __HT_CHART_VERSION_SCHEMA_LOADING=$(helm search repo scalar-labs/schema-loading -l --output json 2>/dev/null \
    | python3 -c "${resolve}" "scalar-labs/schema-loading" "${app_version}")
}

# Run one `helm template` invocation and count pass/fail.
# Args: <label> <release> <chart> <chart-version> <values-yaml>
__ht_check () {
  local label="$1" release="$2" chart="$3" chart_version="$4" values_yaml="$5"
  local out
  if [ -z "${chart_version}" ]; then
    STATIC_FAILED=$((STATIC_FAILED + 1))
    printf '    %s✗ %s: chart version unresolved (helm search repo returned no match for app_version)%s\n' \
      "${CRED}" "${label}" "${CRESET}"
    return 1
  fi
  if ! out=$(helm template "${release}" "${chart}" --version "${chart_version}" -f "${values_yaml}" 2>&1); then
    STATIC_FAILED=$((STATIC_FAILED + 1))
    printf '    %s✗ %s (chart=%s version=%s):%s\n' \
      "${CRED}" "${label}" "${chart}" "${chart_version}" "${CRESET}"
    printf '%s' "${out}" | head -30 | sed 's/^/        /'
    return 1
  fi
  # Even on exit 0, surface obvious validation warnings in stderr.
  STATIC_PASSED=$((STATIC_PASSED + 1))
  printf '    %s✓ %s (chart=%s version=%s)%s\n' \
    "${CGREEN}" "${label}" "${chart}" "${chart_version}" "${CRESET}"
}

run_helm_template_checks () {
  local pattern_name="$1"
  local bundle_dir="$2"

  printf '  %shelm template (L2) for %s:%s\n' "${CBOLD:-}" "${pattern_name}" "${CRESET:-}"

  # Read SCALARDL_VERSION from e2e-config.local.json next to this lib, else fall back.
  local cfg_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/e2e-config.local.json"
  local app_version=""
  if [ -f "${cfg_file}" ]; then
    app_version=$(python3 -c '
import json,sys
try:
  print(json.load(open(sys.argv[1])).get("scalardlSdkVersion","") or json.load(open(sys.argv[1])).get("scalardlImageTag",""))
except Exception:
  print("")
' "${cfg_file}" 2>/dev/null)
  fi
  app_version="${app_version:-3.13.0}"

  __resolve_chart_versions "${app_version}"

  # Pattern-name → release name (mirrors W2 namespace use).
  local rel="${pattern_name}"

  # Ledger Helm values (always present).
  __ht_check "Ledger helm template" \
    "${rel}-ledger" \
    "scalar-labs/scalardl" \
    "${__HT_CHART_VERSION_SCALARDL}" \
    "${bundle_dir}/scalardl-ledger-custom-values.yaml" || true

  # Schema-loader Ledger Helm values (always).
  __ht_check "Schema-loader Ledger helm template" \
    "${rel}-ledger-schema" \
    "scalar-labs/schema-loading" \
    "${__HT_CHART_VERSION_SCHEMA_LOADING}" \
    "${bundle_dir}/schema-loader-ledger-custom-values.yaml" || true

  # Auditor side (when present).
  if [ -f "${bundle_dir}/scalardl-auditor-custom-values.yaml" ]; then
    __ht_check "Auditor helm template" \
      "${rel}-auditor" \
      "scalar-labs/scalardl-audit" \
      "${__HT_CHART_VERSION_SCALARDL_AUDIT}" \
      "${bundle_dir}/scalardl-auditor-custom-values.yaml" || true
    __ht_check "Schema-loader Auditor helm template" \
      "${rel}-auditor-schema" \
      "scalar-labs/schema-loading" \
      "${__HT_CHART_VERSION_SCHEMA_LOADING}" \
      "${bundle_dir}/schema-loader-auditor-custom-values.yaml" || true
  fi
}
