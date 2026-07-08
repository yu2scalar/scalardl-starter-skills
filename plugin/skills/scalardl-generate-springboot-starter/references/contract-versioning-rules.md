# Contract / Function versioning rules

> Self-contained reference. Source: ScalarDL Core source (`common/.../contract/ContractManager.java` + `common/.../function/FunctionManager.java` + `ledger/.../scalardb/ScalarFunctionRegistry.java`) + Skill 004 naming convention.

## Why versioning matters — different rules for Contract vs Function

ScalarDL has **two different update rules**. Read both before treating versioning as one thing.

### Contract — versioning is mandatory

ScalarDL Ledger **cannot update a registered Contract**. `ContractManager.register()` does an existence check via `get()` and throws `CONTRACT_ALREADY_REGISTERED` if the id is already present. There is no API to unregister, disable, or replace a Contract.

To deploy new Contract logic you **must** register it under a different class name. The skill's versioning convention exists to make this both human-readable and collision-free.

### Function — versioning is recommended but not required

`FunctionManager.register()` does **not** do an existence check; it just calls `bind()`, which is a plain ScalarDB `put` (upsert). Re-registering a Function with the same id replaces its bytecode in place. The same module also exposes `unbind()` (a `Delete`) so Functions can be removed entirely.

Why? Functions don't write to the audit chain (they only touch ScalarDB business tables). They're operationally similar to any application code — updating in place is normal.

**This skill still emits versioned class names for Functions.** Reasons:

- audit / debugging — knowing exactly which Function bytecode ran on each historical execute,
- canary / rollback — keep `<Base>FunctionV1_0_0` running while you canary `V1_1_0`,
- pair stability — Contract / Function pairs (`<Base>V1_0_0` ↔ `<Base>FunctionV1_0_0`) make wiring obvious.

Treat it as a convention. If you want PUT-style overwrites for a Function, leave the `version` in the JSON unchanged and re-POST `/api/functions/register` — the skill happily overwrites the bytecode for the existing class id.

## Skill 004 naming convention

```
{Base}V{Major}_{Minor}_{Patch}
```

| Base name | Version | Generated class |
|---|---|---|
| `OrderUpdater` | `1.0.0` | `OrderUpdaterV1_0_0` |
| `OrderUpdater` | `1.2.3` | `OrderUpdaterV1_2_3` |
| `OrderUpdater` | `2.0.0` | `OrderUpdaterV2_0_0` |
| `UserUpdater` | `10.10.10` | `UserUpdaterV10_10_10` |

## File naming

| File | Pattern | Example |
|---|---|---|
| Definition JSON | `{Base}_V{Major}_{Minor}_{Patch}.json` | `definitions/contracts/OrderUpdater_V1_0_0.json` |
| Generated Java | `{Base}V{Major}_{Minor}_{Patch}.java` | `generated/contracts/OrderUpdaterV1_0_0.java` |
| Compiled `.class` | `{Base}V{Major}_{Minor}_{Patch}.class` | `compiled/contracts/com/example/contracts/OrderUpdaterV1_0_0.class` |

## Pair versions stay aligned

When you make a Contract / Function pair, **bump them together**:

| Contract | Function |
|---|---|
| `OrderUpdaterV1_0_0` | `OrderUpdaterFunctionV1_0_0` |

If they drift apart, the Contract keeps invoking the older Function until you explicitly rewire the linked Function id.

## When to bump which segment

- **PATCH** (`1.0.0` → `1.0.1`): bug fix, minor behaviour adjustment without changing the external contract.
- **MINOR** (`1.0.0` → `1.1.0`): backward-compatible additions (new optional input field, new return field).
- **MAJOR** (`1.0.0` → `2.0.0`): breaking changes — input field removed/renamed, fundamentally different logic.

## Multiple versions can coexist

ScalarDL is happy to host different versions of the same base name simultaneously:

```
On the Ledger:
  - OrderUpdaterV1_0_0  (older, taking production traffic)
  - OrderUpdaterV2_0_0  (newer, canary)
```

The client picks one by name: `executeContract("OrderUpdaterV2_0_0", ...)`.

## VersionUtil

The skill ships `util/VersionUtil.java` so the naming rule lives in exactly one place:

```java
VersionUtil.getVersionedName("OrderUpdater", "1.0.0")
  // → "OrderUpdaterV1_0_0"

VersionUtil.definitionFileName("OrderUpdater", "1.0.0")
  // → "OrderUpdater_V1_0_0.json"
```

Malformed versions (e.g. `"1.0"`, `"v1.0.0"`) raise `IllegalArgumentException` early.
