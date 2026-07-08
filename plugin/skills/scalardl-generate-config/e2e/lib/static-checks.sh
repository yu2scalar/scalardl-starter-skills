#!/usr/bin/env bash
# Static checks (smoke-equivalent invariants) for one rendered pattern.
#
# Plan reference: docs/plan-009-auto-e2e-test-harness.md W2 (L1 — render).
# Mirrors invariants from skills/scalardl-generate-config/smoke/run.sh but
# tailored for per-pattern checking after lib/render-pattern.sh has produced
# a single bundle.
#
# Usage:
#   source lib/static-checks.sh
#   run_static_checks <pattern-name> <bundle-dir>
#
# Sets / increments these globals (must be initialised by caller):
#   STATIC_PASSED, STATIC_FAILED

set -uo pipefail

run_static_checks () {
  local pattern_name="$1"
  local bundle_dir="$2"

  # short helpers — must reference the OUTER counters via global state
  __ok () {
    STATIC_PASSED=$((STATIC_PASSED + 1))
    printf '    %s✓ %s%s\n' "${CGREEN:-}" "$*" "${CRESET:-}"
  }
  __ng () {
    STATIC_FAILED=$((STATIC_FAILED + 1))
    printf '    %s✗ %s%s\n' "${CRED:-}" "$*" "${CRESET:-}"
  }

  printf '  %sstatic checks for %s:%s\n' "${CBOLD:-}" "${pattern_name}" "${CRESET:-}"

  # --- 1. bash -n on every script -----------------------------------------
  local f
  for f in "${bundle_dir}/scripts"/*.sh; do
    [ -f "${f}" ] || continue
    if bash -n "${f}" 2>/dev/null; then
      __ok "bash -n: $(basename "${f}")"
    else
      __ng "bash -n: $(basename "${f}")"
      bash -n "${f}" || true
    fi
  done

  # --- 2. yaml.safe_load on every yaml ------------------------------------
  local y
  for y in "${bundle_dir}"/*.yaml; do
    [ -f "${y}" ] || continue
    if python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "${y}" 2>/dev/null; then
      __ok "yaml parse: $(basename "${y}")"
    else
      __ng "yaml parse: $(basename "${y}")"
    fi
  done

  # --- 3. properties parse on every .properties ---------------------------
  local p
  for p in "${bundle_dir}"/*.properties; do
    [ -f "${p}" ] || continue
    if python3 - "${p}" <<'PYEOF'
import sys
with open(sys.argv[1]) as f:
    for ln_no, line in enumerate(f, 1):
        s = line.strip()
        if not s or s.startswith('#') or s.startswith('!'):
            continue
        if '=' not in s and ':' not in s:
            print(f"line {ln_no}: not key=value: {s}")
            sys.exit(1)
PYEOF
    then
      __ok "properties parse: $(basename "${p}")"
    else
      __ng "properties parse: $(basename "${p}")"
    fi
  done

  # --- 4. boolean lowercase invariant -------------------------------------
  # PyYAML accepts capitalised booleans, so this catches silent regressions.
  for f in "${bundle_dir}"/*.yaml "${bundle_dir}"/*.properties; do
    [ -f "${f}" ] || continue
    if grep -nE '(:|=)\s*(True|False)\b' "${f}" >/dev/null; then
      __ng "boolean lowercase: capitalised True/False in $(basename "${f}")"
      grep -nE '(:|=)\s*(True|False)\b' "${f}" | head -3
    else
      __ok "boolean lowercase: $(basename "${f}")"
    fi
  done

  # --- 5. credential invariant (no inline placeholders in Helm values) ----
  for f in "${bundle_dir}/scalardl-ledger-custom-values.yaml" "${bundle_dir}/scalardl-auditor-custom-values.yaml"; do
    [ -f "${f}" ] || continue
    if grep -qE 'scalar\.db\.(username|password)=\$\{env:' "${f}"; then
      __ok "credential env-ref: $(basename "${f}")"
    else
      __ng "credential: DB cred not env-referenced in $(basename "${f}")"
      grep -E 'scalar\.db\.(username|password)=' "${f}" || true
    fi
    if grep -qE '<LEDGER_DB_(USERNAME|PASSWORD)>|<AUDITOR_DB_(USERNAME|PASSWORD)>' "${f}"; then
      __ng "credential: inline DB placeholder leaked into $(basename "${f}")"
    else
      __ok "no inline DB placeholder: $(basename "${f}")"
    fi
  done

  # --- 6. duplicate-/keys-mount regression (2026-05-11 chart fields bug) --
  for f in "${bundle_dir}/scalardl-ledger-custom-values.yaml" "${bundle_dir}/scalardl-auditor-custom-values.yaml"; do
    [ -f "${f}" ] || continue
    if awk '/^[[:space:]]*extraVolumeMounts:/{flag=1; next} /^[[:space:]]*[a-zA-Z]/&&flag{flag=0} flag && /mountPath:[[:space:]]*\/keys/' "${f}" | grep -q .; then
      __ng "no /keys in extraVolumeMounts (would create duplicate mount): $(basename "${f}")"
    else
      __ok "no duplicate /keys mount risk: $(basename "${f}")"
    fi
  done

  # --- 7. license env-ref (when licensing=true) ---------------------------
  local lic_yaml="${bundle_dir}/scalardl-ledger-custom-values.yaml"
  if [ -f "${lic_yaml}" ] && grep -q 'scalar.dl.licensing.license_key' "${lic_yaml}"; then
    if grep -q '<YOUR_LICENSE_KEY>' "${lic_yaml}"; then
      __ng "license invariant: <YOUR_LICENSE_KEY> placeholder leaked into Ledger values"
    else
      __ok "license invariant: no inline license_key in Ledger values"
    fi
    if grep -q 'env:LEDGER_LICENSE_KEY' "${lic_yaml}"; then
      __ok "license invariant: \${env:LEDGER_LICENSE_KEY} reference present"
    else
      __ng "license invariant: \${env:LEDGER_LICENSE_KEY} reference missing"
    fi
  fi

  local aud_yaml="${bundle_dir}/scalardl-auditor-custom-values.yaml"
  if [ -f "${aud_yaml}" ] && grep -q 'scalar.dl.licensing.license_key' "${aud_yaml}"; then
    if grep -q 'env:AUDITOR_LICENSE_KEY' "${aud_yaml}"; then
      __ok "license invariant: \${env:AUDITOR_LICENSE_KEY} reference present in Auditor values"
    else
      __ng "license invariant: \${env:AUDITOR_LICENSE_KEY} missing in Auditor values"
    fi
  fi

  # --- 8. HMAC SERVERS_HMAC_SECRET_KEY shared structurally (Auditor + HMAC)
  local secrets_file="${bundle_dir}/scripts/create-scalardl-secrets.sh"
  if [ -f "${secrets_file}" ]; then
    # Only assert when Auditor + HMAC pattern (when both ledger + auditor blocks reference the shell var)
    local servers_refs
    servers_refs=$(grep -c -E -- '--from-literal=SERVERS_HMAC_SECRET_KEY="\$\{SERVERS_HMAC_SECRET_KEY\}"' "${secrets_file}" 2>/dev/null || true)
    # We don't know auditor+hmac here without reading context; just sanity-check:
    # if servers_refs > 0, count must be 2 (ledger + auditor); if 0, that's also fine (DS or no-Auditor).
    if [ "${servers_refs}" = "0" ] || [ "${servers_refs}" = "2" ]; then
      __ok "HMAC SERVERS_HMAC_SECRET_KEY references structurally consistent (count=${servers_refs})"
    else
      __ng "HMAC SERVERS_HMAC_SECRET_KEY reference count = ${servers_refs} (expected 0 or 2)"
    fi
  fi

  # --- 9. release name baked from pattern (not hardcoded scalardl)
  for f in "${bundle_dir}/scripts/start-scalardl.sh" "${bundle_dir}/scripts/stop-scalardl.sh"; do
    [ -f "${f}" ] || continue
    if grep -q "RELEASE_PREFIX" "${f}"; then
      __ng "release name: RELEASE_PREFIX leftover in $(basename "${f}") (must use baked-in {{ledgerName}})"
    else
      __ok "release name: no RELEASE_PREFIX leftover in $(basename "${f}")"
    fi
  done

  # --- 10. lifecycle scripts emitted --------------------------------------
  for fname in env-template.sh init-schemas.sh start-scalardl.sh stop-scalardl.sh create-scalardl-secrets.sh; do
    if [ -f "${bundle_dir}/scripts/${fname}" ]; then
      __ok "lifecycle: ${fname} emitted"
    else
      __ng "lifecycle: ${fname} missing"
    fi
  done

  # --- 10b. 3-entity model invariants (plan-010 correction) --------------
  # ledger.as.client.properties: entity.id=ledger, cert paths point to ledger-*.pem
  local lac_file="${bundle_dir}/ledger.as.client.properties"
  if [ -f "${lac_file}" ]; then
    if grep -q '^scalar\.dl\.client\.entity\.id=ledger$' "${lac_file}"; then
      __ok "3-entity: ledger.as.client.properties entity.id=ledger"
    else
      __ng "3-entity: ledger.as.client.properties entity.id != ledger"
    fi
    # admin* references in active (non-comment) lines must be absent.
    # Comments explaining the pre-plan-010 mislabelling are allowed.
    if grep -vE '^[[:space:]]*#' "${lac_file}" | grep -q 'admin'; then
      __ng "3-entity: 'admin' string leaked into ledger.as.client.properties (non-comment line)"
    else
      __ok "3-entity: no 'admin' reference in ledger.as.client.properties (non-comment)"
    fi
    # DS pattern: cert path must be ledger-cert.pem (not admin-cert.pem)
    if grep -q 'cert_path=' "${lac_file}"; then
      if grep -q 'cert_path=\./cert/ledger-cert\.pem' "${lac_file}"; then
        __ok "3-entity: ledger.as.client.properties cert_path=./cert/ledger-cert.pem"
      else
        __ng "3-entity: ledger.as.client.properties cert_path wrong (expected ledger-cert.pem)"
      fi
    fi
  fi

  # auditor.as.client.properties (Auditor=Yes only): entity.id=auditor
  local aac_file="${bundle_dir}/auditor.as.client.properties"
  if [ -f "${aac_file}" ]; then
    if grep -q '^scalar\.dl\.client\.entity\.id=auditor$' "${aac_file}"; then
      __ok "3-entity: auditor.as.client.properties entity.id=auditor"
    else
      __ng "3-entity: auditor.as.client.properties entity.id != auditor"
    fi
    if grep -vE '^[[:space:]]*#' "${aac_file}" | grep -q 'admin'; then
      __ng "3-entity: 'admin' string leaked into auditor.as.client.properties (non-comment line)"
    else
      __ok "3-entity: no 'admin' reference in auditor.as.client.properties (non-comment)"
    fi
    if grep -q 'cert_path=' "${aac_file}"; then
      if grep -q 'cert_path=\./cert/auditor-cert\.pem' "${aac_file}"; then
        __ok "3-entity: auditor.as.client.properties cert_path=./cert/auditor-cert.pem"
      else
        __ng "3-entity: auditor.as.client.properties cert_path wrong (expected auditor-cert.pem)"
      fi
    fi
  fi

  # generate-server-pki.sh: must NOT call `gen_pair admin` anymore (plan-010 correction)
  local pki_file="${bundle_dir}/scripts/generate-server-pki.sh"
  if [ -f "${pki_file}" ]; then
    if grep -qE '^gen_pair admin\b' "${pki_file}"; then
      __ng "3-entity: generate-server-pki.sh still calls 'gen_pair admin' (should be removed)"
    else
      __ok "3-entity: generate-server-pki.sh does not generate admin pair"
    fi
    if grep -qE '^gen_pair client\b' "${pki_file}"; then
      __ok "3-entity: generate-server-pki.sh generates client pair"
    else
      __ng "3-entity: generate-server-pki.sh missing client pair generation"
    fi
  fi

  # --- 11. plan-010 client.properties invariants --------------------------
  # client.properties is the runtime app's config (execute-contract / list-contracts).
  # Distinct from admin's *.as.client.properties.
  local cp_file="${bundle_dir}/client.properties"
  if [ -f "${cp_file}" ]; then
    __ok "plan-010: client.properties emitted"

    # Read pattern context to drive conditional invariants.
    local pattern_file="${E2E_DIR:-${SCRIPT_DIR}/..}/patterns/${pattern_name}.json"
    if [ ! -f "${pattern_file}" ]; then
      pattern_file="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)/patterns/${pattern_name}.json"
    fi
    local cp_auditor cp_envoy_lb cp_ds cp_hmac
    if [ -f "${pattern_file}" ]; then
      cp_auditor="$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get("context",{}).get("auditor",False); print("true" if v else "false")' "${pattern_file}")"
      cp_envoy_lb="$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get("context",{}).get("envoyLoadBalancer",False); print("true" if v else "false")' "${pattern_file}")"
      cp_ds="$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get("context",{}).get("dsPattern",False); print("true" if v else "false")' "${pattern_file}")"
      cp_hmac="$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get("context",{}).get("hmacPattern",False); print("true" if v else "false")' "${pattern_file}")"
    fi

    # (a) When envoy-loadbalancer, <LEDGER_EXTERNAL_IP> placeholder must be present
    #     pre-install (install-pattern.sh sed-patches it later).
    if [ "${cp_envoy_lb}" = "true" ]; then
      if grep -q '<LEDGER_EXTERNAL_IP>' "${cp_file}"; then
        __ok "plan-010: client.properties has <LEDGER_EXTERNAL_IP> placeholder (envoy-loadbalancer)"
      else
        __ng "plan-010: client.properties missing <LEDGER_EXTERNAL_IP> placeholder (envoy-loadbalancer)"
      fi
      if [ "${cp_auditor}" = "true" ]; then
        if grep -q '<AUDITOR_EXTERNAL_IP>' "${cp_file}"; then
          __ok "plan-010: client.properties has <AUDITOR_EXTERNAL_IP> placeholder (Auditor=Yes)"
        else
          __ng "plan-010: client.properties missing <AUDITOR_EXTERNAL_IP> placeholder (Auditor=Yes)"
        fi
      fi
    fi

    # (b) auditor.enabled must match pattern.auditor axis.
    if [ "${cp_auditor}" = "true" ]; then
      if grep -q '^scalar\.dl\.client\.auditor\.enabled=true' "${cp_file}"; then
        __ok "plan-010: client.properties auditor.enabled=true (Auditor=Yes → cross-validation)"
      else
        __ng "plan-010: client.properties auditor.enabled mismatch (expected true, Auditor=Yes)"
      fi
      if grep -q '^scalar\.dl\.client\.auditor\.host=' "${cp_file}"; then
        __ok "plan-010: client.properties auditor.host present"
      else
        __ng "plan-010: client.properties auditor.host missing (Auditor=Yes)"
      fi
    else
      if grep -q '^scalar\.dl\.client\.auditor\.enabled=false' "${cp_file}"; then
        __ok "plan-010: client.properties auditor.enabled=false (Auditor=No)"
      else
        __ng "plan-010: client.properties auditor.enabled mismatch (expected false, Auditor=No)"
      fi
    fi

    # (c) authentication.method matches pattern.dsPattern / hmacPattern axes.
    if [ "${cp_ds}" = "true" ]; then
      if grep -q '^scalar\.dl\.client\.authentication\.method=digital-signature' "${cp_file}"; then
        __ok "plan-010: client.properties auth.method=digital-signature (DS pattern)"
      else
        __ng "plan-010: client.properties auth.method mismatch (expected digital-signature)"
      fi
      # DS: cert/key paths must be present
      if grep -q 'digital_signature\.cert_path=' "${cp_file}" && \
         grep -q 'digital_signature\.private_key_path=' "${cp_file}"; then
        __ok "plan-010: client.properties DS cert + private_key paths present"
      else
        __ng "plan-010: client.properties DS cert/private_key paths missing"
      fi
    elif [ "${cp_hmac}" = "true" ]; then
      if grep -q '^scalar\.dl\.client\.authentication\.method=hmac' "${cp_file}"; then
        __ok "plan-010: client.properties auth.method=hmac (HMAC pattern)"
      else
        __ng "plan-010: client.properties auth.method mismatch (expected hmac)"
      fi
      # HMAC: pre-install must have placeholder (install-pattern.sh fills it).
      if grep -q '<CLIENT_HMAC_SECRET_KEY>' "${cp_file}"; then
        __ok "plan-010: client.properties has <CLIENT_HMAC_SECRET_KEY> placeholder (HMAC pre-install)"
      else
        __ng "plan-010: client.properties missing <CLIENT_HMAC_SECRET_KEY> placeholder (HMAC pre-install)"
      fi
    fi

    # (d) entity.id must be set (some value, defaults to "client" but user-overridable).
    if grep -q '^scalar\.dl\.client\.entity\.id=' "${cp_file}"; then
      __ok "plan-010: client.properties entity.id present"
    else
      __ng "plan-010: client.properties entity.id missing"
    fi
  else
    __ng "plan-010: client.properties missing (runtime client config — should always be emitted)"
  fi
}
