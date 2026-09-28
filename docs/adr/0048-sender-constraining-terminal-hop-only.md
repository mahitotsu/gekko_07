# ADR 0048: 送信者拘束（DPoP / RFC 8705）は委任チェーンの終端ホップにしか適用できず、現時点では導入しない

- **Status**: Accepted
- **Date**: 2026-09-25

## Context

[ADR 0013](0013-dpop-sender-constraining.md)でfraud-mcp-server→account-serviceの1ホップにDPoP（RFC 9449）を試験導入・実機検証し、[ADR 0015](0015-dpop-removal-and-fraud-detection-engine-mtls.md)でSPIRE mTLSとの実利の重複を理由に撤去した。ADR 0015は、mTLSの全ホップ横展開が完了した後に送信者拘束をあらためて評価する余地を残していた。

k8s内部通信のmTLS横展開が全ホップで完了した（[architecture.md](../architecture.md) §3.5）ことを受け、もう一方の送信者拘束方式であるRFC 8705（証明書拘束アクセストークン）を使い捨て環境で再検証した。本ADRは、DPoP・RFC 8705の両方式に共通する構造的制約と、RFC 8705再検証の結論を1件の決定として記録し、[architecture.md](../architecture.md) §11に散在していた判断・根拠と[insights.md](../insights.md) §5に混在していた仕様レベルの論証を、ここへ集約する。

### 前提：RFC 8705には独立した2つの機能がある

ADR 0012/0013/0019が「RFC 8705は不成立」と結論したのは、mTLSを**クライアント認証方式そのもの**として使う場合（`clientAuthenticatorType: client-x509`。Keycloak 26.7.0はSubject DNしか照合せず、SPIRE発行証明書のURI SAN（SPIFFE ID）を見ないという製品上の制約）についてである。本ADRが再検討するのはこれとは独立した第2の機能——証明書拘束アクセストークン（`tls.client.certificate.bound.access.tokens`。クライアント認証方式は`federated-jwt`等どれでもよく、TLS接続で提示された証明書のサムプリントをトークンの`cnf.x5t#S256`へ埋め込むだけ）——であり、`client-x509`の制約とは別軸である。

## Decision

**現時点では、DPoP・RFC 8705のいずれも委任チェーンへ導入しない。** ADR 0013/0015の撤去判断を維持する。根拠は以下の3点。

### なぜDPoP・RFC 8705はいずれも委任チェーンの終端ホップにしか適用できないか（仕様レベルの根拠）

「既に拘束済みのsubject_tokenを別クライアントが再exchangeすると拒否される」という制約（DPoPで[ADR 0013](0013-dpop-sender-constraining.md)、RFC 8705で本ADR再検証時に実機確認。詳細な実機再現は[insights.md](../insights.md) §5）は、Keycloak固有の実装都合ではなく、関連する複数の仕様の定義を重ね合わせると論理的に導出できる構造的帰結である。

