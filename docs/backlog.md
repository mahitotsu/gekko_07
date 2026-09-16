# バックログ

未着手の改善項目・未決定事項。着手時はこのファイルから該当項目を削除し、必要ならarchitecture.md/services.md/insights.mdへ結果を記録する。

## Token Exchange / Envoyサイドカー

- **ext-authzサービスの呼び出し元汎用化（複数クライアント対応）**：[k8s/ext-authz/](../k8s/ext-authz/)は現状、呼び出し元ごとに固定資格情報を持つ別インスタンス（`ext-authz-service-cc`=fraud-detection-engine固定のclient_credentials）を並べる形で対応している。fraud-mcp-server向けは[ADR 0019](adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)で共有インスタンス自体を廃止し、呼び出し元自身のPod内サイドカーへ移したため、この項目の対象から外れた。残りのホップ（frontend→account-service/fraud-agent、fraud-agent→fraud-mcp-server、account-service→analyst-attribute-service）へ横展開する際、ADR 0019と同じ「呼び出し元のPod内サイドカー化」を横展開するか、共有インスタンス継続＋資格情報の動的切り替えの仕組みを作るかを判断する
- **ext-authz-service-cc・ext-authz-service-analystの身元検証ギャップ**：[ADR 0019](adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)で指摘した「Keycloakが検証するmTLS身元と主張するclient_idの不一致」は、fraud-mcp-server向け(パターン①)のみ解消した。`ext-authz-service-cc`(fraud-detection-engine、client_credentials)・`ext-authz-service-analyst`(account-service→analyst-attribute-service)は同じギャップを抱えたまま。client_credentialsパターンにはKeycloakのSPIFFE federated-jwt対応が使えるか(client_credentialsもclient認証自体は同じ`federated-jwt`で通るはず、実機未検証)を含め、同じ是正パターンの横展開を検討する
- **frontendのdirectAccessGrantsEnabled一時許可の後始末**：[k8s/keycloak/test-fixtures-job.yaml](../k8s/keycloak/test-fixtures-job.yaml)は、フロントエンド未実装でもブラウザなしでログインし1ホップ先行検証を行うため、`frontend`クライアントの`directAccessGrantsEnabled`を一時的にtrueにしている。frontend実装時に、自動テストで使い続けるか、Authorization Code + PKCEのみに戻すかを判断する
- **合言葉ヘッダー名・env var名の確定**：1ホップ先行検証でヘッダー名`x-gekko-handshake`・env var名`HANDSHAKE_TOKEN_FILE`を採用し、Python実装のスタブ間で統一した（[k8s/account-service/app-configmap.yaml](../k8s/account-service/app-configmap.yaml)等）。Java/TypeScript/Rust/Go等、他言語での本実装時にも同じ命名を踏襲する
- **Unixドメインソケット化の再検討**：[ADR 0009](adr/0009-envoy-ingress-responsibility-and-bypass-prevention.md)でTCP loopback+合言葉方式を採用しUnixドメインソケット化は見送ったが、「同一Pod内でアプリが侵害された場合」まで守る要求が出てきたら再検討する
- **DPoPの適用範囲**：[ADR 0013](adr/0013-dpop-sender-constraining.md)でfraud-mcp-server→account-serviceの1ホップに導入したが、[ADR 0015](adr/0015-dpop-removal-and-fraud-detection-engine-mtls.md)で撤去した（mTLSとの実利の重複が大きい一方、制約だけが残るため）。実機検証で得た知見は下記「DPoP」節に残す
- **Token Exchange結果のキャッシュ**：`(subject jti, audience)`単位でのキャッシュを検討しているが、ext_authzサービス側に持たせるか、どの範囲で共有するかは未決定。キャッシュTTLは性能とのトレードオフを意図的に選んだ短い値にする
- **交換後トークンのアクセストークン有効期間**：[ADR 0006](adr/0006-claim-vs-external-attribute-criteria.md)は、トークン漏洩・誤用時の被害範囲を抑える多層防御として交換後トークンの有効期間を短く設定する方針を前提にしている。ログイントークンとは別に、各クライアント（frontend/fraud-mcp-server/account-service）が交換で得るトークンのAccess Token Lifespanを具体的に何秒にするかは未決定

