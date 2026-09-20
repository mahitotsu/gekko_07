# ADR 0017: edge-proxyを導入し、Keycloakを完全mTLS化する

- **Status**: Partially superseded by [0022](0022-keycloak-mgmt-probe-exec.md)（`KC_HTTP_MANAGEMENT_HOST=0.0.0.0`のまま残すという決定は0022で`127.0.0.1`+execプローブに変更された。edge-proxy導入・8080撤廃の決定自体は有効なまま）
- **Date**: 2026-09-16

## Context

[ADR 0016](0016-ext-authz-and-keycloak-mtls.md)でext-authz-service(-cc)↔Keycloakの1ホップをmTLS化したが、Keycloakにはブラウザ経由のログイン・`kcadm.sh`による管理操作・`scripts/verify-hop.sh`のROPCシミュレーションなど、SPIFFE身元を持ちえない呼び出し元が既に存在するため、Keycloakの8080を「恒久的な非対称性」として意図的に平文のまま残していた。

この非対称性そのものを解消する提案があった: Keycloak(将来的にはfrontendも)の前段に、非mTLS外部接続を一元的に引き受けるリバースプロキシを置き、Keycloak/frontend自体は常にmTLSのみで通信させる。実は[ADR 0004](0004-external-access-via-port-forward.md)は最初から「edge-proxy相当のService(nginx等、パスベースで内部の各サービスに振り分ける)」を想定しており、本ADRはこれをEnvoyベースで先行実装するものである。frontendは未実装のため、当面はKeycloak1系統へのパススルーのみとする。

## Decision

**業務ロジックを持たないEnvoy単体のPod「edge-proxy」(`k8s/edge-proxy/`)を追加し、Keycloakへの唯一の平文入口とする。** Keycloakコンテナ自体は`KC_HTTP_HOST=127.0.0.1`でPod外から直接到達不能にし、Keycloakの8080はService自体から削除する。Keycloakのingress Envoyは、account-service(ADR 0015)と同じ「単一filter_chainで完全にmTLS必須」の構成に統合できるようになった。

### edge-proxyの構成

- Envoyコンテナのみ(account-service/ext-authz-serviceのEnvoyコンテナと同じ雛形)。SPIRE registration entry(`k8s:pod-label:app:edge-proxy`、`k8s:container-name:envoy`)を持ち、自分のSPIFFE SVIDでKeycloakのmTLSポート(8443)へ接続する
- 外部向け(`0.0.0.0:80`)は平文のまま(ADR 0004により外部公開はport-forward前提のため、ここに新たにサーバー証明書発行の仕組みを持ち込む理由は無い)
- 現状は`domains: ["*"]`の1ルートでKeycloakへ丸ごとパススルー。frontend実装時にroute_configへvirtual_host/routeを追加してパスベースで振り分ける想定

### Keycloakの8080に依存していた呼び出し元の付け替え

実装前に、Service経由でKeycloak:8080へ到達していた全経路を洗い出した(`kubectl exec`でPod内loopbackに閉じる`keycloak-reimport-realm`は対象外)。

| 呼び出し元 | 変更 |
|---|---|
| `scripts/verify-hop.sh`(ROPCログインシミュレーション) | port-forward先を`svc/keycloak`から`svc/edge-proxy`へ |
| `k8s/keycloak/test-fixtures-job.yaml`(kcadm.shによるクライアントシークレット/テストユーザー投入) | `test-fixtures-configmap.yaml`の`SERVER`を`http://edge-proxy.gekko.svc.cluster.local:80`へ |
| `Makefile`の`keycloak-forward` | `svc/edge-proxy 3000:80`へ |
| account-serviceのjwt_authn(`keycloak_jwks`クラスタ、JWKS取得) | edge-proxyを経由せず、account-service自身が既に持つSPIRE身元でKeycloakの8443へ直接mTLS接続するよう変更(ADR 0016 Consequencesが残していた既知の未対応項目を解消) |

### KC_HTTP_MANAGEMENT_HOSTの実機知見

`kc.sh start --help`で確認した通り、`--http-management-host`は明示しない限り`--http-host`の値を継承する。そのため`KC_HTTP_HOST=127.0.0.1`だけを設定すると、health/mgmt(9000、kubeletのreadiness/liveness/startupProbeが直接参照)まで道連れでloopback化され、Podが起動直後にProbe失敗で再起動ループする。`KC_HTTP_MANAGEMENT_HOST=0.0.0.0`を明示的に設定してこれを打ち消す必要がある。

## Consequences

- Keycloakへのplaintextでの到達経路(8080)が完全に無くなった。到達可能なのは`https-mtls:8443`(許可されたSPIFFE ID: `ext-authz-service`・`ext-authz-service-cc`・`account-service`・`edge-proxy`のみ)と、kubelet専用の`http-mgmt:9000`のみ
- Keycloakの実質的な「非mTLS呼び出し元向けの受け口」はedge-proxyへ移動した。edge-proxy自体はDBアクセスも業務ロジックも持たない薄いEnvoyのみのPodであり、Keycloak本体(トークン発行・DB資格情報を持つJVMプロセス)より侵害時の実害が小さいコンポーネントに攻撃面を寄せられた
- frontend実装時は、frontendもedge-proxy経由にする(同じPodを使い回し、route_configにvirtual_host/routeを追加するだけで済む)想定 → [ADR 0024](0024-frontend-edge-proxy-and-simplified-login.md)で実施済み(想定通り、Podは変更せずroute_config分割のみで対応できた)
- NetworkPolicyによるL3/4の多層防御は本ADRのスコープ外。kube-router netpolがこのクラスタで実際に有効なことは実機確認済みだが、[ADR 0012](0012-spiffe-spire-mtls-single-hop.md) R7が最初から「mTLS/業務認可とは独立な別トラック」と位置づけている通り関心事が異なり、kubeletプローブとの相性検証という別の実機検証項目を抱えるため、architecture.mdに記録するに留める
