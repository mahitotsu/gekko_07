# ADR 0012: fraud-mcp-server→account-serviceの1ホップにSPIFFE/SPIREでmTLSを導入する

- **Status**: Accepted
- **Date**: 2026-09-15

## Context

これまでの設計・実装は「誰がどのトークンで何をしてよいか」という業務認可層（Keycloak・スコープ・Token Exchange。[access-control-requirements.md](../access-control-requirements.md) BR0〜BR8、[ADR 0002](0002-token-exchange-in-envoy-sidecar.md)・[ADR 0009](0009-envoy-ingress-responsibility-and-bypass-prevention.md)・[ADR 0010](0010-egress-listener-granularity.md)）に集中しており、Envoy間の通信路自体（誰が接続してきているか・盗聴/改竄耐性）は素のHTTP/1.1平文のままだった。これは業務認可層とは別の関心事であり、金融系トラフィックにふさわしい水準を別途検討した。

### ゼロトラストの要件（R1〜R7）

NIST SP 800-207/800-207A（ゼロトラストの核心は"identity-based segmentation"：IP/サブネットではなくワークロード単位の暗号学的な身元で信頼境界を引く）とPCI DSS 4.0（内部セグメントであっても侵害されうる経路とみなし強力な暗号化を求める方向への拡張）を踏まえ、以下を要件とする。

- **R1 全hop暗号化**：ingressだけでなくEnvoy間の内部通信もTLS1.2+必須
- **R2 相互認証**：通信の両側が相手のワークロード身元を暗号学的に検証する（サーバー側TLSのみは不可）
- **R3 ワークロード単位の識別**：証明書はサービスごとに区別できること（共有1組の証明書は不可）
- **R4 短命・自動ローテーション**：長期の自己署名証明書の手動配布・手動更新は運用上の負債であり不可
- **R5 業務認可層との併存**：mTLS/ワークロードIDはBR0〜BR8の代替にならない。両層は独立に必要
- **R6 トークン盗用対策は別トラック**：DPoP/RFC 8705のようなトークン送信者拘束は、輸送層のmTLSと直交する課題として別管理する
- **R7 ネットワーク層の多層防御**：NetworkPolicyによるL3/4のdefault-denyも、mTLS・業務認可とは独立な層として別途検討する

### cert-manager vs SPIFFE/SPIRE

R1〜R4を満たす実現手段として、cert-manager（自己署名CA Issuer）とSPIFFE/SPIREを比較した。

| 手段 | 評価 |
|---|---|
| cert-manager（自己署名CA Issuer） | R1〜R3は満たすが、R4（自動ローテーション）は「Certificateリソースの命名規則（namespace/ServiceAccount）」止まりで、実行時のワークロード属性証明（このPodが本当にそのノード・ServiceAccountで動いているか）までは持たない。部分達成 |
| **SPIFFE/SPIRE（採用）** | R1〜R4を額面通り満たす。ノード/ServiceAccountに基づく実行時属性証明から短命（既定1時間程度）なX.509-SVIDを自動発行・自動ローテーションする |

Istio導入（[ADR 0003](0003-k3d-without-istio.md)）は「学習対象がトラフィック管理等まで拡散する」という理由で当面不採用としたが、SPIREはワークロードID発行だけに機能が閉じているため同じ理由は当てはまらない。JWT検証・RBAC・Token Exchange・client_credentialsと同じ粒度で、単一の本番相当の関心事（ワークロードID・mTLS）を1つずつ実機検証していく、というこのプロジェクトの一貫した方針に沿う。

### RFC 8705（証明書拘束アクセストークン）は構造的に成立しない

トークン送信者拘束の代替候補としてRFC 8705（mTLSの証明書でアクセストークンを拘束する）を検討したが、本プロジェクトのアーキテクチャでは**スコープの問題ではなく構造的に成立しない**と判断した。