## DPoP

[ADR 0013](adr/0013-dpop-sender-constraining.md)でfraud-mcp-server→account-serviceの1ホップに実装・実機検証したが、[ADR 0015](adr/0015-dpop-removal-and-fraud-detection-engine-mtls.md)で撤去した（このホップは既にSPIRE mTLSで身元を限定済みのため実利の重複が大きく、投資に見合わないと判断）。コードは無いが、将来DPoPを再検討する際に効く実機知見として残す。

- **「拘束のスロット」は委任チェーンに1箇所、終端ホップのみ**：subject_tokenに既存の拘束が無ければ要求者は自分の鍵で新しく拘束できるが、既存の拘束がある場合は別クライアント・別鍵での再exchangeがKeycloakに拒否される（`400: Sender-constrained token exchange rejected as the token was not issued for the requesting client`。実機検証済み）。このため一度どこかのホップでDPoPを有効化すると、そこから先(例：account-service→analyst-attribute-service)への拡張はできない
- **frontendへの適用は限定的**：frontend→fraud-mcp-server向けのexchangeには上記制約により適用できない。frontend→account-serviceへの直接exchange（pattern②、確定パス。それ自体が委任チェーンの終端となる）であれば理論上は可能だが、frontend未実装のため未検証
- **Keycloakの`dpop.bound.access.tokens`が有効なクライアントは、トークンリクエスト全般（ROPCログイン等も含む）で常にDPoP proofが必須になる**点、**proof lifetime/clock skew windowが固定**（`DEFAULT_PROOF_LIFETIME=10秒`・`DEFAULT_ALLOWED_CLOCK_SKEW=15秒`、Keycloak 26.7.0でハードコード）である点も、再検討時の制約として記録
- **Keycloak issue #51205（DPoP bound tokenとdelegation/actor tokenの衝突）**：26.7.0に対して未解決のまま提出されている。今回遭遇した「既存の拘束を持つsubject_tokenの再exchange失敗」と同種の問題を指摘しており、将来Keycloak側の挙動が変わればこのプロジェクトの制約も変わる可能性がある

## mTLS / SPIFFE / SPIRE

[ADR 0012](adr/0012-spiffe-spire-mtls-single-hop.md)でfraud-mcp-server→account-service、[ADR 0015](adr/0015-dpop-removal-and-fraud-detection-engine-mtls.md)でfraud-detection-engine→account-service、[ADR 0016](adr/0016-ext-authz-and-keycloak-mtls.md)でext-authz-service(-cc)↔呼び出し元Envoy・ext-authz-service(-cc)↔Keycloak、[ADR 0017](adr/0017-edge-proxy-full-keycloak-mtls.md)でedge-proxy導入によるKeycloakの完全mTLS化(8080撤廃、account-serviceのJWKS取得もmTLS化)に導入済み。以下は明示的にスコープ外とした。

