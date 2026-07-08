---
name: scalardl-validate-config
description: Audits an existing ScalarDL configuration (Ledger / Auditor / Client properties files, plus Helm values yaml) against the property reference doc. Detects mis-configurations (Auditor-vs-proof requirement, mixed-config traps, TLS pairing gaps), deprecated keys, inconsistent cross-file values (HMAC secret mismatch, authentication.method drift), and AI-leverage lints (typo in property names, enum value violations, homoglyph identifiers). Read-only — reports findings with severity, recommendation, and reference-doc citations.
---

# scalardl-validate-config

> Status: **v0.1.0 (2026-05-14 — plan-015 initial implementation)**
> Targets ScalarDL 3.13.0+.

## Overview

A **read-only** audit skill. The user supplies one or more local file paths (Ledger / Auditor / Client properties, plus Helm values yaml). The skill parses each file, applies a catalog of 16 rules sourced from the reference doc, and emits a single Markdown report table to the console.

The skill **does not modify files**. The user reviews findings and decides which to act on. Each finding cites a section of the source-of-truth reference doc so the user can read context.

### What this skill does NOT do

- Modify or rewrite config files (read-only audit only)
- Run helm template / helm install / connect to a live Ledger
- Verify version compatibility against a running deployment (= future v2)
- Audit k8s ConfigMap / Secret directly (k8s integration = future v2)
- Audit Spring Boot `application.properties` from `scalardl-generate-springboot-starter` (Spring Boot prefix differs — future v2)

### Source-of-truth for rules

All rule semantics live in `skills/scalardl-generate-config/references/scalardl-configurations.md` (plugin-root relative — same plugin, sister skill). Whenever a rule references the doc with `§ "..."` it is pointing at a section header in that file. Open it alongside this SKILL.md when adding or refining rules.

## Phase 0 — collect target file paths

Run the following Q&A loop to collect the user's audit targets. Each path is independent; the skill works with 1, 2, …, or N files. **Do not require a complete set** — some users will audit only client.properties, others only Helm values.

```
Q0. Which configuration files do you want to audit? Provide local file paths.
    Press Enter on a blank line when done. Hints:

      ./ledger.properties
      ./auditor.properties
      ./client.properties
      ./scalardl-config/ledger.as.client.properties
      ./scalardl-config/auditor.as.client.properties
      ./scalardl-config/client.properties
      ./scalardl-config/scalardl-ledger-custom-values.yaml
      ./scalardl-config/scalardl-auditor-custom-values.yaml

    File path:
```

For each path:

1. Verify the file exists. If not, surface "file not found: <path>" as an issue (severity Error, rule `R0-file-not-found`) and continue with the next path.
2. Auto-detect the file's role from the filename (case-insensitive):

   | filename pattern | role |
   |---|---|
   | `ledger.as.client.properties` | Ledger Server cert-holder properties |
   | `auditor.as.client.properties` | Auditor Server cert-holder properties |
   | exactly `client.properties` (and none of the above) | runtime Client properties |
   | contains `ledger.properties` | Ledger Server config |
   | contains `auditor.properties` | Auditor Server config |
   | contains `scalardl-ledger` AND `.yaml` | Helm Ledger values |
   | contains `scalardl-auditor` AND `.yaml` | Helm Auditor values |
   | other | ask the user explicitly |

3. If the role cannot be auto-detected, ask:

   ```
   ❓ Could not auto-detect role of "<filename>". Which is it?
     (a) Ledger Server properties
     (b) Auditor Server properties
     (c) Runtime Client properties
     (d) Helm values — Ledger
     (e) Helm values — Auditor
     (f) Skip this file
   ```

Once all paths are collected and roled, proceed to Phase 1.

## Phase 1 — per-file rule application

For each file, parse it (Properties = `key=value` lines; yaml = standard yaml) and apply the rules listed below that apply to its role. Accumulate `Issue` records as you go.

`Issue` record shape (internal — never written to file, just used to build the final table):

