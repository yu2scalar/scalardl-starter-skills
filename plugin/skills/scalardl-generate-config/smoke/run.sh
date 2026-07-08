#!/usr/bin/env bash
# Smoke test for scalardl-generate-config.
#
# Renders every template for the 4 main configurations
#   (Auditor=Yes/No × Auth=DS/HMAC), parses the rendered output, then runs
#   the generated PKI script for DS configs and openssl-verifies the keys.
#
# Per plan-008 OI-7, this is the "bash + diff" smoke harness. A more rigorous
# test-harness (gradle / pytest) is on the v0.4 stable backlog.
#
# Usage (from repo root):
#   bash skills/scalardl-generate-config/smoke/run.sh
#
# Exit code: 0 = all checks passed; non-zero = at least one failed.
# Output dir: /tmp/scalardl-config-smoke/ (overwritten each run).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL_DIR="${REPO_ROOT}/skills/scalardl-generate-config"
OUT_BASE="/tmp/scalardl-config-smoke"
RENDER_PY="${SKILL_DIR}/smoke/render.py"

PASS=0
FAIL=0

green () { printf '\e[32m%s\e[0m\n' "$*"; }
red   () { printf '\e[31m%s\e[0m\n' "$*"; }

ok ()   { PASS=$((PASS + 1)); green "  ✓ $*"; }
ng ()   { FAIL=$((FAIL + 1)); red   "  ✗ $*"; }

# ---- Common context variables shared across all configs ---------------------
COMMON_VARS='
  "generatedAt": "2026-05-09T10:00:00Z",
  "targetVersion": "3.13.0",
  "ledgerName": "scalardl-ledger",
  "ledgerNamespace": "default",
  "ledgerPort": 50051,
  "ledgerPrivilegedPort": 50052,
  "ledgerAdminPort": 50053,
  "ledgerPrometheusPort": 8080,
  "auditorName": "scalardl-audit",
  "auditorNamespace": "default",
  "auditorPort": 40051,
  "auditorPrivilegedPort": 40052,
  "auditorAdminPort": 40053,
  "auditorPrometheusPort": 8080,
  "ledgerCertHolderId": "ledger",
  "ledgerCertVersion": 1,
  "auditorCertHolderId": "auditor",
  "auditorCertVersion": 1,
  "adminEntityId": "admin",
  "adminCertVersion": 1,
  "adminCertPath": "./cert/admin-cert.pem",
  "adminPrivateKeyPath": "./cert/admin-key.pem",
  "clientEntityId": "client",
  "clientCertVersion": 1,
  "adminLedgerHost": "<LEDGER_EXTERNAL_IP>",
  "adminAuditorHost": "<AUDITOR_EXTERNAL_IP>",
  "adminHmacSecretKey": "<ADMIN_HMAC_SECRET>",
  "ledgerScalarDbContactPoints": "cassandra",
  "ledgerScalarDbUsername": "<LEDGER_DB_USERNAME>",
  "ledgerScalarDbPassword": "<LEDGER_DB_PASSWORD>",
  "ledgerScalarDbStorage": "cassandra",
  "auditorScalarDbContactPoints": "cassandra-auditor",
  "auditorScalarDbUsername": "<AUDITOR_DB_USERNAME>",
  "auditorScalarDbPassword": "<AUDITOR_DB_PASSWORD>",
  "auditorScalarDbStorage": "cassandra",
  "ledgerHmacCipherKey": "AAAA-LEDGER-CIPHER-KEY-PLACEHOLDER==",
  "auditorHmacCipherKey": "BBBB-AUDITOR-CIPHER-KEY-PLACEHOLDER==",
  "serverServerHmacSecret": "CCCC-SHARED-SERVERS-SECRET-PLACEHOLDER==",
  "kubernetesNamespace": "default",
  "licenseKey": "<YOUR_LICENSE_KEY>",
  "licenseType": "trial",
  "pkiOutDir": "./cert",
  "pkiValidityDays": 3650,
  "tlsClientLedgerCaPath": "",
  "tlsClientAuditorCaPath": ""
'

