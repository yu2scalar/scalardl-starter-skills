---
name: scalardl-generate-springboot-starter
description: Q&A-driven generation of a Spring Boot + Swagger starter project that uses the ScalarDL Java Client SDK. Detects an adjacent scalardl-generate-config bundle (Branch A → consume host/port/auth/cert/HMAC from it) or runs a standalone Q&A (Branch B → DS or HMAC chosen explicitly). Produces an empty project with the register / execute REST infrastructure but no Contract or Function definitions — use scalardl-add-contract and scalardl-add-function to fill those in.
---

# scalardl-generate-springboot-starter

> Status: **v0.6.0-rc1 (2026-05-13 — plan-012 v2 implementation: M2 bundle auto-detect + Branch A/B split + HMAC auth + literal-bake secret handling + production warning block + .gitignore enforcement. Preset matrix unchanged from v0.3.0: 3 Contract + 2 Function. Targets ScalarDL 3.13.0+ exclusively, `--release 17`.)**
> Related plans: plan-012 v2 (M2 bundle Branch A/B + HMAC, source of truth), plan-002 (skill restructure + presets), plan-007 (preset consolidation + rename). Plan docs live in the repo under `docs/` for contributors.

## Overview

Scaffolds a working Spring Boot project around the ScalarDL Java Client SDK. The generated app exposes REST endpoints for registering and executing Contracts and Functions (whose source is rendered at runtime from JSON definitions and compiled with `javax.tools.JavaCompiler`). This skill **only emits the project shell**; populate it with `scalardl-add-contract` and `scalardl-add-function` after scaffolding.

**v0.6.0-rc1 highlights**:

- **Two-branch design** (plan-012 v2 §0): auto-detects an adjacent `./scalardl-config/` bundle emitted by `scalardl-generate-config`. Branch A consumes it (no duplicate Q&A); Branch B is the previous v0.5.0 standalone flow with HMAC added.
- **DS and HMAC both supported** as first-class authentication methods (Branch A picks whichever the bundle uses; Branch B asks A15).
- **Secret material is baked as literal values** into the generated project (HMAC secret_key → application.properties, DS private key → cert/). The scaffold writes a `.gitignore` that excludes both, plus a multi-line warning block at the top of application.properties that documents the k8s Secret / Vault / Spring Cloud Config migration paths. The starter is a **sample/demo**; production users follow the warning block.

### What this skill emits

- Spring Boot 3.5.x + Java 17 + Gradle (Groovy DSL) scaffold
- springdoc-openapi (Swagger UI) at `/swagger-ui/index.html`
- ScalarDL Java Client SDK wired into a service layer (DS + HMAC + TLS + Auditor all supported on the same property set)
- Contract / Function generators (Mustache-driven, runtime compile)
- All preset templates ready to use:
  - Contract: `READ_ASSET`, `PUT_ASSET`, `PUT_ASSETS`
  - Function: `UPSERT_RECORD`, `UPSERT_RECORDS`
