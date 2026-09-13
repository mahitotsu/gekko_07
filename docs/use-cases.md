# ユースケース

具体的な業務シナリオごとに、どのサービスがどう連携して実現するかを示す。各サービスの役割は[services.md](services.md)、認可判定の詳細は[permission-matrix.md](permission-matrix.md)を参照。

異常系は「どのように拒否が観測されるか」も明記する。同じ「拒否」でも、リクエスト自体がエラーになる場合と、処理は完了しつつ結果セットが絞り込まれる場合があり、両者を区別する。

## 不正検知・口座凍結

### UC1: 正常系（AIが標準口座の不審取引を提案し、juniorアナリストが確定する）

登場人物：yamada-analyst（junior, 担当地域=東京）

```
1. yamada-analystがfrontendからログイン
2. frontendでAIエージェント（fraud-agent）とのチャットを開始
   → frontend: Token Exchange①（audience=fraud-mcp-server, scope=account:read）でダウンスコープしたトークンを発行し、fraud-agentに渡す
3. fraud-agent → fraud-mcp-server: MCPツール get_flagged_transactions を呼ぶ
4. fraud-mcp-server: Token Exchange②（audience=account-service, scope=account:read）
5. account-service: Token Exchange③（audience=analyst-attribute-service, scope=analyst:read）でyamada-analystの属性（東京, junior）を取得
6. account-service: 東京の standard 口座の不審取引を返す（permission-matrix.md 表5）
7. fraud-agentが分析し「この口座を凍結すべきです」と提案。fraud-mcp-serverのpropose_freezeツールで提案を記録（scope=account:propose）
8. yamada-analystがfrontendのダッシュボードで提案内容・根拠を確認し、「凍結を確定」ボタンを押す
9. frontend: 自身の直接ログイントークン（scope=account:freeze含む）でaccount-serviceの凍結APIを呼ぶ
10. account-service: 再度analyst-attribute-serviceへ照会し（多層防御）、東京・standard・junior → ALLOW。凍結を実行し、手順7の提案IDと紐付けて記録
```

### UC2: 正常系（AIがhigh-value口座を提案し、seniorアナリストが確定する）

登場人物：suzuki-senior（senior, 担当地域=東京・大阪）

UC1と同じ流れだが、手順6で大阪のhigh-value口座も結果に含まれる（permission-matrix.md 表5、senior行は地域一致であればティア不問でALLOW）。

### UC3: 異常系・権限不足（juniorアナリストにはhigh-value口座がAI経由でも見えない）

登場人物：yamada-analyst（junior, 担当地域=東京）が東京のhigh-value口座について尋ねる場合

```
1〜5. UC1と同様
6. account-service: permission-matrix.md 表5でjunior×high-value=DENY → 結果セットから当該口座を除外
7. fraud-agentはそもそもこの口座のデータを受け取っていないため、凍結提案自体が発生しない
```

**拒否の見え方**：HTTPエラーにはならない。AIエージェントに見えるデータの時点で既に絞り込まれているため、「AIが見落とした」のではなく「そもそも見せていない」という設計になる。

### UC4: 異常系・地域不一致（担当地域外の口座はAI経由でも人間経由でも見えない）

登場人物：yamada-analyst（担当地域=東京）が大阪の口座について尋ねる、またはfrontendから直接大阪の口座を照会しようとする場合

```
- AI経由：UC3と同じ経路で、大阪の口座はaccount-serviceの結果セットから除外される
- frontend直接：account-serviceが同じくpermission-matrix.md表5に基づき除外する（呼び出し経路が違うだけで、判定権威はaccount-service一箇所に集約されている）
```

### UC5: 異常系・AIエージェントが凍結を直接実行しようとするケース（構造的に不可能）

```
1. 仮にfraud-agent（またはfraud-mcp-server）が凍結APIを直接呼ぼうとしても、
   手持ちのトークンはToken Exchange①で発行された scope=account:read のみのトークンであり、
   account:freezeスコープを含まない
2. account-serviceのスコープチェック（permission-matrix.md 表2）でDENY
```

**拒否の見え方**：これはリクエスト時点のスコープ不足によるHTTPエラー（403相当）であり、UC3/UC4の「結果セットの絞り込み」とは異なる種類の拒否。そもそも`fraud-mcp-server`クライアントには`account:freeze`のoptional client scopeが割り当てられていない（permission-matrix.md 表1脚注）ため、Token Exchangeの時点で`account:freeze`を要求しても`invalid_scope`等で拒否される（トークン自体がそもそも取得できないパターン）。

### UC6: 正常系（payment-serviceによる通常の入出金処理）

登場人物：なし（機械間認証）

```
1. payment-serviceがclient_credentialsでトークンを取得（scope=account:transact）
2. account-serviceへ入出金処理を依頼
3. account-service: scope=account:transactを確認 → 許可。analyst-attribute-serviceへの照会は発生しない（permission-matrix.md 表4）
```

このパスはユーザー委任チェーンに一切参加しない、account-serviceの「通常のマイクロサービスから利用される」側面を示す。