Keycloakへの実際のToken Exchange呼び出しは、各サービス自身のEnvoyではなく共有の`ext-authz-service`（Envoyサイドカーを持たない）が行う（[ADR 0002](0002-token-exchange-in-envoy-sidecar.md)）。RFC 8705はトークン発行時にmTLS認証したクライアント証明書と、トークン提示時に使われたクライアント証明書が同一であることを要求するが、本プロジェクトでは「発行時にKeycloakへ接続する主体（`ext-authz-service`）」と「提示時にaccount-serviceへ接続する主体（fraud-mcp-server自身のEnvoy）」が異なるプロセス・異なる証明書になる。これは`ext-authz-service`を言語非依存の集約点として設計したADR 0002の意図そのものが生む帰結であり、この集約を維持する限りRFC 8705は成立しない（ADR 0002をWASMフィルタ化して各サービス自身のEnvoy内でToken Exchangeを完結させれば理論上は成立するが、ADR 0002が明示的に退けたビルドトールチェーン導入コストを再度負うことになり、今回は見送る。backlog.md参照）。

このため、トークン送信者拘束が必要になった場合はDPoP（RFC 9449）を検討対象とする。DPoPはアクセストークン自体はキャッシュ可能なまま、提示のたびに新しい署名付きproof（`htm`/`htu`/`iat`/`ath`をバインド）を要求する方式で、mTLS接続の同一性に依存しないため、`ext-authz-service`を挟む今のアーキテクチャと矛盾しない。ただし、DPoP proofの再生検知にはjti追跡という検証側の状態保持が新たに必要になり、Envoyの`jwt_authn`フィルタ（ステートレス）では完結しないため、これは本ADRのスコープ外の、規模の大きい別課題として引き続きbacklog.mdで管理する。

## Decision

**fraud-mcp-server（egress）↔ account-service（ingress）の1ホップのみに、SPIFFE/SPIREが発行するX.509-SVIDによるmTLS＋ALPNネゴシエーションのHTTP/2を導入する。** 既にOAuth Token Exchange（パターン①）で実機検証済みの同じホップに絞ることで、[ADR 0002](0002-token-exchange-in-envoy-sidecar.md)・[ADR 0010](0010-egress-listener-granularity.md)と同じ「1ホップ先行検証してから横展開する」方針を踏襲する。

これは別途検討していた「envoy間だけh2c化する」という案を包含する。TLSを追加する以上、素のh2c（平文HTTP/2）を別立てするより、TLS+ALPNでのh2ネゴシエーションの方が標準的かつ設定もシンプルなため、統合した。

### スコープ境界

**対象**：SPIRE server/agentのデプロイ、account-service・fraud-mcp-server双方のEnvoyサイドカーへのSPIFFE ID割り当て、このホップのmTLS＋ALPN h2化、検証、本ADR。

**対象外（backlog.md参照）**：`ext-authz-service`のKeycloak向け接続（Envoyサイドカーを持たないため平文のまま）、RFC 8705（上記の通り構造的に不成立）、他ホップへの横展開、`spiffe-csi`ドライバ・`spire-controller-manager`（新規可動部を増やさないため見送り）、account-service/fraud-mcp-serverの**ワークロードPod自体**への`hostPID`/`hostNetwork`付与（属性解決が実機で失敗した場合のみ再検討）。

### 設計判断

