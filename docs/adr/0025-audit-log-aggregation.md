# ADR 0025: 監査ログ集約基盤（Alloy + otel-lgtm）を導入し、監査（BR8）の実現方式を再設計する

- **Status**: Accepted
- **Date**: 2026-09-17

## Context

`docs/architecture.md` §8（監査）は、口座凍結解除の事後追跡可能性（[access-control-requirements.md](../access-control-requirements.md) BR8）を満たす手段として「`proposal_id` + OpenTelemetryトレース + Keycloakイベントログの統合」を構想していたが、OpenTelemetry関連は`k8s/`配下に一度も実装されておらず（構想止まり）、`proposal_id`自体もaccount-serviceが依然「1ホップ先行検証用の最小スタブ」（業務ロジック・永続化なし）のため未実装のままだった。

一方でADR 0019〜0024を経て、以下が今のアーキテクチャの実態として確立している。

- 全ホップのingressで`jwt_authn`の`claim_to_headers`が`x-auth-sub`/`x-auth-scope`/`x-auth-jti`を実リクエストヘッダーとして注入する
- `sub`は委任チェーン全体で元のアナリストのまま維持される設計（architecture.md 110行目。Impersonation方式）
- 全Token ExchangeはKeycloak単一インスタンスを経由する
- Envoyは全6ホップのingress/egressに常駐しているが、`access_log`もKeycloakの`eventsEnabled`も未設定で、どちらのログも各Podの標準出力に流れた後は消えている（k3dのPodは再起動で消える）

これらを踏まえ、OTel分散トレーシング（トレースコンテキストの伝播が全ホップのEnvoy設定変更を要する、侵襲性の高い変更）を撤退し、既存のEnvoy/Keycloakが持つログ出力を集約・永続クエリ可能にする方針へ転換した。集約先はユーザー提案の**Grafana Alloy（収集・転送）+ `grafana/otel-lgtm`（Loki+Grafana+OTel Collector等の一体型イメージ）**を採用した。`proposal_id`自体のaccount-service側実装（DB永続化）はADR 0007の本実装まで持ち越し、本ADRは監査ログの集約基盤のみをスコープとする。

## Decision

### `k8s/observability/`を新設する（`spire`と同じ「独立インフラnamespace」パターン）

`observability` namespaceに、Alloy（DaemonSet、`grafana/alloy:v1.19.2`）と`otel-lgtm`（Deployment、`grafana/otel-lgtm:0.33.0`）を配置した。

- Alloyは`discovery.kubernetes`でPodメタデータを取得し、`gekko` namespaceの`envoy`/`keycloak`コンテナのみに絞り込んだうえで、hostPath（`/var/log/pods`、読み取り専用）経由でログファイルをtailし、CRIエンベロープ（`stage.cri`）を剥がしてotel-lgtmのLoki push API（`http://otel-lgtm.observability.svc.cluster.local:3100/loki/api/v1/push`）へ直接送る。OTel Collector（otel-lgtm同梱）は経由しない
- `sub`/`jti`等の値はLokiのストリームラベルにはしない（値ごとに別ストリームになりカーディナリティが際限なく増えるアンチパターンになるため）。`namespace`/`pod`/`container`のみラベルにし、`sub`/`jti`/`scope`での絞り込みはクエリ時のLogQLライン文字列フィルタで行う
- Alloyはログの中身自体はhostpathでファイルを読むだけで、`gekko`/`spire` namespaceへの越境ネットワーク通信は発生しない。ただし`discovery.kubernetes`（Podメタデータ取得）はKubernetes APIサーバーへのegressを必要とする。`kubernetes` ServiceはClusterIP（`10.43.0.1:443`）を持つが、k3dの既定CNI（kube-router）はNetworkPolicyをDNAT後の宛先（k3dノードの実IP:6443）で評価するため、ClusterIP宛てのipBlockルールでは一致しない（実機で発覚。insights.md参照）。AlloyのNetworkPolicy egressは、otel-lgtmへのLoki push(3100)に加え、k3dノードCIDR（`172.19.0.0/16`、edge-proxyのADR 0004例外と同じCIDR）宛てポート6443を許可している
- `observability` namespaceにも`gekko`と同じdefault-deny＋allow-dns（ADR 0018）を適用した（`spire`のような特権要件が無いため、例外扱いにしない）
- otel-lgtmは`grafana/otel-lgtm`が公式に「デモ/開発用の一体型イメージ、本番非推奨」としているものをそのまま採用した。Grafana・Loki・Prometheus・Tempo・Pyroscope・OTel Collectorの6プロセスが同居するが、今回使うのはGrafana+Lokiのみで残りは起動するが未使用（実機調査の詳細はinsights.md）。PVCは持たせておらず、Pod再起動でログは失われる（Consequences参照）
- 人手でのGrafana UI参照用に、ADR 0004のport-forward方針を踏襲した`make grafana-forward`を追加した

### 全ホップのEnvoy ingress/egressに`access_log`を追加する

`http_connection_manager`の`typed_config`に、`envoy.extensions.access_loggers.stream.v3.StdoutAccessLog`（`json_format`、`%REQ(x-auth-sub)%`/`%REQ(x-auth-scope)%`/`%REQ(x-auth-jti)%`等）を追加した。全8サービス・12箇所（account-service/analyst-attribute-service/fraud-mcp-server/fraud-agent/frontendのingress+egress、fraud-detection-engineのegressのみ、edge-proxy、Keycloak自身のEnvoy）に横展開した。

