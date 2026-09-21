# ADR 0035: Keycloakを事前ビルド済みイメージ(`kc.sh build`)で`start --optimized`起動する

- **Status**: Accepted
- **Date**: 2026-09-21

## Context

Keycloakは初期構成以来`start-dev`で起動しており、[ADR 0008](0008-per-service-datastore-strategy.md)で埋め込みH2からPostgres接続に変更した際も`start-dev`自体は維持されたままだった。以降[ADR 0016](0016-ext-authz-and-keycloak-mtls.md)/[0017](0017-edge-proxy-full-keycloak-mtls.md)/[0019](0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)/[0022](0022-keycloak-mgmt-probe-exec.md)/[0028](0028-postgres-mtls-tcp-proxy.md)がKeycloak周辺の構成に手を入れたが、いずれも起動コマンド自体は見直していなかった。`start-dev`は起動のたびにQuarkusのaugmentation（設定を反映した最適化ビルド）をやり直すため、realm設定の反復修正やPod再作成を伴う開発サイクルで起動時間がボトルネックになっていた。

`KC_HOSTNAME`・`KC_HTTP_ENABLED`・`KC_HEALTH_ENABLED`等、本番モード(`start`)が通常要求する設定は[ADR 0004](0004-external-access-via-port-forward.md)（`KC_HOSTNAME`をport-forward先のURLへ固定）・[ADR 0022](0022-keycloak-mgmt-probe-exec.md)の流れで既に実行時設定として入っていたため、`start-dev`→`start --optimized`への切り替え自体は追加の前提整備なしに検討できた。

## Decision

### 事前ビルド済みイメージの導入

[services/keycloak/Dockerfile](../../services/keycloak/Dockerfile)を新設し、`quay.io/keycloak/keycloak:26.7.0`をベースに`KC_DB=postgres`・`KC_FEATURES=spiffe,client-auth-federated`・`KC_HEALTH_ENABLED=true`を指定した`kc.sh build`をイメージビルド時に実行する（account-service等、他サービスのDockerfileと同じマルチステージ構成）。これらはaugmentation時に固定されるbuild-timeオプションであり、値を変える場合はイメージの再ビルドが必要になる（[k8s/keycloak/deployment.yaml](../../k8s/keycloak/deployment.yaml)の同名環境変数と値を一致させること）。

Makefileには他のコンパイルを要するサービス（account-service等）と同じパターンで`build-keycloak`ターゲットを追加し、`deploy`から呼び出す（[Makefile](../../Makefile)）。

### 起動コマンドの変更

[k8s/keycloak/deployment.yaml](../../k8s/keycloak/deployment.yaml)のargsを`["start-dev", "--import-realm", "--features=..."]`から`["start", "--optimized", "--import-realm"]`へ変更する。`--features`はビルド時に`KC_FEATURES`として焼き込み済みのため実行時引数からは外す。

## Consequences

- 起動時間を実機で比較した（k3dクラスタでPod再作成→Ready、`kubectl get pod`のタイムスタンプで計測）：`start-dev`は111秒（うちaugmentation単体で63.3秒）、`start --optimized`は54秒（augmentationなし）。約2倍高速化した
- [scripts/verify-hop.sh](../../scripts/verify-hop.sh)の全18ステップ（実ブラウザ相当のOIDCログイン、frontend→fraud-agent→fraud-mcp-server→account-serviceのToken Exchangeチェーン、表5のABAC判定、mTLS/NetworkPolicyの異常系）を最適化ビルドに対して実行し、exit code 0で全て成功。回帰なし
- build-timeオプション（db/features/health-enabled）がイメージに焼き込まれるため、これらを変更する運用は「deployment.yamlの環境変数を書き換えて再適用」だけでは完結しなくなり、`make build-keycloak`によるイメージ再ビルドが新たに必要になる
- 複数レプリカ化した場合のInfinispanローカルキャッシュの制約（未文書化、architecture.md§11には未記載）は本ADRの対象外で、未解消のまま残る
- [k8s/keycloak/deployment.yaml](../../k8s/keycloak/deployment.yaml)冒頭コメントを本変更に合わせて更新済み