- Per-resource REST controllers: `ContractPreviewController`, `ContractRegisterController`, `ContractRegisterFromSourceController`, `ContractExecuteController`, `FunctionPreviewController`, `FunctionRegisterController`, `FunctionRegisterFromSourceController`, `CertificateController` (dispatches to `ClientService::registerSecret` when authMethod=hmac, else `ClientService::registerCertificate`), `LedgerValidationController` (`GET /api/ledger/validate` — verifies an asset's ledger integrity via `ClientService::validateLedger`)
- An empty `examples/` directory (with `.gitkeep`) where `scalardl-add-contract` / `scalardl-add-function` write definition JSONs as the user adds them
- A `.gitignore` that excludes `cert/`, `src/main/resources/application.properties`, and the usual build artefacts (because both DS keys and HMAC secrets are baked as literal values)
- A project-marker manifest `.scalardl-starter-skills.json` at the project root that downstream `add-*` skills read

### What's intentionally out of scope

- Generating Contract or Function JSON definitions — use `scalardl-add-contract` / `scalardl-add-function` for that.
- Behaviour-rich Contracts (custom modify logic, validation, multi-step branching) — those are added downstream by Claude Code editing the generated `.java`, not encoded in JSON.
- **Production secret management** (k8s Secret / Vault / Spring Cloud Config) — the scaffold bakes literal sample-grade secrets and documents the migration paths inside `application.properties`; productionising is left to the user.
- **Mixed authentication patterns** (DS Client + HMAC Server-Server, etc.) — plan-008 D7: skill supports "all DS" or "all HMAC" only.
- Bench CLI, Helm deployment — see Plan 002 §11 for the v0.2 candidate list.

## Phase 0 — M2 bundle detection (run BEFORE A1)

Before any Q&A, scan the current working directory for an adjacent `scalardl-generate-config` bundle and offer to consume it:

```
Step 1. Test whether ./scalardl-config/ exists as a directory.
        (This is where scalardl-generate-config writes its Helm values / properties /
         scripts / cert by default — A0b in M2 SKILL.md.)

Step 2. Test whether ./scalardl-config/client.properties exists as a file.

Step 3. Test whether ./.scalardl-starter-skills.json (CWD ROOT, NOT inside the bundle dir)
        exists, parse it, and confirm the top-level key `serverConfigGenerated`
        is present with `authPattern` equal to "digital-signature" or "hmac".

        Path rationale: M2 (scalardl-generate-config) SKILL.md "Manifest hand-off"
        explicitly writes `serverConfigGenerated` into `<cwd>/.scalardl-starter-skills.json`
        (the project-root manifest, NOT a bundle-internal file). So the manifest
        lives at the same level as `./scalardl-config/`, not inside it.

Step 4. If all of Steps 1..3 are true, parse the following fields from the manifest:
          serverConfigGenerated.authPattern             → "digital-signature" | "hmac"
          serverConfigGenerated.deployment              → "ledger" | "ledger+auditor"
                                                          (treat "ledger+auditor" as auditor.enabled=true)
          serverConfigGenerated.scalardlVersion         → A3 default
          serverConfigGenerated.connection.ledger.serviceName / .port (informational)
        Then prompt the user:

   ❓ M2 bundle detected at ./scalardl-config/
        - authPattern      : <digital-signature | hmac>
        - deployment       : <ledger | ledger+auditor>
        - scalardlVersion  : <e.g. 3.13.0>
        - bundle skill ver : <e.g. 0.4.0-rc1>
      Consume this bundle to skip the Phase-1 connection / auth Q&A? (Y/n)

   Y → Branch A (§ "Q&A — Branch A (M2 consume)" below)
   n → Branch B (§ "Q&A — Branch B (standalone)" below); warn the user that
       they will be asked all connection / auth questions explicitly.

Step 5. If any of Steps 1..3 fail, silently fall through to Branch B with no notice.
```

**Why a Y/n prompt instead of auto-Branch-A?** Some users may have an old bundle in `./scalardl-config/` and want a fresh standalone scaffold pointed at a different Ledger. The cost of one confirmation is small compared to the surprise of a wrong auto-consume.

**Bundle path is fixed at `./scalardl-config/`** (and manifest path is fixed at `./.scalardl-starter-skills.json`). If the bundle is somewhere else, choose Branch B and supply the path at A0 (below). Multi-bundle selection UI is intentionally out of scope (plan-012 v2 §5).

## Q&A — Branch A (M2 consume)

When the user confirms Y at Phase 0, ask **only project basics** and consume everything else from the bundle:

| # | Question | Default |
|---|---|---|
| A1 | Project name (also the output directory) | `demo-scalardl-app` |
| A2 | Java package | `com.example.demoscalardl` |
| A2a | Project description | `Spring Boot demo for the ScalarDL Java Client SDK` |
| A3 | ScalarDL Java Client SDK version | Bundle manifest's `targetScalardlVersion` if present, else `3.13.0`. **Rejects < 3.13.0** (see About A3) |
| A4 | Spring Boot version | `3.5.7` |
| A5 | Java toolchain | `17` |
| A6 | Build tool | Gradle (Groovy DSL) |
| A7 | Output directory | `./<A1>/` |

**A8..A16 are skipped.** All connection / auth / cert / TLS / Auditor values come from `./scalardl-config/client.properties` (parsed) + `./.scalardl-starter-skills.json` at the **CWD root** (auth pattern + deployment metadata; NOT inside the bundle dir). See § "Branch A — bundle consumption logic" below for the exact mapping.

## Q&A — Branch B (standalone)

When Phase 0 fails or user declines, run the standalone Q&A. A1..A7 are identical to Branch A; A8 is removed (Phase 0 supersedes the v0.5.0 "pull from scalardl-generate-config?" question).

| # | Question | Default |
|---|---|---|
| A1..A7 | (same as Branch A) | (same) |
| A0 (optional) | M2 bundle path if not at `./scalardl-config/` | (blank — pure standalone) |
| A9 | Ledger host | `localhost` |
| A10 | Ledger port (gRPC) | `50051` |
| A11 | Ledger privileged port | `50052` |
| A12 | Ledger TLS enabled? | `false` |
| A13 | Client entity id | `<A1>-client` (e.g. `demo-scalardl-app-client`) |
| A14 | Ledger deployment shape | `Ledger only` (default) or `Ledger + Auditor` |
| A15 | Authentication method | `digital-signature` (default) or `hmac` |

If A14 = `Ledger + Auditor`:

| # | Question | Default |
|---|---|---|
| A14a | Auditor host | `localhost` |
| A14b | Auditor port (gRPC) | `40051` |
| A14c | Auditor privileged port | `40052` |
| A14d | Auditor TLS enabled? | match A12 |

If A15 = `hmac`:

| # | Question | Default |
|---|---|---|
| A15a | HMAC secret_key version | `1` |

(The HMAC secret itself is **not** asked — the skill generates a fresh `openssl rand -base64 32` value at scaffold time and bakes it as a literal into `application.properties`. See § "Branch B — HMAC secret generation" below.)

If A12 = `true` (Ledger TLS):

| # | Question | Default |
|---|---|---|
| A16a | TLS ca_root_cert_path | (blank — falls back to system truststore) |
| A16b | TLS override_authority (envoy SAN DNS, e.g. `<ledger>-envoy.<ns>.svc.cluster.local`) | (blank) |

If A14d = `true` (Auditor TLS):

| # | Question | Default |
|---|---|---|
| A16c | Auditor TLS ca_root_cert_path | (blank) |
| A16d | Auditor TLS override_authority | (blank) |

If A0 (M2 bundle path override) is non-blank, re-run Phase 0 against that path and, if it succeeds, switch to Branch A.

**About A3 (SDK version coupling — important; 3.13.0+ ONLY):**

This skill targets **ScalarDL Ledger / Auditor v3.13.0 or later** exclusively. **Older versions are rejected at scaffold time.** The reason:

- ScalarDL Ledger 3.12.x and earlier ship a Java 8 JRE Docker image (`eclipse-temurin:8-jre-jammy`).
- ScalarDL Ledger 3.13.0+ ships a Java 21 JRE Docker image (`eclipse-temurin:21-jre-jammy`).
- The runtime compiler (`JavaCompilerService`) emits Java 17 bytecode (class file version 61.0). Java 17 bytecode is loadable by Java 21 (3.13.0+) but NOT by Java 8 (3.12.x and earlier; would throw `UnsupportedClassVersionError` at Contract register time).

If the user enters an SDK version below 3.13.0, the skill must:

```
❌ This skill targets ScalarDL 3.13.0 or later.
   You entered: <X.Y.Z>
   Reason: the runtime compiler emits Java 17 bytecode, which the Java 8 JRE
   in Ledger 3.12.x and earlier cannot load. Either upgrade your deployment
   to 3.13.0+, or use an older release of this skill (which targeted Java 8).
```

The SDK version must also match the running Ledger / Auditor server version. A 3.14 SDK against a 3.13 server is fine (newer client compatible with same major); a 3.13 SDK against a 3.14 server may drift on protocol details. If you don't know the server version, ask the operator before scaffolding.

**About A9..A12 (Ledger connection — required to actually run, Branch B only):**

The host / port / TLS values land in `application.properties` as `scalardl.server-host`, `scalardl.server-port`, `scalardl.server-privileged-port`, and `scalardl.tls-enabled`. Defaults assume a local docker-compose Ledger; for a remote Ledger pass the IP/hostname and adjust ports.

**About A13 (Client entity id, Branch B only):**

This is the **id of the certificate / HMAC identity** registered against the Ledger. It is used in `application.properties` as `scalar.dl.client.entity.id` and as the entity id passed to `ClientService::registerCertificate` / `ClientService::registerSecret`. The default `<A1>-client` derives from the project name.

**About A14 (Auditor wiring — important; runtime mismatch causes `DL-LEDGER-407003`, Branch B only):**

A ScalarDL Ledger configured with Auditor enabled rejects any client request that lacks an Auditor signature. The skill must know up front so the generated `application.properties` matches the deployment.

```
Ledger deployment shape?
  1) Ledger only            (default; no Auditor)
  2) Ledger + Auditor       (Ledger and Auditor run side-by-side; client signs both)
```

> **Note — this choice also changes how `GET /api/ledger/validate` reports results.** `ClientService.validateLedger` has two distinct error semantics (ScalarDL "Validate your data"): **Ledger-only** does *not* throw on a tamper — it returns a `LedgerValidationResult` whose `StatusCode` (e.g. `INVALID_HASH`, `INVALID_OUTPUT`) signals it; **Ledger+Auditor** *throws* `ClientException(INCONSISTENT_STATES)` on a Ledger/Auditor mismatch. `ScalarDLService.validateLedger` branches on `auditor.enabled` to handle both, surfacing either as `{valid:false, code:...}` (HTTP 200, a finding — not a request error). Auditor-mode validation also needs server-side Asset Proof enabled, which the **scalardl-generate-config** deploy bundle configures (not this app).

**About A15 (Authentication method, Branch B only):**

ScalarDL supports two client authentication methods. The skill is mutually exclusive: pick one for the whole deployment (plan-008 D7 mixed-config restriction).

```
Authentication method?
  1) digital-signature   (default; uses EC P-256 cert + private key in ./cert/)
  2) hmac                (uses a Base64-encoded shared secret)
```

If `hmac`, the skill **does not ask for the secret** — it generates a fresh secret via `openssl rand -base64 32` and bakes it into `application.properties` as a literal value. See § "Branch B — HMAC secret generation" for the exact flow + the warning the user receives.

**About A15a (HMAC secret_key version, Branch B HMAC only):**

ScalarDL supports versioned HMAC secrets to allow online rotation. Version `1` is the default for new deployments; bump it when rotating an existing one. The matching `register-secret` call on the Ledger uses the same version.

**About A16 (TLS detail, Branch B only when TLS is enabled):**

When the Ledger is fronted by envoy with TLS termination, the client SDK needs:

1. **`ca_root_cert_path`** — to verify the envoy cert. Leave blank to use the JVM's system truststore (works for publicly-signed certs).
2. **`override_authority`** — the SAN DNS name in the envoy cert (e.g. `<ledger>-envoy.<ns>.svc.cluster.local`). Required when connecting via IP (e.g. minikube tunnel exposes envoy on `127.0.0.1`) or any hostname that doesn't match the cert.

Both are optional; setting them is required only when local testing surfaces TLS verification errors (`UNAVAILABLE: io exception` with a TLS handshake failure cause).

> ⚠️ **Heads-up about Contract immutability vs Function mutability** (different rules — read carefully):
>
> - **Contract** is **immutable once registered**. ScalarDL has **no API to disable, deactivate, or unregister** a registered Contract: `ContractManager.register()` (Core source `common/.../contract/ContractManager.java`) explicitly throws `CONTRACT_ALREADY_REGISTERED` if a Contract id already exists. Once on the Ledger, Contract bytecode lives there forever. Bug fixes mean **registering a new versioned id** (`<Base>V<Major>_<Minor>_<Patch>`) and **switching the client to call the new id**; old versions stay callable forever.
>
> - **Function** CAN be overwritten. `FunctionManager.register()` performs no existence check, and the underlying `ScalarFunctionRegistry.bind()` is a plain ScalarDB `put` (upsert). Re-registering a Function with the same id replaces its bytecode in place. `unbind()` (Delete) is also implemented. Functions are not part of the Ledger's audit chain (they touch ScalarDB only), so updating them is operationally safe in the same sense as updating any application code.
>
> - **Why this skill still emits versioned class names for Functions too**: trace-ability and rollback. Even though Function bytecode can be overwritten, keeping `<Base>FunctionV1_0_0`, `V1_0_1`, … alongside lets you flip clients between versions without scrambling, audit which Function executed each time, and hold a known-good fallback. Treat versioned naming as a recommended convention for Functions, not a hard ScalarDL rule.
>
> Pick A14 (and the SDK version in A3) deliberately, and prefer testing on a non-production Ledger first — Contract immutability means your mistakes are permanent.

## Branch A — bundle consumption logic

After A1..A7 are answered, perform these steps in order:

```
Step 1. Read ./scalardl-config/client.properties (Java Properties parse).
        Verify no <PLACEHOLDER> values remain.

        If any value still looks like a <NAME_IN_ANGLE_BRACKETS> placeholder
        (e.g. <CLIENT_HMAC_SECRET_KEY>, <LEDGER_EXTERNAL_IP>), STOP with:

          ❌ Bundle ./scalardl-config/client.properties still contains an
             unsubstituted placeholder: <PLACEHOLDER_NAME>
             Run `source ./scalardl-config/env.sh` first so that env-template.sh's
             `sed -i` step replaces the placeholders, then re-run this skill.

        This is the OI-B guard from plan-012 v2 §6. Silent bake of placeholder
        values would produce a starter that fails at runtime with an obscure
        auth error.

Step 2. Read ./.scalardl-starter-skills.json (CWD root, NOT bundle-internal) and extract:
          serverConfigGenerated.authPattern               → AUTH_METHOD
                                                            ("digital-signature" or "hmac")
          serverConfigGenerated.deployment                → AUDITOR_ENABLED is true iff
                                                            this is "ledger+auditor"
          serverConfigGenerated.scalardlVersion           → A3 default (override allowed)

        (The manifest is authoritative for these three flags; client.properties has
         the same information in SDK-key form and is used for the connection /
         identity values in Step 3 below. Reading both lets Phase 0 fail-fast
         before the heavier Step 3 parse if the manifest is malformed.)

Step 3. Map bundle SDK keys to scaffold Mustache variables for application.properties.tmpl:

  Bundle key (client.properties)                          → Mustache var
  ────────────────────────────────────────────────────────────────────────
  scalar.dl.client.server.host                            → SCALARDL_HOST
  scalar.dl.client.server.port                            → SCALARDL_PORT
  scalar.dl.client.server.privileged_port                 → SCALARDL_PRIVILEGED_PORT
  scalar.dl.client.entity.id                              → CLIENT_ENTITY_ID
  scalar.dl.client.authentication.method                  → AUTH_METHOD ("digital-signature" / "hmac")
  scalar.dl.client.entity.identity.digital_signature
       .cert_path                                         → (ignored — scaffold uses fixed ./cert/client-cert.pem)
       .private_key_path                                  → (ignored — scaffold uses fixed ./cert/client-key.pem)
       .cert_version                                      → (ignored — defaults to 1)
  scalar.dl.client.entity.identity.hmac
       .secret_key (LITERAL value)                        → HMAC_SECRET_KEY
       .secret_key_version                                → HMAC_SECRET_KEY_VERSION
  scalar.dl.client.tls.enabled                            → SCALARDL_TLS_ENABLED, TLS_ENABLED
  scalar.dl.client.tls.ca_root_cert_path                  → TLS_CA_ROOT_CERT_PATH
  scalar.dl.client.tls.override_authority                 → TLS_OVERRIDE_AUTHORITY
  scalar.dl.client.auditor.enabled                        → AUDITOR_ENABLED
  scalar.dl.client.auditor.host                           → AUDITOR_HOST
  scalar.dl.client.auditor.port                           → AUDITOR_PORT
  scalar.dl.client.auditor.privileged_port                → AUDITOR_PRIVILEGED_PORT
  scalar.dl.client.auditor.tls.enabled                    → AUDITOR_TLS_ENABLED
  scalar.dl.client.auditor.tls.ca_root_cert_path          → AUDITOR_TLS_CA_ROOT_CERT_PATH
  scalar.dl.client.auditor.tls.override_authority         → AUDITOR_TLS_OVERRIDE_AUTHORITY

  Also derive Mustache section flags:
  DS    = (AUTH_METHOD == "digital-signature")
  HMAC  = (AUTH_METHOD == "hmac")

Step 4. Copy DS material (if AUTH_METHOD == "digital-signature"):
          ./scalardl-config/cert/client-cert.pem  →  <project>/cert/client-cert.pem
          ./scalardl-config/cert/client-key.pem   →  <project>/cert/client-key.pem
        (TLS CA cert: if TLS_CA_ROOT_CERT_PATH is a relative path inside the
         bundle's cert/, copy it too and rewrite the value to ./cert/<filename>.)

Step 5. Render application.properties.tmpl with the variable set from Step 3.
        Sections `{{#DS}}...{{/DS}}` are rendered only when AUTH_METHOD is
        digital-signature; `{{#HMAC}}...{{/HMAC}}` only when hmac.
        The warning block at the top of the file is unconditional.

Step 6. Render all other templates (build.gradle, ScalarDLProperties.java,
        ScalarDLService.java, etc.) using project-basics variables.

Step 7. Render the .gitignore template (already excludes cert/ + application.properties).

Step 8. Write .scalardl-starter-skills.json with branch="A" + consumedM2Bundle="./scalardl-config/"
        + authenticationMethod=<AUTH_METHOD>. See "Manifest write" below.

Step 9. Inform the user of side-effects (cert copy + warning block + .gitignore).
```

## Branch B — HMAC secret generation

When A15 = `hmac`, after all A1..A16 questions are gathered:

```
Step 1. Generate a fresh secret:    openssl rand -base64 32
        (32 bytes raw → ~44 Base64 chars. Capture stdout.)

Step 2. Bind the value to Mustache var HMAC_SECRET_KEY.
        HMAC_SECRET_KEY_VERSION comes from A15a.

Step 3. Render application.properties.tmpl as usual — the `{{#HMAC}}...{{/HMAC}}`
        section will be active and the secret will be baked as a literal.

Step 4. After scaffold completion, tell the user:

  ✅ HMAC secret_key generated and baked into application.properties (length: 44 chars).
     cat src/main/resources/application.properties | grep hmac-secret-key
     # → scalardl.hmac-secret-key=<base64-value>

  ⚠️  The Ledger you point this app at must have the SAME secret registered
     against the same entity id (A13) and secret_key_version (A15a).
     - If you used scalardl-generate-config for the deploy, that bundle's
       env.sh already exports a CLIENT_HMAC_SECRET_KEY and the bundle's
       client.properties is the source of truth. In that case, prefer
       Branch A (re-run this skill with the bundle present at ./scalardl-config/).
     - If you have a standalone Ledger, register the secret with:
         scalardl register-secret --properties <admin-client.properties> \
                                  --entity-id <A13> --secret-version <A15a> \
                                  --secret-key <the-base64-value-above>
       (Or hit POST /api/certificate/register on this app — it dispatches to
        ClientService::registerSecret when authentication-method=hmac.)
```

(Skipping the secret-key Q&A and generating it for the user keeps the friction down. The trade-off is that the user must coordinate with the Ledger side; the message above tells them how.)

For DS (A15 = `digital-signature`, default): no secret is generated. The user is responsible for putting `client-cert.pem` and `client-key.pem` under `<project>/cert/`. The completion message includes the openssl 1-liner:

```bash
# Generate a self-signed cert/key for local testing:
openssl ecparam -genkey -name prime256v1 -noout -out cert/client-key.pem
openssl req -new -x509 -key cert/client-key.pem -out cert/client-cert.pem -days 365 \
    -subj "/CN=<A13-entity-id>"
```

## Rendering rules — Mustache sections in `application.properties.tmpl`

The template uses Mustache sections to vary output by branch / auth method / TLS / Auditor state:

| Section | Active when | Contents |
|---|---|---|
| `{{#DS}}...{{/DS}}` | `AUTH_METHOD == "digital-signature"` | cert-version / cert-path / private-key-path |
| `{{#HMAC}}...{{/HMAC}}` | `AUTH_METHOD == "hmac"` | hmac-secret-key (literal) / hmac-secret-key-version |
| `{{#TLS_ENABLED}}...{{/TLS_ENABLED}}` | Client TLS on | tls-ca-root-cert-path / tls-override-authority |
| `{{#AUDITOR_TLS_ENABLED}}...{{/AUDITOR_TLS_ENABLED}}` | Auditor TLS on | auditor.tls-ca-root-cert-path / auditor.tls-override-authority |
| `{{#FOO}}{{FOO}}{{/FOO}}` (nested) | the inner var is non-empty | guards optional fields like `TLS_CA_ROOT_CERT_PATH` |

The warning block at the top of `application.properties` is **unconditional** — it's always present, regardless of branch / auth method.

## Output layout

```
<project-name>/
├─ .gitignore                              ← excludes cert/, application.properties, build artefacts
├─ .scalardl-starter-skills.json                   ← project-marker manifest (read by add-* skills)
├─ build.gradle, settings.gradle, gradlew, gradlew.bat
├─ gradle/wrapper/
├─ src/
│  ├─ main/
│  │  ├─ java/<package-path>/
│  │  │  ├─ Application.java
│  │  │  ├─ cli/RenderCli.java                 ← offline renderer, invoked via `./gradlew render`
│  │  │  ├─ config/ScalarDLProperties.java     ← DS + HMAC + TLS + Auditor on the same property set
│  │  │  ├─ controller/{ContractPreview,ContractRegister,ContractRegisterFromSource,ContractExecute,FunctionPreview,FunctionRegister,FunctionRegisterFromSource,Certificate,LedgerValidation}Controller.java
│  │  │  ├─ service/{ScalarDL,Contract,Function,JavaCompiler,CodeManagement}*Service|Generator.java
│  │  │  ├─ dto/{Contract,Function}Definition.java
│  │  │  └─ util/VersionUtil.java
│  │  └─ resources/
│  │     ├─ application.properties             ← warning block + literal secrets when HMAC
│  │     ├─ static/index.html
│  │     ├─ contract-templates/{READ_ASSET,PUT_ASSET,PUT_ASSETS}.java.mustache
│  │     └─ function-templates/{UPSERT_RECORD,UPSERT_RECORDS}.java.mustache
│  └─ test/java/<package-path>/
│     ├─ ApplicationTests.java
│     └─ MustacheRenderSmokeTest.java
├─ definitions/{contracts,functions}/    (persisted by the register endpoints)
├─ generated/{contracts,functions}/      (rendered .java; regenerated on each register call)
├─ compiled/{contracts,functions}/       (javac output)
├─ examples/                             (empty + .gitkeep; populated by /scalardl-add-contract and /scalardl-add-function)
├─ cert/                                 (Branch A: copied from M2 bundle; Branch B DS: user-generated; HMAC: empty + .gitkeep)
└─ README.md
```

## Manifest write — `.scalardl-starter-skills.json`

After rendering the Spring Boot scaffold, write `.scalardl-starter-skills.json` at the project root with the following content (filling each field from the Q&A answers + Phase 0 outcome):

```json
{
  "projectName": "<A1>",
  "groupId": "<the part of A2 minus the last segment, or the whole A2 if a flat package>",
  "packageName": "<A2>",
  "projectDescription": "<A2a>",
  "scalardlSdkVersion": "<A3>",
  "targetScalardlMinVersion": "3.13.0",
  "springBootVersion": "<A4>",
  "javaVersion": "<A5>",
  "clientEntityId": "<A13 in Branch B; bundle's scalar.dl.client.entity.id in Branch A>",
  "auditorEnabled": <A14 == "Ledger + Auditor", as a JSON boolean>,
  "starter": {
    "skill": "scalardl-generate-springboot-starter",
    "version": "0.6.0-rc1",
    "branch": "A | B",
    "consumedM2Bundle": "<bundle path if Branch A, else null>",
    "authenticationMethod": "digital-signature | hmac"
  },
  "createdBy": "scalardl-generate-springboot-starter v0.6.0-rc1",
  "createdAt": "<current UTC time as ISO 8601, e.g. 2026-05-13T12:00:00Z>"
}
```

`targetScalardlMinVersion` is fixed at `"3.13.0"` for v0.6.x. The `starter.branch` field lets future tooling distinguish bundle-consuming vs standalone scaffolds. The `add-*` skills can read `starter.authenticationMethod` if a future preset needs to be auth-aware (current add-* skills are auth-agnostic).

This manifest is the source of truth that `scalardl-add-contract` and `scalardl-add-function` use to pre-fill `packageName`, default the linked Contract id, etc. Write it unconditionally at the end of every scaffold run, even if the user opts out of the smoke compile or asks for a minimal project.

## Smoke compile

After scaffolding, run:

```bash
cd <project-name>
./gradlew compileJava --no-daemon
```

If it fails, surface the compiler output. Skip on request.

## Completion message

Branch-aware. The two variants differ in the cert/HMAC follow-up section.

**Branch A (M2 bundle consumed):**

```
✅ <project-name>/ scaffolded (Branch A — consumed ./scalardl-config/).

Authentication method: <digital-signature | hmac>
<if DS>  Cert/key copied: ./scalardl-config/cert/client-{cert,key}.pem  →  <project>/cert/
<if HMAC> HMAC secret_key inherited from bundle and baked into application.properties.

ℹ️  application.properties contains a top-of-file warning block with the production-
    migration paths (k8s Secret / Vault / Spring Cloud Config). .gitignore excludes
    cert/ + application.properties so you don't accidentally commit secrets.

Next steps:
  cd <project-name>

  # 1. Add a Contract definition:
  /scalardl-add-contract

  # 2. (Optional) Add a Function definition:
  /scalardl-add-function

  # 3. Boot the app:
  ./gradlew bootRun

  # 4. Register identity (auto-dispatches: DS → registerCertificate, HMAC → registerSecret):
  curl -X POST http://localhost:8080/api/certificate/register

  # 5. Register a Contract from JSON definition:
  curl -X POST http://localhost:8080/api/contracts/register \
    -H 'Content-Type: application/json' -d @examples/<your-contract>.json

  # (After executing a Contract that wrote an asset) verify its ledger integrity:
  curl "http://localhost:8080/api/ledger/validate?assetId=<your-asset-id>"

Swagger UI: http://localhost:8080/swagger-ui/index.html
```

**Branch B (standalone):**

```
✅ <project-name>/ scaffolded (Branch B — standalone, no M2 bundle).

Authentication method: <digital-signature | hmac>
<if DS>  Generate cert/key before running:
           openssl ecparam -genkey -name prime256v1 -noout -out cert/client-key.pem
           openssl req -new -x509 -key cert/client-key.pem -out cert/client-cert.pem \
               -days 365 -subj "/CN=<A13>"
<if HMAC> HMAC secret_key generated (`openssl rand -base64 32`) and baked into
          application.properties. Ledger must have the SAME secret registered for
          entity_id=<A13>, secret_version=<A15a>.

ℹ️  application.properties contains a top-of-file warning block with the production-
    migration paths (k8s Secret / Vault / Spring Cloud Config). .gitignore excludes
    cert/ + application.properties so you don't accidentally commit secrets.

Next steps:
  cd <project-name>

  # 1. (DS only) Put cert/client-cert.pem + cert/client-key.pem in place; see above.

  # 2. Add a Contract definition:
  /scalardl-add-contract

  # 3. (Optional) Add a Function definition:
  /scalardl-add-function

  # 4. Boot the app:
  ./gradlew bootRun

  # 5. Register identity (auto-dispatches: DS → registerCertificate, HMAC → registerSecret):
  curl -X POST http://localhost:8080/api/certificate/register

  # 6. Register a Contract from JSON definition:
  curl -X POST http://localhost:8080/api/contracts/register \
    -H 'Content-Type: application/json' -d @examples/<your-contract>.json

  # (After executing a Contract that wrote an asset) verify its ledger integrity:
  curl "http://localhost:8080/api/ledger/validate?assetId=<your-asset-id>"

Swagger UI: http://localhost:8080/swagger-ui/index.html
```

Both variants finish with the standard Contract / Function versioning reminder:

```
Versioning + immutability (Contract vs Function — different rules):
  - Contract is permanent. ScalarDL has NO API to unregister/disable a Contract;
    its bytecode stays in the Ledger forever once registered. Bug fixes =
    bump the version in the JSON, register a new <Base>V<M>_<m>_<p>, switch
    the client. Test on a non-production Ledger first.
  - Function CAN be overwritten by re-register (same id, new bytecode replaces
    old). Functions don't write to the audit chain, so updating them is
    operationally safe. The skill still emits versioned class names for
    Functions for trace/debug/rollback clarity, but that's a convention,
    not a ScalarDL rule.
```

## Limitations

1. **Skill emits the project shell only.** Contract / Function definitions are added by the sibling skills `scalardl-add-contract` and `scalardl-add-function`, run from the scaffolded project's directory.
2. **Function ScalarDB API**: ScalarDL's `Database` exposes only `get / scan / put / delete`. Function presets (`UPSERT_RECORD` / `UPSERT_RECORDS`) all go through `put`, which forces an implicit pre-read. ScalarDB's `Put` itself is being deprecated in favour of explicit `Insert` / `Upsert` / `Update`; Function-side exposure of those is under consideration upstream.
3. **`functionArgument` is unused** in generated Function code; clients send the body via `contractArgument` only. PII separation via signed-vs-unsigned arguments is a v0.3 topic.
4. **No multi-Function pairing per Contract execution** today — Plan 002 §11 v0.2 candidate.
5. **Mixed authentication patterns** (DS Client + HMAC Server-Server, etc.) are out of scope per plan-008 D7. The skill supports "all DS" or "all HMAC", never both in the same scaffold.
6. **Sample-grade secret handling**: DS private keys are kept as plaintext files under `<project>/cert/`; HMAC secrets are literal in `application.properties`. The `.gitignore` excludes both, and `application.properties` documents the production migration paths inline. The scaffold is **not** a production-ready secret manager — by design.

## Related files

- `templates/.gitignore.tmpl` — excludes `cert/*`, `src/main/resources/application.properties`, build artefacts
- `templates/src/main/resources/application.properties.tmpl` — warning block + Mustache sections (`{{#DS}}`, `{{#HMAC}}`, `{{#TLS_ENABLED}}`, `{{#AUDITOR_TLS_ENABLED}}`)
- `templates/src/main/java/__pkg__/config/ScalarDLProperties.java.tmpl` — shared property class for DS + HMAC + TLS + Auditor
- `templates/src/main/java/__pkg__/service/ScalarDLService.java.tmpl` — `buildClientConfig()` dispatches by `authenticationMethod`; `registerCertificate()` dispatches to `ClientService::registerSecret` when HMAC
- `templates/src/main/resources/contract-templates/{READ_ASSET,PUT_ASSET,PUT_ASSETS}.java.mustache` — Contract templates
- `templates/src/main/resources/function-templates/{UPSERT_RECORD,UPSERT_RECORDS}.java.mustache` — Function templates
- `templates/examples/.gitkeep` — placeholder so the empty `examples/` directory is tracked. `scalardl-add-contract` and `scalardl-add-function` write user-added definitions here at runtime.
- `references/scalardl-contract-api.md`, `references/scalardl-function-api.md` — base class signatures
- `references/contract-versioning-rules.md` — `<Base>V<Major>_<Minor>_<Patch>` naming
- `references/function-database-api-limitations.md` — why Insert/Upsert/Update aren't reachable
- `references/contract-argument-vs-function-argument.md` — signed vs unsigned (background only)
- `references/scalardl-properties-keys.md` — `application.properties` key reference
- `../scalardl-generate-config/templates/properties/client.properties.tmpl` — M2 source-of-truth that Branch A consumes
