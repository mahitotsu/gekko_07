# ADR 0018: gekko namespaceにNetworkPolicyでL3/4のdefault-denyを導入する

- **Status**: Partially superseded by [0022](0022-keycloak-mgmt-probe-exec.md)（Keycloakのhttp-mgmt:9000に対する`ipBlock`ベースのingress許可ルールは0022で撤廃された）・[0028](0028-postgres-mtls-tcp-proxy.md)（「共有PostgresインスタンスはmTLS適用対象外」という前提を0028が覆し、常駐4サービスの接続はEnvoyのmTLS配下に移した。db-init/seed JobはNetworkPolicyのみで保護する現状維持）・[0030](0030-fraud-agent-implementation.md)（「全ての許可ルールはpodSelectorで宛先を特定できる」という前提を0030が初めて崩し、fraud-agent→Anthropic API向けに`ipBlock 0.0.0.0/0`ベースの公開インターネットegressを追加した）。その他の許可ルールの決定は有効なまま
- **Date**: 2026-09-16

## Context

これまでの実装（OAuth Token Exchange、[ADR 0012](0012-spiffe-spire-mtls-single-hop.md)・[ADR 0015](0015-dpop-removal-and-fraud-detection-engine-mtls.md)・[ADR 0016](0016-ext-authz-and-keycloak-mtls.md)・[ADR 0017](0017-edge-proxy-full-keycloak-mtls.md)のSPIRE mTLS）は「誰が何をしてよいか」という業務認可層と、「誰と話しているか」という通信路の身元検証・暗号化の2層に集中しており、L3/4（IPアドレス・ポート単位の到達可否）は素通しのままだった。[ADR 0012](0012-spiffe-spire-mtls-single-hop.md) R7・[ADR 0017](0017-edge-proxy-full-keycloak-mtls.md)は、NetworkPolicyによるL3/4のdefault-denyを「mTLS・業務認可とは独立な別トラック」として繰り返し先送りしてきた。

技術的な導入障壁は実機確認済みである（このクラスタでkube-router netpolが実際に有効なことを`iptables-save`で`KUBE-ROUTER-INPUT/FORWARD/OUTPUT`・Pod単位の`KUBE-POD-FW-*`チェーンとして確認済み）。増分価値が大きい対象として、mTLSの適用対象外である共有Postgresインスタンス（[ADR 0008](0008-per-service-datastore-strategy.md)）と、Keycloakのkubelet向けhttp-mgmt:9000が[docs/backlog.md](../backlog.md)で名指しされていた。直近でaccount-serviceのplaintext受け口を撤廃したばかりであり、「1ホップずつ実機検証してから横展開する」という一貫した方針の次の段として、本ADRでこのL3/4防御を導入する。

## Decision

**`gekko` namespace全体に、ingress/egress双方向のdefault-denyを適用し、実装済みの全接続パスを明示的な許可ルールとして積み上げる。** `spire` namespaceは本ADRの対象外とする（後述）。

### 接続グラフ

`k8s/*/envoy-configmap*.yaml`とService定義から、実装済みの接続経路を以下の通り確定した。

| 送信元 (label `app=`) | 宛先 | ポート | 備考 |
|---|---|---|---|
| fraud-mcp-server | account-service | 8080 | mTLS(SPIRE)、パターン① |
| fraud-mcp-server | ext-authz-service | 8080 | Token Exchange |
| fraud-detection-engine | account-service | 8080 | mTLS(SPIRE)、パターン② |
| fraud-detection-engine | ext-authz-service-cc | 8080 | client_credentials |
| ext-authz-service | keycloak | 8443 (https-mtls) | mTLS |
| ext-authz-service-cc | keycloak | 8443 (https-mtls) | mTLS |
| account-service | keycloak | 8443 (https-mtls) | JWKS取得、mTLS |
| edge-proxy | keycloak | 8443 (https-mtls) | mTLS |
| keycloak | postgres | 5432 | |
| keycloak-db-init(Job) | postgres | 5432 | 初回DBセットアップ |
| keycloak-test-fixtures(Job) | edge-proxy | 80 | kcadm.sh |
| kubelet(ノードIP) | keycloak | 9000 (http-mgmt) | readiness/liveness/startupProbe |
| kubectl port-forward(ノードIP経由) | edge-proxy | 80 | 外部公開経路([ADR 0004](0004-external-access-via-port-forward.md)) |

fraud-mcp-server・fraud-detection-engineにはKubernetes Service自体が存在しない（他から呼ばれる経路が無い）ため、ingressは一切許可せずdefault-denyのままにする（frontend/fraud-agent実装時に追加）。

