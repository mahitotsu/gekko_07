# ADR 0038: fraud-agent→Anthropic egressルートに timeout: 0s / idle_timeout: 300s を設定する

- **Status**: Accepted
- **Date**: 2026-09-23
- **Amends**: [0030](0030-fraud-agent-implementation.md)（「Envoyのタイムアウト設計」で`timeout: 0s`＋`idle_timeout: 300s`を適用したホップの一覧に、抜けていた`anthropic_gateway`ルート自身を追加）

## Context

[ADR 0037](0037-fraud-agent-anthropic-stream-retry.md)でターン単位の自動リトライを追加した後も、実際のチャット利用で同種の切断が高い確率で再現した。`kubectl logs`で実際のエラー内容を確認したところ、真の一次エラーは`API Error: 504 upstream request timeout. This is a server-side issue, usually temporary — try again in a moment.`であり、その直後にSDK内部のセッション再開試行も同じ理由で失敗し、最終的に`API Error: The socket connection was closed unexpectedly`としてクライアントに露出していることが分かった。

`504 upstream request timeout`はEnvoyが生成するエラーであり、外部要因（Anthropic側やネットワーク）の問題ではない。[k8s/fraud-agent/envoy-configmap.yaml](../../k8s/fraud-agent/envoy-configmap.yaml)の`anthropic_gateway`仮想ホストのルートを確認したところ、`timeout`・`idle_timeout`のいずれも明示されていなかった。[ADR 0030](0030-fraud-agent-implementation.md)の「Envoyのタイムアウト設計」は、`/chat`が通る全ホップに`timeout: 0s`＋`idle_timeout: 300s`を適用したと記載しているが、実際に一覧されていたのは`edge-proxy→frontend`・`frontend→fraud-agent`・`fraud-agent自身のingress`の3ホップのみで、**fraud-agent→Anthropic（egress）ホップ自体が対象から漏れていた**。この結果、Envoyの既定route timeout（15秒）がそのまま適用され、ある程度まとまった量のテキストを生成する応答（今回のような表を含む調査レポート等）が15秒を超えると`504`で強制終了されていた。

[ADR 0037](0037-fraud-agent-anthropic-stream-retry.md)で追加したアプリ層リトライは、この504自体は`isRetryableRunError`のパターンに一致しないため救えず（1回目の504はそのまま`RUN_ERROR`になるか、SDK内部の再接続試行が別の理由でさらに失敗して初めて2回目のエラーとしてリトライ対象になる）、根本原因（route timeoutの欠落）を直接解消するものではなかった。今回、実際にユーザーが同じ操作を繰り返すたびにほぼ確実に再発したのは、この15秒という固定上限が、生成に時間のかかる応答では日常的に超過される値だったためである。

## Decision

`anthropic_gateway`ルートに、`app_upstream`ルート（frontend→fraud-agentのingress、[ADR 0030](0030-fraud-agent-implementation.md)）と同じ設計思想を適用する：`timeout: 0s`（総時間の上限を無効化）＋`idle_timeout: 300s`（無活動時間の上限）。Anthropic呼び出しは実行時間が本質的に不定長（モデルの応答生成時間に依存）であり、固定`timeout`ではなく無活動時間で制御すべきという点は、ingress側のホップと全く同じ理由による。

`retry_policy`（[ADR 0030](0030-fraud-agent-implementation.md)、[ADR 0037](0037-fraud-agent-anthropic-stream-retry.md)）はそのまま維持する。今回のtimeout是正とは独立の防御層（接続の使い回し自体が失効しているケース）であり、競合しない。

## Consequences

- 影響範囲：`k8s/fraud-agent/envoy-configmap.yaml`（`anthropic_gateway`ルート）のみ。`kubectl apply`＋fraud-agent Deploymentの再起動（Envoyはこの静的ConfigMapを起動時に読み込むため、ホットリロードではなく再起動で反映する）で適用した
- `make deploy`等でこのConfigMapを再適用する際、既存のfraud-agentサイドカー起動シーケンス（[ADR 0009](0009-envoy-ingress-responsibility-and-bypass-prevention.md)のinitContainer構成）に変更はない
- 実機（k3dクラスタ、`scripts/verify-hop.sh`のログイン手法を流用したアドホック検証）で、口座789・456双方の精査を実際に`/chat`経由で実行し、`RUN_ERROR`無しで`RUN_FINISHED`まで到達することを確認した（検証結果はコミットメッセージ・作業ログ参照。恒久的な回帰検知としては`scripts/verify-hop.sh`パターン⑤の既存チェックがこのタイムアウト欠落も今後カバーする）
- [ADR 0037](0037-fraud-agent-anthropic-stream-retry.md)のアプリ層リトライは、このtimeout是正後に残る真に一時的な接続断（ネットワークの瞬断等）に対する防御として引き続き有効
