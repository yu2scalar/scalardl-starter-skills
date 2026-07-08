# Bundled License PEM directory (for ScalarDL Ledger / Auditor)

This directory holds the public-key certificates (PEM) used for ScalarDL Ledger / Auditor license verification. `scalardl-starter-skills/scalardl-generate-config` uses them as the source when injecting into Helm values.

## Bundled files

| File | Purpose | Origin | Sync date (sha256 matches scalardb-skills) |
|---|---|---|---|
| `trial-cert.pem` | For the Trial license | Copied from `~/IdeaProjects/scalardb-skills/skills/generate-scalardb-cluster-values/references/license-pem/trial-cert.pem` | 2026-05-08 (sha256: `c1b47975...`) |
| `production-cert.pem` | For the Production (= Enterprise) license | Same as above (`production-cert.pem`) | 2026-05-08 (sha256: `0cf23c5c...`) |

**Note on origin**: The PEMs above come from the ScalarDL samples fixture. As the trial / enterprise license verifier issued by Scalar Inc., **ScalarDL Ledger / Auditor use the same public key as ScalarDB Cluster**. The `scalardb-skills` README states that they originate from "the ScalarDL samples fixture" (`~/IdeaProjects/scalardb-skills/skills/generate-scalardb-cluster-values/references/license-pem/README.md`).

## About expiry

Both PEMs currently bundled have a `notAfter` that is already past (2024-02-15). However:

> The license verification implementation of ScalarDL / ScalarDB Cluster uses **only the public-key portion of the cert** for signature verification, so an expired `notAfter` (validity period) on the cert itself causes no operational problem.

(Confirmed by the user during a scalardb-skills Day 2 session.)

If a new PEM is provided, update it using one of the procedures below:

## How to replace the PEM

### Recommended: sync via scalardb-skills

Update `references/license-pem/{trial,production}-cert.pem` on the scalardb-skills side and re-copy them here.

```bash
cp ~/IdeaProjects/scalardb-skills/skills/generate-scalardb-cluster-values/references/license-pem/trial-cert.pem      ./trial-cert.pem
cp ~/IdeaProjects/scalardb-skills/skills/generate-scalardb-cluster-values/references/license-pem/production-cert.pem ./production-cert.pem
```

After updating, also rewrite the sha256 values in this README.

### If received directly from Scalar Inc.

```bash
cp /path/to/new-trial-cert.pem      ./trial-cert.pem
cp /path/to/new-production-cert.pem ./production-cert.pem
```

Afterwards, placing the same PEM on the scalardb-skills side as well is recommended (to keep the two repos consistent).

## Related properties (ScalarDL)

These PEMs are injected into the following properties:

- `scalar.dl.licensing.license_key` (**emitted as a `<YOUR_LICENSE_KEY>` placeholder**; the user fills it in when injecting the secret)
- `scalar.dl.licensing.license_check_cert_pem` (**the full text of this PEM** is embedded into `licensing.licenseCheckCertPem` in the Helm values)

For both Trial and Production, the `license_key` is issued individually by Scalar Inc., so the user injects it via a secret / environment variable. The `license_check_cert_pem` (= cert) uses the one bundled in this directory.

## Compatibility notes (knowledge from scalardb-skills)

- A Trial license is compatible with any license type (source: scalardb-skills-side `ClusterNodeWithLicoseCheckerUtils.java:34-35`; ScalarDL is assumed to go through an equivalent decision path).
- A Production license is for enterprise use.
- The ScalarDL Ledger / Auditor license check runs at startup. If the cert PEM is missing or inconsistent, startup fails.

## ScalarDL-specific notes (append here if differences arise)

No differences between ScalarDB Cluster and ScalarDL Ledger/Auditor license certs have been confirmed so far. If any are found, they will be tracked separately in this README.
