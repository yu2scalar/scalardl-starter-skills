package com.example.functions;

import com.fasterxml.jackson.databind.JsonNode;
import com.scalar.db.api.Delete;
import com.scalar.db.api.Get;
import com.scalar.db.api.Put;
import com.scalar.db.api.Result;
import com.scalar.db.api.Scan;
import com.scalar.db.io.Key;
import com.scalar.dl.ledger.database.Database;
import com.scalar.dl.ledger.exception.ContractContextException;
import com.scalar.dl.ledger.function.JacksonBasedFunction;
import javax.annotation.Nullable;

/**
 * Sample Function for plan-009 E2E auto harness (L4 register-function / execute).
 * Paired with com.example.contracts.SmokeAsset.
 *
 * Reads `contractArgument` (the same JSON the Contract received), extracts
 * asset_id + data, and upserts a row into ScalarDB table smoke.smoke_assets:
 *
 *   asset_id    TEXT  (partition key)
 *   data_json   TEXT  (JSON-encoded payload)
 *
 * The table must be pre-created by `scalardb-schema-loader` (NOT
 * `scalardl-schema-loader`, which manages DL system tables only). See
 * plan-009 W5 for the bootstrap step. The Function does NOT create the
 * table; calling invoke when the table is missing yields a ScalarDB error
 * that surfaces as an `execute` failure.
 *
 * Function-side `Database` exposes only get / scan / put / delete per
 * ~/claude/dl/scalardl/common/.../database/Database.java — no Insert /
 * Upsert / Update in current trunk. `put` is structurally upsert at the
 * ScalarDB storage layer (forces implicit pre-read).
 */
public class SmokeAssetFunction extends JacksonBasedFunction {

  @Override
  public JsonNode invoke(
      Database<Get, Scan, Put, Delete, Result> database,
      @Nullable JsonNode functionArgument,
      JsonNode contractArgument,
      @Nullable JsonNode contractProperties) {
    if (contractArgument == null || !contractArgument.has("asset_id") || !contractArgument.has("data")) {
      throw new ContractContextException("Required contractArgument fields: asset_id, data");
    }
    String assetId = contractArgument.get("asset_id").asText();
    JsonNode data = contractArgument.get("data");

    Put put = Put.newBuilder()
        .namespace("smoke")
        .table("smoke_assets")
        .partitionKey(Key.ofText("asset_id", assetId))
        .textValue("data_json", data.toString())
        .build();
    database.put(put);

    return getObjectMapper().createObjectNode()
        .put("status", "ok")
        .put("asset_id", assetId);
  }
}