```
{
  severity: "Error" | "Warning" | "Info",
  file: "<path the user entered>",
  property: "<scalar.dl... or yaml dotted path>",
  value: "<current value, masked if secret>",
  rule_id: "R1".."R16",
  rule_summary: "<one-line of what the rule checks>",
  recommendation: "<what to do about it>",
  citation: "§ \"...\" in skills/scalardl-generate-config/references/scalardl-configurations.md"
}
```

### Rule-to-role applicability matrix

| Role | Rules to run |
|---|---|
| Ledger Server / Ledger Helm values | R1, R2, R4, R5 (TLS), R6, R11, R12, R13, R14, R15, R16 |
| Auditor Server / Auditor Helm values | R1 (auditor-side check), R5 (TLS), R6, R14, R15, R16 |
| Ledger Server cert-holder (`ledger.as.client`) | R3, R5 (TLS), R10, R14, R15, R16 |
| Auditor Server cert-holder (`auditor.as.client`) | R3, R5 (TLS), R10, R14, R15, R16 |
| Runtime Client | R3, R5 (TLS), R8, R9, R10, R12, R14, R15, R16 |

(Cross-file rules R7, R8 belong to Phase 2.)

## Phase 2 — cross-file rules

After all files are parsed in Phase 1, run cross-file rules that compare values across files. Trigger each rule only when **both** required files are present:

- **R7**: Ledger Server's `servers.authentication.hmac.secret_key` and Auditor Server's `servers.authentication.hmac.secret_key` must be byte-equal when both are set.
- **R8**: `scalar.dl.client.authentication.method` (from Client) should equal `scalar.dl.ledger.authentication.method` (from Ledger), and similarly for Auditor.

## Phase 3 — emit report

After Phases 1 and 2 finish, sort `Issue`s:

1. Severity descending (`Error` → `Warning` → `Info`)
2. Within the same severity, by `file` then by `property` (alphabetical)

Then print the report to the console using exactly this template (replace `<...>` placeholders with actual values; if 0 issues print "✅ All checks passed" and skip the table):

```markdown
## ScalarDL Config Audit Report

<N> issue(s) found (<E> Error, <W> Warning, <I> Info)

| # | Severity | File | Property | Value | Rule | Recommendation |
|---|---|---|---|---|---|---|
| 1 | ❗ Error | <file> | <property> | <value-or-(set)> | <R-id>: <rule-summary> | <recommendation>. See <citation>. |
| 2 | ⚠ Warning | <file> | <property> | <value-or-(set)> | <R-id>: <rule-summary> | <recommendation>. See <citation>. |
| 3 | ⓘ Info | <file> | <property> | <value-or-(set)> | <R-id>: <rule-summary> | <recommendation>. See <citation>. |
| ... | ... | ... | ... | ... | ... | ... |
```

### Value masking

For any property name whose key-tail (last dot-separated segment) matches `*secret*`, `*hmac*`, `*key*`, `*credential*`, `*password*`, render the `Value` column as `(set)` instead of the raw value. This avoids leaking literal HMAC secrets / API tokens / passwords into the chat transcript.

Special-case: TLS cert/key **file paths** (e.g. `*.cert_path`, `*.private_key_path`) are NOT masked — they are paths, not secret material.

### "did you mean" suggestion (R14)

When R14 fires, the `Recommendation` column should include the closest known property name within Levenshtein distance ≤ 2:

```
R14: unknown property — did you mean `scalar.dl.ledger.proof.enabled`?
```

If the unknown property has no near neighbour (distance > 2 to every known key), emit:

```
R14: unknown property — not found in the reference doc property list. Verify the key name against `skills/scalardl-generate-config/references/scalardl-configurations.md` § "Ledger 設定" / "Auditor 設定" / "クライアント設定".
```

## Rule catalog (R1-R16)

Each rule entry is `(id, severity, applies_to, summary, predicate)`. The predicate is described in prose — implement it by reading the user's file content and applying the logic.

> Citations below reference `skills/scalardl-generate-config/references/scalardl-configurations.md` (plugin-root relative — sister skill of this one).

### R1 — Auditor requires proof.enabled=true