1. **送信者拘束の定義そのものが「鍵の保持者の同一性」を要求する**：[RFC 9449](https://www.rfc-editor.org/rfc/rfc9449.html)（DPoP）はIntroductionで"the legitimate presenter of the token is constrained to be the sender that holds and proves possession of the private part of the key pair"と定義する。[RFC 9700](https://www.rfc-editor.org/doc/rfc9700/)（OAuth 2.0 Security BCP）も「sender-constrained access tokenは、その適用範囲を特定の送信者に限定し、その送信者はある秘密の認知を証明する義務を負う」という定義を採用している。つまり「正当な提示者」は、発行時に鍵の所有を証明した**同一の主体**であることが定義上の前提になる
2. **RFC 8693のImpersonation方式は、提示者の同一性をあえて消す設計になっている**：[RFC 8693](https://www.rfc-editor.org/rfc/rfc8693.html)は`actor_token`を伴わない交換（Impersonation）について、発行されるトークンが「元のsubject_tokenの主体そのもの」として振る舞うと定義し、`act`クレーム（誰が実際に代理したか）は付与しない。つまりImpersonation方式は、トークンを見る限り「実際に今それを提示しているのが誰か」を意図的に記録・追跡しない設計である
3. **この2つを重ねると論理的に破綻する**：DPoP/RFC 8705は「今この鍵を持っている者だけが正当な提示者」と定義する一方、Impersonation方式のToken Exchangeは「元の主体とは別の実体が、その区別を記録せずに正当な提示者として振る舞ってよい」ことを許す。両者を同時に満たす唯一の整合的な解釈は「拘束済みsubject_tokenを別の鍵の保持者が再exchangeすることを拒否する」以外にない。もしKeycloakがここで黙って新しい鍵へ拘束し直す（re-bind）挙動を許せば、盗まれた拘束済みトークンを攻撃者がImpersonation方式のToken Exchangeで「自分の鍵に付け替えて」正当化できてしまい、送信者拘束の目的（盗難トークンの再利用防止）そのものが破られる。厳密には、**再バインドが安全になる条件は存在する——ASが要求元クライアントを「その主体のactorとして」独立に認可できる場合**である。しかしImpersonation方式はまさにその認可の根拠（誰が代理しているかの記録・判定）を持たない。したがってImpersonation下では、Keycloakの拒否は安全側に倒す唯一の選択肢であり、必然的な帰結である。この「独立な認可根拠」を明示的に備えるのが次節のDelegation方式であり、だからこそDelegationでは再バインドが原理的に成立する

RFC 8693自身はcnf/送信者拘束について一切規定せず（"the specific syntax, semantics, and security characteristics of the tokens themselves...are explicitly out of scope"）、RFC 9449もRFC 8693やdelegation/actor/token exchangeという語を一度も使っていない。この非互換性は**どの仕様書にも明文化されていない、複数の仕様を組み合わせた際に初めて顕在化する仕様間ギャップ**である。Keycloakの未解決issue [#51205](https://github.com/keycloak/keycloak/issues/51205)（2026-07-27、"DPoP拘束済みトークンとdelegation/actor機能を同時に使いたい"という機能要望）は、この組み合わせを求める実際のニーズが未解決のまま残っていることを示している。

帰結として、DPoP・RFC 8705のどちらも、**後続で再exchangeされることの無い終端ホップ**にしか安全に設定できない。委任チェーンは線形とは限らず、account-service→analyst-attribute-serviceのような枝を持つため終端ホップは複数ありうるが、各終端ホップで守れるのはそのホップ単体であり、「委任チェーン全体でトークン窃取を塞ぐ」という広い効果は、Impersonation方式を採る限り原理的に得られない。

### Delegation方式（`actor_token`＋`act`クレーム）は原理的には両立しうるが、代替にならない

Delegation方式では各ホップが「自分自身の鍵で自分自身の`actor_token`を提示する」ことが前提になり、`act`クレームが「誰が代理したか」を明示的に記録する。「鍵の保持者の同一性」を各ホップ内で完結させホップ間の連鎖を`act`クレームのネストで表現するため、上記1〜3の矛盾（**トークン所有者の証明**という関心事）は生じない。しかしDelegation方式の採否は本来これとは独立したもう一つの関心事（**委任モデルそのものの選択**）であり、この軸には固有のコストが2つある。

1. **トークンサイズ**：`act`クレームはホップ数に応じて入れ子になり（[RFC 8693 §4.1](https://www.rfc-editor.org/rfc/rfc8693.html#section-4.1)）、gekko_07の4ホップの委任チェーン（frontend→fraud-agent→fraud-mcp-server→account-service）ではホップを追うごとにJWTペイロードが線形に太る
2. **Keycloakの機能成熟度**：`act`クレーム生成に必要な`token-exchange-delegation`機能はKeycloakの成熟度区分で"Experimental"であり、gekko_07が既に採用している`spiffe`/`client-auth-federated`機能の"Preview"よりさらに一段階低い、最も未熟な区分である

gekko_07は`sub`を委任チェーン全体で同一に保ち`jti`/`scope`の違いで追跡する監査設計（[architecture.md](../architecture.md) §5・§9）のためにImpersonation方式を採用している（[ADR 0019](0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)は、Delegationモデルをクライアント認証方式の検討の一つとして扱ったが「トークン意味論はimpersonation的な現状を変更しない」と明記した）。Delegation方式への転換は監査設計の作り直しに加え、この2つのコストも引き受けることになるため、送信者拘束の制約を回避する目的だけで採る選択肢にはならない。

### RFC 8705再検証の結論（2026-09-24 / 2026-09-25、使い捨て環境）

使い捨てのKeycloak 26.7.0 / Envoy v1.31.5コンテナ（gekko_07クラスタ本体には一切触れず、検証後に破棄）で第2の機能を再検証した。詳細な実機の罠・手順は[insights.md](../insights.md) §5.2。要点は以下。

- **実装可能性は肯定的**：発行側（Keycloakへ`cnf`を埋め込む）は、EnvoyのXFCCをKeycloakの`x509cert-lookup`（`haproxy`プロバイダ）が期待するBase64(DER)へ整形するだけでよく、証明書のパース・検証・再署名等の暗号処理は不要——約30行の文字列整形サイドカーで足りることをend-to-endで確認した。検証側（利用時の`cnf.x5t#S256`照合）はEnvoyの`%DOWNSTREAM_PEER_FINGERPRINT_256%`とアプリ側の数行の文字列比較だけで完結し、新規のフィルタ・Luaは不要。ADR 0012が挙げたもう一つのブロッカー（発行時接続と提示時接続が別証明書になる問題）も、[ADR 0019](0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)以降のPod内サイドカー構成で解消済み
- **しかしDPoPと全く同じ終端ホップ制約を持つ**：3クライアントの委任チェーンで、既に拘束済みのsubject_tokenを別クライアント・別証明書が再exchangeすると、DPoPの時と一字一句同じ`"Sender-constrained token exchange rejected as the token was not issued for the requesting client"`でKeycloakに拒否される。Keycloakのこの拒否ロジックは拘束方式（DPoPのJWK拘束かRFC 8705の証明書拘束か）に依存しない汎用ロジックであり、上記「仕様レベルの根拠」がRFC 8705にもそのまま当てはまることを実機で裏付けた

したがって、RFC 8705を導入しても効果は各終端ホップ単体に限られる。その範囲の**大部分**はmTLS（`match_typed_subject_alt_names`）が既に守っている——ただしmTLSが守るのは通信路の呼び出し元身元であって、トークンの再利用そのものではない。account-serviceのように複数の正規呼び出し元（fraud-mcp-server・fraud-detection-engine・frontend・audit-service）からのmTLSを受ける構成では、ある呼び出し元が漏らしたトークンを、別の正規呼び出し元（有効なSPIRE証明書を持つワークロードが侵害された場合）が同じaccount-serviceへ提示するケースはmTLSでは止まらず、証明書拘束なら`cnf`不一致で止まる。つまりmTLSとの重複は完全ではなく、残差は「相互に到達可能な正規呼び出し元どうしの横方向トークン再利用」である。この残差は狭く、効果は依然として終端ホップ単体に限られるため、DPoPを撤去した[ADR 0015](0015-dpop-removal-and-fraud-detection-engine-mtls.md)の判断軸（mTLSとの実利の大幅な重複＋終端ホップ限定）がRFC 8705にもそのまま当てはまり、**現時点では導入しない**という結論に至った。再検証で更新されたのは「実装が安価であること」および上記の残差脅威の輪郭であり、投資に見合うかという未決の問いは[architecture.md](../architecture.md) §11に残す。

## Consequences

- 送信者拘束に関する**現在有効な断面**は[architecture.md](../architecture.md) §3.5（不採用）と §11（未決の問い）に一本化され、判断の**根拠**は本ADRに集約された。[insights.md](../insights.md) §5は、再検討時に再利用できる実機の罠・検証手順（Java TLSがSubject空証明書の非critical SANを拒否する、`haproxy`プロバイダがBase64(DER)を期待する、Envoyのフィンガープリントヘッダー等）に限定される
- 本ADRは[ADR 0013](0013-dpop-sender-constraining.md)/[ADR 0015](0015-dpop-removal-and-fraud-detection-engine-mtls.md)のDecisionを変更しない（撤去判断を覆さず、RFC 8705にも同じ判断が及ぶことを確認しただけであるため、両ADRのStatusは更新しない）
- 更新した他文書：[architecture.md](../architecture.md) §3.5・§11（再掲をやめ本ADR・insights §5へのポインタに置換）、[insights.md](../insights.md) §5（仕様レベルの論証・結論を本ADRへ移し、実機の罠に限定）、[adr/README.md](README.md) 索引
- 将来、委任チェーン全体ではなく終端ホップ単体のトークン窃取まで防ぎたい要求が明確になった場合、本ADRの実装可能性の知見（安価に実装できる）を出発点に再評価できる
