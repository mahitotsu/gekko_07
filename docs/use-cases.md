# ユースケース

具体的な業務シナリオごとに、どのサービスがどう連携して実現するかを示す。各サービスの役割は[services.md](services.md)、認可判定の詳細は[access-control-design.md](access-control-design.md)を参照。

異常系は「どのように拒否が観測されるか」も明記する。同じ「拒否」でも、リクエスト自体がエラーになる場合と、処理は完了しつつ結果セットが絞り込まれる場合があり、両者を区別する。

## 不正検知・口座凍結解除

### UC0: 前提（fraud-detection-engineによる自動凍結）

登場人物：なし（機械間認証）

```
1. fraud-detection-engineが取引パターンを監視し、疑わしい取引パターンを検知する
2. fraud-detection-engineがclient_credentialsでトークンを取得（scope=account:freeze）
3. account-serviceへ当該口座の凍結を依頼する
4. account-service: scope=account:freezeを確認 → 許可。analyst-attribute-serviceへの照会は発生しない（access-control-design.md 表4）。凍結の判定根拠（発火した検知ルール等）を記録する
```

このパスはユーザー委任チェーンに一切参加しない、account-serviceの「通常のマイクロサービスから利用される」側面を示す。以降のUC1〜UC5は、この自動凍結が既に起きていることを前提にする。

### UC1: 正常系（AIが標準口座の凍結解除を提案し、juniorアナリストが確定する）

登場人物：yamada-analyst（junior, 担当地域=東京）

```
1. yamada-analystがfrontendからログイン
2. frontendでAIエージェント（fraud-agent）とのチャットを開始
   → frontend: 自身のログイントークン（aud=frontend）を`subject_token`にToken Exchangeを実行（audience=fraud-mcp-server, scope=account:read）し、ダウンスコープしたトークンをfraud-agentに渡す
3. fraud-agent → fraud-mcp-server: MCPツール get_frozen_accounts を呼ぶ
4. fraud-mcp-server: Token Exchange（audience=account-service, scope=account:read）
5. account-service: Token Exchange（audience=analyst-attribute-service, scope=analyst:read）でyamada-analystの属性（東京, junior）を取得
6. account-service: 東京の standard 口座のうち凍結中のものを、凍結根拠とともに返す（access-control-design.md 表5）
7. fraud-agentが凍結理由・取引履歴を分析し「この口座は誤検知の疑いがあり、凍結を解除すべきです」と提案。fraud-mcp-serverのpropose_unfreezeツールで提案を記録（scope=account:propose）
8. yamada-analystがfrontendのダッシュボードで提案内容・根拠を確認し、「凍結解除を確定」ボタンを押す
9. frontend: 自身のログイントークン（aud=frontend）を`subject_token`に別のToken Exchangeを実行（audience=account-service, scope=account:unfreeze）し、そのトークンでaccount-serviceの凍結解除APIを呼ぶ
10. account-service: 再度analyst-attribute-serviceへ照会し（多層防御）、東京・standard・junior → ALLOW。凍結解除を実行し、手順7の提案IDと紐付けて記録
```

### UC2: 正常系（AIがhigh-value口座の凍結解除を提案し、seniorアナリストが確定する）

登場人物：suzuki-senior（senior, 担当地域=東京・大阪）

UC1と同じ流れだが、手順6で大阪のhigh-value口座も結果に含まれる（access-control-design.md 表5、senior行は地域一致であればティア不問でALLOW）。

### UC3: 異常系・権限不足（juniorアナリストにはhigh-value口座がAI経由でも見えない）

登場人物：yamada-analyst（junior, 担当地域=東京）が東京のhigh-value口座について尋ねる場合

```
1〜5. UC1と同様
6. account-service: access-control-design.md 表5でjunior×high-value=DENY → 結果セットから当該口座を除外
7. fraud-agentはそもそもこの口座のデータを受け取っていないため、凍結解除提案自体が発生しない
```

**拒否の見え方**：HTTPエラーにはならない。AIエージェントに見えるデータの時点で既に絞り込まれているため、「AIが見落とした」のではなく「そもそも見せていない」という設計になる。

### UC4: 異常系・地域不一致（担当地域外の口座はAI経由でも人間経由でも見えない）

登場人物：yamada-analyst（担当地域=東京）が大阪の口座について尋ねる、またはfrontendから直接大阪の口座を照会しようとする場合

```
- AI経由：UC3と同じ経路で、大阪の口座はaccount-serviceの結果セットから除外される
- frontend直接：account-serviceが同じくaccess-control-design.md表5に基づき除外する（呼び出し経路が違うだけで、判定権威はaccount-service一箇所に集約されている）
```

### UC5: 異常系・AIエージェントが凍結解除を直接実行しようとするケース（構造的に不可能）

```
1. 仮にfraud-agent（またはfraud-mcp-server）が凍結解除APIを直接呼ぼうとしても、
   手持ちのトークンはfrontendとのToken Exchangeで発行された scope=account:read のみのトークンであり、
   account:unfreezeスコープを含まない
2. account-serviceのスコープチェック（access-control-design.md 表2）でDENY
```

**拒否の見え方**：これはリクエスト時点のスコープ不足によるHTTPエラー（403相当）であり、UC3/UC4の「結果セットの絞り込み」とは異なる種類の拒否。そもそも`fraud-mcp-server`クライアントには`account:unfreeze`のoptional client scopeが割り当てられていない（architecture.md §4、access-control-design.md 表2）ため、Token Exchangeの時点で`account:unfreeze`を要求しても`invalid_scope`等で拒否される（トークン自体がそもそも取得できないパターン）。
