# `contractArgument` vs `functionArgument`

> Self-contained reference. Source: `~/claude/docs-scalardl/docs/how-to-write-function.mdx` (official ScalarDL docs).

## Why two arguments

`executeContract` takes two JSON arguments:

```java
ContractExecutionResult result = clientService.executeContract(
    contractId,
    contractArgument,      // → Contract.invoke()
    functionId,
    functionArgument);     // → Function.invoke()
```

They differ in **digital signature**:

| Argument | Signed? | Persistence | Typical use |
|---|---|---|---|
| `contractArgument` | **Yes (digitally signed)** | Persisted in the Ledger together with the signature; immutable | Domain data that must stay tamper-proof (amounts, counterparties, timestamps, …) |
| `functionArgument` | **No** | Written into the DB only; can be deleted later | Data with a deletion requirement (PII / GDPR-bound, ephemeral details, …) |

From the official docs:

> A `functionArgument` is a runtime argument for the Function specified by the requester. The argument is **not digitally signed** as opposed to the contract argument so that it can be used to pass data that is stored in the database but it might be deleted at some later point for some reason.

## Typical use cases

### Banking transfer
- Contract argument: amount, account ids (immutable, signed, in the Ledger)
- Function argument: customer name, address (PII, deletable later)

### Audit log
- Contract argument: operation id, timestamp
- Function argument: client IP, User-Agent

## Skill 004 v0.1.0 stance

**`functionArgument` is always `"{}"`**. The client sends one JSON — the Contract argument. Anything the Function needs from the Contract is bridged via `setContext()`:

```java
// inside the Contract
JsonNode context = getObjectMapper().createObjectNode().put("computed", value);
setContext(context);

// inside the Function
JsonNode context = getContractContext();
String computed = context.get("computed").asText();
```

## Future extension (v0.2+)

For PII-bound flows that need a separate, deletable argument:

- Add a Function-side field schema in the skill (mirrors the Contract field schema).
- Have the skill emit a REST endpoint that accepts both JSONs.
- Generated Function code can then read `functionArgument.get(...)` directly.
