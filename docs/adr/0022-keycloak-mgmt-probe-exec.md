# ADR 0022: Keycloakのkubelet向けhttp-mgmt(9000)をexecプローブ化してloopback限定にする

- **Status**: Accepted
- **Date**: 2026-09-17

## Context

[ADR 0017](0017-edge-proxy-full-keycloak-mtls.md)でkeycloakコンテナ自体の8080(app)は`KC_HTTP_HOST=127.0.0.1`でPod外から直接到達不能にしたが、health/mgmt(9000)は`KC_HTTP_MANAGEMENT_HOST=0.0.0.0`のまま残していた。理由は、`--http-management-host`が既定で`--http-host`を継承するため、明示しないとmgmtまで道連れでloopback化され、kubeletのreadiness/liveness/startupProbe(`httpGet`、対象はPod IP:9000)が到達できずPodが起動直後に再起動ループすることを実機で確認したためである。[ADR 0018](0018-network-policy-default-deny.md)は、この「kubeletだけは9000に到達できる必要がある」という制約の下で、NetworkPolicyのingressを`ipBlock: 172.19.0.0/16`(このk3d環境でkubeletのProbeが到達するノードIP相当のdocker networkサブネット)からのみ許可することで、L3/4レベルの到達範囲を絞ってきた。

第三者レビューでこの構成について指摘を受けた: **kubeletのhttpGet/tcpSocketプローブは、Service・Envoyサイドカーのmtls終端・NetworkPolicyの「Pod単位の許可リスト」という通常のゼロトラストモデルを迂回して、ノードのルート名前空間からPodの実IP(`eth0`)へ直接TCP接続する**という、Kubernetesの構造的な制約に基づくものである(Istioが`STRICT`mTLSモード下でkubeletの平文プローブをどう扱うか——専用ポート15020をmTLS対象外として例外化する——という業界共通のパターンを見ても、この制約自体は消せないことが分かる)。9000はSPIFFE身元検証もmTLSも掛けられない「条件付きの平文の穴」であり、`ipBlock`の範囲を将来広く書き間違えれば実質的に無条件公開になるリスクを抱えていた。

一方、Keycloak公式ドキュメント(observability/health)は、公式Dockerイメージに`curl`が同梱されていない環境向けに、次のシェルワンライナーをreadiness probeの推奨実装として掲載している。

```sh
{ printf 'HEAD /health/ready HTTP/1.0\r\n\r\n' >&0; grep 'HTTP/1.0 200'; } 0<>/dev/tcp/localhost/9000
```

`kubectl exec`で対象Podに実際にこのコマンドを実行したところ、`/health/ready`・`/health/live`・`/health/started`いずれも`HTTP/1.0 200 OK`が返り、`/bin/sh`が`bash`へのシンボリックリンクであることも確認できた(`/dev/tcp`はbashの機能)。execプローブはkubeletがコンテナランタイム(CRI)経由でコンテナ内にコマンドを実行する方式であり、**Podのネットワークインターフェースを一切経由しない**。つまりexecプローブに切り替えれば、9000を再びloopback限定にしてもkubeletから到達可能なままにできる。

このワンライナー自体は本プロジェクトで初出ではない。[docs/insights.md](../insights.md)には、`envoyproxy/envoy`公式イメージにも同じくcurl/wgetが同梱されておらず、`bash`の`/dev/tcp`で代替した記録がすでにあり([scripts/verify-hop.sh](../../scripts/verify-hop.sh)でEnvoy管理API(`:9901/stats`)の疎通確認に使用)、本ADRはこのプロジェクト内で確立済みのパターンをKeycloakのProbeにも適用するものである。

## Decision

**Keycloakのreadiness/liveness/startupProbeを`httpGet`から`exec`(`/dev/tcp`ワンライナー)へ変更し、`KC_HTTP_MANAGEMENT_HOST`を`127.0.0.1`に変更する。** これにより9000はapp(8080)と同じく、コンテナ内loopbackからしか到達できなくなる。

### 具体的な変更

- [k8s/keycloak/deployment.yaml](../../k8s/keycloak/deployment.yaml): `KC_HTTP_MANAGEMENT_HOST=127.0.0.1`。3つのProbeを`exec`化(エンドポイントのみ`/health/ready`・`/health/live`・`/health/started`で使い分け、コマンド構造は共通)
- [k8s/keycloak/service.yaml](../../k8s/keycloak/service.yaml): `http-mgmt:9000`のポート定義を撤廃(ADR 0017で8080を撤廃したのと同じ理由——loopback限定のポートをServiceで公開しても到達できないため無意味)
- [k8s/keycloak/networkpolicy.yaml](../../k8s/keycloak/networkpolicy.yaml): `ipBlock: 172.19.0.0/16`からport 9000を許可するingressルールを撤廃(誰からもネットワーク経由で到達できなくなったため、許可リスト自体が不要になった)

### 他サービスへの適用方針

現時点でProbeが定義されているのはKeycloakのみで、account-service等の他サービスにはまだ無い。今後これらのサービスにヘルスチェックを追加する際は、素朴に`httpGet`でアプリのポートやEnvoyの管理ポートを晒すのではなく、**「execプローブ + loopback限定」を標準パターンとする**([ADR 0009](0009-envoy-ingress-responsibility-and-bypass-prevention.md)がアプリ本体に課しているloopback限定の原則を、Probe用エンドポイントにも一貫して適用する)。

## Consequences

- Keycloak Podへのネットワーク到達可能な経路は、`https-mtls:8443`(許可されたSPIFFE IDのみ)のみになった。9000は誰からもネットワーク経由で到達不能(NetworkPolicyでの許可リストにすら載らない)であり、「kubeletのみ許可」という条件付きの平文の穴が構造的に消えた
- `ipBlock: 172.19.0.0/16`の許可ルールが不要になったことで、将来他のNetworkPolicyがこのCIDRを安易に流用して過度に広い許可を書いてしまうリスクも減った
- execプローブはPodのネットワーク到達性そのものを検証しないため、「app(8080)自体は生きているがネットワーク的に他Podから到達できない」という種類の障害(例:CNI側の不具合)は、httpGetと違って検知できない。ただしこの種の障害はEnvoyサイドカー側のhttpGetプローブ(未設定)や、実際のトラフィック疎通失敗として別経路で顕在化するため、許容範囲と判断する
- Keycloak公式が推奨する`/dev/tcp`ワンライナーは`bash`が前提。イメージが将来`ubi9-micro`ベース等に変わり`/bin/sh`がbashでなくなった場合は動作しなくなるため、Keycloakのバージョンアップ時はこのProbeが引き続き成功することを確認する