- Severity: **Error**
- Applies to: Ledger Server (properties or Helm values)
- Predicate: `scalar.dl.ledger.auditor.enabled` is `true` AND (`scalar.dl.ledger.proof.enabled` is `false` OR absent).
- Why: Ledger's constructor throws `IllegalArgumentException` (LedgerError.CONFIG_PROOF_MUST_BE_ENABLED) at startup.
- Recommendation: Set `scalar.dl.ledger.proof.enabled=true`.
- Citation: § "必須プロパティ行列"

### R2 — Standalone Ledger + HMAC auth still needs DS proof key

- Severity: **Error**
- Applies to: Ledger Server
- Predicate: `auditor.enabled=false` AND `authentication.method=hmac` AND `proof.enabled=true` AND both `proof.private_key_path` and `proof.private_key_pem` are absent / empty.
- Why: When Auditor is disabled, `servers.authentication.hmac.secret_key` is **not read** by the constructor (LedgerConfig only reads it inside `if (isAuditorEnabled)`). AssetProof signing then forcibly falls back to DigitalSignatureSigner, which requires a DS proof private key.
- Recommendation: Set `scalar.dl.ledger.proof.private_key_path` or `_pem`. (Setting `servers.authentication.hmac.secret_key` does NOT help in this standalone configuration.)
- Citation: § "Constructor が `serversAuthHmacSecretKey` を読むタイミング" + § "必須プロパティ行列" (bold rows)

### R3 — Deprecated client properties (legacy `cert_*` family)

- Severity: **Warning**
- Applies to: Runtime Client, Ledger/Auditor Server cert-holder (`*.as.client.properties`)
- Predicate: Any of the following keys is present:
  - `scalar.dl.client.cert_holder_id`
  - `scalar.dl.client.cert_path`
  - `scalar.dl.client.cert_pem`
  - `scalar.dl.client.cert_version`
  - `scalar.dl.client.private_key_path`
  - `scalar.dl.client.private_key_pem`
  - `scalar.dl.client.authentication_method` (underscore-style)
- Why: All deprecated, removed in ScalarDL 5.0.0.
- Recommendation: Switch to the modern `entity.*` form:

  | old | new |
  |---|---|
  | `cert_holder_id` | `entity.id` |
  | `cert_path` | `entity.identity.digital_signature.cert_path` |
  | `cert_pem` | `entity.identity.digital_signature.cert_pem` |
  | `cert_version` | `entity.identity.digital_signature.cert_version` |
  | `private_key_path` | `entity.identity.digital_signature.private_key_path` |
  | `private_key_pem` | `entity.identity.digital_signature.private_key_pem` |
  | `authentication_method` (underscore) | `authentication.method` (dot) |

- Citation: § "Skill 取り扱い方針 (deprecated 系プロパティ)" (family 1)

### R4 — Mixed config trap: DS auth + HMAC server-server

- Severity: **Warning**
- Applies to: Ledger Server (properties or Helm values)
- Predicate: `auditor.enabled=true` AND `authentication.method=digital-signature` AND `servers.authentication.hmac.secret_key` is set.
- Why: server-server authentication and AssetProof signing both switch to HMAC because `servers.hmac.secret_key` is set. However, the constructor still requires `proof.private_key_*` for the DS-auth path. The DS proof key becomes "dead config" that must remain present.
- Recommendation: Either (a) remove `servers.authentication.hmac.secret_key` (= full DS path, server-server stays on DS), or (b) switch `authentication.method` to `hmac` (= full HMAC path, the DS proof key requirement disappears).
- Citation: § "混合構成 (DS auth + HMAC server-server) の落とし穴"

### R5 — TLS pairing incomplete

- Severity: **Error**
- Applies to: Ledger / Auditor / Client (any with `tls.*` keys)
- Predicate: `*.tls.enabled=true` AND one or more of the required companions is missing:
  - For Server side: `tls.cert_chain_path` AND `tls.private_key_path`
  - For Client/Auditor → counterparty: `tls.ca_root_cert_path` OR `tls.ca_root_cert_pem` (one of the two), AND typically `tls.override_authority` when the cert SAN doesn't match the network hostname
- Why: Bare `tls.enabled=true` without companions → TLS handshake failure at runtime.
- Recommendation: Fill in the missing TLS keys, or set `tls.enabled=false` if TLS is not intended.
- Citation: Group `tls` (§ "列の凡例") + the TLS rows in each property table

