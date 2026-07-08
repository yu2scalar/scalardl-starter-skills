# E2E auto harness for `/scalardl-generate-config`

Plan: [`docs/plan-009-auto-e2e-test-harness.md`](../../../docs/plan-009-auto-e2e-test-harness.md)

Implementation status:

| W | Phase | Status |
|---|---|---|
| W0 | plan approve | ✅ 2026-05-11 |
| W1 | `e2e-config.local.json` schema + `preflight.sh` | ✅ 2026-05-11 |
| W2 | L1 (render) — 8 patterns × static checks | ✅ 2026-05-11 |
| W3 | sample Contract + Function bytecode bundle | ✅ 2026-05-11 |
| W4 | L2 (helm template dry-run) | ✅ 2026-05-11 |
| W5 | L3 (helm install on minikube) | ✅ implemented 2026-05-11 (pending user real-run verification) |
| W6 | L4 (register + execute) | ✅ **implemented this commit (pending user real-run verification)** |
| W7 | teardown + cleanup policy | not started |
| W8 | full-run + summary | not started |
| W9 | PR | not started |

## Quick start (W1 — preflight only)

```bash
cd skills/scalardl-generate-config/e2e
cp e2e-config.local.json.example e2e-config.local.json
$EDITOR e2e-config.local.json           # adjust kubectlContext if not "minikube"
export E2E_LICENSE_KEY='<your-trial-license-token-from-Scalar-Inc>'
bash run.sh --layer preflight
```

