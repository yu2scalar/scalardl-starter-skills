# ScalarDL Contract API

> Self-contained reference for Skill 004. Authoring sources are cited inline; nothing here is read from `~/claude/dl/scalardl/` at runtime.

## Recommended base class: `JacksonBasedContract`

```java
package com.scalar.dl.ledger.contract;

public abstract class JacksonBasedContract
    extends ContractBase<JsonNode> {

  /**
   * Implement business logic that reads/writes assets through the Ledger.
   *
   * @param ledger     The Ledger interface bound to this Contract's asset namespace.
   * @param argument   The contract argument as a Jackson JsonNode (digitally signed by the caller).
   * @param properties (Nullable) Pre-registered properties for this Contract — set when calling
   *                   {@code clientService.registerContract(id, name, file, properties)}.
   * @return JsonNode that becomes the Contract's response (or null).
   */
  public abstract JsonNode invoke(
      Ledger<JsonNode> ledger,
      JsonNode argument,
      JsonNode properties);

  /** Pass context to the linked Function; the Function reads it via getContractContext(). */
  protected void setContext(JsonNode context);

  /** Jackson ObjectMapper for assembling the return value. */
  protected ObjectMapper getObjectMapper();
}
```

Source: `~/claude/dl/scalardl/common/src/main/java/com/scalar/dl/ledger/contract/JacksonBasedContract.java`

## Ledger interface (excerpt)

```java
public interface Ledger<T> {
  Optional<Asset<T>> get(String assetId);
  void put(String assetId, T data);
}
```

- `get(assetId)` returns the most recent asset. To walk the history, advance the age and call again, or use whatever scan API the underlying Ledger implementation exposes.
- `put(assetId, data)` either creates the asset or appends a new version (its age increments by 1).

## Alternative base classes (for reference)

| Class | Argument type | When to use |
|---|---|---|
| `JacksonBasedContract` | `JsonNode` (Jackson) | **Recommended** — balances type safety and performance. |
| `JsonpBasedContract` | `JsonObject` (javax.json) | Legacy environments still wired to JSON-P. |
| `StringBasedContract` | `String` | Raw JSON, fastest in throughput, requires hand-written parsing. |
| `Contract` (deprecated) | — | Kept for compatibility; do not use for new work. |

## Naming and immutability

- A registered Contract's class name **cannot be updated**.
- Each new version goes under a fresh class name (e.g. `OrderUpdaterV1_0_0` → `OrderUpdaterV1_1_0`).
- See `contract-versioning-rules.md` for details.

## Error handling inside a Contract

- For domain-level errors (insufficient balance, bad input, etc.), throw `ContractContextException`.
- Runtime exceptions are wrapped by ScalarDL.
- Package: `com.scalar.dl.ledger.exception.ContractContextException`.