### R6 — Placeholder leak

- Severity: **Error**
- Applies to: any file
- Predicate: Any property value matches `<[A-Z_][A-Z0-9_]*>` (env-style placeholder) — e.g. `<YOUR_LICENSE_KEY>`, `<LEDGER_EXTERNAL_IP>`, `<CLIENT_HMAC_SECRET_KEY>`, `<AUDITOR_EXTERNAL_IP>`.
- Why: Indicates an unfinished setup — `scalardl-generate-config` and the manual playbook emit these placeholders explicitly for the user to replace before `start-scalardl.sh`. A placeholder that survives to runtime config means the substitution step was skipped.
- Recommendation: Run the relevant substitution step (sed-patch from env.sh or playbook), or set the value manually.
- Citation: (Skill design — placeholder pattern from `scalardl-generate-config` outputs)

### R7 — Cross-file HMAC secret_key mismatch

- Severity: **Error**
- Applies to: cross-file (Ledger + Auditor, both required to trigger)
- Predicate: Both `scalar.dl.ledger.servers.authentication.hmac.secret_key` AND `scalar.dl.auditor.servers.authentication.hmac.secret_key` are set, but the values differ (byte-equal comparison).
- Why: Server-server HMAC auth requires both sides to agree on the same secret. Mismatch → authentication failure at startup.
- Recommendation: Set both to the same secret. Generated by `openssl rand -base64 32` (or whatever method created the original).
- Citation: § "HMAC server-server 経路で必須となるプロパティ"

### R8 — Cross-file authentication.method drift

- Severity: **Warning**
- Applies to: cross-file (Client + Ledger, optionally Client + Auditor)
- Predicate:
  - If Client and Ledger files are both present: `scalar.dl.client.authentication.method` ≠ `scalar.dl.ledger.authentication.method`.
  - If Client and Auditor files are both present: `scalar.dl.client.authentication.method` ≠ `scalar.dl.auditor.authentication.method`.
- Why: Client-side and Server-side auth methods must match for the gRPC handshake. The reference doc considers the 3 authentication directions independent, but Client↔Ledger and Client↔Auditor specifically must align.
- Recommendation: Set all three (`client.authentication.method` / `ledger.authentication.method` / `auditor.authentication.method`) to the same value.
- Citation: § "3 つの認証方向の整理"

### R9 — validate-ledger contract_id stale

