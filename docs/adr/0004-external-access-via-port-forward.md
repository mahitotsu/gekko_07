# ADR 0004: 外部公開はIngressではなくkubectl port-forwardで行う

- **Status**: Accepted
- **Date**: 2026-09-13

## Context

ホストのブラウザからクラスタ内のfrontend/Keycloakへアクセスする方法として、以下を検討した。

| 手段 | 必要な部品 |
|---|---|
| Ingress + 独自ホスト名 | Ingressコントローラ、Ingressリソース、ホストOS側のDNS解決（`/etc/hosts`かnip.io） |
| **`kubectl port-forward`（採用）** | 何も要らない。`kubectl`があれば動く |

docker compose時代（gekko_05）は`ports: ["3000:80"]`一発で`http://localhost:3000`がホストから使え、`KC_HOSTNAME`もこの値に固定していた。Ingressを使う場合、Pod側とホスト側でDNSの見え方が非対称になり（Pod側はCoreDNSでService名を自動解決できるが、ホスト側の独自ホスト名はデフォルトでは何の意味も持たない）、これを解決するための部品（Ingressコントローラ、ホストDNS設定）が新たに必要になる。

## Decision

**`kubectl port-forward`で外部公開する**。Ingressリソース・Ingressコントローラは使わない。

- edge-proxy相当のService（nginx等、パスベースで内部の各サービスに振り分ける）を通常のDeployment/Serviceとしてデプロイする
- `kubectl port-forward svc/edge-proxy 3000:80`でホストの`localhost:3000`に接続する
- `KC_HOSTNAME`はdocker compose時代と同じ`http://localhost:3000`のまま維持する

これにより[ADR 0003](0003-k3d-without-istio.md)で不要と判断したTraefik（k3d標準同梱のIngressコントローラ）・servicelbを無効化し、クラスタを軽量に保てる（`k3d/cluster-config.yaml`参照）。

## Consequences

- `kubectl port-forward`はプロセスとして動かし続ける必要があり、対象Podが再作成されると接続が切れ手動再実行が必要になる（Serviceに対する自動再解決はされない）。`make`タスクでの管理を前提とする
- 複数人による同時アクセスやIngressそのものの検証には向かないが、今回はローカル単独開発が前提のため許容する
- 今回の目的（Envoyサイドカーでのtoken exchange検証）に無関係な部品（Ingressコントローラ、ホストDNS設定）を持ち込まずに済む
