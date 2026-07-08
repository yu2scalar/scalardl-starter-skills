package com.example.contracts;

import com.fasterxml.jackson.databind.JsonNode;
import com.scalar.dl.ledger.contract.JacksonBasedContract;
import com.scalar.dl.ledger.exception.ContractContextException;
import com.scalar.dl.ledger.statemachine.Asset;
import com.scalar.dl.ledger.statemachine.Ledger;
import javax.annotation.Nullable;

/**
 * Sample Contract for plan-009 E2E auto harness (L4 register-contract / execute).
 *
 * Argument shape (JSON):
 *   {"asset_id": "<id>", "data": <any-json-object>}
 *
 * Effect:
 *   - Append-only put under the asset_id (ScalarDL's ledger.put creates a new
 *     aged version on every call).
 *   - Read-back via ledger.get to learn the assigned age (snapshot read-your-
 *     writes per ScalarDL semantics).
 *
 * Return shape (JSON):
 *   {"asset_id": "<id>", "age": <int>}
 *
 * The paired Function SmokeAssetFunction reads `contractArgument` directly
 * (does NOT depend on Contract.setContext) to upsert a row in a ScalarDB
 * business table. See sample/functions/SmokeAssetFunction.java.
 */
public class SmokeAsset extends JacksonBasedContract {

  @Override
  public JsonNode invoke(Ledger<JsonNode> ledger, JsonNode argument, @Nullable JsonNode properties) {
    if (argument == null || !argument.has("asset_id") || !argument.has("data")) {
      throw new ContractContextException("Required argument fields: asset_id, data");
    }
    String assetId = argument.get("asset_id").asText();
    JsonNode data = argument.get("data");

    // Append-only put. ScalarDL's Ledger versions every put with a new age.
    ledger.put(assetId, getObjectMapper().createObjectNode().set("data", data));

    // Read back to learn the freshly-assigned age.
    int age = ledger.get(assetId).map(Asset::age).orElse(0);

    return getObjectMapper().createObjectNode()
        .put("asset_id", assetId)
        .put("age", age);
  }
}