- **他ホップへの横展開**：frontend→account-service/fraud-mcp-server、account-service→analyst-attribute-service等、残りの委任関係へのmTLS適用は未着手（frontend/analyst-attribute-service自体が未実装）。frontend実装時はedge-proxy(ADR 0017)を経由させ、同じPodを使い回す想定
- **NetworkPolicyのspire namespaceへの横展開**：[ADR 0018](adr/0018-network-policy-default-deny.md)で`gekko` namespaceにL3/4のdefault-denyを導入したが、`spire` namespace（spire-server/spire-agent）は対象外とした。spire-agentが`hostNetwork: true`で動作しており、kube-router netpolがhostNetwork Podに対してどう振る舞うかが未検証なため。加えて`spire-entries` Job（`kubectl exec`でspire-serverへ接続する）等、`gekko` namespaceとは異なる接続パターンを持つ点も要考慮
- **ADR 0002見直し（RFC 8705を実現するためのWASMフィルタ化）**：見送ったままだが、そもそもRFC 8705（mTLSクライアント認証、`client-x509`）はKeycloak 26.7.0がSubject DNしか見ずSPIFFE URI SANに未対応（Keycloak公式Issue #41907）と判明したため、WASM化しても目的（SPIFFE身元でのクライアント認証）は達成できないことが分かった（[ADR 0019](adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)、docs/insights.md参照）。fraud-mcp-server向けは代わりにKeycloakネイティブのSPIFFE JWT-SVID対応で目的を達成済み。本項目自体はRFC 8705路線として完全に見送りでよい
- **ワークロードPod（account-service-stub/fraud-mcp-server-stub等）自体への`hostPID`/`hostNetwork`付与**：SPIRE agentには必要だが、ワークロードPod側はカーネルのPID名前空間の性質上不要なはずという推測のもとで見送った。属性解決が実機で失敗した場合（SDS呼び出しがタイムアウトする、spire-serverのログに"no selectors found after max poll attempts"が出る等）のみ再検討する
- **`spiffe-csi`ドライバ・`spire-controller-manager`**：新規可動部を増やさないため、hostPathでのソケット共有・`spire-server entry create` CLIでの手動登録を選んだ。本番相当の運用を検証したくなった場合に再評価する

## 属性・アクセス制御の粒度

- **口座属性の拡張要否**：現状は地域(`region`)とティア(`standard`/`high-value`)の2軸のみ（access-control-design.md 表5）。実装を進める中でさらに軸が必要になるか要検討
- **アナリストの担当地域が複数ある場合の表現**：配列で持つ想定（access-control-design.md 表6）だが、Keycloakロール/属性のどちらに載せるかは未定

## 監査

- **`proposal_id`とOpenTelemetryトレース・Keycloakイベントログの統合方式**：architecture.md §8で要件のみ決めた。監査ツールを別途作るか、突合方法の詳細は未定
- **サンプリング率を下げた場合の`trace_id`保持**：サンプリング率を1.0未満に下げた状態でも`sampled=false`のリクエストのtrace_idがログに残ることを実機で確認する必要がある（未検証）

## データストア

- **本番相当環境でのインスタンス分離**：現状はローカルのメモリ制約を理由にaccount-service/fraud-detection-engine/analyst-attribute-service/KeycloakのPostgreSQLを共有インスタンスにしている（ADR 0008）。本番相当の構成を検証したくなった場合、サービスごとの専用インスタンスへの切り替えを検討する
- **既定メンテナンスDB（`postgres`）への接続が全ロールに残っている**：[k8s/keycloak/db-init-configmap.yaml](../k8s/keycloak/db-init-configmap.yaml)で`keycloak`データベースはPUBLICのCONNECT権限を剥奪したが、Postgresの既定メンテナンスデータベース自体は未対応。実データを持たないため実害はないが、完全な分離ではない

## Keycloak

- **`standard.token.exchange.enabled`属性の機能的検証**：1ホップ先行検証（frontend→fraud-mcp-server、fraud-mcp-server→account-service）でRFC 8693トークン交換リクエストが実際に通ることを確認済み（[insights.md](insights.md)参照）。ただしaudience解決には対象audience向けの`oidc-audience-mapper`がclient scope側に必要という追加の前提が判明した（同insights.md）。account-service→analyst-attribute-serviceの経路（analyst-attribute-serviceはまだKeycloakクライアントとして未定義）は未検証のまま
- **標準client scope（profile/email/roles等）の要否**：`--import-realm`での直接importでは自動生成されないため現状未定義（詳細はrealm-configmap.yamlのコメント参照）。ログイントークンに`preferred_username`等が必要になった時点でclientScopesに明示定義を追加する

## インフラ

- **k3dクラスタの複数ノード化**：現状`servers: 1, agents: 0`（k3d/cluster-config.yaml）。スケジューリングの検証が必要になった場合はagentノードを追加するか検討
- **WSL2 cgroup v2化の恒久性**：`.wslconfig`の`kernelCommandLine = cgroup_no_v1=all`で対応済み（insights.md参照）だが、Windows Update等で設定が失われないかは未検証