`preflight` runs 9 checks (per plan-009 D9 / D10 — environment provisioning is
the user's responsibility; the harness validates only):

1. `e2e-config.local.json` present + valid JSON
2. `kubectl` reaches a cluster
3. minikube tunnel running (or LB-providing equivalent — set
   `E2E_SKIP_TUNNEL_CHECK=1` to skip)
4. `helm` CLI present
5. `scalar-labs` helm chart repo registered
6. `scalardl` SDK CLI present (the modern binary name; older 3.6.x bundled as `scalardl-client` is NOT compatible — we use the positional-subcommand form `scalardl register-cert ...`)
7. Docker daemon running (for plan-009 host-Docker-postgres flow)
8. bundled trial PEM SHA-256 matches recorded value
9. License env vars set — **prefer** `E2E_LEDGER_LICENSE_KEY` + `E2E_AUDITOR_LICENSE_KEY` (Scalar Inc. issues per-product trial tokens; a Ledger token cannot authenticate the Auditor pod and vice versa). The single `E2E_LICENSE_KEY` is accepted as a legacy fallback (used for both Servers) but Auditor=Yes patterns (p5/p6/p8) will likely fail license check.

Each failure prints a specific repair command (e.g. `helm repo add ...`,
`minikube start`, etc.). Re-run preflight after fixing.

## L1 render (W2)

```bash
bash run.sh --layer L1
```

Reads `patterns/p1..p8.json` (axes per pattern), merges with `lib/defaults.json`
(common Mustache context), renders every applicable template through
`smoke/render.py`, then runs ~28 static checks per pattern (bash -n, yaml /
properties parse, boolean lowercase, credential env-ref, no inline DB
placeholder, no /keys mount duplicate, license env-ref, HMAC structural
consistency, release-name baking, lifecycle script presence). Output lands
under `e2e-runs/<timestamp>-L1/<pattern>/`.

Expected: 228 static checks pass across 8 patterns.

## L2 helm template dry-run (W4)

```bash
bash run.sh --layer L2
```

Runs L1 first, then on each rendered bundle calls `helm template <release>
<chart> --version <pinned> -f <values.yaml>` for each chart-yaml combination
(scalardl + scalardl-audit + schema-loading × 2 when Auditor=Yes). Verifies
the chart accepts the rendered values — catches schema mismatches like the
duplicate-`/keys`-mount bug from plan-008 P12 before they reach an actual
cluster.

Chart version pinning uses the same algorithm as `start-scalardl.sh`:
`helm search repo scalar-labs/<chart> -l --output json` filtered by
`app_version == SCALARDL_VERSION` (from `e2e-config.local.json`,
default 3.13.0).

Expected: 250 checks pass across 8 patterns (228 static + 22 helm-template,
varying with auditor count). The harness writes one directory per pattern,
same shape as L1; logs are inspectable for manual review.

Requires `helm` CLI on PATH + `scalar-labs` repo registered (preflight
check 4 + 5).

## L3 helm install on minikube (W5)

```bash
export E2E_LEDGER_LICENSE_KEY='<Ledger trial token from Scalar Inc.>'
export E2E_AUDITOR_LICENSE_KEY='<Auditor trial token from Scalar Inc.>'
# (Or legacy single token, but Auditor=Yes patterns will likely reject it:
#  export E2E_LICENSE_KEY='<token>')
bash run.sh --layer L3                                       # all 8 patterns
bash run.sh --layer L3 --pattern p1-noauditor-ds-proof-envoy # one pattern
bash run.sh --layer L3 --no-cleanup                          # keep deployed (debug)
```

For each pattern (sequential, per plan-009 D7):
1. **Teardown** any prior run of the pattern (idempotent — safe re-entry)
2. **Postgres** start as host Docker container(s):
   - Always `pg-ledger-<pattern>` on host port `5432`, db `ledger`
   - Auditor=Yes: also `pg-auditor-<pattern>` on host port `5433`, db `auditor` (per D12: independent fault domains)
   - Wait `pg_isready` (timeout 60 s each)
3. **env.sh** written to the bundle dir with `LEDGER_LICENSE_KEY` (from `$E2E_LICENSE_KEY`), `LEDGER_DB_*` / `AUDITOR_DB_*` (random per-pattern passwords from `openssl rand`), and the auto-load logic for `LICENSE_CHECK_CERT_PEM`. HMAC keys are left empty so `start-scalardl.sh` regenerates them via `openssl rand` per pattern.
4. **`bash scripts/init-schemas.sh`** (schema-loader Job, wait Complete)
5. **`bash scripts/start-scalardl.sh`** (PKI gen [DS only] → Secret create → helm install Ledger + Auditor → `kubectl wait` Ready, timeout 10 min/pod)
6. **External IP retrieval** (envoy-loadbalancer mode): `kubectl get svc ... -o jsonpath` with 60 s retry, then `sed -i` replaces `<LEDGER_EXTERNAL_IP>` / `<AUDITOR_EXTERNAL_IP>` placeholders in the admin client properties
7. **Per-pattern teardown** (D11, mandatory unless `--no-cleanup`):
   - `helm uninstall` all 2-4 releases
   - `kubectl delete namespace` (drops Secrets, PVCs, ConfigMaps)
   - `docker rm -f` for both postgres containers

Logs land at `e2e-runs/<ts>-L3/<pattern>/install-init-schemas.log` /
`install-start-scalardl.log` / `teardown.log` for post-mortem.

**Prerequisites (run `bash run.sh --layer preflight` first)**:
- minikube running with `minikube tunnel` (LoadBalancer support)
- `kubectl` reaches cluster
- `helm` + `scalar-labs` chart repo registered
- `docker` daemon
- License env vars set (`E2E_LEDGER_LICENSE_KEY` + `E2E_AUDITOR_LICENSE_KEY` preferred; legacy `E2E_LICENSE_KEY` accepted with caveat)

## L4 register + execute (W6)

```bash
export E2E_LEDGER_LICENSE_KEY='<Ledger trial token from Scalar Inc.>'
export E2E_AUDITOR_LICENSE_KEY='<Auditor trial token from Scalar Inc.>'
# (Or legacy single token, but Auditor=Yes patterns will likely reject it:
#  export E2E_LICENSE_KEY='<token>')
bash run.sh --layer L4                                       # all 8 patterns
bash run.sh --layer L4 --pattern p1-noauditor-ds-proof-envoy # one pattern
bash run.sh --layer all                                      # alias for L4
```

L4 runs L1 + L2 + L3, then per pattern (after install succeeds):

1. **scalardb-schema-loader**: `docker run ghcr.io/scalar-labs/scalardb-schema-loader:<SCALARDL_VERSION>` to create `smoke.smoke_assets` business table in Ledger's host postgres (uses `--add-host=host.docker.internal:host-gateway` for Linux/Docker-Desktop compatibility)
2. **register-cert** (DS) or **register-secret** (HMAC): admin entity against Ledger; also against Auditor when Auditor=Yes
3. **register-contract** `SmokeAsset` (with `prebuilt/com/example/contracts/SmokeAsset.class`): Ledger; also Auditor when Auditor=Yes
4. **register-function** `SmokeAssetFunction` (with `prebuilt/com/example/functions/SmokeAssetFunction.class`): Ledger only (Functions are Ledger-side; Auditor does not replay them in plan-009 scope)
5. **execute**: `scalardl execute-contract --properties ledger.as.client.properties --contract-id SmokeAsset --contract-argument '{"asset_id":"smoke-asset-1","data":{"v":1}}' --function-id SmokeAssetFunction`
6. **Invariants** (assertion, fail-fast):
   - `execute-contract` exit 0
   - `response.proof` field present ↔ `proof.enabled=true` per pattern
   - `SELECT count(*) FROM smoke.smoke_assets WHERE asset_id='smoke-asset-1'` == 1 (via `docker exec pg-ledger-<pattern> psql`)

Per-pattern logs land at `e2e-runs/<ts>-L4/<pattern>/l4/` (numbered by step:
`01-scalardb-schema-loader-ledger.log`, `02-register-cert-ledger.log`,
`03-register-contract-ledger.log`, `04-register-function-ledger.log`,
`05-execute.log`, etc.). The L3 logs from W5 (`install-init-schemas.log`,
`install-start-scalardl.log`) sit one level up in the same bundle dir.

**Additional L4 prerequisite**: the **modern `scalardl` CLI** on PATH (or
set `scalardlClientBinPath` in `e2e-config.local.json`). This is the
picocli-based entrypoint from `scalardl-java-client-sdk` ≥ 3.10. The CLI
form is `scalardl <subcommand> --properties <file> [flags]` — verified
against trunk `ScalarDlCommandLine.java:16` (`@Command(name="scalardl")`)
and the subcommand classes (`CertificateRegistration`,
`ContractRegistration`, `FunctionRegistration`, `ContractExecution`).

The older 3.6.x SDK shipped as `scalardl-client` with a `--command <name>`
flag — **incompatible** with W6's invocations. If your installed SDK is
that old, upgrade to ≥ 3.10 (matches plan-008 D13: target 3.13.0+).

**Caveat**: `execute-contract` CLI prints only `Contract result:` /
`Function result:` JSON to stdout. AssetProofs are returned via the SDK's
`ContractExecutionResult.getLedgerProofs()` but NOT printed by the CLI,
so W6 v1 does not assert the `proof` field presence from stdout. Verify
the `proof.enabled` difference between patterns via Ledger pod logs or
`scalardl validate-ledger` (future enhancement).

## Files

```
e2e/
├── run.sh                            # main entry (argv parse + dispatch by --layer)
├── lib/
│   ├── preflight.sh                  # 9-check pre-condition validation (W1)
│   ├── defaults.json                 # common Mustache context for all patterns (W2)
│   ├── render-pattern.sh             # render one pattern to a bundle dir (W2)
│   ├── static-checks.sh              # smoke-equivalent invariants per bundle (W2)
│   ├── helm-template-checks.sh       # L2 helm template dry-run per bundle (W4)
│   ├── install-pattern.sh            # L3 install: postgres + env.sh + init-schemas + start-scalardl + IP patch (W5)
│   ├── teardown-pattern.sh           # idempotent teardown: helm + ns + docker (W5)
│   └── register-and-execute.sh       # L4 register-cert/secret + register-contract/function + execute + assert (W6)
├── patterns/                         # 8 pattern axes — one JSON per row (W2)
│   ├── p1-noauditor-ds-proof-envoy.json
│   ├── p2-noauditor-ds-noproof-envoy.json
│   ├── p3-noauditor-hmac-proof-envoy.json
│   ├── p4-noauditor-hmac-noproof-envoy.json
│   ├── p5-auditor-ds-envoy.json
│   ├── p6-auditor-hmac-envoy.json
│   ├── p7-noauditor-ds-proof-pf.json
│   └── p8-auditor-ds-envoy-tls.json
├── e2e-config.local.json.example     # template — copy to e2e-config.local.json
├── .gitignore                        # e2e-config.local.json + env.sh + e2e-runs/
└── README.md                         # this file
```

`e2e-config.local.json` and `env.sh` are gitignored — they hold license keys
and DB credentials.

## Sample Contract + Function bundle (W3)

Minimal Contract + paired Function for L4 register / execute. See
[`sample/README.md`](sample/README.md) for full detail.

```
sample/
├── contracts/SmokeAsset.java                          # source
├── functions/SmokeAssetFunction.java                  # source
├── prebuilt/com/example/contracts/SmokeAsset.class    # compiled, v61.0
├── prebuilt/com/example/functions/SmokeAssetFunction.class
├── prebuilt/sha256.txt                                # SHA-256 of both .class
├── schema.{sql,json}                                  # ScalarDB business-side schema
├── build.gradle / settings.gradle                     # reproducible Gradle build
└── build.sh                                           # direct-javac wrapper (no JDK toolchain needed)
```

`bash sample/build.sh` re-builds the bytecode from sources and rewrites
`prebuilt/sha256.txt`. The committed `.class` files target Java 17
(`--release 17`, major version 61) per plan-008 D13.

## What's coming next

- **W4..W8**: helm template / install / register / execute / cleanup, end-to-end

See [`docs/plan-009-auto-e2e-test-harness.md`](../../../docs/plan-009-auto-e2e-test-harness.md)
for the full pattern matrix and acceptance criteria.
