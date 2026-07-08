-- plan-009 W3 — ScalarDB business-side schema for SmokeAssetFunction.
--
-- The Function writes one row per execute into smoke.smoke_assets:
--   asset_id    TEXT  (partition key)
--   data_json   TEXT  (JSON-encoded payload)
--
-- Loaded by `scalardb-schema-loader` (NOT `scalardl-schema-loader`, which
-- manages DL system tables only). See plan-009 W5 for the bootstrap step.
--
-- Use with scalardb-schema-loader 3.13.0+ in JSON mode — this .sql file is
-- the human-readable doc; the loader actually consumes the JSON next to it
-- (schema.json), generated 1:1 from this file.

CREATE NAMESPACE IF NOT EXISTS smoke;

CREATE TABLE IF NOT EXISTS smoke.smoke_assets (
  asset_id    TEXT,
  data_json   TEXT,
  PRIMARY KEY (asset_id)
);
