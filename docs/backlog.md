# バックログ

未着手の改善項目・未決定事項。着手時はこのファイルから該当項目を削除し、必要ならarchitecture.md/services.md/insights.mdへ結果を記録する。

## サービス構成

- **各サービスの実装言語の割り当て**：多言語構成にする方針は決めた（requirements.md参照）が、frontend/fraud-agent/fraud-mcp-server/payment-service/account-service/analyst-attribute-serviceのどれをどの言語にするかは未定。fraud-agent/fraud-mcp-serverはMCP公式SDKの充実度からPython/TypeScriptが有力候補
- **fraud-agentのLLM呼び出し方式**：Claude API直呼び出しか、他のSDK/フレームワークを使うかは未定

## Token Exchange / Envoyサイドカー

- **先行検証するホップの確定**：[ADR 0002](adr/0002-token-exchange-in-envoy-sidecar.md)で「1ホップ先行検証→横展開」の方針は決めたが、対象ホップ（fraud-mcp-server→account-service想定）の具体的な実装（Envoy bootstrap設定、ext_authzサービスのプロトコル：HTTPモード想定）はこれから
- **DPoPの適用範囲**：フロントエンド接点（ブラウザ〜frontend間）のみに適用するか、Envoyサイドカー化に伴いDPoP検証もサイドカー側（ext_authzまたは別フィルタ）に寄せるかは未決定
- **Token Exchange結果のキャッシュ**：`(subject jti, audience)`単位でのキャッシュを検討しているが、ext_authzサービス側に持たせるか、どの範囲で共有するかは未決定

## 属性・アクセス制御の粒度

- **口座属性の拡張要否**：現状は地域(`region`)とティア(`standard`/`high-value`)の2軸のみ（access-control-design.md 表5）。実装を進める中でさらに軸が必要になるか要検討
- **アナリストの担当地域が複数ある場合の表現**：配列で持つ想定（access-control-design.md 表6）だが、Keycloakロール/属性のどちらに載せるかは未定

## 監査

- **`proposal_id`とOpenTelemetryトレース・Keycloakイベントログの統合方式**：architecture.md §7で要件のみ決めた。監査ツールを別途作るか、突合方法の詳細は未定
- **サンプリング率を下げた場合の`trace_id`保持**：サンプリング率を1.0未満に下げた状態でも`sampled=false`のリクエストのtrace_idがログに残ることを実機で確認する必要がある（未検証）

## インフラ

- **k3dクラスタの複数ノード化**：現状`servers: 1, agents: 0`（k3d/cluster-config.yaml）。スケジューリングの検証が必要になった場合はagentノードを追加するか検討
- **WSL2 cgroup v2化の恒久性**：`.wslconfig`の`kernelCommandLine = cgroup_no_v1=all`で対応済み（insights.md参照）だが、Windows Update等で設定が失われないかは未検証