- **信頼ドメイン**：`gekko.internal`（k8s namespace `gekko`とは意図的に別の文字列にし、両概念を混同しない）
- **新しい`spire` namespace**：`gekko`とは分離し、TokenReview作成・pods/exec等のID基盤特有のRBAC面をアプリ層から切り離す
- **SPIRE server**：StatefulSet（1レプリカ）+ PVC（sqlite3データストア）、自己署名ルートCA（`UpstreamAuthority`未設定＝SPIRE組み込みデフォルト）、`k8s_psat`ノードアテスタ、`Notifier "k8sbundle"`で信頼バンドルを`spire-bundle` ConfigMapへ配布
- **SPIRE agent**：DaemonSet、`k8s_psat`（agent側）＋`WorkloadAttestor "k8s"`（`skip_kubelet_verification = true`。k3dのkubelet証明書はk3s内蔵CAの自己署名で、agentの既定の信頼ストアに含まれないため）。`hostPID: true`＋`hostNetwork: true`は本リポジトリで初めて使う特権設定で、PID/cgroup経由のワークロード相関づけに必要な、意図的な例外として明記する
- **Workload API ソケット配信**：`hostPath`（`/run/spire/sockets`）をagentとワークロードPod（Envoyコンテナのみ）双方でマウントする、SPIRE公式チュートリアルが示す非CSI・非Istio環境での標準パターン
- **registration entry**：account-service・fraud-mcp-server双方とも**Envoyコンテナのみ**をselectorで指定する（`k8s:container-name:envoy`）。アプリコンテナは秘密鍵に一切触れない、既存の合言葉ヘッダーと同じ「アプリはEnvoyが検証済みのものだけを信頼する」設計思想を踏襲
- **Envoy側のSDS検証**：`combined_validation_context`（SDSで動的に信頼バンドルを取得でき、SPIREのCAローテーションに追従する）を、Envoy組み込みの`envoy.tls.cert_validator.spiffe`より優先した。後者の信頼バンドルは静的`DataSource`でSDS供給できず、今回のスコープ（SDS配線のみ）とは合わない。`validation_context_sds_secret_config.name`はSPIRE Agent SDSが認識する固定のマジック名`"ROOTCA"`でなければならない（信頼ドメイン名等の任意文字列を渡すと「そのSPIFFE IDへのSVIDリクエスト」と誤解釈され拒否される。実機検証で判明）
- **ALPN "h2"だけでは不十分**：ALPNはハンドシェイク時のネゴシエーションにのみ影響し、クラスタが実際に話すコーデックには影響しない。`account_service_upstream`クラスタには別途`typed_extension_protocol_options`で`explicit_http_config.http2_protocol_options`を明示する
- **SDS利用にはbootstrap設定へ`node.id`/`node.cluster`の追加が必須**：SDSはxDSプロトコルの一種でDiscoveryRequestにNode識別子が要るため（実機検証で判明）
- **account-serviceのingressリスナーはTLS/plaintextの2つのfilter_chainに分岐する**：単一の共有リスナーにmTLS必須のtransport_socketを1つだけ設定すると、SPIRE化していないfraud-detection-engine（パターン②）からの接続まで拒否してしまうことが実機検証で判明した。`envoy.filters.listener.tls_inspector`リスナーフィルタ＋`filter_chain_match.transport_protocol`（`tls`/`raw_buffer`）で振り分け、同じHTTPフィルタチェーン（jwt_authn/rbac/lua/router）を両方に適用する。詳細・既知の限界はConsequences参照

## Consequences

- fraud-mcp-server→account-serviceのホップは、OAuth Token Exchangeによる業務認可（誰が何をしてよいか）と、SPIRE発行のmTLSによる通信路の身元検証・暗号化（誰と話しているか）という、独立した2つの層で守られるようになる
- **既知の限界：account-serviceへのplaintextでの到達自体は引き続き可能**。account-serviceのingressリスナーは全呼び出し元が共有する単一のリスナーであり、fraud-detection-engine（パターン②、SPIRE化はスコープ外）を壊さないために、TLS/plaintextの両方を受け付けるfilter_chain構成にした（Design Decisions参照）。account-serviceはfilter_chain選択の時点（L4）ではHTTPパスを見られないため、「読み取り・提案系のパスだけmTLS必須にし、freezeパスだけplaintextを許可する」といったパス単位の強制はできない。結果として、R2（相互認証）が額面通り機能するのは「TLSで接続してきた場合」に限られ、mTLSは呼び出し元が選択する任意の追加防御層にとどまる（有効なOAuthトークンさえあれば、plaintextでの到達自体は今回の変更前と変わらず可能）。この限界を解消するには、fraud-detection-engine（および将来の他の呼び出し元）もSPIRE化してplaintextの受け口自体を廃止するか、NetworkPolicy等の別レイヤーで呼び出し元を制限する必要があり、いずれも本ADRのスコープ外としてbacklog.mdに追加する
- `hostPID`・`hostNetwork`・DaemonSet・`pods/exec`・StatefulSet+PVC（postgres以外）・新しい`spire` namespace・`bitnami/kubectl`イメージは、いずれも本リポジトリで初めて使う要素。実機検証で想定通り動くかは別途insights.mdに記録する
- 他ホップ（frontend→account-service等）へのmTLS横展開、`ext-authz-service`自体のSPIFFE化、DPoPの検証・実装方式、RFC 8705を実現するためのADR 0002見直し（WASMフィルタ化）は、いずれも本ADRのスコープ外としてbacklog.mdへ追加する
