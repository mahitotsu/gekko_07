# ADR 0016: SPIRE mTLSをext-authz-service(-cc)・Keycloakへ拡張する

- **Status**: Accepted
- **Date**: 2026-09-16

## Context

[ADR 0012](0012-spiffe-spire-mtls-single-hop.md)・[ADR 0015](0015-dpop-removal-and-fraud-detection-engine-mtls.md)で`fraud-mcp-server`・`fraud-detection-engine` → `account-service`の1ホップはSPIRE mTLS化し、account-serviceへのplaintext到達経路は完全に撤廃した。しかしADR 0012のスコープ境界(§スコープ境界)・[backlog.md](../backlog.md)が明示していた通り、Token Exchange/client_credentialsの実装本体である`ext-authz-service`(および`ext-authz-service-cc`)はEnvoyサイドカーを持たず、以下2ホップが平文のまま残っていた。

1. 各サービスのEnvoy(egress) → `ext-authz-service`/`ext-authz-service-cc`
2. `ext-authz-service`(-cc) → Keycloak

OAuthのトークン交換・検証はEnvoy(またはEnvoyから呼ばれるext-authz-service)が一手に担い、アプリ本体は一切関与しない([ADR 0002](0002-token-exchange-in-envoy-sidecar.md)・[ADR 0009](0009-envoy-ingress-responsibility-and-bypass-prevention.md))という設計を踏まえると、この2ホップだけが「Envoyを経由しない生のHTTP通信」として取り残されているのは、既に構築したmTLS境界の一貫性を損なう。本ADRでこのギャップを閉じる。

## Decision

**`ext-authz-service`・`ext-authz-service-cc`・Keycloakそれぞれに新規Envoyサイドカーを追加し、上記2ホップをSPIRE mTLS化する。** メカニズムはADR 0012/0015で確立した「TLS終端は常にEnvoyサイドカーが担い、アプリ本体は生の証明書に一切触れない」パターンをそのまま再利用する。新しいメカニズムを持ち込まない。

### `ext-authz-service`(-cc)

- Envoyサイドカーを追加し、ingress(fraud-mcp-server/fraud-detection-engineのEnvoyからの着信)・egress(Keycloakへの発信)の両方をこのEnvoyが担う
- ingressは呼び出し元が常にSPIRE化済みのEnvoy1つに限定されるため、account-serviceが経由した「TLS/plaintext 2 filter_chain」の中間段階(ADR 0012)を踏まず、最初から単一のmTLS必須filter_chainにした(ADR 0015と同じ最終形をいきなり採用)
- egressはhostAliasesで`keycloak`を127.0.0.1へ静的マッピングし、appが実ホスト名でリクエストを組み立てるだけで同一Pod内のEnvoyが横取りする、fraud-mcp-server/fraud-detection-engineの既存egressパターン([ADR 0010](0010-egress-listener-granularity.md))をそのまま踏襲した
- appコンテナのバインドホストを`0.0.0.0`から`127.0.0.1`に変更し(`LISTEN_HOST`環境変数化)、Pod外からの直接到達を防いだ(ADR 0009 主対策①と同じ考え方)

### Keycloak — 呼び出し元の非対称性とポート分離

Keycloakには、SPIFFE身元を持ちえない呼び出し元(ブラウザ経由のログイン、`kcadm.sh`による管理操作、`scripts/verify-hop.sh`のROPCシミュレーション)が既に存在する。これらはaccount-serviceの呼び出し元(全てEnvoyサイドカー経由でSPIRE化されたワークロード)とは性質が異なり、account-service/ADR 0015のような「単一filter_chainへの統合・plaintext受け口の完全撤廃」はそのまま適用できない。

そのため、**Keycloakはポートを分離する**方針を採った。

- 既存の`http:8080`/`http-mgmt:9000`は無変更のまま残す。keycloakコンテナ自身が直接受け、ブラウザ・`kcadm.sh`・`verify-hop.sh`向けの経路として引き続き平文のまま機能する
- 新設の`https-mtls:8443`はEnvoyサイドカーが受け、`require_client_certificate: true`＋`match_typed_subject_alt_names`で`ext-authz-service`・`ext-authz-service-cc`の2つのSPIFFE IDのみに限定する。同一Pod内のkeycloakコンテナ(127.0.0.1:8080)へ平文で転送する(TLS終端はEnvoyで完結しており、Pod内loopback越えまで暗号化する必要はない)

この非対称性は将来「まだ塞ぎ忘れている」と誤解されないよう、意図的な恒久設計としてbacklog.mdに明記する。

### SPIREのbase trackへの格上げ

KeycloakはPostgresと並ぶ基盤コンポーネントであり、スタブ実装である他サービスとは異なり`make deploy`(base track)で単独デプロイされる。KeycloakがEnvoyサイドカーを持つ以上、SPIRE(spire-agentのWorkload APIソケット)が事前に存在しないとKeycloak Podが起動できなくなるため、**SPIREのデプロイを「1ホップ検証スタブ専用」(`make deploy-verify-hop`)から「base trackの前提コンポーネント」(`make deploy`)へ格上げした**。`make deploy`は`k8s/keycloak/deployment.yaml`を適用する直前に`deploy-spire`を呼ぶ。

## Consequences

- `ext-authz-service`(-cc)↔呼び出し元Envoy、`ext-authz-service`(-cc)↔Keycloakの両ホップがmTLS化され、[ADR 0002](0002-token-exchange-in-envoy-sidecar.md)・[ADR 0009](0009-envoy-ingress-responsibility-and-bypass-prevention.md)が掲げる「TLS終端は常にEnvoy」という設計の一貫性が回復した。backlog.mdの「ext-authz-service自体のSPIFFE化」項目は解消済みとして削除する
- **Keycloakの8080/9000は今後も恒久的に平文のまま残る**。これはADR 0012/0015が「解消すべき既知の限界」として扱っていたのとは異なり、ブラウザ・管理操作というSPIFFE身元を持ちえない呼び出し元が存在する限り解消できない、構造的な設計上の境界である。将来browserベースの認証にmTLSを課す手段(WebAuthn的な端末証明など)が採用されない限り、この非対称性は残り続ける
- SPIREが`make deploy`単独の実行でも起動するようになり、Keycloak+Postgresだけを触りたい場合でも`k8s/spire/`一式(StatefulSet+PVC、DaemonSet、`hostPID`/`hostNetwork`)が常時稼働するようになった。ローカル環境のリソース消費は増えるが、新しいメカニズムを追加しない(既存のSPIRE基盤を再利用する)ことを優先した
- account-serviceのjwt_authnが参照するKeycloakのJWKSエンドポイント(`http://keycloak.gekko.svc.cluster.local:8080/realms/gekko/protocol/openid-connect/certs`)は本ADRの対象外。引き続き平文の8080を使う(account-service自身はEnvoyのSDS経由でmTLSを検証しているが、jwt_authnのJWKS取得はEnvoy内部のHTTPクラスタ呼び出しであり、この経路のmTLS化は将来の課題としてbacklog.mdに残す)
