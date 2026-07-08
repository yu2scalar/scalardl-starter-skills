#!/usr/bin/env bash
# E2E auto harness entry point for /scalardl-generate-config (plan-009).
#
# Plan: docs/plan-009-auto-e2e-test-harness.md
#
# Usage:
#   bash skills/scalardl-generate-config/e2e/run.sh [options]
#
# Options:
#   --layer <L>            Run only the specified layer.
#                            preflight  → pre-condition checks only (W1)
#                            L1         → render templates per pattern (W2)        [TODO]
#                            L2         → helm template dry-run     (W4)           [TODO]
#                            L3         → helm install + wait Ready (W5)           [TODO]
#                            L4         → register-cert + execute   (W6)           [TODO]
#                            all        → everything (default once W6 is done)     [TODO]
#   --pattern <p1..p8>     Run only this pattern (default: all 8 patterns)         [TODO from W2]
#   --no-cleanup           Skip teardown for failed patterns (debug)               [TODO from W7]
#   --config <path>        Use a non-default config file (default: ./e2e-config.local.json) [TODO from W7]
#
# Exit code: 0 on success, non-zero on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LAYER="preflight"
PATTERN_FILTER=""
NO_CLEANUP="0"

# --- argv parse --------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --layer)
      LAYER="${2:-}"
      if [ -z "${LAYER}" ]; then
        echo "ERROR: --layer requires an argument" >&2
        exit 2
      fi
      shift 2
      ;;
    --pattern)
      PATTERN_FILTER="${2:-}"
      if [ -z "${PATTERN_FILTER}" ]; then
        echo "ERROR: --pattern requires an argument (e.g. p1-noauditor-ds-proof-envoy)" >&2
        exit 2
      fi
      shift 2
      ;;
    --config)
      echo "WARNING: ${1} option recognised but not yet implemented (lands later)." >&2
      shift 2
      ;;
    --no-cleanup)
      NO_CLEANUP="1"
      shift
      ;;
    -h|--help)
      sed -n '2,21p' "${BASH_SOURCE[0]}"   # print the comment header as help
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# --- dispatch ---------------------------------------------------------------