# ---- Render one config + run all checks ------------------------------------
run_config () {
  local label="$1"
  local auditor="$2"        # true | false
  local auth="$3"           # ds | hmac
  local licensing="$4"      # true | false (license type=trial when true)

  local case_dir="${OUT_BASE}/${label}"
  rm -rf "${case_dir}" && mkdir -p "${case_dir}"

  local ds=$([ "$auth" = "ds" ] && echo true || echo false)
  local hmac=$([ "$auth" = "hmac" ] && echo true || echo false)
  local auth_method=$([ "$auth" = "ds" ] && echo "digital-signature" || echo "hmac")
  # When Auditor=Yes proof.enabled is forced true; when Auditor=No assume true to also exercise the Counterintuitive case
  local proof_enabled=true

  local ctx="{
    ${COMMON_VARS},
    \"auditor\": ${auditor},
    \"dsPattern\": ${ds},
    \"hmacPattern\": ${hmac},
    \"authMethod\": \"${auth_method}\",
    \"proofEnabled\": ${proof_enabled},
    \"licensing\": ${licensing},
    \"tlsEnabled\": false,
    \"tlsServerServer\": false,
    \"envoyLoadBalancer\": true
  }"

  echo
  printf '\e[1m== Config: %s (auditor=%s, auth=%s, licensing=%s) ==\e[0m\n' \
    "$label" "$auditor" "$auth" "$licensing"

  # --- Render: Helm values (ledger always; auditor only when auditor=true) ---
  python3 "$RENDER_PY" "${SKILL_DIR}/templates/values/scalardl-ledger-custom-values.yaml.tmpl"  "$ctx" > "${case_dir}/scalardl-ledger-custom-values.yaml"
  python3 "$RENDER_PY" "${SKILL_DIR}/templates/values/schema-loader-ledger-custom-values.yaml.tmpl" "$ctx" > "${case_dir}/schema-loader-ledger-custom-values.yaml"
  python3 "$RENDER_PY" "${SKILL_DIR}/templates/properties/ledger.as.client.properties.tmpl" "$ctx" > "${case_dir}/ledger.as.client.properties"
  python3 "$RENDER_PY" "${SKILL_DIR}/templates/properties/client.properties.tmpl"           "$ctx" > "${case_dir}/client.properties"

  if [ "$auditor" = "true" ]; then
    python3 "$RENDER_PY" "${SKILL_DIR}/templates/values/scalardl-auditor-custom-values.yaml.tmpl" "$ctx" > "${case_dir}/scalardl-auditor-custom-values.yaml"
    python3 "$RENDER_PY" "${SKILL_DIR}/templates/values/schema-loader-auditor-custom-values.yaml.tmpl" "$ctx" > "${case_dir}/schema-loader-auditor-custom-values.yaml"
    python3 "$RENDER_PY" "${SKILL_DIR}/templates/properties/auditor.as.client.properties.tmpl" "$ctx" > "${case_dir}/auditor.as.client.properties"
  fi

  mkdir -p "${case_dir}/scripts"
  python3 "$RENDER_PY" "${SKILL_DIR}/templates/scripts/create-scalardl-secrets.sh.tmpl" "$ctx" > "${case_dir}/scripts/create-scalardl-secrets.sh"
  python3 "$RENDER_PY" "${SKILL_DIR}/templates/scripts/env-template.sh.tmpl"           "$ctx" > "${case_dir}/scripts/env-template.sh"
  python3 "$RENDER_PY" "${SKILL_DIR}/templates/scripts/init-schemas.sh.tmpl"           "$ctx" > "${case_dir}/scripts/init-schemas.sh"
  python3 "$RENDER_PY" "${SKILL_DIR}/templates/scripts/start-scalardl.sh.tmpl"         "$ctx" > "${case_dir}/scripts/start-scalardl.sh"
  python3 "$RENDER_PY" "${SKILL_DIR}/templates/scripts/stop-scalardl.sh.tmpl"          "$ctx" > "${case_dir}/scripts/stop-scalardl.sh"
  if [ "$auth" = "ds" ]; then
    python3 "$RENDER_PY" "${SKILL_DIR}/templates/scripts/generate-server-pki.sh.tmpl" "$ctx" > "${case_dir}/scripts/generate-server-pki.sh"
  fi

  # --- Check: bash -n on every script -------------------------------------
  for f in "${case_dir}/scripts"/*.sh; do
    if bash -n "$f" 2>/dev/null; then
      ok "bash -n: $(basename "$f")"
    else
      ng "bash -n: $(basename "$f")"
      bash -n "$f" || true
    fi
  done

  # --- Check: yaml.safe_load on every yaml --------------------------------
  for y in "${case_dir}"/*.yaml; do
    if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$y" 2>/dev/null; then
      ok "yaml parse: $(basename "$y")"
    else
      ng "yaml parse: $(basename "$y")"
      python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$y" || true
    fi
  done

  # --- Check: properties files parseable as Java Properties ---------------
  for p in "${case_dir}"/*.properties; do
    [ -f "$p" ] || continue
    if python3 - "$p" <<'PYEOF'
import sys
# very permissive properties parser: each non-comment non-blank line must be key=value
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
      ok "properties parse: $(basename "$p")"
    else
      ng "properties parse: $(basename "$p")"
    fi
  done

  # --- Check: License invariant. Helm values must NOT contain literal license_key value ---
  if [ "$licensing" = "true" ]; then
    if grep -q '<YOUR_LICENSE_KEY>' "${case_dir}/scalardl-ledger-custom-values.yaml"; then
      ng "License invariant: license_key placeholder leaked into Helm values"
    else
      ok "License invariant: Helm values have no inline license_key"
    fi
    if grep -q 'env:LEDGER_LICENSE_KEY' "${case_dir}/scalardl-ledger-custom-values.yaml"; then
      ok "License invariant: Helm values reference \${env:LEDGER_LICENSE_KEY}"
    else
      ng "License invariant: Helm values missing \${env:LEDGER_LICENSE_KEY}"
    fi
    if [ "$auditor" = "true" ]; then
      if grep -q 'env:AUDITOR_LICENSE_KEY' "${case_dir}/scalardl-auditor-custom-values.yaml"; then
        ok "License invariant: Auditor Helm values reference \${env:AUDITOR_LICENSE_KEY}"
      else
        ng "License invariant: Auditor Helm values missing \${env:AUDITOR_LICENSE_KEY}"
      fi
    fi
  fi

  # --- Check: Credential invariant (D-2026-05-11). Sensitive values must use
  # ${env:VAR} reference, NEVER appear as inline placeholders or literal values.
  for f in "${case_dir}/scalardl-ledger-custom-values.yaml" "${case_dir}/scalardl-auditor-custom-values.yaml"; do
    [ -f "$f" ] || continue
    # DB credentials must be env refs
    if grep -qE 'scalar\.db\.(username|password)=\$\{env:' "$f"; then
      ok "Credential invariant (DB cred env-ref): $(basename "$f")"
    else
      ng "Credential invariant: DB cred not env-referenced in $(basename "$f")"
      grep -E 'scalar\.db\.(username|password)=' "$f" || true
    fi
    # Inline placeholder credential values (e.g. <LEDGER_DB_PASSWORD>) must NOT
    # appear — they are remnants of the old Mustache-bake-in design.
    if grep -qE '<LEDGER_DB_(USERNAME|PASSWORD)>|<AUDITOR_DB_(USERNAME|PASSWORD)>|<ADMIN_HMAC_SECRET>' "$f"; then
      ng "Credential invariant: inline placeholder leaked into $(basename "$f")"
      grep -nE '<LEDGER_DB_|<AUDITOR_DB_|<ADMIN_HMAC_' "$f" || true
    else
      ok "Credential invariant (no inline placeholder): $(basename "$f")"
    fi
  done

  # --- Check: Boolean values render as lowercase true/false (NEVER True/False) ---
  # PyYAML and Java's Boolean.parseBoolean accept capitalised booleans, so this
  # regression won't surface via yaml/properties parse checks alone. Guard
  # explicitly: any "<key>: True" / "<key>=True" / "<key>: False" / "<key>=False"
  # in the rendered output is a bug.
  for f in "${case_dir}"/*.yaml "${case_dir}"/*.properties; do
    [ -f "$f" ] || continue
    if grep -nE '(:|=)\s*(True|False)\b' "$f" >/dev/null; then
      ng "Boolean lowercase invariant: capitalised True/False in $(basename "$f")"
      grep -nE '(:|=)\s*(True|False)\b' "$f" | head -3
    else
      ok "Boolean lowercase invariant: $(basename "$f")"
    fi
  done

  # --- Check: Envoy LoadBalancer block is emitted in Helm values ---
  if grep -qE '^\s*type:\s*LoadBalancer' "${case_dir}/scalardl-ledger-custom-values.yaml"; then
    ok "Envoy: Ledger Helm values emit service.type: LoadBalancer"
  else
    ng "Envoy: Ledger Helm values missing envoy.service.type: LoadBalancer"
  fi
  if [ "$auditor" = "true" ]; then
    if grep -qE '^\s*type:\s*LoadBalancer' "${case_dir}/scalardl-auditor-custom-values.yaml"; then
      ok "Envoy: Auditor Helm values emit service.type: LoadBalancer"
    else
      ng "Envoy: Auditor Helm values missing envoy.service.type: LoadBalancer"
    fi
  fi

  # --- Check: admin client properties carry the external-IP placeholder ---
  if grep -q '<LEDGER_EXTERNAL_IP>' "${case_dir}/ledger.as.client.properties"; then
    ok "Envoy: ledger.as.client.properties has <LEDGER_EXTERNAL_IP> placeholder"
  else
    ng "Envoy: ledger.as.client.properties missing <LEDGER_EXTERNAL_IP> placeholder"
  fi
  if [ "$auditor" = "true" ]; then
    if grep -q '<AUDITOR_EXTERNAL_IP>' "${case_dir}/auditor.as.client.properties"; then
      ok "Envoy: auditor.as.client.properties has <AUDITOR_EXTERNAL_IP> placeholder"
    else
      ng "Envoy: auditor.as.client.properties missing <AUDITOR_EXTERNAL_IP> placeholder"
    fi
  fi

  # --- Check: HMAC secret invariant. Shared secret references the same shell var
  # in both ledger-credentials-secret and auditor-credentials-secret. Now that
  # values come from env (`${SERVERS_HMAC_SECRET_KEY}`), the invariant is
  # structural: both create-secret commands must reference the same shell var.
  if [ "$hmac" = "true" ] && [ "$auditor" = "true" ]; then
    local secrets_file="${case_dir}/scripts/create-scalardl-secrets.sh"
    local servers_refs
    servers_refs=$(grep -c -E -- '--from-literal=SERVERS_HMAC_SECRET_KEY="\$\{SERVERS_HMAC_SECRET_KEY\}"' "$secrets_file" || true)
    if [ "$servers_refs" = "2" ]; then
      ok "HMAC invariant: SERVERS_HMAC_SECRET_KEY referenced in both ledger+auditor Secrets"
    else
      ng "HMAC invariant: expected 2 references to \${SERVERS_HMAC_SECRET_KEY}, found ${servers_refs}"
      grep -nE 'SERVERS_HMAC_SECRET_KEY' "$secrets_file" || true
    fi
  fi

  # --- plan-010: client.properties emitted + structural correctness ---
  if [ -f "${case_dir}/client.properties" ]; then
    ok "plan-010: client.properties emitted"
    if grep -qE '^scalar\.dl\.client\.entity\.id=client$' "${case_dir}/client.properties"; then
      ok "plan-010: client.properties entity.id=client"
    else
      ng "plan-010: client.properties entity.id missing or wrong"
    fi
    if [ "$auditor" = "true" ]; then
      grep -qE '^scalar\.dl\.client\.auditor\.enabled=true$' "${case_dir}/client.properties" \
        && ok "plan-010: client.properties auditor.enabled=true (Auditor=Yes)" \
        || ng "plan-010: client.properties auditor.enabled NOT true (Auditor=Yes)"
    else
      grep -qE '^scalar\.dl\.client\.auditor\.enabled=false$' "${case_dir}/client.properties" \
        && ok "plan-010: client.properties auditor.enabled=false (Auditor=No)" \
        || ng "plan-010: client.properties auditor.enabled NOT false (Auditor=No)"
    fi
    if [ "$auth" = "ds" ]; then
      grep -qE 'cert_path=\./cert/client-cert\.pem' "${case_dir}/client.properties" \
        && ok "plan-010: client.properties DS uses client-cert.pem" \
        || ng "plan-010: client.properties DS does NOT use client-cert.pem"
    else
      grep -q '<CLIENT_HMAC_SECRET_KEY>' "${case_dir}/client.properties" \
        && ok "plan-010: client.properties HMAC has <CLIENT_HMAC_SECRET_KEY> placeholder" \
        || ng "plan-010: client.properties HMAC missing <CLIENT_HMAC_SECRET_KEY> placeholder"
    fi
  else
    ng "plan-010: client.properties missing"
  fi

  if [ "$auth" = "ds" ] && [ -f "${case_dir}/scripts/generate-server-pki.sh" ]; then
    grep -qE '^gen_pair client$' "${case_dir}/scripts/generate-server-pki.sh" \
      && ok "plan-010: generate-server-pki.sh includes gen_pair client" \
      || ng "plan-010: generate-server-pki.sh missing gen_pair client"
  fi

  if [ "$auth" = "hmac" ]; then
    grep -q '^export CLIENT_HMAC_SECRET_KEY=' "${case_dir}/scripts/env-template.sh" \
      && ok "plan-010: env-template.sh has CLIENT_HMAC_SECRET_KEY export" \
      || ng "plan-010: env-template.sh missing CLIENT_HMAC_SECRET_KEY export"
  fi

  # --- Check: env-template.sh + init/start/stop scripts emitted ---
  for f in env-template.sh init-schemas.sh start-scalardl.sh stop-scalardl.sh; do
    if [ -f "${case_dir}/scripts/${f}" ]; then
      ok "Lifecycle script emitted: ${f}"
    else
      ng "Lifecycle script missing: ${f}"
    fi
  done

  # --- Check: schema-loader install is in init-schemas.sh, NOT start-scalardl.sh ---
  if grep -q "schema-loading" "${case_dir}/scripts/init-schemas.sh"; then
    ok "Schema-loader separation: init-schemas.sh contains schema-loading install"
  else
    ng "Schema-loader separation: init-schemas.sh missing schema-loading install"
  fi
  if grep -q "helm install.*schema-loading" "${case_dir}/scripts/start-scalardl.sh"; then
    ng "Schema-loader separation: start-scalardl.sh still contains schema-loader install (should be in init-schemas.sh)"
  else
    ok "Schema-loader separation: start-scalardl.sh has no schema-loader install"
  fi

  # --- Check: create-scalardl-secrets.sh is idempotent (kubectl apply pattern) ---
  if grep -q -- '--dry-run=client -o yaml | kubectl apply -f -' "${case_dir}/scripts/create-scalardl-secrets.sh"; then
    ok "Secrets script idempotent (kubectl apply pattern)"
  else
    ng "Secrets script NOT idempotent (no kubectl apply pattern found)"
  fi

  # --- Check: Helm values use CHART fields, no manual /keys mount (regression
  # prevention for the duplicate-/keys-mount bug, 2026-05-11). The chart auto-
  # mounts /keys when scalarLedgerConfiguration.secretName + ledgerProofEnabled
  # are set; adding `extraVolumeMounts: - mountPath: /keys` here would create
  # a duplicate volumeMount in the rendered Deployment.
  for f in "${case_dir}/scalardl-ledger-custom-values.yaml" "${case_dir}/scalardl-auditor-custom-values.yaml"; do
    [ -f "$f" ] || continue
    # /keys mount should NOT be in extraVolumeMounts
    if awk '/^[[:space:]]*extraVolumeMounts:/{flag=1; next} /^[[:space:]]*[a-zA-Z]/&&flag{flag=0} flag && /mountPath:[[:space:]]*\/keys/' "$f" | grep -q .; then
      ng "Duplicate-mount risk: /keys mount in extraVolumeMounts of $(basename "$f")"
    else
      ok "No duplicate /keys mount in $(basename "$f")"
    fi
    # Top-level secretName must point to credentials Secret (envFrom)
    if grep -qE '^[[:space:]]{2}secretName:[[:space:]]*(ledger|auditor)-credentials-secret' "$f"; then
      ok "Chart envFrom Secret (top-level): $(basename "$f")"
    else
      ng "Chart envFrom Secret missing top-level secretName in $(basename "$f")"
    fi
  done

  # --- Check: ledger values uses chart's scalarLedgerConfiguration.secretName
  # for PKI (DS only; HMAC standalone+proof also needs it)
  if [ "$auth" = "ds" ] || ( [ "$auth" = "hmac" ] && [ "$auditor" = "false" ] ); then
    if grep -qE 'scalarLedgerConfiguration:' "${case_dir}/scalardl-ledger-custom-values.yaml" \
        && grep -qE '^[[:space:]]+secretName:[[:space:]]*ledger-key-secret' "${case_dir}/scalardl-ledger-custom-values.yaml"; then
      ok "Ledger PKI Secret bound via scalarLedgerConfiguration.secretName"
    else
      ng "Ledger PKI Secret NOT bound via chart's scalarLedgerConfiguration.secretName"
    fi
  fi

  # --- Check: Helm release names baked in via Mustache (not hardcoded
  # `scalardl` literal). The Q&A A4a / A4d value flows into {{ledgerName}}
  # / {{auditorName}} and must reach start/stop scripts. Catches the 2026-05-11
  # bug where RELEASE_PREFIX defaulted to "scalardl" and ignored A4a.
  for f in "${case_dir}/scripts/start-scalardl.sh" "${case_dir}/scripts/stop-scalardl.sh"; do
    [ -f "$f" ] || continue
    if grep -q "RELEASE_PREFIX" "$f"; then
      ng "Release name: RELEASE_PREFIX still referenced in $(basename "$f") (must use baked-in {{ledgerName}}/{{auditorName}})"
    else
      ok "Release name: no RELEASE_PREFIX leftover in $(basename "$f")"
    fi
    if grep -qE "LEDGER_RELEASE=\"scalardl-ledger\"" "$f"; then
      ok "Release name: LEDGER_RELEASE baked from A4a in $(basename "$f")"
    else
      ng "Release name: LEDGER_RELEASE missing or wrong in $(basename "$f")"
    fi
  done

  # --- Check: DS PKI generation actually works ---------------------------
  if [ "$auth" = "ds" ]; then
    pushd "${case_dir}" >/dev/null
    if bash scripts/generate-server-pki.sh >"${case_dir}/pki-stdout.log" 2>"${case_dir}/pki-stderr.log"; then
      ok "PKI generation: script ran cleanly"
    else
      ng "PKI generation: script failed (see ${case_dir}/pki-stderr.log)"
      popd >/dev/null
      return
    fi

    # plan-010 3-entity model: ledger / auditor / client (no separate "admin" entity).
    local expected_keys="ledger client"
    if [ "$auditor" = "true" ]; then
      expected_keys="ledger auditor client"
    fi

    for name in $expected_keys; do
      local k="${case_dir}/cert/${name}-key.pem"
      local c="${case_dir}/cert/${name}-cert.pem"
      if openssl ec -in "$k" -noout -text 2>/dev/null | grep -q "ASN1 OID: prime256v1"; then
        ok "PKI: ${name} key is prime256v1 (ECDSA P-256)"
      else
        ng "PKI: ${name} key not prime256v1"
      fi
      if openssl x509 -in "$c" -noout -text 2>/dev/null | grep -q "Signature Algorithm: ecdsa-with-SHA256"; then
        ok "PKI: ${name} cert signed with ecdsa-with-SHA256"
      else
        ng "PKI: ${name} cert wrong sig algorithm"
      fi
    done
    popd >/dev/null
  fi
}

echo "Smoke test for scalardl-generate-config"
echo "  Repo root: ${REPO_ROOT}"
echo "  Output:    ${OUT_BASE}"
rm -rf "${OUT_BASE}" && mkdir -p "${OUT_BASE}"

# 4 main configurations × license=true (most realistic shape)
run_config "auditor-ds-license"      true  ds   true
run_config "auditor-hmac-license"    true  hmac true
run_config "noauditor-ds-license"    false ds   true
run_config "noauditor-hmac-license"  false hmac true

# license=false sanity (license skip path)
run_config "auditor-ds-nolicense"    true  ds   false
run_config "auditor-hmac-nolicense"  true  hmac false

echo
printf '\e[1m=== Summary ===\e[0m\n'
green "  ${PASS} checks passed"
if [ "$FAIL" -gt 0 ]; then
  red "  ${FAIL} checks failed"
  exit 1
fi
echo "  output: ${OUT_BASE}"
