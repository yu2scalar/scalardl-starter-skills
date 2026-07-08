---
name: scalardl-generate-config
description: Q&A-driven generation of a complete ScalarDL Server-side deploy + runtime client bundle. Emits 4 Helm chart custom values (Ledger / Auditor / Schema-Loader-Ledger / Schema-Loader-Auditor) + 2 Server cert-holder properties (`ledger.as.client.properties` / `auditor.as.client.properties` — used **once at deploy** to register each Server's own cert; entity.id = `ledger` / `auditor`) + 1 runtime client properties (`client.properties` — used by the app for all register-cert / register-contract / register-function / execute-contract calls; entity.id = `client`) + Server PKI (ECDSA P-256, when DS pattern selected — generates ledger / auditor / client key pairs; no separate `admin` entity per the 3-entity model in plan-010) + License PEM injection (trial/production bundled, license_key from env) + HMAC shared secret (when HMAC pattern selected). Targets ScalarDL 3.13.0+. Authentication patterns are limited to "all DS" or "all HMAC" — mixed configurations are deliberately not supported (see plan-008 D7 for rationale).
---

# scalardl-generate-config

> Status: **v0.4.0-rc1 (Plan 008 in progress — P0..P11 complete; P12 E2E in progress)**
> Related plans: plan-008 (this skill's original design), plan-010 (M2 client.properties extension), plan-013 (reference doc Local fork). Plan docs live in the repo under `docs/` for contributors; they are not part of the installed bundle.
> References: `references/scalardl-configurations.md` (source-of-truth for ScalarDL properties — Local fork, edit directly), `references/license-pem/` (bundled trial / production cert PEMs)

## Overview

Generates ScalarDL **Server-side admin/deploy configuration** as a complete bundle, ready for Helm-based deployment + admin operations (`register-cert` / `register-contract` / `register-function` / `validate-ledger`).

This skill is **not** about generating a runtime Spring Boot app's `client.properties` — that is the Spring Boot app's concern (handled by `scalardl-generate-springboot-starter` and the future M3 skill). This skill produces the configuration that **the deployed ScalarDL Server reads**, plus the configuration that an **admin CLI** uses to talk to that Server for first-time registration.

### How this skill executes (read this first)

**There is no separate generator binary or runner script.** This SKILL.md is the prompt that drives _you_ (the Claude instance running this skill). The execution model is:

1. Drive the Q&A in Phases 0..8 below, asking the user one phase at a time.
2. Bind the collected answers to the Mustache context variables that templates expect (variable names appear inline in each `.tmpl` and are summarised under each Phase).
3. For each output file:
   - Use the `Read` tool to load the matching `templates/**/*.tmpl`.
   - Substitute the placeholders manually (you are the renderer — see "Mustache subset" below for the syntax you have to handle).
   - Use the `Write` tool to write the substituted content to `<output-dir>/`.
4. After the last file, write/merge the `.scalardl-starter-skills.json` `serverConfigGenerated` block (see "Manifest hand-off" below).
5. Print the post-write next-steps block from Phase 8 A8d.

#### What to say to the user vs. what to keep internal

This is a Q&A skill for end users. Users may be running this for the first time and **don't know your implementation details**. Keep user-facing messages outcome-focused and free of jargon:

- ✅ "Rendering 7 files…" / "Wrote 7 files to `./scalardl-config/`."
- ✅ "Question 4: How will the admin CLI reach the Ledger?" (followed by the choices)
- ❌ "Only `{{<identifier>}}` should be interpreted as the Mustache subset" — internal renderer rule, don't surface
- ❌ "Template comments contain Helm Go-template syntax; preserve them verbatim" — internal observation, don't surface (correct behaviour, but the user doesn't need to know)
- ❌ "Mustache standalone-tag rule" / "boolean lowercase invariant" / "not Mustache syntax" — internal terminology

If you _need_ to flag something the user must act on (e.g. a missing license token, a placeholder they have to replace), say it plainly: "Replace `<YOUR_LICENSE_KEY>` in `env.sh` before deploying." Implementation reasoning (regex matches, parser idiosyncrasies, chart field names) stays in your own head unless the user explicitly asks.

#### Templates directory layout

```
skills/scalardl-generate-config/templates/
├── values/
│   ├── scalardl-ledger-custom-values.yaml.tmpl          # always
│   ├── scalardl-auditor-custom-values.yaml.tmpl         # Auditor=Yes only
│   ├── schema-loader-ledger-custom-values.yaml.tmpl     # always
│   └── schema-loader-auditor-custom-values.yaml.tmpl    # Auditor=Yes only
├── properties/
│   ├── ledger.as.client.properties.tmpl                 # always (Ledger Server's own cert holder identity)
│   ├── auditor.as.client.properties.tmpl                # Auditor=Yes only (Auditor Server's own cert holder identity)
│   └── client.properties.tmpl                           # always (runtime client identity — plan-010, 3-entity model)
└── scripts/
    ├── env-template.sh.tmpl                             # always (env.sh template the user copies + fills in)
    ├── init-schemas.sh.tmpl                             # always (one-shot schema-loader Job)
    ├── start-scalardl.sh.tmpl                           # always (PKI gen + Secret create + helm install + wait Ready)
    ├── stop-scalardl.sh.tmpl                            # always (helm uninstall + Secret delete + ns delete)
    ├── create-scalardl-secrets.sh.tmpl                  # always (idempotent Secret creation, called by init/start)
    └── generate-server-pki.sh.tmpl                      # DS pattern, OR HMAC + proof.enabled=true, OR TLS=Yes
```

**Important: every `.tmpl` listed as `# always` MUST be rendered + written in every run.** Omitting `client.properties.tmpl` (or any other "always" template) breaks the bundle — the user gets no way to run `execute-contract`. When rendering, walk the list above as a checklist; don't infer from chapter prose.

#### Mustache subset you need to handle

Templates use a small subset of Mustache; you must support exactly these:

| Syntax | Meaning |
|---|---|
| `{{var}}` | Substitute the value of `var`. |
| `{{#flag}}...{{/flag}}` | Emit the body when `flag` is truthy (boolean true; ignore non-boolean truthiness — every section variable in these templates is a boolean). |
| `{{^flag}}...{{/flag}}` | Emit the body when `flag` is falsy. |
| _(no other tags)_ | No partials, no lambdas, no iteration over arrays. |

Common boolean flags: `auditor`, `dsPattern`, `hmacPattern`, `proofEnabled`, `envoyLoadBalancer`, `licensing`, `tlsEnabled`, `tlsServerServer`.

##### Render rules for primitive values

- **Booleans must render as lowercase `true` / `false`** — never `True` / `False` / `yes` / `1`. ScalarDL config parsers tolerate mixed case (`Boolean.parseBoolean` is case-insensitive), but YAML 1.2 only recognises lowercase as the boolean type, so `True` survives as a string and trips strict parsers / linters. The two templates emit `{{proofEnabled}}` and `{{auditor}}` into both YAML (`ledgerProofEnabled: {{proofEnabled}}`, `ledgerAuditorEnabled: {{auditor}}`) and Java properties (`scalar.dl.ledger.proof.enabled={{proofEnabled}}`) — the same value must work in both, so lowercase is the only safe choice.
- **Integers, strings, paths**: emit verbatim.
- **Missing variable** (variable does not appear in your bound context): emit an empty string and proceed. Do NOT leave the literal `{{var}}` in the output — that is a render bug and will break downstream parsers.

#### Optional smoke-test renderer (NOT the production path)

A minimal Python Mustache renderer exists at `skills/scalardl-generate-config/smoke/render.py` and is used by `smoke/run.sh`. It is **only for the smoke harness** (CI sanity, repo-side authoring verification) — the production rendering path is _you_ doing the substitution and `Write`-ing the files, so do **not** invoke `render.py` to fulfil a user request. The user gets a higher-quality result when you render directly (you can comment intelligently, omit irrelevant sections, and warn about ambiguous values), and treating `render.py` as a runner would couple users to a Python dependency that the skill design intentionally avoids.

### What this skill emits

Under `<output-dir>/` (default `./scalardl-config/`):

```
scalardl-config/
├── scalardl-ledger-custom-values.yaml          # Helm values for `scalardl` chart
├── scalardl-auditor-custom-values.yaml         # Helm values for `scalardl-audit` chart  (Auditor=Yes only)
├── schema-loader-ledger-custom-values.yaml     # Helm values for `schema-loading` chart targeting Ledger DB
├── schema-loader-auditor-custom-values.yaml    # Helm values for `schema-loading` chart targeting Auditor DB  (Auditor=Yes only)
├── ledger.as.client.properties                 # entity.id=ledger — used ONCE at deploy to register the Ledger server's own cert
├── auditor.as.client.properties                # entity.id=auditor — used ONCE at deploy to register the Auditor server's own cert (Auditor=Yes only)
├── client.properties                           # entity.id=client — used by the app for register-cert / register-contract / register-function / execute-contract (plan-010, 3-entity model)
└── cert/                                       # Server PKI (DS pattern only)
    ├── ledger-key.pem                          # Ledger server's cert holder
    ├── ledger-cert.pem
    ├── auditor-key.pem                         # Auditor server's cert holder (Auditor=Yes only)
    ├── auditor-cert.pem                        # (Auditor=Yes only)
    ├── client-key.pem                          # runtime app's identity (used for all human/app operations)
    └── client-cert.pem
```

The `.scalardl-starter-skills.json` manifest at the project root (if present) gets a `serverConfigGenerated` block written so a future M3 skill can pick up connection info without re-asking.

### What's intentionally out of scope

- ~~`client.properties` for the runtime Spring Boot app — M3 (`generate-scalardl-environment`, Plan 009)~~ — **moved into M2 by plan-010 (2026-05-11)**. The runtime client config is now emitted by this skill (see `client.properties` in the output tree above).
- ScalarDB schema YAML for application business tables — `scalardb-schema-loader` is the right tool
- docker-compose for local dev — currently not in scope of any M (re-evaluated when M3 plan lands)
- Production PKI from a real CA — this skill emits self-signed certs for development / getting-started; production deploys should use a real CA
- License key acquisition — Skill emits `<YOUR_LICENSE_KEY>` placeholder; user obtains the real key from Scalar Inc. and injects it via secret/env (see `references/license-pem/README.md`)
- Mixed authentication configurations (e.g. DS Client + HMAC Server-Server) — deliberately not supported, see "Authentication patterns" below

## Authentication patterns (D7)

ScalarDL has **4 independent cryptographic operations**:

1. **Client ↔ Ledger** (controlled by `scalar.dl.ledger.authentication.method`)
2. **Client ↔ Auditor** (controlled by `scalar.dl.auditor.authentication.method`, Auditor configurations only)
3. **Ledger ↔ Auditor (server-server)** (controlled implicitly by the **presence of** `scalar.dl.{ledger,auditor}.servers.authentication.hmac.secret_key`)
4. **AssetProof signing** (also controlled by the same `servers.authentication.hmac.secret_key` flag, **bound to (3)**)

Operations (3) and (4) are bound. So in principle, 8 configurations exist. **However, this skill supports only 2 patterns:**

| Pattern | (1)(2) Client | (3)(4) Server-Server / AssetProof | Server PKI | HMAC secret |
|---|---|---|---|---|
| **All DS**   | DS   | DS   | required (ledger / auditor / client)           | not used |
| **All HMAC** | HMAC | HMAC | not required for Server-Server / AssetProof    | required (shared between Ledger ↔ Auditor)  |

Mixed configurations (e.g. DS Client + HMAC Server-Server) are **trap configurations**: they work, but `proof.private_key_*` becomes "dead-but-required" — the constructor `LedgerConfig.java:519-523` still requires it for DS auth even when AssetProof signing actually uses HMAC. Avoiding this trap is the design rationale for the 2-pattern restriction.

> Detail: see `references/scalardl-configurations.md` § "混合構成 (DS auth + HMAC server-server) の落とし穴" + § "必須プロパティ行列".

## Pre-flight check

The skill can run from anywhere — it does not require a scaffolded Spring Boot project. However, if `.scalardl-starter-skills.json` exists at the current working directory, the skill will read it for default values (project name, Auditor preference, etc.) so users don't re-enter information.

Detection:

```bash
$ ls -la ./.scalardl-starter-skills.json
```

- **If absent**: skill prompts for everything; defaults listed below apply
- **If present**: skill prefills defaults from `projectName` / `auditorEnabled` / `scalardlSdkVersion` and writes a new `serverConfigGenerated` block on completion (existing top-level keys preserved verbatim — see "Manifest hand-off" below)

## Q&A flow — Phases 0..8

The Q&A is structured into 8 phases, totalling roughly 9..14 questions depending on user choices (Auditor on/off, DS vs HMAC, license skip vs trial/production, TLS on/off). Per plan-008 D19, DB credentials and license_key value are **NOT** asked at Q&A time — they live in env vars set in `env.sh` post-Q&A.

**⚠ Important pre-step**: before walking through Phase 0, **always check whether the user's first message contains a bulk pre-answer** (Phase 0.5 below). If it does, extract values and silently skip the corresponding questions. The per-question "never silently substitute" rule below applies only to questions Claude is actually asking — extracted answers from the user's own paste are NOT substitution, they ARE the user's choice.

For each Q below (that is not pre-answered), follow the global CLAUDE.md rule: **never silently substitute the user's choice.** When a value conflicts with a constraint (e.g. SDK 3.12.x), present options + reasoning and ask the user to decide.

### Phase 0.5 — Bulk pre-answer (REQUIRED check before interactive Q&A)

**CRITICAL** — this phase runs BEFORE Phase 0 / Phase 1 etc. The user's **first message** after `/scalardl-generate-config` launch may be a free-form natural-language summary of their intended configuration. **You MUST check for and parse such a bulk pre-answer block at the start, and MUST silently skip any Q&A whose value was extracted.**

This is an explicit override of the global "never silently substitute the user's choice" rule: **a value extracted from the user's first message IS the user's choice**. Do NOT re-ask to "confirm" — that defeats the entire point of bulk pre-answer. The post-extraction summary you echo back (step 2 below) is the confirmation: the user can stop you there if any extraction is wrong.

**Trigger**: Claude, on receiving the first user message, checks whether it contains configuration keywords (see axis table below). If yes, enter bulk-pre-answer mode (no opt-in needed — extraction is automatic and silent skipping of covered questions is required). If the message is empty / just "go" / "start" / unrelated, fall through to interactive Q&A from A0a.

**Workflow** (when triggered — this is the required sequence, do not deviate):

1. Parse the user's message against the axis table and extract values. Be liberal: synonyms count (e.g. "auditor on" = A1=Yes, "no auditor" = A1=No, "Ledger only" = A1=No, "MySQL" appearing in a URL = A5a=jdbc).
2. Echo back a 2-line summary in this exact form, then immediately proceed to step 3 without waiting:
   ```
   Got: <comma-separated key=value pairs of extracted answers>
   Will ask: <comma-separated remaining question IDs (only the truly missing ones)>
   ```
3. Proceed through Phases 1..8, **silently skipping** every question whose answer was extracted in step 1. **Do NOT** re-prompt "is your storage type jdbc?" if A5a was already extracted as jdbc — that is exactly the friction this phase exists to remove.
4. Final A8c confirmation still asked once at the very end — the user must confirm the FULL decision summary before any file write. That's the single global confirmation; per-question confirmations during the flow are explicitly redundant when extraction happened.

**Important: extraction confidence and edge cases**:
- If a field is ambiguous (e.g. user wrote "fast storage" — unclear which storage), do NOT extract; ask it normally.
- If the user pastes incomplete info (e.g. mentions Auditor=Yes but no Auth method), extract what you can and ask only the remaining items.
- Do NOT extract A0a (version) / A0b (output dir) from words like "scalardl 3.13" unless explicitly written as `version=3.13.0` or `output=PATH` — these are too ambiguous to risk false positives.
- A4a..A4f (release names / namespaces / ports) default to fixed values; only extract if user explicitly says `ledger-release=NAME` etc.
- A7b..A7d (PKI defaults) only extract if explicitly mentioned; otherwise use defaults silently (these are rarely overridden and don't deserve their own question when bulk-paste is in use).

**Parseable axes (keywords Claude recognises in free-form text)**:

| Q&A ID | Parses from… | Example phrases |
|---|---|---|
| A0a Target ScalarDL version | "version=X.Y.Z" / "scalardl 3.13" | `version=3.13.0`, `ScalarDL 3.13.0` |
| A0b Output directory | "output=PATH" / "outputDir=PATH" | `output=./scalardl-config/` |
| A1 Auditor? | "Auditor=Yes/No" / "with Auditor" / "Ledger only" | `Auditor=Yes`, `Ledger+Auditor`, `Ledger only` |
| A2 Auth method | "DS" / "digital-signature" / "HMAC" | `DS`, `auth=hmac`, `digital-signature` |
| A3 AssetProof? | "proof=Yes/No" / "AssetProof=on/off" | `proof=Yes`, `AssetProof on`. Skipped when A1=Yes (forced true) |
| A4a Ledger Helm release | "ledger-release=NAME" | `ledger-release=scalardl-ledger`. Default keeps `scalardl-ledger` |
| A4b Ledger namespace | "ledger-ns=NAME" / "namespace=NAME" | `namespace=default` |
| A4c Ledger ports | "ledger-grpc=PORT" / "ports=default" | rare to override |
| A4d/e/f Auditor release / ns / ports | mirror Ledger keys with `auditor-` prefix | `auditor-release=scalardl-audit` |
| A4g Connection mode | "envoy-loadbalancer" / "port-forward" / "external=HOST" | `envoy-loadbalancer`, `port-forward` |
| A4h TLS | "TLS=Yes/No" / "TLS on" / "no TLS" | `TLS=Yes`, plus a follow-up for server-server when A1=Yes ∧ TLS=Yes |
| A5a Ledger storage | "jdbc" / "cassandra" / "cosmos" / "dynamo" / "multi-storage" | `Ledger storage=jdbc` |
| A5b Ledger contact_points | URL/host after "Ledger" | `jdbc:mysql://192.168.214.130/ledger` |
| A5e Auditor storage | same as A5a but Auditor-side | `Auditor storage=jdbc` |
| A5f Auditor contact_points | URL/host after "Auditor" | `jdbc:mysql://192.168.214.130/auditor` |
| A6a License type | "trial" / "production" / "skip" | `trial license`, `license=skip` |
| A7a PKI strategy | "script-only" / "in-process" | `script-only` (default) |
| A7b/c/d | Rare to override; if user says "PKI defaults" or doesn't mention, use defaults | |
| A9a Client entity_id | "client=NAME" / explicit `clientEntityId=NAME` | `clientEntityId=app1`. Default `client` (rarely overridden). |

Anything not extracted from the user's message keeps its default and is asked normally.

**Example bulk pre-answer interaction**:

```
[User invokes /scalardl-generate-config]
[User pastes as first message:]
  "Auditor=Yes, digital-signature, envoy-loadbalancer, TLS=No,
   Ledger storage=jdbc + jdbc:mysql://192.168.214.130/ledger,
   Auditor storage=jdbc + jdbc:mysql://192.168.214.130/auditor,
   trial license."

[Claude responds:]
  Got: A1=Yes, A2=digital-signature, A3=forced(Auditor=Yes), A4g=envoy-loadbalancer,
       A4h=No, A5a=jdbc, A5b=jdbc:mysql://192.168.214.130/ledger,
       A5e=jdbc, A5f=jdbc:mysql://192.168.214.130/auditor, A6a=trial
  Will ask: A0a (version), A0b (output dir), A4a/A4d (release names),
            A4b/A4e (namespaces), A7a..A7d (PKI), A8b/A8c (confirm).
  Proceeding to A0a — Target ScalarDL version? (default 3.13.0)
```

This converts a 14-Q&A session into a 6-7-Q&A session for repeat use (e.g. the manual verification playbook). Defaults for unmentioned items still apply, so plain Enter through the remaining questions works.

### Phase 0 — Prerequisites

#### A0a — Target ScalarDL version

| | Value |
|---|---|
| **Question** | "What ScalarDL version are you targeting?" |
| **Default** | `3.13.0` (or `.scalardl-starter-skills.json#scalardlSdkVersion` if present) |
| **Validation** | If user enters anything below `3.13.0`, **reject** with this exact message: |

```
ScalarDL versions below 3.13.0 ship a Java 8 JRE in the Ledger Docker image.
This skill emits Java 17 bytecode and configurations targeting 3.13.0+ only.
3.12.x and below are not supported.

To proceed, choose one of:
  (a) Upgrade your target deployment to ScalarDL 3.13.0 or later
  (b) Use a different tooling that supports the older Java 8 runtime

If you mistyped the version, please re-enter a value >= 3.13.0.
```

Then re-prompt.

> Background: see `references/scalardl-configurations.md` § (header) — "ScalarDL v3.13.0 における...".

#### A0b — Output directory

| | Value |
|---|---|
| **Question** | "Where should the generated configuration be written?" |
| **Default** | `./scalardl-config/` |
| **Behavior** | Create the directory if absent. If non-empty, ask the user to confirm overwrite (Y/n). |

### Phase 1 — Deployment shape

#### A1 — Auditor enabled?

| | Value |
|---|---|
| **Question** | "Are you running ScalarDL with an Auditor (Byzantine-fault-detection configuration), or Ledger-only?" |
| **Default** | `Yes` if `.scalardl-starter-skills.json#auditorEnabled = true`, else ask |
| **Effect** | Auditor=Yes → emit 6 files (4 yaml + 2 properties); Auditor=No → emit 4 files (2 yaml + 1 properties; the Auditor-side files are skipped) |
| **Reminder shown after the answer** | "Auditor=Yes constructively requires `proof.enabled=true` (constructor enforcement in `LedgerConfig.java:513-515`). The skill will set this automatically; the AssetProof-related Q&A in Phase 3 is skipped." |

### Phase 2 — Authentication pattern

#### A2 — Authentication method

| | Value |
|---|---|
| **Question** | "Which authentication pattern do you want? — `digital-signature` (DS) or `hmac`. Both apply uniformly to Client↔Ledger, Client↔Auditor, and (when Auditor=Yes) Server-Server + AssetProof signing." |
| **Default** | `digital-signature` |
| **Options** | `digital-signature` / `hmac` |

**Crucial post-table reminder (always shown after the answer):**

> ScalarDL has 4 independent cryptographic operations. This skill applies your single chosen method uniformly to **all** of them, **deliberately**. Mixed configurations (e.g. DS Client + HMAC Server-Server) are technically possible but cause `proof.private_key_*` to be "dead-but-required" (constructor checks it even when unused). To avoid that trap, this skill restricts you to one method across the board. If you genuinely need a mixed configuration for production, generate values with this skill and edit the YAML by hand afterwards — but understand the trap before you do.
>
> Reference: `references/scalardl-configurations.md` § "混合構成 (DS auth + HMAC server-server) の落とし穴".

### Phase 3 — AssetProof handling

#### Branch on A1

| A1 (Auditor) | Phase 3 behavior |
|---|---|
| **Yes** | `proof.enabled=true` is **forced** by ScalarDL constructor (`LedgerConfig.java:513-515` throws `LedgerError.CONFIG_PROOF_MUST_BE_ENABLED` if `proof.enabled=false` while `auditor.enabled=true`). Skip A3. **Inform** the user: "Auditor=Yes implies `proof.enabled=true`. The skill sets it automatically." |
| **No** | Show A3 (single Yes/No) below |

#### A3 — Enable AssetProof? (Auditor=No only)

| | Value |
|---|---|
| **Lead text (explanation, shown before the question)** | "AssetProof is a hash-chain signed by the Ledger on every transaction. Retaining it client-side gives you three things:<br>• **Audit trail** — non-repudiation evidence (each tx signed by the Ledger's private key)<br>• **Tamper-evidence** — detect later direct tampering of the backend DB (modifications that bypass the Ledger's API) by comparing stored AssetProofs vs regenerated ones<br>• **Offline signature verification** — ship the Ledger public key with the app and call `AssetProof.validateWith()` to verify a proof without contacting the Ledger" |
| **Question** | "Do you want to enable AssetProof?" |
| **Type** | Single Yes/No |
| **Yes** | `proof.enabled=true` — AssetProofs are generated at commit time and returned to the client |
| **No** | `proof.enabled=false` — Ledger does not generate AssetProofs; `validate-ledger`'s server-side hash-chain check still runs (5 validators in `LedgerValidationService`) but no signed proof is returned to the client |

**Post-question reminder:**

> If your concern is "the Ledger server itself could be tampered with" (Byzantine-fault), client-side AssetProof retention does **not** help — the Ledger holds the signing key and could regenerate matching proofs. To detect Byzantine faults, run with **Auditor enabled** (re-answer A1 with Yes) so a second independent server cross-signs.
>
> Reference: `references/scalardl-configurations.md` § "単体運用での限界 (threat model)".

#### A3 → AssetProof signing key requirements

The pattern A2 + A1 + A3 result determines what signing key is needed:

| A1 (Auditor) | A2 (Pattern) | proof.enabled | AssetProof signing | Phase 7 generates |
|---|---|---|---|---|
| Yes | DS   | true (forced) | DS via `proof.private_key_*` | Server PKI (incl. Ledger key for proof) |
| Yes | HMAC | true (forced) | HMAC via `servers.authentication.hmac.secret_key` | Shared HMAC secret |
| No  | DS   | A3-driven     | DS via `proof.private_key_*` (only when `proof.enabled=true`) | Server PKI |
| No  | HMAC | A3-driven     | DS-forced via `proof.private_key_*` (counterintuitive — see below) | Server PKI (only when `proof.enabled=true`) |

**Counterintuitive case (A1=No × A2=HMAC × A3=Yes):** The `servers.authentication.hmac.secret_key` property is only **read** by `LedgerConfig` constructor when `auditor.enabled=true`. In standalone Ledger configurations, the field is never populated regardless of properties value, so AssetProof signing falls through to DS. **DS keys are required even though Client↔Ledger auth is HMAC.** This is the rationale for D7's "all DS or all HMAC" pattern restriction — but the standalone-HMAC-with-proof corner still requires DS keys for AssetProof. The skill handles this by emitting Server PKI in this case anyway.

> Reference: `references/scalardl-configurations.md` § "必須プロパティ行列" + § "Constructor が `serversAuthHmacSecretKey` を読むタイミング".

### Phase 4 — Connection info (Helm values + admin client)

These answers populate (a) Helm values for the Server-side charts and (b) admin client properties for `register-cert` / `register-contract`.

#### A4a — Ledger Helm release name

| | Value |
|---|---|
| **Question** | "What Helm release name will you use for the Ledger? The Scalar `scalardl` chart derives multiple Kubernetes Services from the release name, all prefixed with this value: `<release>-envoy` (LoadBalancer, the admin client target), `<release>-envoy-metrics`, `<release>-headless` (gRPC backend), `<release>-metrics`. The full admin client target host is therefore `<release>-envoy.<namespace>.svc.cluster.local`." |
| **Default** | `scalardl-ledger` |
| **Effect** | The value flows into Mustache `{{ledgerName}}` and is referenced in: Auditor's `auditorLedgerHost`, admin client properties `EXTERNAL_IP` retrieval command, `start-scalardl.sh` (helm release name + `kubectl wait` selector), and `stop-scalardl.sh`. Picking a non-default value here will cascade correctly to all generated files. |

#### A4b — Ledger Kubernetes namespace

| | Value |
|---|---|
| **Question** | "Which Kubernetes namespace will the Ledger be deployed to?" |
| **Default** | `default` |

#### A4c — Ledger ports

| | Value |
|---|---|
| **Question** | "Override the default Ledger ports? (Press Enter to accept defaults.)" |
| **Defaults** | gRPC `50051` / privileged gRPC `50052` / admin `50053` / Prometheus exporter `8080` |

#### A4d — Auditor Helm release name (Auditor=Yes only)

| | Value |
|---|---|
| **Question** | "What Helm release name will you use for the Auditor? Same prefix-derivation rule as A4a: the chart creates `<release>-envoy` / `<release>-headless` / `<release>-metrics` / `<release>-envoy-metrics` services. Admin client target host: `<release>-envoy.<namespace>.svc.cluster.local`." |
| **Default** | `scalardl-audit` (note: chart name is `scalardl-audit`, not `scalardl-auditor` — common confusion) |

#### A4e — Auditor Kubernetes namespace (Auditor=Yes only)

| | Value |
|---|---|
| **Question** | "Which Kubernetes namespace will the Auditor be deployed to?" |
| **Default** | `default` |

#### A4f — Auditor ports (Auditor=Yes only)

| | Value |
|---|---|
| **Question** | "Override the default Auditor ports? (Press Enter to accept defaults.)" |
| **Defaults** | gRPC `40051` / privileged gRPC `40052` / admin `40053` / Prometheus exporter `8080` |

#### A4g — Admin CLI connection mode

| | Value |
|---|---|
| **Question** | "How will the admin CLI (the holder of `ledger.as.client.properties` / `auditor.as.client.properties`) reach the Ledger / Auditor for `register-cert`, `register-contract`, etc.?" |
| **Options** | `envoy-loadbalancer` (have the Helm chart provision a LoadBalancer service on top of the bundled Envoy sub-chart — `envoy.enabled` is already `true` by chart default, the skill flips `envoy.service.type` to `LoadBalancer`) / `port-forward` (use `kubectl port-forward` from your laptop, host = `localhost`) / `external` (Ingress / LoadBalancer hostname **that you have already provisioned** is accessible from your laptop — the skill does NOT create it) |
| **Default** | `envoy-loadbalancer` |
| **Effect** | `envoy-loadbalancer` → Helm values emit `envoy.service.type: LoadBalancer` for Ledger (and Auditor when A1=Yes); admin client properties get `scalar.dl.client.server.host=<LEDGER_EXTERNAL_IP>` placeholder that the user replaces with the value of `kubectl get svc <ledger>-envoy -o jsonpath='{.status.loadBalancer.ingress[0].ip}'` after `helm install`. `port-forward` → admin client hosts default to `localhost`. `external` → ask for the Ledger external hostname and (Auditor=Yes) Auditor external hostname; the skill writes them straight into the properties. |
| **Note on annotations** | The skill emits `envoy.service.type: LoadBalancer` only. Cloud-provider-specific `envoy.service.annotations` (e.g. AWS NLB, GKE Internal LB, Azure Internal LB) are intentionally NOT asked — add them by hand to the generated Helm values when your environment needs them. |

#### A4h — TLS

| | Value |
|---|---|
| **Question** | "Enable TLS between client (admin CLI / runtime app) and Server (Ledger / Auditor)? (Recommended for production; usually skipped for getting-started.)" |
| **Default** | `No` |
| **If Yes** | Ask for: Server-side cert chain path / private key path (Helm values use these) AND admin-client-side ca_root_cert path or pem (`ledger.as.client.properties`/`auditor.as.client.properties` use this). Skill emits both with file paths under `<output-dir>/cert/` (auto-generated) or user-supplied paths |

> If `(Auditor=Yes) AND TLS=Yes`, also ask whether **Server-Server (Ledger ↔ Auditor) TLS** is on; defaults to the same value as A4h. Maps to `scalar.dl.auditor.tls.enabled` (separate from `server.tls.enabled`).

### Phase 5 — ScalarDB connection (Server side)

ScalarDL's Ledger and Auditor each store their system tables (`asset` / `asset_metadata` / etc.) in ScalarDB. **In an Auditor-enabled deployment, the Ledger and Auditor must use independent ScalarDB instances** — that's the entire point of having an Auditor (Byzantine fault detection requires the two to be in separate management domains).

The skill writes `scalar.db.*` settings into:

- `scalardl-ledger-custom-values.yaml` — for the Ledger's runtime
- `scalardl-auditor-custom-values.yaml` — for the Auditor's runtime (Auditor=Yes only)
- `schema-loader-ledger-custom-values.yaml` — for the schema-loader job that creates DL system tables in the Ledger's ScalarDB
- `schema-loader-auditor-custom-values.yaml` — same for Auditor's ScalarDB (Auditor=Yes only)

#### A5a — Ledger ScalarDB storage type

| | Value |
|---|---|
| **Question** | "Which ScalarDB storage backs the **Ledger**'s system tables?" |
| **Options** | `cassandra` / `cosmos` / `dynamo` / `jdbc` / `multi-storage` |
| **Default** | `cassandra` |

> Note: `multi-storage` is supported but advanced. If chosen, this skill emits a `scalar.db.storage=multi-storage` line plus a TODO comment; user fills the storage map by hand. (Same UX as scalardb-skills.)

#### A5b — Ledger ScalarDB contact points

| | Value |
|---|---|
| **Question** | "Contact points (host / endpoint) for the Ledger's ScalarDB?" |
| **Default (depends on A5a)** | See table below — the default value adapts to the storage type chosen in A5a. |

| A5a (storage) | A5b default | Notes |
|---|---|---|
| `cassandra` | `cassandra` | k8s service name in the same namespace |
| `jdbc` | `jdbc:postgresql://postgres:5432/ledger` | JDBC URL form. Replace host / DB name to match your Postgres deployment. For host-machine Postgres under minikube, use `jdbc:postgresql://host.minikube.internal:5432/ledger` |
| `cosmos` | `<your-cosmos-account>.documents.azure.com:443` | Cosmos DB endpoint URL. User MUST fill in real account name |
| `dynamo` | `(empty — fill in only if using a custom endpoint)` | DynamoDB auth is region-based, so contact_points is usually empty (set via `scalar.db.dynamo.region=...` in the values.yaml instead) |
| `multi-storage` | `(skip — emit TODO comment)` | Multi-storage requires `scalar.db.multi_storage.storages=...` plus per-storage `contact_points` etc. — fill by hand following `~/dl/3.11.hmac/scalardl-ledger-custom-values.yaml` shape |

**Why default-by-storage-type matters**: a fixed default like `cassandra` is misleading when the user picked `jdbc` in A5a — they then have to remember to type a JDBC URL by hand, defeating the Q&A's purpose. Conditional default makes Enter-through actually work.

#### ⚠ Heads-up — sharing tables with external ScalarDB apps (Function feature)

Show this advisory between A5b and the credentials advisory below, **only when the user intends to use the ScalarDL Function feature AND access the Function-written table directly from a separate ScalarDB application**. The skill cannot detect this from the Q&A inputs, so present it unconditionally as an "if-this-applies-to-you" note:

> If you plan to write a table through the ScalarDL Function feature **and** also read or write that same table directly from a separate ScalarDB application, both apps must point at the **same Coordinator table** — otherwise transaction commit state diverges and reads can return stale or uncommitted data. Concretely, the `scalar.db.storage` / `scalar.db.contact_points` / Coordinator namespace this skill emits for the **Ledger** (A5a / A5b above) must match the corresponding settings in the external ScalarDB app's config.
>
> This is the official warning from `https://scalardl.scalar-labs.com/docs/latest/how-to-run-applications#underlying-database`:
>
> > both ScalarDL and ScalarDB applications must refer to the same Coordinator table to guarantee consistency.
>
> The Auditor's ScalarDB stays independent — this requirement only constrains the Ledger's ScalarDB ↔ external app pair. Keys that must match between the two configs: `scalar.db.storage`, `scalar.db.contact_points`, and the Coordinator namespace (default `coordinator`).

#### Phase 5 — DB credentials are env-driven (no Q&A)

ScalarDB `username` / `password` are **not asked** at Q&A time. They live in the consolidated `{ledger,auditor}-credentials-secret` Kubernetes Secret and reach the Server pods via `extraEnvFrom`. The user supplies them in `env.sh` (copied from `env-template.sh` after Q&A finishes); `start-scalardl.sh` sources `env.sh` and `create-scalardl-secrets.sh` injects them into the Secret.

Inform the user of this between A5b (or A5f for Auditor) and A6a:

> ScalarDB credentials (`scalar.db.username` / `scalar.db.password`) and the license key are **not asked here** — they live in env vars. After Q&A finishes, you'll `cp env-template.sh env.sh`, set `LEDGER_DB_USERNAME` / `LEDGER_DB_PASSWORD` / `LEDGER_LICENSE_KEY` (and `AUDITOR_*` when Auditor=Yes), then `bash start-scalardl.sh` will inject them into the Kubernetes Secret. This keeps Helm values yaml free of inline credentials (plan-008 D19).

#### A5e..A5f — Auditor ScalarDB (Auditor=Yes only)

Asked **only when A1=Yes**. Same shape as A5a + A5b but for the Auditor's ScalarDB.

| Q | Default | Note |
|---|---|---|
| A5e | Storage type — `cassandra` | Same as Ledger by default; user can pick a different backend for true Byzantine isolation |
| A5f | Contact points — **depends on A5e** (same table as A5b, but suffix `-auditor` on host names) | E.g. A5e=`cassandra` → A5f default `cassandra-auditor`; A5e=`jdbc` → `jdbc:postgresql://postgres-auditor:5432/auditor`. **Different default host** to discourage colocation with Ledger's storage |

(Auditor DB credentials are env-driven — see "Phase 5 — DB credentials are env-driven" above. Not asked at Q&A.)

**Pre-A5e advisory shown when A1=Yes:**

> The Auditor must use a **separate ScalarDB infrastructure** from the Ledger. Otherwise both servers share a fault domain, defeating the purpose of having an Auditor. At minimum, separate hosts; ideally, separate clouds / different DB engines / different operational teams. The defaults below assume separation.
>
> Reference: `references/scalardl-configurations.md` § "Auditor 設定" — `scalar.db.*` row note ("Auditor 用は Ledger とは独立した DB を使うことが推奨される (Byzantine 検知のため別管理ドメイン)").

### Phase 6 — License (D15)

ScalarDL Enterprise installations require a `license_key` issued by Scalar Inc. plus a `license_check_cert_pem` (the verifier public key Scalar uses to sign keys). The skill bundles trial / production verifier cert PEMs under `references/license-pem/` (sha256-identical to scalardb-skills, sourced from the ScalarDL samples fixture). Both values are emitted via the Kubernetes Secret `scalardl-license`, which the Helm chart mounts as env vars (`extraEnvFrom`); the Helm values themselves only contain env-var references, never the actual values.

This is the same pattern used by `scalardb-skills/generate-scalardb-cluster-values` — keeping the two skills consistent so users developing on both can reuse Secret-creation muscle memory.

#### A6a — License type

| | Value |
|---|---|
| **Question** | "Are you using a Trial or Production (Enterprise) license, or skipping license configuration (development / non-Enterprise builds)?" |
| **Options** | `trial` / `production` / `skip` |
| **Default** | `trial` |
| **Effect when `trial` / `production`** | (1) Helm values for both Ledger and Auditor emit the `licensing` block: `scalar.dl.licensing.license_key=${env:HELM_LICENSE_KEY}` and `scalar.dl.licensing.license_check_cert_pem=${env:HELM_LICENSE_CHECK_CERT_PEM}`. (2) The pod's `extraEnvFrom` is augmented with `secretRef: { name: scalardl-license }`. (3) The bundled PEM is copied from `references/license-pem/<type>-cert.pem` to `<output-dir>/license-pem/<type>-cert.pem`. (4) `<output-dir>/scripts/create-scalardl-secrets.sh` includes a `kubectl create secret generic scalardl-license ...` invocation. |
| **Effect when `skip`** | The `licensing` block is omitted entirely from both Helm values (no commented-out form — clean output). No PEM is copied. The license-related lines do not appear in the Secret-creation script. |

> Caveat about bundled cert validity: both `trial-cert.pem` and `production-cert.pem` may have a past `notAfter` date (the bundled samples fixture's certs were issued for an earlier window). This is **not** a runtime issue: ScalarDL's license verifier consumes only the **public-key** portion of the cert, not the `notAfter` field, so verification continues to work after the wall-clock validity expires. Confirmed via scalardb-skills Day 2 user verification (see `references/license-pem/README.md` "About expiry").

#### Phase 6 — License key is env-driven (no Q&A)

The license_key value is **not asked** at Q&A time. Following plan-008 D19, both the Helm values yaml AND `create-scalardl-secrets.sh` reference it via `${env:LEDGER_LICENSE_KEY}` / `${env:AUDITOR_LICENSE_KEY}` (per-Server) — there is **no inline `<YOUR_LICENSE_KEY>` placeholder in any generated file**. The user supplies the actual tokens through `env.sh` (sourced by `start-scalardl.sh`), so the key never enters the skill's run transcript or any committed file.

Inform the user between A6a and A7a:

> Your license_key value is **not asked here** — supply it via env vars at deploy time:
> ```bash
> export LEDGER_LICENSE_KEY='<Ledger trial token from Scalar Inc.>'
> export AUDITOR_LICENSE_KEY='<Auditor trial token>'   # Auditor=Yes only
> ```
> Then `bash start-scalardl.sh` reads `env.sh` (which sources the values) and `create-scalardl-secrets.sh` injects them into the consolidated Secret (`{ledger,auditor}-credentials-secret`). The Helm values yaml only contains `${env:LEDGER_LICENSE_KEY}` references (invariant: zero inline credentials).

(A6a still determines whether the licensing block is emitted at all, the bundled PEM choice trial/production, and the `extraEnvFrom` wiring — see above.)

#### A6 → outputs

| File | A6a = `trial` / `production` | A6a = `skip` |
|---|---|---|
| `scalardl-ledger-custom-values.yaml` | `licensing` block emitted with env refs; `extraEnvFrom` includes `scalardl-license` | block omitted; `extraEnvFrom` does not include `scalardl-license` |
| `scalardl-auditor-custom-values.yaml` (Auditor=Yes only) | same as Ledger | same |
| `<output-dir>/license-pem/<type>-cert.pem` | bundled PEM copied here | file not created |
| `<output-dir>/scripts/create-scalardl-secrets.sh` | includes `kubectl create secret generic scalardl-license ...` block | block omitted (script body still emitted if Phase 7 / 8 require Secrets for PKI / HMAC) |
| `<output-dir>/.gitignore` | always created with `env.sh` ignored (license/DB cred live there) | same — `env.sh` always gitignored |

#### Reference

`references/scalardl-configurations.md` § "Ledger 設定" rows for `scalar.dl.licensing.license_key` and `scalar.dl.licensing.license_check_cert_pem` (and the corresponding Auditor rows). Both are documented as "Enterprise 限定" — the skip path is for dev / OSS-only builds.

### Phase 7 — Server PKI generation (D11 / D12, DS pattern only)

When A2 = `digital-signature`, the Ledger, the Auditor (when A1 = Yes), and the runtime `client` entity each need an ECDSA P-256 keypair for signing. Per D11, the algorithm is fixed at **`SHA256withECDSA` × `prime256v1` (NIST P-256)**, confirmed against `~/claude/dl/scalardl/common/src/main/java/com/scalar/dl/ledger/crypto/DigitalSignatureSigner.java:21` (`DEFAULT_ALGORITHM` constant) and the helm-charts sample keys. The skill emits a self-signed cert + private key pair per identity — appropriate for getting-started / dev. Production deploys should replace these with certs from a real CA; see `references/scalardl-pki-keys.md`.

**Skipped entirely if A2 = `hmac`** (HMAC pattern uses Phase 8's shared-secret flow instead). However, note the counterintuitive case from Phase 3: when `A1=No × A2=HMAC × A3=Yes` (standalone Ledger with HMAC client + AssetProof enabled), DS keys are still required for AssetProof signing. In that single case, Phase 7 fires for the Ledger key only. The skill detects this branch automatically.

#### A7a — PKI generation strategy

| | Value |
|---|---|
| **Question** | "How should the PKI keypairs (Ledger{{#auditor}}, Auditor{{/auditor}}, client) be obtained?" |
| **Options** | (a) `generate-now`: skill runs `openssl` immediately and writes keys to `<output-dir>/cert/` (recommended; requires openssl in PATH) / (b) `script-only`: skill writes `<output-dir>/scripts/generate-server-pki.sh` but does not execute (user runs later, e.g. on a separate machine) / (c) `existing`: user already has the keypairs; skill prompts for paths and skips generation |
| **Default** | `generate-now` if `command -v openssl` succeeds, else fall back to `script-only` |

**Behavior of each option:**

- **(a) `generate-now`**: Skill runs `bash <output-dir>/scripts/generate-server-pki.sh`. After success, runs `openssl ec -text -noout` on each key and confirms `ASN1 OID: prime256v1`. On failure (openssl missing, write error, etc.), surfaces the error and asks the user whether to re-attempt, fall back to `script-only`, or abort.
- **(b) `script-only`**: Same script written; user runs it later. Skill prints the exact command to run.
- **(c) `existing`**: Skill prompts for `--existing-cert-dir` (path to a directory containing `ledger-key.pem`, `ledger-cert.pem`, etc.) and copies / symlinks them into `<output-dir>/cert/`. If files are missing or filenames don't match the expected layout, skill aborts with a clear list of expected filenames.

#### A7b — Cert holder identities

Each cert is registered on the **opposite** server's identity registry by a one-time run of `register-cert` using that Server's own `.as.client.properties` file (e.g. `ledger.as.client.properties` registers the Ledger entity's cert; `auditor.as.client.properties` registers the Auditor entity's cert). The holder id is how each server looks up the other's cert at runtime. Convention: holder id matches the role name.

| | Value |
|---|---|
| **Question (Ledger holder id)** | "What `cert_holder_id` should the Ledger be registered under (used by the Auditor's properties as `scalar.dl.auditor.ledger.cert_holder_id`)?" |
| **Default** | `ledger` |
| **Question (Auditor holder id, A1=Yes only)** | "What `cert_holder_id` should the Auditor be registered under (used by the Ledger's properties as `scalar.dl.ledger.auditor.cert_holder_id`)?" |
| **Default** | `auditor` |
> 3-entity model (plan-010 correction): `ledger.as.client.properties` and `auditor.as.client.properties` use the Server's own role names as their `entity.id` — **NOT** a separate "admin" identity. The Ledger server registers itself as `entity.id=ledger` (using `ledger-cert.pem`); the Auditor server registers itself as `entity.id=auditor`. There is no separate human-admin entity. All human/app operations (register-cert, register-contract, register-function, execute-contract) run through `client.properties` (entity.id = `client`), set in Phase 9. The "admin entity" was a misdesign introduced and then removed during plan-010 verification.

> Holder ids are arbitrary strings but should be unique across all identities registered on a server. Production deployments often use FQDN-style ids (`ledger.example.com`) for traceability.

#### A7c — Cert version + validity

| | Value |
|---|---|
| **Question (validity)** | "Validity period (days) for the self-signed certs (overrideable via `VALIDITY_DAYS` env when the script runs)?" |
| **Default** | `3650` (10 years — convenient for getting-started / dev) |
| **Question (cert version)** | "Initial `cert_version` for all three identities? (You bump this when rotating keys; the on-server registry keeps multiple versions.)" |
| **Default** | `1` |

#### A7d — (removed; admin entity does not exist in the 3-entity model)

Previously this step resolved paths for an "admin" cert holder. With the corrected 3-entity model (ledger / auditor / client — no admin), the relevant cert paths are:

| | Value |
|---|---|
| **Ledger server cert** | `./cert/ledger-cert.pem` + `./cert/ledger-key.pem` (used by `ledger.as.client.properties`) |
| **Auditor server cert** (A1=Yes) | `./cert/auditor-cert.pem` + `./cert/auditor-key.pem` (used by `auditor.as.client.properties`) |
| **Runtime client cert** | `./cert/client-cert.pem` + `./cert/client-key.pem` (used by `client.properties`, set in Phase 9) |
| **Path location** | All under `<output-dir>/cert/`. Whoever runs the CLI runs from `<output-dir>/` so the `./cert/...` paths resolve. |

#### A7 → outputs

| File | A2 = `digital-signature` | A2 = `hmac` |
|---|---|---|
| `<output-dir>/scripts/generate-server-pki.sh` | written for all DS sub-options | not written (HMAC has no PKI) |
| `<output-dir>/cert/ledger-{key,cert}.pem` | written when A7a = `generate-now` (skill runs the script) | not written |
| `<output-dir>/cert/auditor-{key,cert}.pem` (A1=Yes) | written when A7a = `generate-now` | not written |
| `<output-dir>/cert/client-{key,cert}.pem` | written when A7a = `generate-now` (Phase 9 runtime client identity) | not written |
| `scalardl-{ledger,auditor}-custom-values.yaml` | populated with `{{ledgerCertHolderId}}` / `{{auditorCertHolderId}}` / `{{ledgerCertVersion}}` / `{{auditorCertVersion}}` from A7b / A7c | DS-specific properties omitted |
| `ledger.as.client.properties` | populated with `entity.id=ledger` + `./cert/ledger-cert.pem` + `./cert/ledger-key.pem` + `{{ledgerCertVersion}}` | DS-specific properties omitted |
| `auditor.as.client.properties` (A1=Yes) | populated with `entity.id=auditor` + `./cert/auditor-cert.pem` + `./cert/auditor-key.pem` + `{{auditorCertVersion}}` | DS-specific properties omitted |
| `<output-dir>/scripts/create-scalardl-secrets.sh` | PKI section emitted: `kubectl create secret generic ledger-keys --from-file=private-key=./cert/ledger-key.pem` (and auditor-keys if A1=Yes) | PKI section omitted |

#### Reference

- `references/scalardl-configurations.md` § "Ledger-Auditor 間サーバ間認証 (server-server) の DS / HMAC 選択" — the Ledger / Auditor required-property tables under "DS server-server 経路で必須となるプロパティ"
- `references/scalardl-pki-keys.md` (TBD — long-form notes on cert rotation, production CA migration, openssl one-liners) — to be added in a polish phase

### Phase 9 — Runtime client identity (plan-010, 3-entity model)

The runtime `client.properties` is emitted in this phase. The `client` entity is the identity an actual application uses for **every human/app operation**: register-cert (one-time), register-contract, register-function, execute-contract, list-contracts. The other two `*.as.client.properties` files belong to the Ledger / Auditor SERVERS themselves and are used only once at deploy to register the Server's own cert on the network (cross-validation prerequisite). Per ScalarDL semantics, `ContractEntry` is keyed on `(id, entityId, keyVersion)`, so Contracts must be registered by the entity that will execute them — which is `client`, not the Server entities.

#### A9a — Client entity_id

| | Value |
|---|---|
| **Question** | "What `entity_id` should the runtime client identify as (used in `client.properties` as `scalar.dl.client.entity.id`)?" |
| **Default** | `client` |
| **Effect** | Substitutes `{{clientEntityId}}` in `client.properties.tmpl`. For DS pattern, Phase 7's `generate-server-pki.sh` already emits `client-cert.pem` + `client-key.pem` (one fixed naming, not parameterised by A9a — the file names stay `client-*` regardless; only the entity_id in properties varies). For HMAC, the client.properties references `<CLIENT_HMAC_SECRET_KEY>` placeholder for the user to replace before register-secret. |

#### A9 → outputs

| File | Emitted? | Content |
|---|---|---|
| `client.properties` | always | Runtime client config: connection (Ledger + Auditor when A1=Yes), auth (DS: cert paths to `./cert/client-*.pem` / HMAC: `<CLIENT_HMAC_SECRET_KEY>` placeholder), `auditor.enabled` matches A1 (true → cross-validation on every call), TLS settings match A4h |
| `cert/client-{key,cert}.pem` | DS pattern only | Phase 7 `generate-server-pki.sh` emits these (one additional `gen_pair client` call) |
| `env-template.sh` | always | If HMAC pattern: adds `export CLIENT_HMAC_SECRET_KEY=''` slot |

> Note (Auditor cross-validation): when A1=Yes, `client.properties` has `scalar.dl.client.auditor.enabled=true` — every execute-contract call goes to BOTH Ledger and Auditor. This is the WHOLE point of having an Auditor for runtime traffic. The Server `*.as.client.properties` keep `auditor.enabled=false` because each Server's `register-cert` is run separately against that Server.

### Phase 8 — Confirmation + write outputs (always)

This is the final phase. It runs two things in sequence:

1. Show a decision summary and ask the user to confirm.
2. Render and write all files; report results.

Phase 8 always runs (regardless of A2). HMAC secret generation has been moved out of the skill's Q&A flow as of 2026-05-11 (D19 below) — the generated `start-scalardl.sh` runs `openssl rand` at deploy time if the corresponding env vars in `env.sh` are empty, then prints them so the user can save back to `env.sh` for stable redeploy.

#### A8a — (deprecated; HMAC generation moved to runtime, see D19)

Previously this step ran `openssl rand` to generate `ledgerHmacCipherKey` / `auditorHmacCipherKey` / `serverServerHmacSecret` and baked them into `create-scalardl-secrets.sh` as literals. Removed because:

- It coupled the skill's Q&A timing to credential lifecycle (re-running the skill rotated keys, invalidating registered client entities)
- It made credentials visible in the skill's run transcript (transient but observable)
- It conflicted with the env-driven Secret pattern (D19) where shell env vars are the canonical source

The new flow: `start-scalardl.sh` checks `${LEDGER_HMAC_CIPHER_KEY}` etc. at deploy time. If unset, generates via `openssl rand -base64 32` and prints `export LEDGER_HMAC_CIPHER_KEY='<value>'` so the user can save it back to `env.sh`. Re-running the skill no longer rotates keys — only `bash scripts/stop-scalardl.sh && rm cert/*.pem; unset *_HMAC_*; bash scripts/start-scalardl.sh` does.

> Counterintuitive standalone case (A1=No × A2=HMAC × A3=Yes): the AssetProof signing key falls through to DS because `LedgerConfig` doesn't populate `serversAuthHmacSecretKey` when `auditor.enabled=false`. In this single case, Phase 7 (DS PKI) **also** runs to generate the Ledger key. The skill notifies the user before generation that this is happening and why. (See Phase 3 § "Counterintuitive case" for the full source citation.)

> Counterintuitive standalone case (A1=No × A2=HMAC × A3=Yes): the AssetProof signing key falls through to DS because `LedgerConfig` doesn't populate `serversAuthHmacSecretKey` when `auditor.enabled=false`. In this single case, Phase 7 (DS PKI) **also** runs to generate the Ledger key. The skill notifies the user before generation that this is happening and why. (See Phase 3 § "Counterintuitive case" for the full source citation.)

#### A8b — Decision summary

Display the full set of decisions and generated material so the user can audit before any file is written:

```
=== ScalarDL config generation summary ===

ScalarDL target version: 3.13.0+ (constructor floor enforced)
Output directory:        ./scalardl-config/

Deployment shape:        Ledger + Auditor    (or: Ledger-only)
Auth pattern:            digital-signature   (or: hmac)
AssetProof:              enabled (forced by Auditor=Yes)
                         (or: enabled / disabled per A3 Y/N)

Connection (k8s):
  Ledger:   svc/scalardl-ledger.default port 50051 (privileged 50052)
  Auditor:  svc/scalardl-audit.default port 40051 (privileged 40052)
Admin CLI mode:          envoy-loadbalancer → <LEDGER_EXTERNAL_IP>:50051 / <AUDITOR_EXTERNAL_IP>:40051
                         (or: port-forward → localhost:* / external → user-supplied hostname)
TLS:                     off

ScalarDB (Ledger):       cassandra @ cassandra (system tables only)
ScalarDB (Auditor):      cassandra @ cassandra-auditor (independent infra)

License:                 trial   (PEM source: references/license-pem/trial-cert.pem)
License key:             <YOUR_LICENSE_KEY>  (placeholder; provide via Secret)

[DS branch] Server PKI:
  Strategy:      generate-now
  Cert holder ids: ledger=ledger, auditor=auditor, admin=admin
  Cert version:  1
  Validity:      3650 days
  Output paths:  ./scalardl-config/cert/{ledger,auditor,admin}-{key,cert}.pem

[HMAC branch] Generated secrets (save these!):
  HELM_LEDGER_HMAC_CIPHER_KEY              =   <base64-32 random>
  HELM_AUDITOR_HMAC_CIPHER_KEY             =   <base64-32 random>      (Auditor=Yes)
  HELM_LEDGER_SERVERS_HMAC_SECRET_KEY      =   <base64-32 random>      (Auditor=Yes)
  HELM_AUDITOR_SERVERS_HMAC_SECRET_KEY     =   <same value as above>   (Auditor=Yes)

Files to be written:
  scalardl-config/scalardl-ledger-custom-values.yaml
  scalardl-config/scalardl-auditor-custom-values.yaml          [Auditor=Yes]
  scalardl-config/schema-loader-ledger-custom-values.yaml
  scalardl-config/schema-loader-auditor-custom-values.yaml     [Auditor=Yes]
  scalardl-config/ledger.as.client.properties                  (entity.id=ledger — Server's own cert holder, one-time register-cert)
  scalardl-config/auditor.as.client.properties                 (entity.id=auditor — Server's own cert holder, Auditor=Yes only)
  scalardl-config/client.properties                            (entity.id=client — runtime app's identity; register-cert + register-contract + register-function + execute) [plan-010]
  scalardl-config/scripts/env-template.sh
  scalardl-config/scripts/init-schemas.sh
  scalardl-config/scripts/start-scalardl.sh
  scalardl-config/scripts/stop-scalardl.sh
  scalardl-config/scripts/generate-server-pki.sh               [DS pattern]
  scalardl-config/scripts/create-scalardl-secrets.sh
  scalardl-config/cert/...                                     [DS + generate-now — incl. client-cert.pem / client-key.pem per plan-010]
  scalardl-config/license-pem/<type>-cert.pem                  [License ≠ skip]
  .scalardl-starter-skills.json (writer extension)                     [P9, separate phase]
```

If the deployment is HMAC pattern, this is the **only** time the secrets are visible. The skill does **not** persist them anywhere readable after Phase 8d completes (they only live in the Secret-creation script). User must save them to a secret manager before continuing if rotation / replay is needed.

#### A8c — Confirmation

| | Value |
|---|---|
| **Question** | "Write the {{fileCount}} files above to {{outputDir}}? [Y/n]" |
| **Default** | `Y` |
| **If `n`** | Skill prints "Aborted. No files written. Re-run the skill to make changes." and exits. No partial write. |

#### A8d — Write all files + post-write report

**Required write checklist** — before printing the post-write report, render + Write each file in this list. Skip a file only when its gating condition is false. **Do not deviate from this list** (the "templates directory layout" earlier is informational; this is the authoritative emission list, in render order):

| # | Template (under `skills/scalardl-generate-config/templates/`) | Output (under `<output-dir>/`) | Skip when |
|---|---|---|---|
| 1 | `values/scalardl-ledger-custom-values.yaml.tmpl` | `scalardl-ledger-custom-values.yaml` | never |
| 2 | `values/schema-loader-ledger-custom-values.yaml.tmpl` | `schema-loader-ledger-custom-values.yaml` | never |
| 3 | `values/scalardl-auditor-custom-values.yaml.tmpl` | `scalardl-auditor-custom-values.yaml` | Auditor=No (A1) |
| 4 | `values/schema-loader-auditor-custom-values.yaml.tmpl` | `schema-loader-auditor-custom-values.yaml` | Auditor=No (A1) |
| 5 | `properties/ledger.as.client.properties.tmpl` | `ledger.as.client.properties` | never |
| 6 | `properties/auditor.as.client.properties.tmpl` | `auditor.as.client.properties` | Auditor=No (A1) |
| 7 | `properties/client.properties.tmpl` | `client.properties` | **never** (plan-010 runtime client identity — DO NOT skip) |
| 8 | `scripts/env-template.sh.tmpl` | `scripts/env-template.sh` | never |
| 9 | `scripts/init-schemas.sh.tmpl` | `scripts/init-schemas.sh` | never |
| 10 | `scripts/start-scalardl.sh.tmpl` | `scripts/start-scalardl.sh` | never |
| 11 | `scripts/stop-scalardl.sh.tmpl` | `scripts/stop-scalardl.sh` | never |
| 12 | `scripts/create-scalardl-secrets.sh.tmpl` | `scripts/create-scalardl-secrets.sh` | never |
| 13 | `scripts/generate-server-pki.sh.tmpl` | `scripts/generate-server-pki.sh` | DS pattern: never. HMAC + proof.enabled=true (counterintuitive standalone OR Auditor=Yes chart-forced): emit. Otherwise (HMAC + no-proof): skip. |
| 14 | (copy, not template) `references/license-pem/<type>-cert.pem` | `license-pem/<type>-cert.pem` | License=skip |
| 15 | (run script) `scripts/generate-server-pki.sh` to emit `cert/*.pem` | `cert/{ledger,auditor,client}-{key,cert}.pem` (+ `*-tls-*.pem` when TLS=Yes) | A7a=`script-only` (user runs the script later) — but `script-only` should be rare; default is `generate-now` |

After all writes, **self-verify by listing the output dir** (e.g. `ls <output-dir>/`) and confirm each "never"-skipped row produced its file. If any file is missing, the run is a failure — re-render the missing one before the post-write report.

After successful write, prints:

```
Wrote <N> files to ./scalardl-config/

Next steps (env-driven Helm deploy — user pattern):
  1) Copy env-template and fill in values (license / DB cred / etc.):
       cd scalardl-config
       cp scripts/env-template.sh env.sh
       $EDITOR env.sh        # fill in LEDGER_LICENSE_KEY / *_DB_USERNAME / *_DB_PASSWORD / etc.
       echo env.sh >> .gitignore  # NEVER commit secrets

  2) One-time schema bootstrap (only after a fresh backend DB):
       bash scripts/init-schemas.sh
     Runs helm install schema-loader for Ledger (+ Auditor) and waits for the
     Job(s) to complete. Skip this on subsequent redeploys — schemas persist.

  3) Server deploy / redeploy:
       bash scripts/start-scalardl.sh
     PKI gen (DS) + Secret create (idempotent) + helm install Ledger (+
     Auditor) + wait Ready. For HMAC pattern with empty HMAC env vars, the
     script generates fresh keys via `openssl rand -base64 32` and prints
     them so you can save them back to env.sh for stable redeploy. Re-run
     after stop-scalardl.sh (schemas survive, no need to re-init).

  4) Get the Envoy LoadBalancer external IP and patch ALL three properties files:
       LEDGER_IP=$(kubectl get svc scalardl-ledger-envoy -n <ns> -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
       sed -i "s/<LEDGER_EXTERNAL_IP>/${LEDGER_IP}/" ledger.as.client.properties
       sed -i "s/<LEDGER_EXTERNAL_IP>/${LEDGER_IP}/" client.properties
       # Auditor=Yes: also patch <AUDITOR_EXTERNAL_IP> in auditor.as.client.properties + client.properties

  5) Register the Server-side cert holders (cross-validation prerequisite, one-time):
       scalardl register-cert    --properties ledger.as.client.properties     [DS]
       scalardl register-secret  --properties ledger.as.client.properties     [HMAC]
       # Auditor=Yes: also
       scalardl register-cert    --properties auditor.as.client.properties    [DS]
       scalardl register-secret  --properties auditor.as.client.properties    [HMAC]

  6) Register the runtime client identity (the entity that will own Contracts and call execute):
       # For HMAC: first replace <CLIENT_HMAC_SECRET_KEY> in client.properties
       # with `openssl rand -base64 32` (the same value is passed to register-secret).
       scalardl register-cert    --properties client.properties               [DS]
       scalardl register-secret  --properties client.properties               [HMAC]

  7) Register + invoke Contracts/Functions — **all via client.properties** (the client
     entity must self-register because ScalarDL Contracts are entity-scoped):
       scalardl register-contract  --properties client.properties \
           --contract-id <Id> --contract-binary-name <fqn> --contract-class-file <path>.class
       scalardl register-function  --properties client.properties \
           --function-id <Id> --function-binary-name <fqn> --function-class-file <path>.class
       scalardl execute-contract   --properties client.properties \
           --contract-id <Id> --contract-argument '{"...": ...}' \
           [--function-id <Id>]
       scalardl list-contracts     --properties client.properties
       # When Auditor=Yes, the client SDK automatically cross-validates against
       # the Auditor on every execute-contract (scalar.dl.client.auditor.enabled=true
       # is set in client.properties).

  Tear down everything (delete helm releases + Secrets + namespace):
       bash scripts/stop-scalardl.sh
```

Behind the scenes, all sensitive values (license_key / DB username / DB password / HMAC keys) live in two K8s Secrets (`ledger-credentials-secret` and `auditor-credentials-secret`, plus `*-key-secret` for DS PKI file mounts) and reach the ScalarDL Server pods via `extraEnvFrom`. Helm values only contain `${env:VAR}` references — no inline placeholders that the user has to find and replace. This matches the deployment pattern documented in `~/dl/3.11.hmac/` (user reference implementation, 2026-05-11).

Failure during write: skill aborts immediately, leaving any already-written files in place but marking them with a `.partial` extension so the user can audit / clean up before re-running.

### Reference

- `references/scalardl-configurations.md` § "Ledger-Auditor 間サーバ間認証 (server-server) の DS / HMAC 選択" — under "HMAC server-server 経路で必須となるプロパティ", plus "Skill 取り扱い方針 (deprecated 系プロパティ)"
- D8 / D11 / D18 in `docs/plan-008-skill-001-generate-config.md`

## Manifest hand-off: `.scalardl-starter-skills.json` (D4)

After Phase 8d successfully writes all files, the skill writes a `serverConfigGenerated` block into `<cwd>/.scalardl-starter-skills.json` so that downstream skills (chiefly the future M3 `generate-scalardl-environment`) can pick up connection / auth-pattern decisions without re-asking. Per D4, this is **writer-only** for now — no skill currently reads the block, and re-running this skill does not re-use a prior `serverConfigGenerated` (it asks the full Q&A again to avoid stale state).

> **This manifest is NOT a template.** It is a live JSON value you write directly with `Write`. The block-structure schema below uses `<...>` notation to describe what each field _should contain_; you must replace those descriptions with the actual concrete values at write time. For example, `"generatedAt": "<ISO 8601 UTC timestamp>"` in the schema becomes `"generatedAt": "2026-05-11T15:42:00Z"` in the file you write — compute the current UTC timestamp at the moment you do the `Write`, do not leave a literal placeholder like `"${GEN_AT}"` or `"__GENERATED_AT__"` in the JSON. Same goes for `<plugin.json version>`, `<A4a>` etc. — resolve to the concrete value before writing.

### Block structure

```jsonc
{
  "serverConfigGenerated": {
    "generatedAt": "<ISO 8601 UTC timestamp — compute via `date -u +%Y-%m-%dT%H:%M:%SZ` at write time>",
    "skillVersion": "<plugin.json version, e.g. 0.4.0-rc1>",
    "deployment": "ledger" | "ledger+auditor",
    "authPattern": "digital-signature" | "hmac",
    "scalardlVersion": "<from A0a, e.g. 3.13.0>",
    "outputDir": "<from A0b, e.g. ./scalardl-config/>",
    "connection": {
      "ledger":  { "serviceName": "<A4a>", "namespace": "<A4b>", "port": <A4c.grpc>, "privilegedPort": <A4c.privileged>, "adminClientHost": "<A4g resolves to <LEDGER_EXTERNAL_IP> placeholder | localhost | external host>" },
      "auditor": { "serviceName": "<A4d>", "namespace": "<A4e>", "port": <A4f.grpc>, "privilegedPort": <A4f.privileged>, "adminClientHost": "<A4g>" },
      "adminCliMode": "envoy-loadbalancer | port-forward | external"
      // "auditor" key omitted entirely when deployment == "ledger"
    },
    "scalarDb": {
      "ledger":  { "storage": "<A5a>", "contactPoints": "<A5b>" },
      "auditor": { "storage": "<A5e>", "contactPoints": "<A5f>" }
      // "auditor" key omitted entirely when deployment == "ledger"
      // username / password are NEVER persisted here — they live only in Helm values (or Secret) at deploy time
    },
    "license": {
      "type": "trial" | "production" | null,
      "keyHandling": "placeholder" | "provide-now"
      // "keyHandling" omitted when type == null
      // license_key value itself is NEVER persisted in the manifest
    },
    "ds": {
      "certHolderIds": { "ledger": "<A7b>", "auditor": "<A7b>", "admin": "<A7b>" },
      "certVersion": <A7c, e.g. 1>,
      "validityDays": <A7c, e.g. 3650>,
      "pkiOutDir": "<resolved, e.g. ./scalardl-config/cert/>"
      // entire "ds" key omitted when authPattern == "hmac" (except in the standalone-HMAC-with-proof corner)
    },
    "outputs": {
      "scalardlLedgerValues":      "<relative path to ledger custom-values.yaml>",
      "scalardlAuditorValues":     "<...>",     // omitted if deployment == "ledger"
      "schemaLoaderLedgerValues":  "<...>",
      "schemaLoaderAuditorValues": "<...>",     // omitted if deployment == "ledger"
      "ledgerAsClient":            "<relative path to ledger.as.client.properties>",
      "auditorAsClient":           "<...>",     // omitted if deployment == "ledger"
      "createSecretsScript":       "<relative path to scripts/create-scalardl-secrets.sh>",
      "generateServerPkiScript":   "<...>",     // omitted if authPattern == "hmac" (except standalone-HMAC-with-proof corner)
      "pkiDir":                    "<...>",     // omitted if no PKI generation took place
      "licensePemDir":             "<...>"      // omitted if license.type == null
    }
  }
  // Other top-level keys (projectName, auditorEnabled, scalardlSdkVersion,
  // contractsAdded, functionsAdded, etc.) written by other skills are
  // preserved verbatim across this skill's writes. See "Merge rules" below.
}
```

**What is intentionally NOT persisted**:
- `license_key` (real or placeholder) — lives only in `create-scalardl-secrets.sh` and the eventual Kubernetes Secret
- `*HmacCipherKey` / `serverServerHmacSecret` — lives only in `create-scalardl-secrets.sh` (HMAC pattern)
- ScalarDB `username` / `password` — lives only in Helm values (placeholders) or in a Kubernetes Secret at deploy time

This invariant is checked by the smoke test in P10: grep the manifest for known sensitive substrings and assert zero matches.

### Merge rules (writer)

When `<cwd>/.scalardl-starter-skills.json` already exists:

1. Parse the existing JSON. If parsing fails, **abort** (do not overwrite a malformed-but-perhaps-recoverable file). Report the error and ask the user to fix or delete the file.
2. Verify the file is a JSON object at the top level. If it is an array / scalar / non-JSON, abort.
3. Replace **only** the top-level `serverConfigGenerated` key. All other top-level keys are preserved verbatim — that includes any unknown keys the user (or a different scalardl-starter-skills version) added.
4. Write back with **2-space indent**, **stable key ordering** (top-level keys sorted alphabetically; `serverConfigGenerated` sorted in normally — no special ordering), trailing newline.

When the file does not exist at `<cwd>`:

- Create a new file containing **only** the `serverConfigGenerated` block. Other skills will add their own blocks when they next run.

### Reader (deferred to M3)

The reader is intentionally not implemented in this skill. M3 (`generate-scalardl-environment`) will consume `serverConfigGenerated` to seed its own Q&A defaults (avoiding double-entry of host / port / auth pattern). This split is per **D4** in plan-008 — if the reader were here, the Skill would conflate "generate Server admin/deploy" with "consume previous run's defaults", which violates the single-purpose principle.

### Failure modes

| Failure | Skill behavior |
|---|---|
| `<cwd>/.scalardl-starter-skills.json` is malformed JSON | Abort. Print the parse error path + line. Ask user to fix or delete. |
| `<cwd>/.scalardl-starter-skills.json` is a non-JSON file (e.g. binary, plain text) | Abort. Refuse to overwrite a foreign file. |
| `<cwd>/.scalardl-starter-skills.json` is a directory | Abort. Surface the OS error. |
| Insufficient permissions to write `<cwd>/.scalardl-starter-skills.json` | Abort with the OS error. No retry. The Phase 8d files are already written successfully — only the manifest update fails. User can fix permissions and re-run; the manifest will be (re-)written on the next successful Phase 8d. |
| Concurrent skill runs | Not supported. The skill is single-user; concurrent runs may race on the manifest write. (No locking implemented; user is expected to run skills sequentially.) |

## Settled decisions referenced from plan-008

This skill embodies these decisions from `plan-008.md` (truncated; see plan for full rationale):

- **D2** — M2 = Server-side admin/deploy 6 files + Server PKI + License + (HMAC shared secret). Client-side runtime config (`client.properties`) is M3.
- **D7** — Authentication is restricted to "all DS" or "all HMAC". Mixed configurations are not supported.
- **D9** — v5.0.0 deprecation wording is stripped from Skill output (this SKILL.md / Q&A / template render). The reference doc (`scalardl-configurations.md`) is a **Local fork** edited directly in this repo (plan-013, 2026-05-14); internal scaffolding (source-code citations, errata sub-sections, sync history) has been folded into the property tables or removed. Edit the file in place — there is no upstream sync step anymore.
- **D11** — PKI: `SHA256withECDSA` × `prime256v1` (NIST P-256), confirmed via `DigitalSignatureSigner.java:21` and `helm-charts/.github/{ledger,auditor}-key.pem` sample keys.
- **D12** — PKI generation uses openssl in-skill via Bash; failure falls back to "write the script only, user runs it later".
- **D13** — Targets ScalarDL 3.13.0+ exclusively (3.12.x rejected at A0a).
- **D15** — License: trial/production cert PEMs bundled in `references/license-pem/`; `license_key` emitted as placeholder.
- **D18** — 4 cryptographic operations, with (3) Server-Server and (4) AssetProof signing bound to `servers.authentication.hmac.secret_key`.

## How this skill stays self-contained

Per the runtime-independence rule (CLAUDE.md project section + Plan 001 §10.2 / M1.9):

- All ScalarDL knowledge is in `references/scalardl-configurations.md` — a **Local fork** (plan-013), edit it directly in this repo. There is no automatic sync from any external source.
- License PEMs are physically bundled in `references/license-pem/`
- This skill does **not** read `~/claude/dl/scalardl/` or `~/IdeaProjects/demo-dl/` at runtime

If an upstream `~/claude/dl/docs/scalardl-configurations.md` (curated by a parallel Claude session) gains useful updates, **hand-merge** the relevant diff into this Local fork: read the upstream diff, decide which property rows / explanatory paragraphs apply, and edit `references/scalardl-configurations.md` directly. Keep the strip rules (no inline source-code citations like `LedgerConfig.java:511`, no errata sub-sections, no sync history blocks) when merging.

Strip of `v5.0.0` / `[非推奨]` is a render-time concern, handled in templates and Q&A — not in the reference doc.
