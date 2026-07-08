# ScalarDL Function API

> Self-contained reference for Skill 004. Sources are cited inline; nothing here is read from `~/claude/dl/scalardl/` at runtime.

## Recommended base class: `JacksonBasedFunction`

```java
package com.scalar.dl.ledger.function;

public abstract class JacksonBasedFunction
    extends FunctionBase<JsonNode, Get, Scan, Put, Delete, Result> {

  /**
   * Implement DB-side logic atomically with the linked Contract.
   *
   * @param database         A {@link com.scalar.dl.ledger.database.Database} that exposes
   *                         get / scan / put / delete on ScalarDB.
   * @param functionArgument (Nullable) Function argument from the caller. NOT digitally signed —
   *                         intended for data that may need deletion later (e.g. PII).
   * @param contractArgument The accompanying Contract's argument (digitally signed).
   * @param contractProperties (Nullable) Pre-registered Contract properties.
   * @return JsonNode that ends up under {@code functionResult} in ContractExecutionResult (or null).
   */
  public abstract JsonNode invoke(
      Database<Get, Scan, Put, Delete, Result> database,
      JsonNode functionArgument,
      JsonNode contractArgument,
      JsonNode contractProperties);

  /** Read the value the Contract bridged via {@code Contract.setContext()}. */
  protected JsonNode getContractContext();

  protected ObjectMapper getObjectMapper();
}
```

Sources:
- `~/claude/dl/scalardl/common/src/main/java/com/scalar/dl/ledger/function/JacksonBasedFunction.java`
- `~/claude/dl/scalardl/common/src/main/java/com/scalar/dl/ledger/function/FunctionBase.java:72`

## `Database` interface

```java
public interface Database<G, S, P, D, R> {
  Optional<R> get(G get);
  List<R> scan(S scan);
  void put(P put);
  void delete(D delete);
}
```

Functions can call **`get / scan / put / delete` only**. As of SDK 4.0.0-SNAPSHOT, the new ScalarDB primitives `Insert / Upsert / Update` are not exposed. See `function-database-api-limitations.md`.

## `Database` implementation detail (excerpt)

```java
// ~/claude/dl/scalardl/ledger/src/main/java/com/scalar/dl/ledger/database/scalardb/ScalarMutableDatabase.java:78
public void put(Put put) {
    transaction.put(Put.newBuilder(put).implicitPreReadEnabled(true).build());
    //                                  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    //                                  Implicit pre-read is forced (Ledger ⇄ Function consistency).
}
```

Every `put` from a Function performs a pre-read. ScalarDB's newer `Insert`/`Upsert` APIs control pre-read differently, which is part of why they aren't simply swapped in.

## Alternative base classes (for reference)

| Class | Argument type | When to use |
|---|---|---|
| `JacksonBasedFunction` | `JsonNode` | **Recommended** |
| `JsonpBasedFunction` | `JsonObject` (javax.json) | Legacy |
| `StringBasedFunction` | `String` | Raw, fastest |
| `Function` (deprecated) | — | Kept for compatibility |

## Function ↔ transaction lifecycle

- A Function joins the Contract's `DistributedTransaction` automatically — no explicit `commit` / `rollback`.
- Contract success + Function success → both committed.
- Either side throws → both rolled back.
