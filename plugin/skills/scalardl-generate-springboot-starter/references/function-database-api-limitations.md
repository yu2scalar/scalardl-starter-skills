# Function `Database` API limitations

> Self-contained reference. Verified against ScalarDL trunk (4.0.0-SNAPSHOT).

## Bottom line

**The ScalarDL Function path cannot use ScalarDB's `Insert` / `Upsert` / `Update` APIs.** Only legacy `put` / `delete` are reachable.

## Evidence 1: the `Database` interface surface

`~/claude/dl/scalardl/common/src/main/java/com/scalar/dl/ledger/database/Database.java`:

```java
public interface Database<G, S, P, D, R> {
  Optional<R> get(G get);
  List<R> scan(S scan);
  void put(P put);
  void delete(D delete);
}
```

Functions only see **`get / scan / put / delete`**.

## Evidence 2: `JacksonBasedFunction` pins the type parameters

```java
public abstract class JacksonBasedFunction
    extends FunctionBase<JsonNode, Get, Scan, Put, Delete, Result> {
  ...
}
```

The generic parameters of `Database<G, S, P, D, R>` are fixed to `<Get, Scan, Put, Delete, Result>`. The `Insert`, `Upsert`, `Update` types simply aren't present.

## Evidence 3: no escape hatch on the implementation side

`~/claude/dl/scalardl/ledger/src/main/java/com/scalar/dl/ledger/database/scalardb/ScalarMutableDatabase.java`:

```java
public class ScalarMutableDatabase implements MutableDatabase<Get, Scan, Put, Delete, Result> {
  private final DistributedTransaction transaction;  // private, no getter
  ...
  public void put(Put put) {
      transaction.put(Put.newBuilder(put).implicitPreReadEnabled(true).build());
  }
}
```

The `DistributedTransaction` is **private with no accessor**. There is no path from inside a Function to call `transaction.insert / upsert / update`.

## Evidence 4: the implicit pre-read is intentional

`put()` wraps the input with `implicitPreReadEnabled(true)`. That guarantees Ledger ⇄ Function state consistency, but it does not match the pre-read semantics of the new APIs. Switching them in is a deliberate design call, not a drop-in replacement.

## Evidence 5: trunk is also silent about the new APIs

`~/claude/dl/scalardl/build.gradle`:

```
projectVersion = project.findProperty('projectVersion') ?: '4.0.0-SNAPSHOT'
```

So `~/claude/dl/scalardl` is the **trunk (4.0.0-SNAPSHOT)** — the development tip.

Grep across that codebase:

```bash
$ grep -rE "import com.scalar.db.api.(Insert|Upsert|Update)\b" \
    common/src/main ledger/src/main
# (0 hits)
```

The trunk hasn't even added an import for the new APIs in Function-related code. Support is a future concern, not an in-flight change.

## What Skill 004 does

- **Preset names follow ScalarDB intent**: `F_INSERT`, `F_UPSERT`, `F_UPDATE`, `F_DELETE`, `F_READ`.
- **Implementations stay on legacy `put` / `delete`** internally:
  - `F_INSERT` → `database.put(Put.newBuilder()...)` (ScalarDL's implicit pre-read makes it functionally upsert-ish).
  - `F_UPSERT` → same.
  - `F_UPDATE` → `database.get()` for existence check + `database.put()`.
  - `F_DELETE` → `database.delete(Delete.newBuilder()...)`.
  - `F_READ` → `database.get()` / `database.scan()`.
- **Upgrade path when the SDK exposes the new APIs**: keep the preset names, rewrite the Mustache templates to use the new primitives, refresh this reference document.

## Open questions for the SDK side (relevant for v0.2 planning)

- Does ScalarDL plan to expose `Insert` / `Upsert` / `Update` to Function code?
- If yes, will it extend `Database` in place, or introduce a new interface (e.g. `MutableDatabaseV2`)?
- How will `implicitPreReadEnabled` semantics carry over, especially for `Upsert`?
