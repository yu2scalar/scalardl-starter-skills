# ScalarDL 設定パラメータリファレンス (3.13 系)

本ドキュメントは ScalarDL v3.13.0 における Ledger / Auditor / Client の設定プロパティを網羅的にまとめたリファレンスです。

公式 Docs: [docs-scalardl/docs/configurations.mdx](https://github.com/scalar-labs/docs-scalardl/blob/main/docs/configurations.mdx)

## 列の定義

| 列 | 意味 |
|---|---|
| 設定項目 (プロパティ名) | プロパティの完全修飾名 |
| 説明 | プロパティの目的・挙動 |
| 既定値 | プロパティ未設定時に **実効的に適用される値**。`(空)` はその設定項目が無効/未指定相当のまま処理されることを示す。`>0 ガード` のあるプロパティはリテラル既定値 (`0`) ではなく、gRPC framework 既定値を採用 |
| 備考 | 関連プロパティ・前提条件・特殊挙動・非推奨情報。`[公式 Docs 未掲載]` は `configurations.mdx` に記載が無くソースのみで確認できるプロパティ |
| Group | 適用条件 (`base` / `digital-signature` / `digital-signature-deprecated` / `hmac` / `tls` / `option` / `intermediary`) |

## Group 列の凡例

| Group | 意味 |
|---|---|
| `base` | 認証方式・TLS の有無に関わらず適用される基本設定 |
| `option` | 機能トグルや任意のパフォーマンスチューニングなど、明示指定が任意の付加設定 |
| `digital-signature` | `authentication.method=digital-signature` 構成でのみ意味を持つ |
| `digital-signature-deprecated` | 旧 digital-signature 流儀 (cert_holder_id / cert_path / cert_pem / cert_version / private_key_path / private_key_pem) の非推奨プロパティ。リリース 5.0.0 で削除予定 |
| `hmac` | `authentication.method=hmac` 構成でのみ意味を持つ |
| `tls` | TLS 通信を有効にする場合の設定 |
| `intermediary` | `scalar.dl.client.mode=INTERMEDIARY` 時のみ意味を持つ |

---

## Ledger 設定 (Ledger configurations)

| 設定項目 (プロパティ名) | 説明 | 既定値 | 備考 | Group |
|---|---|---|---|---|
| `scalar.dl.ledger.auditor.cert_holder_id` | [非推奨] Auditor 証明書ホルダー ID（デフォルト：`auditor`）。Ledger 側で Auditor の ordering 署名を検証するため、Auditor が事前登録した証明書を引くキー。リリース 5.0.0 で削除されます。Ledger-Auditor 間の認証は HMAC のみを使用するようになります。 | `auditor` | **現状の必須条件**: `auditor.enabled=true` AND `servers.authentication.hmac.secret_key` 未設定 (= server-server 認証が DS 経路) のときに必須。HMAC server-server 経路 (`servers.authentication.hmac.secret_key` 設定) では未使用で、リリース 5.0.0 で削除予定。 | digital-signature |
| `scalar.dl.ledger.auditor.cert_version` | [非推奨] Auditor 証明書バージョン（デフォルト：`1`）。リリース 5.0.0 で削除されます。Ledger-Auditor 間の認証は HMAC のみを使用するようになります。 | `1` | **現状の必須条件**: `auditor.cert_holder_id` と同じ条件（DS server-server 経路で必須）。HMAC server-server 経路では未使用。 | digital-signature |
| `scalar.dl.ledger.auditor.enabled` | Auditor を有効にするフラグ（デフォルト：`false`）。`proof.enabled` が `true` である必要があります。 | `false` |  | base |
| `scalar.dl.ledger.authentication.hmac.cipher_key` | クライアントエンティティの HMAC 秘密鍵を暗号化・復号化するために使用される暗号鍵。認証方式が `hmac` の場合に必要。予測困難で十分な長さの値を設定してください。 | `(空)` |  | hmac |
| `scalar.dl.ledger.authentication.method` | クライアントとサーバ間の認証方式（デフォルト：`digital-signature`）。`digital-signature` または `hmac` を指定できます。 | `digital-signature` |  | base |
| `scalar.dl.ledger.direct_asset_access.enabled` | 本パラメータは、通常の運用においては、デフォルト値（`false`）のままご使用ください。 | `false` |  | option |
| `scalar.dl.ledger.executable_contracts` | 実行可能なコントラクトのバイナリ名。 | `(空)` |  | option |
| `scalar.dl.ledger.function.enabled` | ファンクションを有効にするフラグ（デフォルト：`true`）。 | `true` |  | option |
| `scalar.dl.ledger.name` | Ledger を識別するために使用される Ledger の名前（デフォルト：`Scalar Ledger`）。 | `Scalar Ledger` |  | option |
| `scalar.dl.ledger.namespace` | Ledger テーブルの名前空間（デフォルト：`scalar`）。 | `scalar` |  | option |
| `scalar.dl.ledger.non_privileged_port.function.overwrite.enabled` | 通常ポート (`server.port`) 経由でも既存 function の上書き登録を許可するフラグ（デフォルト：`false`）。`false` の場合、function 上書きは特権ポート (`privileged_port`) 経由のみ許可。 | `false` | [公式 Docs 未掲載] | base |
| `scalar.dl.ledger.non_privileged_port.function.registration.enabled` | 通常ポート (`server.port`) 経由でも function の登録を許可するフラグ（デフォルト：`false`）。`false` の場合、function 登録は特権ポート (`privileged_port`) 経由のみ許可。 | `false` | [公式 Docs 未掲載] | base |
| `scalar.dl.ledger.proof.enabled` | AssetProof を有効にするフラグ（デフォルト：`false`）。`false` の場合、commit 時に AssetProof は生成されず空リストが返り、`validate-ledger` のレスポンスでも `LedgerValidationResult.ledgerProof = null` となる。**ただし `validate-ledger` のサーバ側検証ロジック (Contract / Output / PrevHash / Hash / Nonce の 5 validator) は `proof.enabled` に関係なく走り、StatusCode は通常通り返る**。「サーバ側 hash chain 整合性チェックのみ必要、クライアント側 proof 保管不要」というケースでは `false` で十分。 | `false` | Auditor 有効時は `true` 必須 (constructor で `IllegalArgumentException`)。 | base |
| `scalar.dl.ledger.proof.private_key_path` | AssetProof を **digital-signature で署名する場合** に利用する PEM 形式の秘密鍵ファイルへのパス。署名方式は `authentication.method` ではなく **`servers.authentication.hmac.secret_key` の有無で決定** される。 | `(空)` | `proof.private_key_pem` と排他、どちらか一方を指定。**Auditor 無効時は `authentication.method` 関係なく必須**（standalone Ledger では `servers.authentication.hmac.secret_key` が constructor で読み込まれず常に null 扱いとなり、AssetProof 署名が DS 強制になるため、`proof.private_key_*` が必須チェックされる）。 | digital-signature |
| `scalar.dl.ledger.proof.private_key_pem` | AssetProof を **digital-signature で署名する場合** に利用する PEM エンコードされた秘密鍵データ。署名方式の決定ロジックは `proof.private_key_path` と同じ。 | `(空)` | `proof.private_key_path` と排他、どちらか一方を指定。優先される (`pem` を先に評価)。**Auditor 無効時は `authentication.method` 関係なく必須**（理由は `proof.private_key_path` と同じ）。 | digital-signature |
| `scalar.dl.ledger.server.admin_port` | Ledger サーバー管理ポート（デフォルト：`50053`）。 | `50053` |  | option |
| `scalar.dl.ledger.server.decommissioning_duration_secs` | 停止猶予期間を秒単位で指定（デフォルト：`30`）。この期間中、サーバーは実行されているが gRPC ヘルスチェックに `NOT_SERVING` を返します。 | `30` |  | option |
| `scalar.dl.ledger.server.grpc.max_inbound_message_size` | 単一 gRPC フレームに許可される最大メッセージサイズ（デフォルト：`4194304` バイト）。この制限を超えると `RESOURCE_EXHAUSTED` で失敗します。 | `4194304` (4 MiB) | プロパティのリテラル既定値は `0` (= 空)。`> 0` ガードによりプロパティ未設定時は gRPC framework 既定値 (4 MiB) が実効値として適用される。 | option |
| `scalar.dl.ledger.server.grpc.max_inbound_metadata_size` | 受信が許可される最大メタデータサイズ（デフォルト：`8192` バイト）。 | `8192` (8 KiB) | プロパティのリテラル既定値は `0` (= 空)。`> 0` ガードでプロパティ未設定時は gRPC framework 既定値 (8 KiB) が実効値として適用される。 | option |
| `scalar.dl.ledger.server.port` | Ledger サーバーポート（デフォルト：`50051`）。 | `50051` |  | option |
| `scalar.dl.ledger.server.privileged_port` | Ledger サーバー特権ポート（デフォルト：`50052`）。 | `50052` |  | option |
| `scalar.dl.ledger.server.prometheus_exporter_port` | Prometheus エクスポーターポート（デフォルト：`8080`）。 | `8080` |  | option |
| `scalar.dl.ledger.server.tls.cert_chain_path` | TLS 通信に使用する証明書チェーンファイルのパス（クライアントと Ledger 間の接続時に使用）。 | `(空)` | `server.tls.enabled=true` 時に必要。 | tls |
| `scalar.dl.ledger.server.tls.enabled` | クライアントと Ledger 間の通信に TLS を有効化する設定（デフォルトは無効：`false`）。 | `false` |  | tls |
| `scalar.dl.ledger.server.tls.private_key_path` | TLS 通信に使用する秘密鍵ファイルのパス（クライアントと Ledger 間の接続時に使用）。 | `(空)` | `server.tls.enabled=true` 時に必要。 | tls |
| `scalar.dl.ledger.servers.authentication.hmac.secret_key` | Ledger と Auditor サーバー間のメッセージ認証用 HMAC 秘密鍵。対応する Auditor で同じキーを設定する必要があります。設定されていない場合、digital-signature 認証を使用します。**設定時は AssetProof の署名にも HMAC が使用される** (`HmacSigner` が選択される)。 | `(空)` | Auditor 側 `scalar.dl.auditor.servers.authentication.hmac.secret_key` と一致必須。**重要: 本プロパティは `auditor.enabled=true` の場合にのみ読み込まれる**。Ledger 単体運用 (`auditor.enabled=false`) で本プロパティを properties に書いても **無視され null 扱い** になる。standalone Ledger で AssetProof を HMAC 署名にすることはできない。 | hmac |
| `scalar.dl.ledger.tx_state_management.enabled` | 本パラメータは、通常の運用においては、デフォルト値（`false`）のままご使用ください。 | `false` |  | option |
| `scalar.dl.licensing.license_key` | ライセンス情報。 | `(空)` | Enterprise 限定。 | base |
| `scalar.dl.licensing.license_check_cert_pem` | ライセンス情報確認用証明書。 | `(空)` | Enterprise 限定。 | base |
| `scalar.db.*` | ScalarDL で取り扱うデータを保存する ScalarDB の各種設定。 | — | 詳細は [ScalarDB Configurations](https://scalardb.scalar-labs.com/docs/latest/configurations/) を参照。 | base |

---

## Auditor 設定 (Auditor configurations)

| 設定項目 (プロパティ名) | 説明 | 既定値 | 備考 | Group |
|---|---|---|---|---|
| `scalar.dl.auditor.authentication.hmac.cipher_key` | クライアントエンティティの HMAC 秘密鍵を暗号化・復号化するために使用される暗号鍵。認証方式が `hmac` の場合に必要。予測困難で十分な長さの値を設定してください。 | `(空)` |  | hmac |
| `scalar.dl.auditor.authentication.method` | クライアント-Auditor 間通信の認証方式（デフォルト：`digital-signature`）。`digital-signature` または `hmac` を指定できます。 | `digital-signature` | Ledger 側 `scalar.dl.ledger.authentication.method` と一致必須。 | base |
| `scalar.dl.auditor.authorization.credential` | 認可クレデンシャル（例：`Bearer token`）。 | `(空)` |  | option |
| `scalar.dl.auditor.cert_holder_id` | [非推奨] Auditor 自身の証明書ホルダー ID（デフォルト：`auditor`）。Auditor が自身の AssetProof / ordering 署名に使う証明書を識別するキー。リリース 5.0.0 で削除されます。Ledger-Auditor 間の認証は HMAC のみを使用するようになります。 | `auditor` | **現状の必須条件**: `servers.authentication.hmac.secret_key` 未設定 (= server-server 認証が DS 経路) のときに必須。HMAC server-server 経路では未使用で、リリース 5.0.0 で削除予定。 | digital-signature |
| `scalar.dl.auditor.cert_version` | [非推奨] Auditor 自身の証明書バージョン（デフォルト：`1`）。リリース 5.0.0 で削除されます。Ledger-Auditor 間の認証は HMAC のみを使用するようになります。 | `1` | **現状の必須条件**: `cert_holder_id` と同じ条件（DS server-server 経路で必須）。HMAC server-server 経路では未使用。 | digital-signature |
| `scalar.dl.auditor.grpc.deadline_duration_millis` | gRPC リクエストのデッドライン期間をミリ秒で指定（デフォルト：`60000` ミリ秒）。 | `60000` (60 秒) |  | option |
| `scalar.dl.auditor.grpc.max_inbound_message_size` | 単一 gRPC フレームに許可される最大メッセージサイズ（デフォルト：`4194304` バイト）。この制限を超えると `RESOURCE_EXHAUSTED` で失敗します。 | `4194304` (4 MiB) | プロパティのリテラル既定値は `0` (= 空)。`> 0` ガードでプロパティ未設定時は gRPC framework 既定値 (4 MiB) が実効値として適用される。 | option |
| `scalar.dl.auditor.grpc.max_inbound_metadata_size` | 受信が許可される最大メタデータサイズ（デフォルト：`8192` バイト）。 | `8192` (8 KiB) | プロパティのリテラル既定値は `0` (= 空)。`> 0` ガードでプロパティ未設定時は gRPC framework 既定値 (8 KiB) が実効値として適用される。 | option |
| `scalar.dl.auditor.ledger.cert_holder_id` | [非推奨] Ledger 証明書ホルダー ID（デフォルト：`ledger`）。Auditor が `ExecutionValidationRequest.validateWith()` で **Ledger 由来の AssetProof 署名を検証する** ために使用。リリース 5.0.0 で削除されます。Ledger-Auditor 間の認証は HMAC のみを使用するようになります。 | `ledger` | **現状の必須条件**: `auditor.servers.authentication.hmac.secret_key` 未設定 (= server-server 認証が DS 経路) のときに必須。Auditor 側の Linearizable Validation で Ledger proof の署名検証に直接使われる。HMAC server-server 経路では未使用で、リリース 5.0.0 で削除予定。 | digital-signature |
| `scalar.dl.auditor.ledger.cert_version` | [非推奨] Ledger 証明書バージョン（デフォルト：`1`）。リリース 5.0.0 で削除されます。Ledger-Auditor 間の認証は HMAC のみを使用するようになります。 | `1` | **現状の必須条件**: `ledger.cert_holder_id` と同じ条件（DS server-server 経路で必須）。HMAC server-server 経路では未使用。 | digital-signature |
| `scalar.dl.auditor.ledger.host` | Ledger サーバーのホスト名または IP アドレス（デフォルト：`localhost`）。 | `localhost` |  | option |
| `scalar.dl.auditor.ledger.port` | Ledger サーバーポート（デフォルト：`50051`）。 | `50051` |  | option |
| `scalar.dl.auditor.ledger.privileged_port` | Ledger サーバー特権ポート（デフォルト：`50052`）。 | `50052` |  | option |
| `scalar.dl.auditor.name` | Auditor の名前（デフォルト：`Scalar Auditor`）。Auditor を識別するために使用されます。 | `Scalar Auditor` |  | option |
| `scalar.dl.auditor.namespace` | Auditor テーブルの名前空間（デフォルト：`auditor`）。 | `auditor` |  | option |
| `scalar.dl.auditor.private_key_path` | PEM 形式の秘密鍵ファイルパス。AssetProof への署名とサーバー認証に使用されます。 | `(空)` | `private_key_pem` と排他、どちらか一方を指定。 | digital-signature |
| `scalar.dl.auditor.private_key_pem` | PEM エンコードされた秘密鍵データ。AssetProof への署名とサーバー認証に使用されます。 | `(空)` | `private_key_path` と排他、どちらか一方を指定。優先される (`pem` を先に評価)。 | digital-signature |
| `scalar.dl.auditor.server.admin_port` | Auditor サーバー管理ポート（デフォルト：`40053`）。 | `40053` |  | option |
| `scalar.dl.auditor.server.decommissioning_duration_secs` | 停止猶予期間を秒で指定（デフォルト：`30`）。この期間中、サーバーは gRPC ヘルスチェックリクエストに `NOT_SERVING` を返します。 | `30` |  | option |
| `scalar.dl.auditor.server.grpc.max_inbound_message_size` | 単一 gRPC フレームに許可される最大メッセージサイズ（デフォルト：`4194304` バイト）。この制限を超えると `RESOURCE_EXHAUSTED` で失敗します。 | `4194304` (4 MiB) | プロパティのリテラル既定値は `0` (= 空)。`> 0` ガードでプロパティ未設定時は gRPC framework 既定値 (4 MiB) が実効値として適用される。 | option |
| `scalar.dl.auditor.server.grpc.max_inbound_metadata_size` | 受信が許可される最大メタデータサイズ（デフォルト：`8192` バイト）。 | `8192` (8 KiB) | プロパティのリテラル既定値は `0` (= 空)。`> 0` ガードでプロパティ未設定時は gRPC framework 既定値 (8 KiB) が実効値として適用される。 | option |
| `scalar.dl.auditor.server.port` | Auditor サーバーポート（デフォルト：`40051`）。 | `40051` |  | option |
| `scalar.dl.auditor.server.privileged_port` | Auditor サーバー特権ポート（デフォルト：`40052`）。 | `40052` |  | option |
| `scalar.dl.auditor.server.prometheus_exporter_port` | Prometheus エクスポーターポート（デフォルト：`8080`）。 | `8080` |  | option |
| `scalar.dl.auditor.server.tls.cert_chain_path` | クライアントと Auditor 間の TLS 通信で使用する証明書チェーンファイルのパス。 | `(空)` | `server.tls.enabled=true` 時に必要。 | tls |
| `scalar.dl.auditor.server.tls.enabled` | クライアントと Auditor 間の通信において TLS を有効にするための設定（デフォルトは無効：`false`）。 | `false` |  | tls |
| `scalar.dl.auditor.server.tls.private_key_path` | クライアントと Auditor 間の TLS 通信で使用する秘密鍵ファイルのパス。 | `(空)` | `server.tls.enabled=true` 時に必要。 | tls |
| `scalar.dl.auditor.servers.authentication.hmac.secret_key` | Ledger と Auditor サーバー間の認証用 HMAC 秘密鍵。対応する Ledger 設定と一致させる必要があります。 | `(空)` | Ledger 側 `scalar.dl.ledger.servers.authentication.hmac.secret_key` と一致必須。 | hmac |
| `scalar.dl.auditor.tls.ca_root_cert_path` | Auditor と Ledger 間の TLS 通信に使用するカスタム CA ルート証明書のファイルパス。 | `(空)` | `tls.enabled=true` 時に必要。`pem` と排他。 | tls |
| `scalar.dl.auditor.tls.ca_root_cert_pem` | Auditor と Ledger 間の TLS 通信に使用するカスタム CA ルート証明書（PEM 形式）のデータ。 | `(空)` | `path` と排他、優先される (`pem` を先に評価)。 | tls |
| `scalar.dl.auditor.tls.enabled` | Auditor と Ledger 間の通信に TLS を有効化する設定（デフォルトは無効：`false`）。 | `false` |  | tls |
| `scalar.dl.auditor.tls.override_authority` | Auditor と Ledger 間の TLS 通信に使用する Ledger のホスト名/IP アドレスを指定します。証明書のホスト名がネットワークアドレスと一致しないサーバーへの接続時などに利用します。 | `(空)` |  | tls |
| `scalar.dl.licensing.license_key` | ライセンス情報。 | `(空)` | Enterprise 限定。 | base |
| `scalar.dl.licensing.license_check_cert_pem` | ライセンス情報確認用証明書。 | `(空)` | Enterprise 限定。 | base |
| `scalar.db.*` | ScalarDL で取り扱うデータを保存する ScalarDB の各種設定。 | — | 詳細は [ScalarDB Configurations](https://scalardb.scalar-labs.com/docs/latest/configurations/) を参照。Auditor 用は Ledger とは独立した DB を使うことが推奨される (Byzantine 検知のため別管理ドメイン)。 | base |

---

## クライアント設定 (Client configurations)

| 設定項目 (プロパティ名) | 説明 | 既定値 | 備考 | Group |
|---|---|---|---|---|
| `scalar.dl.client.auditor.authorization.credential` | Auditor 用の認可クレデンシャル（例：`authorization: Bearer token`）。 | `(空)` |  | option |
| `scalar.dl.client.auditor.enabled` | Auditor を有効にするフラグ（デフォルト：`false`）。 | `false` | Ledger 側 `scalar.dl.ledger.auditor.enabled` と一致必須。 | base |
| `scalar.dl.client.auditor.host` | Auditor のホスト名または IP アドレス（デフォルト：`localhost`）。 | `localhost` |  | base |
| `scalar.dl.client.auditor.linearizable_validation.contract_id` | ValidateLedger コントラクトの ID。線形化可能な検証に使用されます（デフォルト：`validate-ledger`）。 | コード上: `validate-ledger-v1_1_0` (v3.13)<br>Docs 表記: `validate-ledger` (古い) | v3.13.0 のコード上の実際のデフォルトは `validate-ledger-v1_1_0` (パッケージ末尾派生で動的に組み立てられる)。`register-contract --contract-id validate-ledger ...` と登録すると `validate-ledger` 実行時に `CONTRACT_NOT_FOUND` (DL-COMMON-404001) になる。回避策は (A) `validate-ledger-v1_1_0` で登録、または (B) 本プロパティに `validate-ledger` を明示 (カスタム ID 設定時は auto-bootstrap が ValidateLedger 自動登録を skip)。 | option |
| `scalar.dl.client.auditor.port` | Auditor サーバーポート（デフォルト：`40051`）。 | `40051` |  | option |
| `scalar.dl.client.auditor.privileged_port` | Auditor サーバー特権ポート（デフォルト：`40052`）。 | `40052` |  | option |
| `scalar.dl.client.auditor.tls.ca_root_cert_path` | Auditor との TLS 通信時に利用する CA ルート証明書（ファイルパス）。発行認証局がクライアントに知られている場合は空でも構いません。 | `(空)` | `auditor.tls.enabled=true` 時に必要。`pem` と排他。 | tls |
| `scalar.dl.client.auditor.tls.ca_root_cert_pem` | Auditor との TLS 通信時に利用する CA ルート証明書（PEM データ）。発行認証局がクライアントに知られている場合は空でも構いません。 | `(空)` | `path` と排他、優先される。 | tls |
| `scalar.dl.client.auditor.tls.enabled` | Auditor との TLS 通信を有効にするフラグ（デフォルト：`false`）。 | `false` | Auditor 側 `server.tls.enabled` と一致させる。 | tls |
| `scalar.dl.client.auditor.tls.override_authority` | Auditor との TLS 通信時に、利用する証明書のホスト名がネットワークアドレスと一致しないサーバーへの接続時などに利用します。 | `(空)` |  | tls |
| `scalar.dl.client.authentication_method` | [非推奨/レガシー名] アンダースコア表記の旧プロパティ名。`scalar.dl.client.authentication.method` (ドット区切り) の前身として残されている互換用設定。両方指定された場合、ドット区切りの新名が優先される。 | `(空)` | [公式 Docs 未掲載] 新名 `authentication.method` を使用するのが正。 | base |
| `scalar.dl.client.authentication.method` | クライアントとサーバー間の認証方式（デフォルト：`digital-signature`）。有効な値：`digital-signature` / `hmac` / `pass-through`（INTERMEDIARY モード用）。 | `digital-signature` |  | base |
| `scalar.dl.client.authorization.credential` | Ledger 用の認可クレデンシャル（例：`authorization: Bearer token`）。 | `(空)` |  | option |
| `scalar.dl.client.auto_bootstrap` | `ClientService` 生成時に identity (cert/secret) と ValidateLedger 契約を自動登録するフラグ（デフォルト：`true`、v3.13.0 で新設）。`true` の場合、`ClientServiceFactory.create()` が `clientService.bootstrap()` を内部で呼びます。`linearizable_validation.contract_id` がカスタム値の場合は ValidateLedger の自動登録部分は skip されます。 | `true` (v3.13 で新設) | [公式 Docs 未掲載] Javadoc にのみ記述あり。 | base |
| `scalar.dl.client.cert_holder_id` | [非推奨] クライアント用証明書のホルダー ID。リリース 5.0.0 で削除予定。代わりに `scalar.dl.client.entity.id` を使用してください。 | `(空)` | 非推奨であり、リリース 5.0.0 で削除されます。代わりに `scalar.dl.client.entity.id` を使用してください。両方が指定された場合、`scalar.dl.client.entity.id` が使用されます。 | digital-signature-deprecated |
| `scalar.dl.client.cert_path` | [非推奨] PEM 形式のクライアント用証明書ファイルのパス。リリース 5.0.0 で削除予定。代わりに `scalar.dl.client.entity.identity.digital_signature.cert_path` を使用してください。 | `(空)` | 非推奨であり、リリース 5.0.0 で削除されます。 | digital-signature-deprecated |
| `scalar.dl.client.cert_pem` | [非推奨] PEM エンコードされたクライアント用証明書データ。リリース 5.0.0 で削除予定。代わりに `scalar.dl.client.entity.identity.digital_signature.cert_pem` を使用してください。 | `(空)` | 非推奨であり、リリース 5.0.0 で削除されます。 | digital-signature-deprecated |
| `scalar.dl.client.cert_version` | [非推奨] 証明書のバージョン。リリース 5.0.0 で削除予定。代わりに `scalar.dl.client.entity.identity.digital_signature.cert_version` を使用してください。 | `1` | 非推奨であり、リリース 5.0.0 で削除されます。 | digital-signature-deprecated |
| `scalar.dl.client.context.namespace` | クライアントリクエストが実行される namespace（デフォルト：`default`）。同一クライアントから複数 namespace にまたがって操作する場合の現在の対象 namespace。`Namespaces.DEFAULT` (`default`) が初期値。 | `default` | [公式 Docs 未掲載] non-default に設定すると `bootstrap()` の identity 登録が skip されるなど挙動分岐がある。 | base |
| `scalar.dl.client.entity.id` | `scalar.dl.client.mode=CLIENT` 時に必須。リクエスト元の一意 ID（例：ユーザーまたはデバイス）。`entity.id` と非推奨の `cert_holder_id` の両方が指定された場合、`entity.id` が優先されます。 | `(空)` |  | base |
| `scalar.dl.client.entity.identity.digital_signature.cert_path` | PEM 形式のクライアント用証明書ファイルのパス。 | `(空)` | `cert_pem` と排他。 | digital-signature |
| `scalar.dl.client.entity.identity.digital_signature.cert_pem` | PEM エンコードされたクライアント用証明書データ。 | `(空)` | `cert_path` と排他。優先される (`pem` を先に評価)。 | digital-signature |
| `scalar.dl.client.entity.identity.digital_signature.cert_version` | 証明書のバージョン（デフォルト：`1`）。1 以上である必要があります。 | `1` |  | digital-signature |
| `scalar.dl.client.entity.identity.digital_signature.private_key_path` | (`private_key_pem` が空の場合は必須) 指定された証明書に対応する PEM 形式の秘密鍵ファイルのパス。 | `(空)` | `private_key_pem` と排他。 | digital-signature |
| `scalar.dl.client.entity.identity.digital_signature.private_key_pem` | (`private_key_path` が空の場合は必須) PEM エンコードされた秘密鍵データ。 | `(空)` | `private_key_path` と排他、優先される。 | digital-signature |
| `scalar.dl.client.entity.identity.hmac.secret_key` | (HMAC 認証に必須) HMAC 認証用の秘密鍵。 | `(空)` |  | hmac |
| `scalar.dl.client.entity.identity.hmac.secret_key_version` | HMAC キーのバージョン（デフォルト：`1`）。1 以上の値を設定してください。 | `1` |  | hmac |
| `scalar.dl.client.grpc.deadline_duration_millis` | gRPC リクエストのデッドライン期間をミリ秒で指定（デフォルト：`60000` ミリ秒）。 | `60000` (60 秒) |  | option |
| `scalar.dl.client.grpc.max_inbound_message_size` | 単一 gRPC フレームに許可される最大メッセージサイズ（デフォルト：`4194304` バイト）。この制限を超えると `RESOURCE_EXHAUSTED` で失敗します。 | `4194304` (4 MiB) | プロパティのリテラル既定値は `0` (= 空)。`> 0` ガードでプロパティ未設定時は gRPC framework 既定値 (4 MiB) が実効値として適用される。 | option |
| `scalar.dl.client.grpc.max_inbound_metadata_size` | 受信が許可される最大メタデータサイズ（デフォルト：`8192` バイト）。 | `8192` (8 KiB) | プロパティのリテラル既定値は `0` (= 空)。`> 0` ガードでプロパティ未設定時は gRPC framework 既定値 (8 KiB) が実効値として適用される。 | option |
| `scalar.dl.client.mode` | クライアントモード（デフォルト：`CLIENT`）。INTERMEDIARY モードでは、このクライアントは他のクライアントから署名されたシリアル化されたリクエストを受信し、サーバーに送信します。有効な値：`CLIENT` / `INTERMEDIARY`。 | `CLIENT` |  | option |
| `scalar.dl.client.private_key_path` | [非推奨] 証明書に対応する PEM 形式の秘密鍵ファイルのパス。リリース 5.0.0 で削除予定。代わりに `scalar.dl.client.entity.identity.digital_signature.private_key_path` を使用してください。 | `(空)` | 非推奨であり、リリース 5.0.0 で削除されます。 | digital-signature-deprecated |
| `scalar.dl.client.private_key_pem` | [非推奨] PEM エンコードされた秘密鍵データ。リリース 5.0.0 で削除予定。代わりに `scalar.dl.client.entity.identity.digital_signature.private_key_pem` を使用してください。 | `(空)` | 非推奨であり、リリース 5.0.0 で削除されます。 | digital-signature-deprecated |
| `scalar.dl.client.server.host` | Ledger サーバーのホスト名または IP アドレス（デフォルト：`localhost`）。DNS またはロードバランサーによって提供される単一のエンドポイントを想定しています。 | `localhost` |  | base |
| `scalar.dl.client.server.port` | Ledger サーバーのポート番号（デフォルト：`50051`）。 | `50051` |  | option |
| `scalar.dl.client.server.privileged_port` | Ledger サーバーの特権ポート番号（デフォルト：`50052`）。 | `50052` |  | option |
| `scalar.dl.client.tls.ca_root_cert_path` | Ledger との TLS 通信時に利用する CA ルート証明書（ファイルパス）。発行認証局がクライアントに知られている場合は空でも構いません。 | `(空)` | `tls.enabled=true` 時に必要。`pem` と排他。 | tls |
| `scalar.dl.client.tls.ca_root_cert_pem` | Ledger との TLS 通信時に利用する CA ルート証明書（PEM データ）。発行認証局がクライアントに知られている場合は空でも構いません。 | `(空)` | `path` と排他、優先される。 | tls |
| `scalar.dl.client.tls.enabled` | Ledger との TLS 通信を有効にするフラグ（デフォルト：`false`）。 | `false` | Ledger 側 `server.tls.enabled` と一致させる。 | tls |
| `scalar.dl.client.tls.override_authority` | Ledger との TLS 通信に使用する Ledger のホスト名/IP アドレスを指定します。証明書のホスト名がネットワークアドレスと一致しないサーバーへの接続時などに利用します。 | `(空)` |  | tls |

---

## AssetProof の署名方式と必須プロパティ行列

`scalar.dl.ledger.proof.enabled` と関連プロパティは、ドキュメントだけ読んでも挙動が判別しにくいので、本セクションで挙動と必須プロパティの組み合わせを整理する。

### AssetProof のクライアント側用途

`proof.enabled` を有効にする実用的な意味を理解しないと、Skill が「proof を有効にすべきか？」を適切に判断できない。AssetProof は **Auditor との連携専用ではなく、クライアント側で保管・検証する用途も標準でサポートされている**。

#### 根拠 1: `ContractExecutionResult` がクライアントに proof を返す

ScalarDL の `ContractExecutionResult` には `ledgerProofs` と `auditorProofs` の 2 つの `AssetProof` リストが含まれ、`getLedgerProofs()` / `getAuditorProofs()` でクライアント側から取得できる。

→ `execute-contract` の **すべてのレスポンス** に `ledgerProofs` が含まれる（Ledger 単体構成では `auditorProofs` は空、`ledgerProofs` のみ返却）。

#### 根拠 2: `AssetProof.validateWith()` でオフライン検証 API を提供

`AssetProof` クラスは公開 API として `validateWith(SignatureValidator validator)` を提供しており、`namespace`/`id`/`age`/`nonce`/`input`/`hash`/`prevHash` を serialize したバイト列を渡された validator で検証する。失敗時は `SignatureException` (`CommonError.PROOF_SIGNATURE_VALIDATION_FAILED`) を投げる。

→ クライアントが Ledger の公開鍵を保持していれば、ScalarDL サーバへの問い合わせ無しで proof のオフライン検証が可能。

#### `AssetProof` の中身

各 AssetProof は以下のフィールドを持つ:

- `namespace` (String)
- `id` (String) — asset ID
- `age` (int) — asset version
- `nonce` (String) — 一意識別子
- `input` (String)
- `hash` (byte[]) — この age での asset 状態のハッシュ
- `prevHash` (byte[]) — 前 age の hash（chain 構造）
- `signature` (byte[]) — Ledger の秘密鍵 or HMAC で署名

`hash` と `prevHash` で **ハッシュチェーン** が形成されているため、過去の任意時点を起点に整合性を遡及検証できる。

#### Ledger 単体 (Auditor 無し) での AssetProof 用途

| 用途 | 概要 | 実装方法 |
|---|---|---|
| **改ざん検知 (受信時保管型)** | アプリは execute-contract のたびに `ledgerProofs` を自前 DB / 不変ストレージ等に保存。後から ScalarDB が直接書き換えられた場合、Ledger 側の正規経路で再生成される proof と保存済み proof の `hash`/`signature` が食い違うことで改ざんを検知できる。 | アプリ層で proof を S3 / WORM ストレージ等に保存 |
| **監査証跡 (Audit trail)** | コンプライアンス対応。各取引の AssetProof を時刻付きで保存しておけば「この時点でこの入力でこの結果が記録された」ことの非否認証拠になる。 | 同上 |
| **オフライン検証** | アプリは Ledger 公開鍵を持っておけば、ScalarDL サーバを介さず `AssetProof.validateWith(SignatureValidator)` (公開 API) で署名検証できる。CLI に対応コマンドはなく、Java/Python SDK 経由でアプリが直接呼ぶ。Ledger ダウン時や監査時に有用。 | 公開鍵をアプリに同梱、`validateWith()` を呼ぶ |
| **Byzantine 検知の前段階** | 将来 Auditor を追加することを見据え、最初から `proof.enabled=true` で proof を蓄積しておけば、Auditor 導入後の検証が連続的に行える。 | `proof.enabled=true` で運用 |
| **`validate-ledger` での自己検証** | アプリは過去の任意時点まで遡って `validate-ledger` を呼び、Ledger 側で hash chain を辿って整合性を検証してもらう。 | API 呼び出し |

> **補足**: `proof.enabled=false` でも `validate-ledger` のサーバ側検証ロジック (Contract / Output / PrevHash / Hash / Nonce の 5 validator) は通常通り動作し、StatusCode は返る。違いは「クライアントに署名済み AssetProof が返るか否か」のみ (signer null なら proof は null 返却)。**サーバ側 hash chain 整合性チェックだけが目的なら `proof.enabled=false` で運用可能**。「クライアント側で proof を保管・後で検証」用途のときだけ `proof.enabled=true` が必要。

#### 単体運用での限界 (threat model)

| 検知できる | 検知できない |
|---|---|
| ✅ DB レイヤや運用者による **直接的な ScalarDB 改ざん** | ❌ Ledger サーバ自身（または Ledger 秘密鍵を持つ者）による改ざん |
| ✅ アプリ側に保管した proof との突合による事後検知 | ❌ 新旧どちらの状態でも整合する署名を Ledger 自身が生成可能 (秘密鍵を持つため) |
| ✅ オフライン署名検証による単発 proof の真正性確認 | ❌ Byzantine fault (= Ledger 自体の悪意・障害) の検知 |

→ **Ledger 自身による改ざん**まで防ぎたい場合は Auditor 構成 (独立した第三者署名) が必須。これが ScalarDL の設計思想。

#### Skill 設計への含意

Configuration 生成 Skill で `proof.enabled` の値を聞く場面では、単に「true/false」を尋ねるのでは不十分。以下のような threat model 質問に変換するとユーザに適切な選択肢を提示できる:

- 「監査証跡が必要ですか？」 → Yes なら `proof.enabled=true`
- 「クライアント側で取引のたびに証拠保存しますか？」 → Yes なら `proof.enabled=true`
- 「Ledger サーバ自身の改ざんも検知したいですか？」 → Yes なら Auditor 構成も必要 (`auditor.enabled=true`、別 DB)



### validate-ledger の 2 経路と検証方法の違い

`validate-ledger` (公開 API / CLI) は `auditor.enabled` の値で内部的に異なる経路に分岐し、検証方法が根本的に異なる:

| 経路 | 検証方法 | 公開 API |
|---|---|---|
| Standalone (`auditor.enabled=false`) | サーバ側 `LedgerValidationService` が 5 validators (Contract / Output / PrevHash / Hash / Nonce) を各 asset に明示適用 | `validate-ledger` |
| Auditor 構成 (`auditor.enabled=true`) | **Layer 1**: ValidateLedger contract が範囲 scan で proof を生成 (両 server で独立実行) / **Layer 2**: SDK 内部 `validateResponses` が両側の proof を namespace+assetId+age+hash で全件照合 | `validate-ledger` (内部で `executeContract` に展開) |

**過去レコード改ざん検知の歴史**:

過去レコード改ざん検知は **Layer 1 と Layer 2 の組み合わせ**で成立する:

- `validateResponses` (Layer 2) は古くから存在し、「**与えられた proof リストを 1 件ずつ照合する**」比較エンジン
- ただし渡される proof は ValidateLedger contract (Layer 1) の出力次第
- 過去 age の proof を比較対象に含めるには、contract が範囲 scan する必要がある
- **公式 bundle の ValidateLedger v1_0_0 (2025-09 リリース) 以降、`startAge=0, endAge=MAX` の範囲 scan が公式デフォルト**となり、過去レコード改ざん検知が turnkey で動くようになった

3.11 以前は `register-contract` で登録するユーザ自作 contract に依存しており、最新 age のみ検証する実装も理論上あり得た。3.12 以降を前提とすれば、追加の対応なく過去改ざん検知が機能する。

**API レイヤ整理**:

| 名称 | 種類 | 公開度 |
|---|---|---|
| `validate-ledger` / `execute-contract` | 公開 API / CLI コマンド | ユーザが直接呼ぶ |
| `validateResponses` | クライアント SDK 内部の private メソッド | 公開されていない |
| `AssetProof.validateWith()` | 公開 API (アプリから呼べる) | クライアント側 proof のオフライン署名検証用 |

公開 API は `validate-ledger` / `execute-contract` のみ。`validateResponses` は SDK 内部実装のため、ユーザ・Skill が直接意識する必要はないが、Auditor 構成の動作原理として把握しておくと挙動理解に役立つ。

**カスタム ValidateLedger contract の使用**:

`linearizable_validation.contract_id` にカスタム値を指定すれば独自 contract を使える。最小限の手順:

1. `JacksonBasedContract` 継承の contract を Java で実装 (公式 v1_0_0 が最小実装の参考)
2. `.class` にコンパイル
3. `register-contract --contract-id <custom-id> --contract-binary-name <FQCN> --contract-class-file <path>` で Ledger / Auditor 双方に登録
4. `client.properties` に `scalar.dl.client.auditor.linearizable_validation.contract_id=<custom-id>` を設定

注意点:

- カスタム ID 指定時は `auto_bootstrap` の ValidateLedger 自動登録は skip される。手動 register が必須
- 過去レコード改ざん検知が必要なら **範囲 scan** (`startAge..endAge` 全件読み込み) を contract で実装する必要あり。最新 age のみの実装にすると過去 age の改ざんは検知できない
- 詳細な contract 開発手順は公式 docs (`how-to-create-a-contract` 系) を参照

### 署名方式の決定ロジック

AssetProof signer は ScalarDL Ledger の DI 設定で次の優先順位で選ばれる:

1. `proof.enabled=false` → signer は null (AssetProof は生成されない)
2. `proof.enabled=true` AND `servers.authentication.hmac.secret_key` が **設定されていない** → `DigitalSignatureSigner` (DS 署名、`proof.private_key` を使用)
3. `proof.enabled=true` AND `servers.authentication.hmac.secret_key` が **設定されている** → `HmacSigner` (HMAC 署名)

**重要な点**: AssetProof の署名方式は `authentication.method` (= クライアント-Ledger 間認証方式) ではなく、**`servers.authentication.hmac.secret_key` の有無** で決まる。

### Constructor が `serversAuthHmacSecretKey` を読むタイミング

`LedgerConfig` の constructor は `servers.authentication.hmac.secret_key` を **`auditor.enabled=true` の場合にしか読み込まない**:

- `auditor.enabled=true` の場合: `servers.authentication.hmac.secret_key` を properties から読み込み、`proof.enabled` も `true` 必須として検証。`authentication.method=digital-signature` で proof private key 不在ならエラー、`authentication.method=hmac` で `servers.authentication.hmac.secret_key` 不在ならエラー
- `auditor.enabled=false` (standalone) の場合: `servers.authentication.hmac.secret_key` は **読み込まれず常に null 扱い**。`proof.enabled=true` なら `proof.private_key_*` が必須

→ **`servers.authentication.hmac.secret_key` は `auditor.enabled=true` のときにしか properties から読み込まれない**。standalone Ledger で本プロパティを設定しても無視され、HMAC signer に切り替わることはない。

### 必須プロパティ行列

| `auditor.enabled` | `proof.enabled` | `authentication.method` | AssetProof 署名方式 | 必須プロパティ | 備考 |
|---|---|---|---|---|---|
| `false` | `false` | (any) | （AssetProof 無し） | なし | `validate-ledger` でも AssetProof 不可 |
| `false` | `true` | `digital-signature` | DS | `proof.private_key_path` または `_pem` | constructor `checkArgument` |
| **`false`** | **`true`** | **`hmac`** | **DS（強制）** | **`proof.private_key_path` または `_pem`** | **`servers.authentication.hmac.secret_key` を書いても読まれない** |
| `true` | `false` | — | — | （起動失敗） | `LedgerError.CONFIG_PROOF_MUST_BE_ENABLED` |
| `true` | `true` | `digital-signature` | DS (default) / HMAC (`servers.hmac.secret_key` 設定時) | `proof.private_key_path` または `_pem` | `servers.authentication.hmac.secret_key` を設定すると server-server / AssetProof 署名が HMAC に切り替わる (混合構成、後述) |
| `true` | `true` | `hmac` | HMAC | `servers.authentication.hmac.secret_key` | `proof.private_key_*` は無くてもよい |

**直感に反する箇所**（太字行）: HMAC 認証であっても **Auditor 無効構成では DS 鍵が必要**。設計意図として、HMAC ベースの AssetProof 署名は「Ledger ↔ Auditor 間のサーバ間認証」に紐付いた機能であり、プロパティ名が複数形 `servers.*` であることに表れている。

**混合構成 (DS auth + HMAC server-server) の落とし穴**:

`auditor.enabled=true` + `authentication.method=digital-signature` の構成でも、`servers.authentication.hmac.secret_key` を **追加で設定する** と server-server 認証と AssetProof 署名は HMAC に切り替わる。これは ScalarDL の Auditor 構成に **4 つの独立した認証方向** が存在するため:

| 認証方向 | 制御 | DS / HMAC の選択 |
|---|---|---|
| Client ↔ Ledger | `ledger.authentication.method` | 明示指定 |
| Client ↔ Auditor | `auditor.authentication.method` | 明示指定 |
| Ledger ↔ Auditor (server-server) | `servers.authentication.hmac.secret_key` の **有無** | 暗黙 (有: HMAC / 無: DS) |
| AssetProof 署名 | 上記と同じ (`servers.hmac.secret_key` の有無) | 暗黙 (有: HMAC / 無: DS) |

そのため "DS Client + HMAC server-server" のような混合構成も可能。

**落とし穴**: 混合構成にしても constructor チェックは DS auth 時に `proof.private_key_*` を依然 required にしているため、**HMAC server-server 経路で AssetProof 署名に使われていなくても `proof.private_key_*` の設定は外せない (dead 設定として残す必要あり)**。`auth.method=hmac` 構成にすればこの dead 設定は不要になる。

### Skill 質問フローへの含意

Configuration 生成 Skill で AssetProof 関連を聞く場合、以下のフローが正確:

```
1. Q: auditor.enabled?
   ├─ Yes:
   │   2. proof.enabled は自動的に true (constructor 要求)
   │   3. Q: authentication.method? (DS / HMAC)
   │      ├─ DS: Q: proof.private_key_path or pem?
   │      └─ HMAC: Q: servers.authentication.hmac.secret_key?
   └─ No (standalone):
       2. Q: proof.enabled?
          ├─ Yes: Q: proof.private_key_path or pem?
          │   (authentication.method の値に関わらず DS 鍵を必ず聞く)
          └─ No: 鍵関連は不要
```

**ポイント**: Auditor 無効ルートでは `authentication.method` の値で proof 鍵の必要性が変わらない、という挙動を Skill 側のロジックに反映する必要がある。

---

## Ledger-Auditor 間サーバ間認証 (server-server) の DS / HMAC 選択

`auditor.enabled=true` 構成では、**Client-Server 認証とは別に** Ledger ↔ Auditor 間の **server-server 認証** が存在する。本セクションは、ここで DS / HMAC のどちらを使うかが「明示的なフラグではなく `servers.authentication.hmac.secret_key` の有無で暗黙的に決まる」という分かりにくい仕様と、それに伴う「非推奨だが現状必須」プロパティ群の整理。

### 3 つの認証方向の整理

ScalarDL には **独立した 3 つの認証方向** がある。それぞれ制御方法が異なる:

| 認証方向 | 制御プロパティ | 選択肢 | 認証方式の決まり方 |
|---|---|---|---|
| Client ↔ Ledger | `scalar.dl.ledger.authentication.method` | `digital-signature` / `hmac` | 明示的に文字列で指定 |
| Client ↔ Auditor | `scalar.dl.auditor.authentication.method` | `digital-signature` / `hmac` | 明示的に文字列で指定 |
| Ledger ↔ Auditor (server-server) | `scalar.dl.{ledger,auditor}.servers.authentication.hmac.secret_key` の有無 | DS / HMAC | **暗黙的**（プロパティが空なら DS、設定されていれば HMAC）|

3 番目だけ命名規則が違うため、「`authentication.method=hmac` にしたから server-server も HMAC になるはず」と誤認しやすい。実際には **3 方向は完全に独立** に選択可能。

### server-server 認証の決定ロジック

Ledger 側 / Auditor 側のどちらでも、起動時の DI 構成で次の判定が走る:

- `servers.authentication.hmac.secret_key` が `null` → **DS 経路**: cert ベースで相互検証
- `servers.authentication.hmac.secret_key` が **非 null** → **HMAC 経路**: 共有 secret key で検証

→ Ledger と Auditor の双方で `servers.authentication.hmac.secret_key` を **同じ値で設定** すれば HMAC 経路、**双方で空** にすれば DS 経路（混在は機能しない、両側で一致させる必要がある）。

### DS server-server 経路で必須となるプロパティ

**Ledger 側** (Auditor の ordering 署名を検証するため、Auditor の cert を引く):

| プロパティ | 用途 |
|---|---|
| `scalar.dl.ledger.auditor.cert_holder_id` | Auditor 証明書を引くキー |
| `scalar.dl.ledger.auditor.cert_version` | 同じく version |
| `scalar.dl.ledger.proof.private_key_path` または `_pem` | AssetProof 署名鍵（DS signer 用）|

**Auditor 側** (Ledger 由来の AssetProof 署名を検証するため、Ledger の cert を引く):

| プロパティ | 用途 |
|---|---|
| `scalar.dl.auditor.ledger.cert_holder_id` | Ledger 証明書を引くキー（Auditor 側 Linearizable Validation で使用）|
| `scalar.dl.auditor.ledger.cert_version` | 同じく version |
| `scalar.dl.auditor.cert_holder_id` | Auditor 自身の証明書識別 |
| `scalar.dl.auditor.cert_version` | 同じく version |
| `scalar.dl.auditor.private_key_path` または `_pem` | Auditor 自身の AssetProof / ordering 署名鍵 |

加えて、**Ledger / Auditor がそれぞれ相手側の証明書を ScalarDL に事前登録** しておく必要がある（`register-cert` などの管理オペレーション）。

### HMAC server-server 経路で必須となるプロパティ

**Ledger 側 / Auditor 側 双方で**:

| プロパティ | 用途 |
|---|---|
| `scalar.dl.ledger.servers.authentication.hmac.secret_key` | Ledger 側で設定 |
| `scalar.dl.auditor.servers.authentication.hmac.secret_key` | Auditor 側で設定（**同じ値**）|

→ 双方の値が一致しなければ認証が成立しない。HMAC 経路を選ぶ場合、上記 DS 系プロパティ（cert_holder_id 等、proof.private_key_*）は **設定しても読まれない**（Ledger 単体では `serversAuthHmacSecretKey` が constructor で読まれずに無効化されるが、Auditor 構成では読まれて HMAC signer が選択される）。

### 「非推奨だが現状必須」プロパティ一覧

リリース 5.0.0 で削除予定だが、**DS server-server 経路を採用する場合は現状必須**:

| プロパティ | 役割 | 現状の必須条件 |
|---|---|---|
| `scalar.dl.ledger.auditor.cert_holder_id` | Auditor cert lookup | DS server-server 経路で必須 |
| `scalar.dl.ledger.auditor.cert_version` | 同 version | 同上 |
| `scalar.dl.auditor.cert_holder_id` | Auditor 自身の cert lookup | 同上 |
| `scalar.dl.auditor.cert_version` | 同 version | 同上 |
| `scalar.dl.auditor.ledger.cert_holder_id` | Ledger cert lookup（**Ledger proof 署名検証に直接利用**）| 同上 |
| `scalar.dl.auditor.ledger.cert_version` | 同 version | 同上 |

これら 6 プロパティは命名上「entity.id」系への置換が用意されておらず、v5.0.0 で **HMAC server-server 強制化と同時に消滅** する設計。

### Skill 取り扱い方針 (deprecated 系プロパティ)

リリース 5.0.0 の ETA が未公表のため、deprecated は「置換コスト」で 2 系統に分けた上で、**Skill が特別処理する必要があるのは系統 (1) のみ** と判断する。

**系統 (1): 1 対 1 置換可能 (Client 系 7 プロパティ)**

| 旧 | 新 |
|---|---|
| `scalar.dl.client.cert_holder_id` | `scalar.dl.client.entity.id` |
| `scalar.dl.client.cert_path` | `scalar.dl.client.entity.identity.digital_signature.cert_path` |
| `scalar.dl.client.cert_pem` | `scalar.dl.client.entity.identity.digital_signature.cert_pem` |
| `scalar.dl.client.cert_version` | `scalar.dl.client.entity.identity.digital_signature.cert_version` |
| `scalar.dl.client.private_key_path` | `scalar.dl.client.entity.identity.digital_signature.private_key_path` |
| `scalar.dl.client.private_key_pem` | `scalar.dl.client.entity.identity.digital_signature.private_key_pem` |
| `scalar.dl.client.authentication_method` (アンダースコア) | `scalar.dl.client.authentication.method` (ドット) |

→ Skill では **新スタイルのみで出力。旧スタイルは UI に出さない**。機能差は無く、機械的なマッピングで置換できる。

**系統 (2): 置換不可 (Server-Server 6 cert プロパティ)**

`ledger.auditor.cert_holder_id` / `cert_version`、`auditor.cert_holder_id` / `cert_version`、`auditor.ledger.cert_holder_id` / `cert_version` は、DS server-server 経路を選んだ場合に通常通り設定する。**Skill で deprecated として特別な処理は不要**。HMAC server-server 経路を選んだ場合は不要となる、という通常の auth method 分岐ロジックで吸収できる。

将来の v5.0.0 移行時には DS 経路を捨てて HMAC 経路に切り替える設計変更が必要になるが、それまでは現状の DS 経路設定をそのまま利用可能。

### Skill 設計への含意

Configuration 生成 Skill での質問フロー:

```
auditor.enabled=true の場合:
  Q: "Ledger-Auditor 間の server-server 認証方式を選んでください"
     ├─ "HMAC（推奨、v5.0.0 への移行不要）"
     │   → servers.authentication.hmac.secret_key を Ledger / Auditor 双方に同じ値で設定
     │   → cert_holder_id 系は設定不要
     │   → proof.private_key_* も不要 (HMAC signer が AssetProof を署名)
     │
     └─ "Digital Signature（v5.0.0 で削除予定、警告表示）"
         → ledger.auditor.cert_holder_id / cert_version (Ledger 側)
         → auditor.cert_holder_id / cert_version (Auditor 自身)
         → auditor.ledger.cert_holder_id / cert_version (Auditor 側)
         → proof.private_key_path / _pem (Ledger / Auditor 双方)
         → 「v5.0.0 移行時は HMAC への切替が必要」と警告
```

`authentication.method` (= Client-Server 認証方式) とは別質問にすることが重要。3 方向独立選択を Skill UI で表現できないと混乱を招く。

> **将来注**: v5.0.0 では DS server-server 経路用の deprecated cert プロパティ群 (`ledger.auditor.cert_*`, `auditor.cert_*`, `auditor.ledger.cert_*`) は廃止予定。新規構築では **HMAC server-server 推奨** (将来の移行不要)。既に HMAC 経路で運用していれば v5.0.0 への移行影響なし。

---

## 参考リンク

- [Run a ScalarDL Application Through ScalarDL Ledger and Auditor](https://github.com/scalar-labs/docs-scalardl/blob/main/docs/how-to-run-applications-with-auditor.mdx)
- [ScalarDL Command Reference](https://github.com/scalar-labs/docs-scalardl/blob/main/docs/scalardl-command-reference.mdx)
- [Getting Started with ScalarDL](https://github.com/scalar-labs/docs-scalardl/blob/main/docs/getting-started.mdx)
- [Getting Started with ScalarDL HashStore](https://github.com/scalar-labs/docs-scalardl/blob/main/docs/getting-started-hashstore.mdx)
- [Getting Started with ScalarDL TableStore](https://github.com/scalar-labs/docs-scalardl/blob/main/docs/getting-started-tablestore.mdx)