- Severity: **Warning**
- Applies to: Runtime Client
- Predicate: `scalar.dl.client.auditor.linearizable_validation.contract_id` is set to literally `validate-ledger`.
- Why: In ScalarDL 3.13.0+ the actual coded default is `validate-ledger-v1_1_0` (built dynamically from the package name of the bundled ValidateLedger class). Registering a contract under the id `validate-ledger` and calling `validate-ledger` will trigger `CONTRACT_NOT_FOUND` (DL-COMMON-404001). Two valid escape hatches: (a) register the contract under `validate-ledger-v1_1_0`, OR (b) explicitly set this property to `validate-ledger` AND register a contract under that id (auto-bootstrap is then skipped per PR #404).
- Recommendation: Either remove this property (use the default `validate-ledger-v1_1_0`), or keep it set to `validate-ledger` only if you have explicitly registered a contract under that id.
- Citation: the "クライアント設定" table — note on the `scalar.dl.client.auditor.linearizable_validation.contract_id` row

### R10 — `admin` entity (3-entity model violation)

- Severity: **Warning**
- Applies to: any properties file with `entity.id` or legacy `cert_holder_id`
- Predicate: `scalar.dl.client.entity.id=admin` (or legacy `scalar.dl.client.cert_holder_id=admin`).
- Why: The settled 3-entity model is `ledger` / `auditor` / `client`. An `admin` entity is left over from an older design (pre-plan-010) and is incompatible with the current `ContractEntry.Key = (id, entityId, keyVersion)` entity-scoping — a contract registered by `admin` cannot be executed by another entity.
- Recommendation: Rename the entity id to `client` (for runtime apps) or to one of `ledger` / `auditor` (for Server cert-holder properties).
- Citation: (memory: `reference_scalardl_3_entity_model`)

### R11 — Auditor=No AND proof.enabled=true requires DS key

- Severity: **Error**
- Applies to: Ledger Server (properties or Helm values)
- Predicate: `auditor.enabled=false` AND `proof.enabled=true` AND both `proof.private_key_path` and `proof.private_key_pem` are absent / empty. (This is the same trap as R2 but triggers regardless of `authentication.method`.)
- Why: Standalone Ledger always uses DigitalSignatureSigner for AssetProof signing (HMAC is unreachable). The DS private key is therefore mandatory whenever proof is enabled.
- Recommendation: Set `proof.private_key_path` or `_pem`.
- Citation: § "必須プロパティ行列" (bold rows) — Auditor=`false` / proof=`true` / `authentication.method=hmac`

### R12 — gRPC max-size literal `0`

- Severity: **Info**
- Applies to: Ledger / Auditor / Client (any `grpc.max_inbound_*_size`)
- Predicate: One of `grpc.max_inbound_message_size`, `grpc.max_inbound_metadata_size` is set to the literal `0`.
- Why: A literal `0` is the source-code default and means "empty" — at runtime the gRPC framework default (4 MiB / 8 KiB) is applied because of the `> 0` guard in BaseServer / RpcUtil. If the intent was actually 4 MiB (or whatever the framework picks), removing the property is equivalent and avoids the gotcha. If the intent was unlimited, set an explicit larger value.
- Recommendation: Remove the property (= rely on framework default), or set an explicit value.
- Citation: the `> 0 ガード` note in § "列の定義"

### R13 — Function register only via privileged_port

- Severity: **Info**
- Applies to: Ledger Server (properties or Helm values)
- Predicate: `function.enabled=true` AND both `non_privileged_port.function.registration.enabled` and `non_privileged_port.function.overwrite.enabled` are absent or `false`.
- Why: With these flags `false` (the default), Function register and overwrite calls are only accepted on the privileged port (`50052`). An app that calls the non-privileged port (`50051`) for register-function will get permission-denied. This is correct default behaviour but easy to be surprised by.
- Recommendation: Confirm that the application uses the privileged port for function management, or enable the non-privileged-port flags if registration over the standard port is desired.
- Citation: the "Ledger 設定" table — note on the `scalar.dl.ledger.non_privileged_port.function.{registration,overwrite}.enabled` row

### R14 — Unknown property name (typo lint, AI-leverage)

- Severity: **Warning**
- Applies to: any properties file
- Predicate: A property key is **not** in the reference doc's property list AND does not match a documented prefix (e.g. `scalar.db.*` for ScalarDB pass-through is allowed). Compute Levenshtein distance from the offending key to every known key; if the minimum distance is ≤ 2, emit "did you mean ...?" suggestion. If distance > 2 (no close neighbour), emit "no near match" warning.
- Why: Strict Properties parsers silently default unknown keys, so a typo like `scalar.dl.ledger.prof.enabled` (= `proof.enabled` typo) will leave the actual `proof.enabled` at its default (`false`) and the user will not know.
- Recommendation: Verify the spelling against the reference doc property list. The reference doc's three tables (Ledger / Auditor / クライアント) are exhaustive for v3.13.0; `scalar.db.*` (ScalarDB pass-through) is documented as a wildcard.
- Citation: the full property list in § "Ledger 設定" / "Auditor 設定" / "クライアント設定" (= use as dictionary)

#### Building the known-property dictionary

When applying R14, build the dictionary at runtime by reading the reference doc's three property tables and the `scalar.db.*` wildcard. Pseudo-algorithm:

1. Read `skills/scalardl-generate-config/references/scalardl-configurations.md`.
2. Within each of the three tables (`## Ledger 設定` / `## Auditor 設定` / `## クライアント設定`), collect every backticked property name from the first column.
3. Add the wildcard `scalar.db.*` (= match any property starting with `scalar.db.`).
4. For each property in the user's file, look up the dictionary. If absent, R14 fires.

### R15 — Enum value violation (AI-leverage)

- Severity: **Error**
- Applies to: any properties file
- Predicate: A property whose documented value set is enumerated (a closed list) has a value outside that set. Specific enumerations from the reference doc:

  | Property | Allowed values |
  |---|---|
  | `scalar.dl.{ledger,auditor,client}.authentication.method` | `digital-signature` / `hmac` / `pass-through` (client INTERMEDIARY only) |
  | `scalar.dl.client.mode` | `CLIENT` / `INTERMEDIARY` |
  | `scalar.dl.*.tls.enabled` | `true` / `false` |
  | `scalar.dl.ledger.proof.enabled` | `true` / `false` |
  | `scalar.dl.ledger.auditor.enabled` | `true` / `false` |
  | `scalar.dl.ledger.function.enabled` | `true` / `false` |
  | `scalar.dl.ledger.direct_asset_access.enabled` | `true` / `false` |
  | `scalar.dl.ledger.tx_state_management.enabled` | `true` / `false` |
  | any other `*.enabled` | `true` / `false` |

  Case sensitivity: enum string values must match exactly (lowercase `digital-signature`, not `DIGITAL-SIGNATURE`; boolean is lowercase `true` / `false`, not `True` / `Yes`).

- Why: ScalarDL config parsing is case-sensitive. A `True` will fail boolean parsing; a `digitalsignature` (missing hyphen) will fail the enum match and either error at startup or silently fall back to a default.
- Recommendation: Use the exact value from the allowed list (case-sensitive).
- Citation: the list of valid values shown in the 「説明」 (Description) column of each property row in the reference doc

### R16 — Homoglyph / visual ambiguity (AI-leverage)

- Severity: **Warning**
- Applies to: identifier-valued properties only (= short identifier strings, not base64 secrets or PEM bodies)
- Predicate: Value contains characters from a homoglyph set in an identifier context. Apply to these properties only:
  - `entity.id` (and legacy `cert_holder_id`)
  - `namespace`
  - `name` (Ledger.name / Auditor.name)
  - `cert_holder_id` family
  - `secret_key_version` (numeric — flag any non-digit)
  - `context.namespace`

  Homoglyph patterns to flag:
  - Digit `0` mixed with letter `O` / `o` in the same value
  - Digit `1` mixed with letter `l` (lowercase L) or `I` (uppercase i) in the same value
  - Non-ASCII characters (Cyrillic `а` `е` `о` `р` `с` `х` etc. look identical to Latin)
  - Trailing whitespace / leading whitespace in the value

  **Do not apply to**: `*.cert_path`, `*.private_key_path`, `*.cert_pem`, `*.private_key_pem`, `*.secret_key`, `*.cipher_key`, `*.contact_points`, license PEMs, or any value containing a `/` or `=` (= likely path or base64).

- Why: A typo like `entity.id=cl1ent` (digit `1` in place of letter `i`) or `cIient` (uppercase `I` instead of lowercase `l`) is visually identical to the intended `client` but compares unequal at runtime — register-cert under the typo'd id and execute-contract under the correct id will fail with `ENTITY_NOT_FOUND`.
- Recommendation: Visually confirm each character in the flagged value. Replace any suspect character with the intended one.
- Citation: (Skill design — AI-leverage lint per plan-015 §1.1)

## Manifest hand-off

This skill is **read-only** and does not write to `.scalardl-starter-skills.json` or any other manifest. The audit run is ephemeral — re-run anytime to re-check.

## Limitations

- Targets ScalarDL 3.13.0+. Older versions have different defaults (e.g. `validate-ledger` contract id) and different property sets; R14 dictionary would be wrong.
- The skill does not connect to a running Ledger or Auditor. Runtime checks (license validity / connectivity / cross-version compat) are out of scope.
- Helm values yaml support is limited to the `*Properties` blocks that contain ScalarDL property keys; chart-native fields (replicaCount / image / resources / nodeSelector etc.) are NOT validated by this skill (use `helm template` + `helm lint` for chart validity).
- Manual `application.properties` from Spring Boot starter (Spring Boot prefix `scalardl.*`) is not yet supported — keys are different from raw ScalarDL `scalar.dl.*` keys. Future v2.