- `jwt_authn`を持つingress（account-service/analyst-attribute-service/fraud-mcp-server/fraud-agent/frontend）では`x-auth-*`が実リクエストヘッダーとして存在するため、そのままログに載る
- egress側（`jwt_authn`を持たない）やedge-proxy・Keycloakの純mTLS中継Envoyでは`x-auth-*`は空文字列になる（相関キーとしては使えないが、疎通のHTTPレベル記録として残す）
- fraud-detection-engineはingressリスナー自体を持たない（内部トリガーで動作するため）ため、egressのみが監査対象になる

### Keycloakのイベントログを有効化する

`k8s/keycloak/realm-configmap.yaml`に`"eventsEnabled": true`・`"eventsListeners": ["jboss-logging"]`を追加した（`adminEventsEnabled`はBR8のスコープ外＝トークン発行の追跡が目的であり管理操作の追跡ではないため見送った）。`k8s/keycloak/deployment.yaml`には`KC_LOG_CONSOLE_OUTPUT: json`（標準出力のJSON化）と`KC_LOG_LEVEL: "INFO,org.keycloak.events:DEBUG"`（`jboss-logging`は成功イベントをDEBUGレベルで出すため、既定のINFOのままだと握りつぶされる。insights.md参照）を追加した。

Keycloakは全Token Exchangeの唯一の発行元であり、そのイベントログ（`TOKEN_EXCHANGE`/`LOGIN`等）には`userId`/`username`/`sessionId`/`token_id`/`scope`/`audience`/`subject_token_client_id`が記録される。監査の主軸はこちらに置く：`sessionId`（Keycloakのログインセッションid）が委任チェーン1インスタンスの相関キーとして機能することを実機で確認した（1回のfrontend操作に由来する全ホップのイベントが同一`sessionId`を持つ。insights.md参照）。Envoyのアクセスログ（`sub`/`jti`）は補助的な位置づけとし、`sub`単体では同一アナリストの複数の並行操作を区別できないという設計上の限界を、`sessionId`で補う。

### frontendのログイントークンに`sub`クレームが欠落していた問題を修正する

本ADRの作業中に、frontendの`/login`（ROPC）が発行するアクセストークンに`sub`クレームが存在しないことが判明した（architecture.md 110行目の「`sub`は元のanalystのまま維持される」という前提と矛盾する。原因はKeycloak 26.7.0自体の挙動と見られ、realm importの構成とは無関係——master realmの組み込みクライアントでも同様に欠落することを確認済み。詳細はinsights.md）。frontendクライアントの`protocolMappers`に、`aud`クレーム欠落時（既存の`audience-self`マッパー）と同じ手法で、`subject-claim`という明示的なdedicated mapper（`oidc-usermodel-property-mapper`、`user.attribute: id`→`claim.name: sub`）を追加した。Token Exchange（委任チェーンの②③④ホップ）はこの問題の影響を受けておらず（元々`sub`を正しく引き継いでいた）、frontend以外のクライアントには追加していない。

### edge-proxyの`/admin/`ルーティング漏れを修正する（ADR 0024の実装漏れ、本ADRの実機検証で発覚）

realm再importを伴う実機検証の過程で、`k8s/keycloak/test-fixtures-job.yaml`のkcadm.shがedge-proxy経由で`/admin/realms/gekko/users`等を呼ぶと401になることが判明した。原因はADR 0024のedge-proxy route_config分割（`/realms/`→Keycloak、`/`→frontend）が`/admin/`を考慮しておらず、catch-allの`/`にマッチしてfrontendへ誤配送されていたため（ADR 0024のコメントは「kcadm.sh等はkubectl exec経由が前提」としていたが、実際にはtest-fixtures-job.yamlがedge-proxy経由で呼んでいた）。`{match: {prefix: "/admin/"}, route: {cluster: keycloak_upstream}}`を`/realms/`ルートの次に追加した。ADR 0024自体のバグであり新規ADRは起こさず、本ADRのコミットで一緒に是正した。

### 検証スクリプト

`scripts/verify-observability.sh`を新設した。既存の`scripts/verify-hop.sh`と同じ実機検証の要領で、(1) frontendへログインして`sub`を取得、(2) 実際の委任チェーンを1本流し、(3) Loki HTTP API（Grafana UIは介さず直接curl、scriptableさを優先）へLogQLクエリを投げ、Envoyアクセスログ・Keycloakイベントログの両方に同一`sub`が記録されていることを確認する。

## Consequences

- 監査ログ集約基盤（Alloy+otel-lgtm）と、全8サービスのEnvoyアクセスログ・Keycloakイベントログの集約が実機で検証された。`docs/backlog.md`の該当項目を解消した
- 監査の相関キー設計を`sub`単体から`sessionId`（チェーン単位）+`sub`/`userId`/`username`（誰が）+`token_id`/`scope`/`audience`（各ホップで何をしたか）の組み合わせへ更新した。architecture.md §8を更新した
- `proposal_id`のaccount-service側実装（DB永続化）は引き続き未着手（ADR 0007の本実装待ち）。今回集約したログは`sub`/`sessionId`による相関のみで、業務レベルの「どの提案に基づく実行か」の紐付けは今後の課題として残る
- otel-lgtmは本番非推奨のデモ/開発用イメージで、PVCを持たせていないためPod再起動でログが失われる。Grafana/Loki以外の同梱コンポーネント（Prometheus/Tempo/Pyroscope/OTel Collector）は起動するが未使用のまま（無効化方法は未調査）
- 副産物として2つの既存バグを発見・是正した：edge-proxyの`/admin/`ルーティング漏れ（ADR 0024）、frontendログイントークンの`sub`クレーム欠落
- `k8s/keycloak/test-fixtures-job.yaml`のパスワード設定に再現性のある問題（realm再import後、作成直後のユーザーでログインに失敗することがある）を発見したが、原因未特定のまま今回は対応を見送った（insights.md・backlog.md参照）