case "${LAYER}" in
  preflight)
    # shellcheck source=lib/preflight.sh
    source "${SCRIPT_DIR}/lib/preflight.sh"
    run_preflight
    exit "${PREFLIGHT_FAILED}"
    ;;
  L1|L2|L3|L4|all)
    # L1   = render + static checks (no cluster).
    # L2   = L1 + helm template dry-run (no cluster, needs `helm` CLI).
    # L3   = L1 + L2 + helm install on cluster (W5; needs minikube + tunnel +
    #        docker, $E2E_LICENSE_KEY).
    # L4   = L3 + register-cert/secret + register-contract/function + execute
    #        + invariant assertions (W6; needs scalardl-client + scalardb-
    #        schema-loader image pullable from ghcr).
    # all  = alias for L4 (full pipeline).
    if [ "${LAYER}" = "all" ]; then
      LAYER="L4"
    fi

    if [ -t 1 ]; then
      CRESET=$'\e[0m'; CGREEN=$'\e[32m'; CRED=$'\e[31m'; CBOLD=$'\e[1m'
    else
      CRESET=''; CGREEN=''; CRED=''; CBOLD=''
    fi
    export CRESET CGREEN CRED CBOLD

    CFG_FILE="${SCRIPT_DIR}/e2e-config.local.json"
    if [ -f "${CFG_FILE}" ]; then
      LOG_DIR="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("logDir","./e2e-runs"))' "${CFG_FILE}" 2>/dev/null)"
    else
      LOG_DIR="./e2e-runs"
    fi
    case "${LOG_DIR}" in
      /*) ;;
      *)  LOG_DIR="${SCRIPT_DIR}/${LOG_DIR}" ;;
    esac
    RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
    RUN_DIR="${LOG_DIR}/${RUN_TS}-${LAYER}"
    mkdir -p "${RUN_DIR}"

    printf '%s%s — run dir: %s%s\n\n' "${CBOLD}" "${LAYER}" "${RUN_DIR}" "${CRESET}"

    # shellcheck source=lib/static-checks.sh
    source "${SCRIPT_DIR}/lib/static-checks.sh"
    STATIC_PASSED=0
    STATIC_FAILED=0
    L3_PATTERN_PASS=0
    L3_PATTERN_FAIL=0
    L4_PATTERN_PASS=0
    L4_PATTERN_FAIL=0

    if [ "${LAYER}" = "L2" ] || [ "${LAYER}" = "L3" ] || [ "${LAYER}" = "L4" ]; then
      # shellcheck source=lib/helm-template-checks.sh
      source "${SCRIPT_DIR}/lib/helm-template-checks.sh"
      if ! command -v helm >/dev/null 2>&1; then
        echo "ERROR: --layer ${LAYER} requires the helm CLI on PATH." >&2
        exit 2
      fi
    fi

    if [ "${LAYER}" = "L3" ] || [ "${LAYER}" = "L4" ]; then
      # Hard prerequisites for cluster touch — fail fast if missing.
      for tool in kubectl docker; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
          echo "ERROR: --layer ${LAYER} requires ${tool} on PATH (see preflight)." >&2
          exit 2
        fi
      done
      # License env: accept either specific (preferred) or legacy single token.
      if [ -z "${E2E_LEDGER_LICENSE_KEY:-}" ] && [ -z "${E2E_LICENSE_KEY:-}" ]; then
        echo "ERROR: --layer ${LAYER} requires a Ledger license token." >&2
        echo "       Set either:" >&2
        echo "         export E2E_LEDGER_LICENSE_KEY='<Ledger trial token>'" >&2
        echo "         export E2E_AUDITOR_LICENSE_KEY='<Auditor trial token>'   (preferred)" >&2
        echo "       or legacy single token:" >&2
        echo "         export E2E_LICENSE_KEY='<token>'   (Auditor patterns will likely reject it)" >&2
        echo "       Run: bash run.sh --layer preflight  to see all prerequisites." >&2
        exit 2
      fi
    fi

    if [ "${LAYER}" = "L4" ]; then
      # Additional L4 prereq: scalardl-client SDK CLI on PATH (or configured path).
      L4_CLIENT_BIN="scalardl"
      L4_CFG_FILE="${SCRIPT_DIR}/e2e-config.local.json"
      if [ -f "${L4_CFG_FILE}" ]; then
        L4_CLIENT_BIN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("scalardlClientBinPath","scalardl"))' "${L4_CFG_FILE}" 2>/dev/null || echo scalardl)"
      fi
      if ! command -v "${L4_CLIENT_BIN}" >/dev/null 2>&1 && [ ! -x "${L4_CLIENT_BIN}" ]; then
        echo "ERROR: --layer L4 requires scalardl-client CLI at ${L4_CLIENT_BIN}." >&2
        echo "       Install scalardl-java-client-sdk and put scalardl-client on PATH," >&2
        echo "       or set scalardlClientBinPath in e2e-config.local.json." >&2
        exit 2
      fi
    fi

    shopt -s nullglob
    PATTERN_FILES=("${SCRIPT_DIR}/patterns"/*.json)
    if [ "${#PATTERN_FILES[@]}" = "0" ]; then
      echo "ERROR: no pattern JSON files under ${SCRIPT_DIR}/patterns/" >&2
      exit 1
    fi
    IFS=$'\n' PATTERN_FILES=($(printf '%s\n' "${PATTERN_FILES[@]}" | sort))

    for pf in "${PATTERN_FILES[@]}"; do
      pattern_name="$(basename "${pf}" .json)"

      # --pattern filter
      if [ -n "${PATTERN_FILTER}" ] && [ "${pattern_name}" != "${PATTERN_FILTER}" ]; then
        continue
      fi

      pattern_dir="${RUN_DIR}/${pattern_name}"
      mkdir -p "${pattern_dir}"

      printf '%s== %s ==%s\n' "${CBOLD}" "${pattern_name}" "${CRESET}"

      # L1: render + static
      if ! bash "${SCRIPT_DIR}/lib/render-pattern.sh" "${pattern_name}" "${pattern_dir}"; then
        printf '    %s✗ render failed for %s%s\n' "${CRED}" "${pattern_name}" "${CRESET}"
        STATIC_FAILED=$((STATIC_FAILED + 1))
        L3_PATTERN_FAIL=$((L3_PATTERN_FAIL + 1))
        echo
        continue
      fi
      run_static_checks "${pattern_name}" "${pattern_dir}"

      # L2: helm template
      if [ "${LAYER}" = "L2" ] || [ "${LAYER}" = "L3" ]; then
        run_helm_template_checks "${pattern_name}" "${pattern_dir}"
      fi

      # L3: install on cluster
      if [ "${LAYER}" = "L3" ] || [ "${LAYER}" = "L4" ]; then
        l3_failed=0
        l4_failed=0
        if ! bash "${SCRIPT_DIR}/lib/install-pattern.sh" "${pattern_name}" "${pattern_dir}"; then
          l3_failed=1
          printf '    %s✗ L3 install failed for %s%s\n' "${CRED}" "${pattern_name}" "${CRESET}"
          L3_PATTERN_FAIL=$((L3_PATTERN_FAIL + 1))
        else
          printf '    %s✓ L3 install complete for %s%s\n' "${CGREEN}" "${pattern_name}" "${CRESET}"
          L3_PATTERN_PASS=$((L3_PATTERN_PASS + 1))
        fi

        # L4: register + execute (only when L3 succeeded)
        if [ "${LAYER}" = "L4" ] && [ "${l3_failed}" = "0" ]; then
          if ! bash "${SCRIPT_DIR}/lib/register-and-execute.sh" "${pattern_name}" "${pattern_dir}"; then
            l4_failed=1
            printf '    %s✗ L4 register+execute failed for %s%s\n' "${CRED}" "${pattern_name}" "${CRESET}"
            L4_PATTERN_FAIL=$((L4_PATTERN_FAIL + 1))
          else
            printf '    %s✓ L4 register+execute complete for %s%s\n' "${CGREEN}" "${pattern_name}" "${CRESET}"
            L4_PATTERN_PASS=$((L4_PATTERN_PASS + 1))
          fi
        elif [ "${LAYER}" = "L4" ] && [ "${l3_failed}" != "0" ]; then
          printf '    %s↷ L4 skipped (L3 install failed)%s\n' "${CRED}" "${CRESET}"
          L4_PATTERN_FAIL=$((L4_PATTERN_FAIL + 1))
        fi

        # Per-pattern cleanup (D11 mandatory unless --no-cleanup).
        if [ "${NO_CLEANUP}" = "1" ]; then
          printf '    (--no-cleanup) leaving %s deployed for inspection\n' "${pattern_name}"
        else
          bash "${SCRIPT_DIR}/lib/teardown-pattern.sh" "${pattern_name}" \
            > "${pattern_dir}/teardown.log" 2>&1 || true
          printf '    teardown done (log: %s/teardown.log)\n' "${pattern_dir}"
        fi
      fi
      echo
    done

    printf '%s%s summary: static %d/%d' \
      "${CBOLD}" "${LAYER}" "${STATIC_PASSED}" "$((STATIC_PASSED + STATIC_FAILED))"
    if [ "${LAYER}" = "L3" ] || [ "${LAYER}" = "L4" ]; then
      printf ' | L3 patterns: %d pass / %d fail' "${L3_PATTERN_PASS}" "${L3_PATTERN_FAIL}"
    fi
    if [ "${LAYER}" = "L4" ]; then
      printf ' | L4 patterns: %d pass / %d fail' "${L4_PATTERN_PASS}" "${L4_PATTERN_FAIL}"
    fi
    printf '%s\n' "${CRESET}"
    printf 'Run dir: %s\n' "${RUN_DIR}"

    # Exit non-zero if any check or any L3/L4 step failed.
    if [ "${STATIC_FAILED}" -gt 0 ] || [ "${L3_PATTERN_FAIL}" -gt 0 ] || [ "${L4_PATTERN_FAIL}" -gt 0 ]; then
      exit 1
    fi
    exit 0
    ;;
  *)
    echo "ERROR: unknown layer: ${LAYER}" >&2
    echo "Valid layers: preflight, L1, L2, L3, L4, all" >&2
    exit 2
    ;;
esac