全Podが共通してサービス名解決に`kube-system`の`kube-dns`（`k8s-app=kube-dns`、53/UDP・TCP）へのegressを要するため、namespace横断で1本の共通ポリシーとして許可する。

### 実装構成

- 共通ポリシー（新設`k8s/network-policy/`）：`default-deny.yaml`（`podSelector: {}`、`policyTypes: [Ingress, Egress]`、ルールなし）と`allow-dns.yaml`（`podSelector: {}`、`policyTypes: [Egress]`、kube-dnsへの53番を許可）
- サービスごとの許可ポリシー：既存の各`k8s/<service>/`ディレクトリに`networkpolicy.yaml`を追加し、上記接続グラフの行をそのままingress/egressルールへ機械的に変換する
- `keycloak-db-init`・`keycloak-test-fixtures`のJob Podに`app`ラベルを新規付与し、podSelectorで正確に指定できるようにした（元々`job-name`ラベルしか無く、他サービスと同じ`app`ラベルの慣習に揃えた）

Kubernetes NetworkPolicyは「同じPodを選択する複数のポリシーは方向ごとに論理和（OR）で合成される」仕様のため、`default-deny.yaml`が全Podのingress/egressを一旦ゼロにした上で、サービスごとのポリシーが必要な穴だけを個別に開ける構成になる。

### kubelet probe・port-forwardの送信元IP

このクラスタはk3d docker network `k3d-gekko07`（サブネット`172.19.0.0/16`、ノードIP`172.19.0.3`、実機確認済み）上の単一ノード構成である。kubeletのprobeも`kubectl port-forward`も、Pod網（`10.42.0.0/24`）ではなくこのdocker networkのIPから到達するため、`ipBlock: 172.19.0.0/16`で許可する。ノードIP単体の`/32`ではなくサブネット単位にしたのは、クラスタ再作成時にノードIPが変わってもポリシーを更新せずに済むようにするため。**この値はこの環境（k3d + Docker Desktop/WSL2のdocker network構成）固有であり、別のdocker network構成でクラスタを再作成した場合は実機で再確認が必要。**

kubectl port-forwardの通信経路については、kubeletがPodのネットワーク名前空間に直接アタッチして中継するため、そもそもCNIのPod網を経由せずNetworkPolicyの対象外になっている可能性がある（未検証）。ipBlock許可はいずれにせよ安全側の措置として残す。

### spire namespaceは対象外

spire-agentは`hostNetwork: true`で動作しており（SPIRE公式チュートリアルが示すPID/cgroup経由のワークロード相関づけに必要、[ADR 0012](0012-spiffe-spire-mtls-single-hop.md)）、kube-router netpolがhostNetwork Podに対してNetworkPolicyをどう適用する（あるいは適用しない）かが実機で未検証である。加えて`spire-entries` Job（`kubectl exec`でspire-serverへ接続する）等、`gekko` namespaceとは異なる接続パターンを持つ。「1ホップずつ実機検証してから横展開する」方針に従い、今回は見送り[docs/backlog.md](../backlog.md)に記録する。

## Consequences

- 共有Postgresインスタンスとkeycloakのhttp-mgmt:9000という、mTLS適用対象外だった2箇所が、L3/4レベルでも許可された呼び出し元・ポートからしか到達できなくなった
- postgres・keycloakのpodSelectorベースの許可は「現在の呼び出し元」に限定されている。将来account-service等が（[ADR 0008](0008-per-service-datastore-strategy.md)の分離検討に伴い）Postgresへ直接接続するようになった場合や、frontend/analyst-attribute-serviceが実装され新しいホップが増えた場合は、対応するNetworkPolicyの許可ルール追加が必要になる（既存のホップ横展開と同じ運用）
- `kube-system`namespaceに`kubernetes.io/metadata.name: kube-system`ラベルが自動付与されていること（Kubernetes 1.21+の標準機能）に暗黙に依存している
- `spire` namespaceへの横展開、`dpop-verifier`という現行マニフェストに存在しない稼働中Podの扱い（調査中に発見。本ADRのスコープ外）は、いずれもbacklog.mdに記録する
- **[0030](0030-fraud-agent-implementation.md)で初めての例外**：fraud-agentがClaude Agent SDK経由で呼ぶAnthropic API（`api.anthropic.com`）向けに、`ipBlock 0.0.0.0/0`（RFC1918プライベートレンジを`except`で除外）による公開インターネットegressを許可した。Anthropicの実IPは固定できないため、これまでの「宛先はpodSelectorまたは既知の固定CIDR」という運用から外れる、意図的な例外である（`k8s/fraud-agent/networkpolicy.yaml`）
