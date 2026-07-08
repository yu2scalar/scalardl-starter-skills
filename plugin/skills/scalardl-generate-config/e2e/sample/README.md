# plan-009 W3 — Sample Contract + Function bundle

Sample Contract / Function pair used by the plan-009 E2E auto harness L4
(register-contract / register-function / execute). Minimal logic — exercises
the `register contract/function, execute contract with function` path end-to-
end per plan-009 D8.

## Files

| File | Purpose |
|---|---|
| `contracts/SmokeAsset.java` | Contract source: append-only `ledger.put(asset_id, {data})` + read-back age |
| `functions/SmokeAssetFunction.java` | Function source: upsert `(asset_id, data_json)` into `smoke.smoke_assets` via ScalarDB |
| `schema.sql` / `schema.json` | ScalarDB business schema for `smoke.smoke_assets` (loaded by `scalardb-schema-loader` — different from the ScalarDL schema-loader) |
| `build.gradle` / `settings.gradle` | Gradle build (requires Gradle 8+ and a JDK 17+; some Linux distros need `openjdk-17-jdk` separately from the JRE) |
| `build.sh` | Direct-`javac` build wrapper (used when Gradle toolchain can't find a JDK compiler — see "Build" below) |
| `prebuilt/com/example/contracts/SmokeAsset.class` | Pre-compiled bytecode (`--release 17`, class-file v61.0) — committed for L4 use |
| `prebuilt/com/example/functions/SmokeAssetFunction.class` | Same |
| `prebuilt/sha256.txt` | SHA-256 of both `.class` files, recorded at build time |

## Behaviour

### `SmokeAsset` Contract

- **Argument** `{"asset_id": "<id>", "data": <any-json>}`
- **Effect**: `ledger.put(asset_id, {data})` (ScalarDL append-only versioning — new aged record per call). Then `ledger.get(asset_id).age()` to learn the assigned age (snapshot read-your-writes).
- **Return** `{"asset_id": "<id>", "age": <int>}`

### `SmokeAssetFunction` Function

- **Paired with** `com.example.contracts.SmokeAsset`. Reads `contractArgument` directly (does not depend on `Contract.setContext` — kept simple for the smoke path).
- **Effect**: upserts one row into ScalarDB `smoke.smoke_assets` using ScalarDB 3.x builder API (`Put.newBuilder()...`).
- **Return** `{"status": "ok", "asset_id": "<id>"}`

Per CLAUDE.md + ScalarDL trunk (`~/claude/dl/scalardl/common/.../database/Database.java`), Function-side `Database` exposes only `get / scan / put / delete`. `put` is structurally upsert at the ScalarDB storage layer (forces implicit pre-read) — no need for explicit Insert / Upsert APIs even when those exist on the client side.

## Build

### Default path (`build.sh`)

```bash
bash build.sh
```

Uses `javac --release 17` directly. Discovers `scalardl-java-client-sdk:3.13.0` and transitive deps (`scalardl-common`, `scalardb`, jackson, `jsr305` for `@Nullable`) in the local `~/.gradle/caches/modules-2/files-2.1/` cache. If the cache is empty, run any Gradle build that depends on `scalardl-java-client-sdk:3.13.0` once (e.g., from `~/IdeaProjects/demo-dl/`) to populate it, **or** use Gradle path below.

### Gradle path (`build.gradle`)

```bash
gradle compileJava       # requires Gradle 8+ + a JDK 17+ (not JRE-only)
```

Outputs land under `build/classes/java/main/...`. For a commit-ready output, `build.sh` is the wrapper of choice.

## Bytecode SHA-256 (committed)

Recorded at build time in `prebuilt/sha256.txt`. The values **must** be
regenerated when the sources change — `build.sh` writes the file
automatically. CI / smoke can `diff` the committed file against a fresh
build to detect uncommitted source changes.

Current (`2026-05-11T08:53:08Z`, `javac 21.0.10`, `--release 17`):

```
SmokeAsset.class           c56afc5b94ef456b2e1fe5615997c14b2cda42384d944787b062598700d3cfb4
SmokeAssetFunction.class   4451cc2f84dd29a6d051004f2fcdd3e91893fa0fc0a665311a6b0cdb5f9629e6
```

Class-file major version: **61** (Java 17, plan-008 D13). Loadable by
ScalarDL Ledger 3.13.0+ (Java 21 JRE). Throws `UnsupportedClassVersionError`
on 3.12.x (Java 8 JRE).

## How L4 will use these (preview)

W6 (L4 — register + execute) will roughly:

1. Run `scalardl-client register-contract --properties ledger.as.client.properties --contract-id SmokeAsset --contract-binary-name com.example.contracts.SmokeAsset --contract-class-file prebuilt/com/example/contracts/SmokeAsset.class`
2. Run `scalardl-client register-function --properties ledger.as.client.properties --function-id SmokeAssetFunction --function-binary-name com.example.functions.SmokeAssetFunction --function-class-file prebuilt/com/example/functions/SmokeAssetFunction.class`
3. Pre-create `smoke.smoke_assets` ScalarDB table via `scalardb-schema-loader -c <client.properties> -f schema.json --coordinator`
4. Run `scalardl-client execute --properties client.properties --contract-id SmokeAsset --contract-argument '{"asset_id":"smoke-asset-1","data":{"v":1}}' --function-ids SmokeAssetFunction`
5. Verify `execute` exit code 0 + response JSON shape + (post-deploy) a row in `smoke.smoke_assets`

For Auditor=Yes patterns, steps 1 and 2 repeat against `auditor.as.client.properties` (register on both Ledger and Auditor — required by ScalarDL Auditor cross-validation).
