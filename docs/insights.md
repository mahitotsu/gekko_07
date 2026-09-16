# 実装で得た気づき・罠

実装を進める過程で見つかった、再発しそうな罠や実機検証で判明した仕様上の落とし穴を記録するナレッジベース。設計判断そのものは[architecture.md](architecture.md)、未着手の改善項目は[backlog.md](backlog.md)を参照。

各項目は原則として次の構造で記述する（当てはまらない要素は省略する）。

- **症状**：どんな問題・違和感が観察されたか
- **原因**：実機検証や調査で判明した根本原因
- **対応**：実際に取った対応・回避策

## Envoy / ext_authz / Token Exchange（1ホップ先行検証、fraud-mcp-server→account-service）

[k8s/ext-authz/](../k8s/ext-authz/)・[k8s/account-service/](../k8s/account-service/)・[k8s/fraud-mcp-server/](../k8s/fraud-mcp-server/)・[scripts/verify-hop.sh](../scripts/verify-hop.sh)で実施。`account:read`/`account:propose`いずれもEnvoy egress(ext_authzによるToken Exchange)→Envoy ingress(jwt_authn/rbac/合言葉)→アプリ、という経路全体が200で通り、期待した`x-auth-*`ヘッダーが転送されることを確認した。Pod外からアプリポートへの直接到達が拒否されることも確認した（ADR 0009主対策①）。

### ext_authz(HTTPモード)のcontext_extensionsはgRPCモード限定

**症状**：ADR 0010の設計通り`ExtAuthzPerRoute.check_settings.context_extensions`でscopeをext_authzサービスへ渡そうとしたが、Envoy公式v3 APIリファレンスを確認すると「These settings are only applied to a filter configured with a grpc_service.」と明記されていた。ADR 0002はHTTPモードのext_authzを採用しているため、この方式はそもそも機能しない。

**原因**：`context_extensions`はgRPCモードのCheckRequest.attributes専用の仕組みで、HTTPモードには伝達経路がない。

**対応**：HTTPモードのext_authzは、`Host`・`Method`・`Path`・`Content-Length`・`Authorization`を`authorization_request.allowed_headers`の設定と無関係に常に自動転送することも確認済み。ext_authzサービス自身が、この自動転送される`Host`（audience）と`Path`+`Method`（access-control-design.md 表2の対応表で解決するscope）だけからToken Exchangeリクエストを組み立てるよう設計を訂正した（[k8s/ext-authz/app-configmap.yaml](../k8s/ext-authz/app-configmap.yaml)）。ADR 0010・architecture.md §3を直接訂正済み（決定自体ではなく実装メカニズムの誤りだったため、新ADRは起こしていない）。

### Keycloak Standard Token Exchange V2:audience解決にはclient scope側のAudience protocol mapperが要る

**症状**：`grant_type=urn:ietf:params:oauth:grant-type:token-exchange`で`audience=fraud-mcp-server`を指定しても`{"error":"invalid_request","error_description":"Requested audience not available: fraud-mcp-server"}`で拒否される。`fraud-mcp-server`・`account-service`とも`standard.token.exchange.enabled: true`は設定済みで、クライアント設定に差はなかった。

**原因**：Standard Token Exchange V2は、要求元クライアント（この例ではfrontend）に割り当てられたclient scope（`scope`パラメータで要求したもの）が、対象audienceを指す`oidc-audience-mapper`（protocol mapper）を持っていない限り、そのaudienceを解決できない。対象クライアント側の設定は不要（公式ドキュメントに明記）だが、要求元側のscopeにmapperが必要という点は明文化されていなかった。`account-service`向けは元々`account:read`等のclientScopeにこのmapperを設定していたため動いていたが、`fraud-mcp-server`向けには存在しなかった。

**対応**：[k8s/keycloak/realm-configmap.yaml](../k8s/keycloak/realm-configmap.yaml)の`account:read`clientScopeに、`account-service`向けと`fraud-mcp-server`向けの**2つの**`oidc-audience-mapper`を持たせた。1つのscopeに複数audienceのmapperを持たせても、実際に発行されるトークンはToken Exchangeリクエストの`audience`パラメータで指定した1つだけに絞り込まれ（他方は含まれない）、ADR 0005の単一audience原則は崩れないことを実機で確認した。同名scopeが複数の実際の委任関係（今回はfrontend→account-service・frontend→fraud-mcp-serverの両方で`account:read`を使う）にまたがる場合は、この「1scope・複数audience mapper」パターンが必要になる。

### kcadm.sh `get <collection> -q <field>=<value>` は一部のリソースでサーバー側フィルタが効かない

**症状**：`kcadm.sh get client-scopes -r gekko -q name=account:read`の結果を`grep -m1 '"id"'`で拾ったIDに対して操作したところ、実際には無関係な組み込みscope（`offline_access`、配列の先頭要素）を操作してしまっていた。`clients`エンドポイントの`-q clientId=xxx`は正しく絞り込めていたため、しばらく気づかなかった。

**原因**：`-q`はkcadmのREST呼び出しにクエリパラメータとして付与されるだけで、対象エンドポイントがそのクエリパラメータをサーバー側で解釈するかどうかはエンドポイントごとに異なる。`/admin/realms/{realm}/clients?clientId=`は有効なフィルタだが、`/admin/realms/{realm}/client-scopes`は`name`によるサーバー側フィルタを持たず、`-q`は黙って無視され全件が返る。

**対応**：`client-scopes`のように`-q`が効くか不明なエンドポイントでは、まず`get client-scopes -r gekko`で全件のname/idの対応をローカルで確認してから対象IDを特定する（`fixtures.sh`の`client_id_of()`ヘルパーは`clients`エンドポイント限定でのみ使う設計にしている）。

### Keycloak 26のDeclarative User Profile:email/氏名未設定だとROPCログインが「Account is not fully set up」で失敗する

**症状**：`kcadm.sh create users -s username=... -s enabled=true`だけでユーザーを作成し、`set-password --temporary=false`でパスワードを設定しても、Resource Owner Password Credentials（direct grant）でのログインが`{"error":"invalid_grant","error_description":"Account is not fully set up"}`で失敗する。ユーザーの`requiredActions`は空配列で、パスワードcredentialも正しく設定されていた。

**原因**：Keycloak 26のDeclarative User Profileが、`email`・`firstName`・`lastName`等の必須プロフィール属性の欠落を検出し、ログイン時に動的に（ユーザーの`requiredActions`配列には現れない形で）`VERIFY_PROFILE`相当の要求を発生させる。

**対応**：[k8s/keycloak/test-fixtures-configmap.yaml](../k8s/keycloak/test-fixtures-configmap.yaml)のテストユーザー作成時に`email`（`example.invalid`ドメイン。RFC 2606で予約された実在解決されないドメイン）・`emailVerified=true`・`firstName`・`lastName`を明示的に設定するようにした。

### ログイントークンに`aud`クレームが実は含まれていなかった（解消済み）

**症状**：`frontend`クライアントでROPCログインして得たトークンをデコードすると、`aud`クレームが一切存在しなかった（`azp: frontend`はあるが`aud`は無し）。access-control-design.md「認証」節は「ログイントークンの`aud`は`frontend`（単一）」と明記している。

**原因**：`aud`クレームは、要求元クライアントに割り当てられたclient scope上のAudience protocol mapperから生成される（上記「Keycloak Standard Token Exchange V2」の項参照）。ログイン自体（Authorization Code / ROPC）はToken Exchangeではなく、かつfrontend自身への自己audience付与マッパーを持つscopeは一つも定義していなかったため、素のログイントークンには`aud`が乗らなかった。

**対応**：[k8s/keycloak/realm-configmap.yaml](../k8s/keycloak/realm-configmap.yaml)の`frontend`クライアント定義に、`included.client.audience: frontend`の`oidc-audience-mapper`を**client直下の"dedicated"protocolMappers**として追加した（clientScope経由ではない。理由：ログイン時は`scope`パラメータで何かを明示的に要求するわけではないため、"defaultClientScopes"にscopeを追加する方式より、常にそのクライアント宛てのトークンに付与される"dedicated"mapperの方が素直）。実機で`aud: "frontend"`が単独で乗ることを確認済み。Token Exchangeで`audience=fraud-mcp-server`等を要求した場合の交換後トークンには`frontend`は混入せず、要求した1つのaudienceだけになることも確認済み（ADR 0005の単一audience原則は崩れない）。

## Envoy / ext_authz / client_credentials（パターン②先行検証、fraud-detection-engine→account-service）

[k8s/ext-authz/deployment-client-credentials.yaml](../k8s/ext-authz/deployment-client-credentials.yaml)・[k8s/fraud-detection-engine/](../k8s/fraud-detection-engine/)・[scripts/verify-hop.sh](../scripts/verify-hop.sh)で実施（[ADR 0010](adr/0010-egress-listener-granularity.md)パターン②）。呼び出し元がsubject_tokenを一切持たない（Authorizationヘッダーなしでリクエストを組み立てる）点が①と異なり、ext_authz側が自分の資格情報でclient_credentialsトークンを取得・キャッシュしてから転送する構成にした。`account:freeze`のみを持つトークンでfreezeエンドポイントは200、read系エンドポイントは403（RBAC）になることを確認し、fraud-detection-engineがそれ以外の権限を持たないことも実機で裏付けた。

### clientScope/clientのdescriptionが255文字を超えると`--import-realm`自体が失敗する（`make up`が新規クラスタで必ず失敗する状態だった）

**症状**：`make up`（新規クラスタ作成→`make deploy`）を実行すると、Keycloakのrollout statusが必ずタイムアウトする。Podのログを見ると`ERROR: Database operation failed` / `ERROR: value too long for type character varying(255)`で起動に失敗し、`kubectl rollout restart`しても再現し続ける。フルスタックトレースを取ると`RepresentationToModel.createClientScope`→`MigrationUtils.updateProtocolMappers`→`ClientScopeAdapter.updateProtocolMapper`のflush中に発生していた。

**原因**：Keycloakのclient/clientScopeの`description`はDB上VARCHAR(255)相当の列に格納される。[k8s/keycloak/realm-configmap.yaml](../k8s/keycloak/realm-configmap.yaml)の`account:read`clientScopeの`description`が303文字あり、これが`--import-realm`実行時のバッチflushでオーバーフローしていた（例外自体は無関係に見える`updateProtocolMappers`のflush呼び出しで発生するが、Hibernateが同一トランザクション内の複数INSERTをバッチ化しているため、実際の原因行とスタックトレースの発生箇所が一致しない）。既存の長期稼働クラスタで再現した際は「何度も再インポートを繰り返した環境固有の劣化」と誤診断しかけたが、新規クラスタ（`make up`直後、初回`--import-realm`）でも100%再現することを確認し、realm-configmap.yamlの内容そのものに起因する決定的なバグだと判明した。

**対応**：`account:read`のdescriptionを255文字以内（215文字）に短縮した。他のclientScope/clientのdescriptionも確認し、いずれも255文字以内であることを確認済み。realm-configmap.yaml冒頭のコメントに「descriptionは255文字以内に収める」という制約を明記した。この制約は今後descriptionを書き足す際に再発しうるため、変更のたびに文字数を意識する必要がある。

### Keycloakの`--import-realm`は初回起動時のみ有効:realm-configmap.yamlの変更が実機に反映されていなかった

**症状**：ADR 0011（シナリオ変更）でrealm-configmap.yamlに追加した`fraud-detection-engine`クライアント・`account:unfreeze`スコープが、`kcadm.sh get clients`で実機に存在しないことが判明した。逆に、削除したはずの旧シナリオの`payment-service`クライアント・`account:transact`スコープが残っていた。test-fixtures Jobは`fraud-detection-engine`クライアントの`secret`を`kcadm update`しようとして対象が存在せず失敗し続けていた。

**原因**：[k8s/keycloak/deployment.yaml](../k8s/keycloak/deployment.yaml)のコメントに元々明記されていた通り、`--import-realm`はデータディレクトリが空の初回起動時のみ実質的な効果を持つ。ADR 0008でPostgresへ永続化するようになって以降、Keycloakは一度ブートストラップされたら二度と起動時インポートを行わない。そのため、realm-configmap.yamlをgitで何度更新しても、Keycloakを（realmを消さずに）再起動するだけでは一切反映されない。今回はさらに、直前の`kubectl apply -f k8s/keycloak/realm-configmap.yaml`自体を忘れていたため、ConfigMapオブジェクトそのものも古いままという問題が重なっていた（`kubectl apply`し忘れ→realm削除→再起動、の順でようやく最新化できた）。

**対応**：`gekko` realmを`kcadm.sh delete realms/gekko`で明示的に削除してからKeycloakをrolling restartし、次回起動時の`--import-realm`に最新のConfigMapを再インポートさせる手順を`make keycloak-reimport-realm`として整備した（Makefile参照）。realm内のテストデータ（`yamada-analyst`ユーザー・各クライアントの自動生成シークレット）は消えるが、`make deploy-verify-hop`のfixtures Jobが冪等に再構築するため実害はない。この手順は破壊的操作（realm削除）を伴うため`make deploy`には組み込まず、realm-configmap.yaml変更時に開発者が明示的に叩く手動ターゲットにした。`make deploy`自体を毎回realm再構築する挙動にしてしまうと、ADR 0008が検証したい「Postgresへの永続化」という前提が崩れてしまうため。

### Envoyの静的bootstrap設定もConfigMap変更をホットリロードしない:古いRBACパスパターンで動き続けていた

**症状**：`account-service`のRBAC設定にaccount:freeze用ポリシーを追加し、account:proposeの回帰テスト（`POST /accounts/{id}/unfreeze-proposals`）を実行したところ、Token Exchange自体は`scope=account:propose`で成功しているにもかかわらず、account-serviceのingress Envoyで「RBAC: access denied」となった。

**原因**：`kubectl exec`でaccount-service-stub Podの管理ポート(`:9901/config_dump`)を確認したところ、稼働中のEnvoyが読み込んでいるRBACポリシーのURLパターンが`^/accounts/[^/]+/freeze-proposals$`という、`unfreeze-proposals`への改名前の古い文字列のままだった。EnvoyはConfigMapマウントの`envoy.yaml`を起動時に1度だけ読み込むstatic bootstrap設定として扱い、ファイルが（kubeletのConfigMap同期により）後から更新されてもプロセスは再読み込みしない。`kubectl apply`でConfigMapを更新しても、それを参照するDeploymentのPod自体が再起動されない限り、実際に動いている設定は古いまま変わらない（Keycloakのrealm importと同種の落とし穴）。これは今回に限らず、account-service/fraud-mcp-serverのenvoy-configmap.yamlを変更するたびに起こりうる一般的なリスクだった。

**対応**：`make deploy-verify-hop`が`kubectl apply`の直後に、対象Deployment（`ext-authz-service`・`ext-authz-service-cc`・`account-service-stub`・`fraud-mcp-server-stub`・`fraud-detection-engine-stub`。いずれも状態を持たないスタブ）を常に`kubectl rollout restart`するよう修正した（Makefile参照）。ConfigMapに実質的な差分がない回でも毎回再起動するが、スタブなので無害。

### rolling restart直後、`kubectl get pod -l`のリストが旧Pod（terminating中）を先頭で返すことがある

**症状**：上記の対応でDeploymentを再起動するようにした直後に`scripts/verify-hop.sh`を実行すると、`ConnectionRefusedError`で失敗することがあった。

**原因**：`kubectl get pod -l app=X -o jsonpath='{.items[0]...}'`で先頭のPodを掴んでいたが、Podが`Terminating`中でも`.status.phase`は`Running`のままであり、かつリストの並び順は保証されない。新Podが`Running`になっていても、削除中の旧Pod（Envoyプロセスは既にリスナーを閉じている）を掴んでしまうことがあった。

**対応**：`--sort-by=.metadata.creationTimestamp`で最新のPodを選ぶ`newest_pod()`ヘルパーを`scripts/verify-hop.sh`に追加し、fraud-mcp-server・account-service・fraud-detection-engineいずれのPod選択もこれ経由に統一した。

## k3d / WSL2

### k3dクラスタが起動直後にAPIサーバーへ一切到達できない（cgroup v1非互換）

**症状**：`k3d cluster create`はエラーなく完了し、`k3d cluster list`もコンテナも正常に見えるが、`kubectl get nodes`が永久に`connection refused`（後にTLSレベルの`EOF`）を返し続ける。

**原因**：2段階あった。

1. まず`k3d kubeconfig merge`が既定では`~/.kube/config`にマージされず、`-d`（`--kubeconfig-merge-default`）を明示しないと別ファイル（`~/.config/k3d/kubeconfig-<cluster>.yaml`）に書き出されるだけだった
2. サーバーアドレスが`https://0.0.0.0:<port>`のまま書き込まれることがあり、クライアント側からの接続先として無効（`0.0.0.0`はワイルドカードbindアドレスであり接続先ではない）だった。`127.0.0.1`に書き換える必要がある
3. 上記を解消してもなお`EOF`が続いた場合、コンテナ内のk3sログ（`docker logs <server-node>`）を確認すると`kubelet is configured to not run on a host using cgroup v1`というエラーで起動→シャットダウンを無限に繰り返していた。DockerのCgroup Versionがv1（`docker info`で確認）だと、k3d既定同梱の新しいk3sバージョンのkubeletが起動を拒否する

**対応**：
- kubeconfigのマージは`k3d kubeconfig merge <cluster> -d -s`を使う
- サーバーアドレスの`0.0.0.0`は`sed`等で`127.0.0.1`に置換する
- 恒久対応はWSL2側のcgroup v2化。Windows側`%UserProfile%\.wslconfig`に以下を追記し、`wsl --shutdown`後にWSL2を再起動する。

  ```ini
  [wsl2]
  kernelCommandLine = cgroup_no_v1=all
  ```

  `/etc/wsl.conf`の`[boot] systemd=true`だけでは不十分（systemdは起動するが、cgroup v1/v2のhybridモードのままになる。`/proc/cmdline`に`cgroup_no_v1=all`を明示的に渡す必要がある）。`stat -fc %T /sys/fs/cgroup/`が`cgroup2fs`、`docker info | grep -i cgroup`が`Cgroup Version: 2`になれば成功。cgroup v2化後は、k3d既定（最新版）のk3sイメージでも問題なく起動することを確認済み

**検証**：cgroup v1のまま`rancher/k3s:v1.32.13-k3s1`（古めのバージョン）に固定した場合は正常起動することを確認し、原因の切り分けを行った。cgroup v2化後にバージョン固定を外し、最新版でも`Ready`になることを確認済み。

### 空きメモリ枯渇でもAPIサーバーが到達不能になる（cgroup v1問題とは別原因、紛らわしい）

**症状**：cgroup v1問題を解消する前の段階で、同様に`kubectl get nodes`が到達不能になる事象に遭遇した。

**原因**：別プロジェクト（docker composeスタック、14コンテナ）が38時間前から起動したままで、ホストの空きメモリが310MiB・スワップ使用量1.2GiBまで逼迫していた。

**対応**：不要なコンテナスタックを`docker compose down`で停止し、メモリを解放。ただし今回はこれだけでは解決せず、上記のcgroup v1問題が別途存在していた。**症状が同じでも原因が複数あり得る**ため、`docker logs`でコンテナ内部の実際のエラーメッセージを確認するまで原因を断定しないこと。

### WSL2に見える空きメモリが、ホストの実メモリ量より大幅に少ない（WSL2既定の上限）

**症状**：PostgreSQL（[ADR 0008](adr/0008-per-service-datastore-strategy.md)）を追加した直後、WSL2内`free -h`の空き容量が1GiB未満まで逼迫しているように見え、Keycloak PodのHTTPヘルスチェック応答が遅れて`startupProbe`の警告イベントが多発した（実際にはPodは0回再起動でクラッシュはしていなかったが、体感として「不安定」に見えた）。ホスト自体は16GBのメモリを持つにもかかわらず、WSL2内`free -h`のtotalは7.6GiBしかなかった。

**原因**：`.wslconfig`に`memory=`を明示していない場合、WSL2は既定で「ホスト物理メモリの約50%、または8GBの小さい方」までしかVMに割り当てない（Microsoft公式のWSL2既定値）。16GBの50%=8GBに近い7.6GiBという観測値はこの既定上限と整合する。ホストの実メモリが枯渇していたわけではなく、WSL2側の自己制限だった。

**対応**：`%UserProfile%\.wslconfig`（`[wsl2]`セクション）に`memory=12GB`を追記し、Windows側で`wsl --shutdown`を実行後にWSL2を再起動する（この操作はWSL2内の全プロセス・Docker・k3dクラスタのコンテナを道連れに終了させるため、WSL2内から`wsl.exe --shutdown`を自分で呼び出すのではなく、Windows側のターミナルから実行すること）。再起動後は`free -h`のtotalが増えていることで反映を確認できる。k3dクラスタ・Podはdockerのボリュームにデータが残っているため`make status`で状態を見て、必要なら`make up`で復帰させる（実機で確認済み：Podは自動的に`RESTARTS: 1`で復帰し、Keycloakの永続化データ・管理者パスワードもPostgresへの永続化により無傷だった）。

併せて、Keycloak Deployment（[k8s/keycloak/deployment.yaml](../k8s/keycloak/deployment.yaml)）のreadiness/livenessProbeに`timeoutSeconds`を明示していなかった点も是正した。既定の1秒だと、このような資源逼迫時にGC・CPU競合で応答が1秒を超えただけでlivenessProbeが誤検知し、正常なPodを強制再起動させかねない。

## SPIFFE/SPIRE mTLS（fraud-mcp-server→account-serviceの1ホップ、ADR 0012）

[k8s/spire/](../k8s/spire/)・[k8s/account-service/envoy-configmap.yaml](../k8s/account-service/envoy-configmap.yaml)・[k8s/fraud-mcp-server/envoy-configmap.yaml](../k8s/fraud-mcp-server/envoy-configmap.yaml)で実施。fraud-mcp-server→account-serviceのホップがmTLS+ALPN h2経由で200・期待した`x-auth-*`ヘッダーで到達することを確認し、既存のfraud-detection-engine→account-service（パターン②、plaintext）が壊れていないことも確認した。

### Envoy `TlsParameters`に`alpn_protocols`フィールドは存在しない

**症状**：`common_tls_context.tls_params.alpn_protocols`を設定してEnvoyを起動すると、`INVALID_ARGUMENT: ... message envoy.extensions.transport_sockets.tls.v3.TlsParameters ... no such field: 'alpn_protocols'`で起動時エラーになった。

**原因**：`alpn_protocols`は`CommonTlsContext`直下のフィールドであり、`TlsParameters`（TLSバージョン・cipher suite等を持つ別メッセージ）には存在しない。設計時の参考資料の誤りをそのまま反映していた。

**対応**：`common_tls_context.alpn_protocols: ["h2"]`のように、`tls_params`と同じ階層（`common_tls_context`直下）に配置するよう訂正した。

### SDS(xDS)を使う場合、bootstrap設定に`node.id`/`node.cluster`が必須

**症状**：`tls_certificate_sds_secret_configs`でSPIRE AgentのSDSを参照する設定にした途端、`TlsCertificateSdsApi: node 'id' and 'cluster' are required. Set it either in 'node' config or via --service-node and --service-cluster options.`で起動時エラーになった。

**原因**：SDSはxDSプロトコルの一種であり、DiscoveryRequestに`Node`識別子を含める必要があるが、これまでの素のHTTPフィルタチェーンだけの構成では`node:`セクションが一度も必要にならなかった。

**対応**：両サービスのenvoy.yaml bootstrapに`node: { id: <service>-envoy, cluster: <service> }`を追加した。

### SPIRE Agent SDSの検証コンテキストは`ROOTCA`という固定のマジック名でしか参照できない

**症状**：`validation_context_sds_secret_config.name`に信頼ドメイン名（`gekko.internal`）を設定したところ、SPIRE Agentのログに`rpc error: code = InvalidArgument desc = workload is not authorized for the requested identities ["gekko.internal"]`が出続け、SDSのシークレット配信が失敗し続けた（`upstream connect error ... TLS error: Secret is not supplied by SDS`で全リクエストが503）。

**原因**：SPIRE AgentのSDS実装は、リソース名として`"default"`（自分のSVID）・`"ROOTCA"`（自トラストドメインのバンドル）・`"ALL"`（全フェデレーションバンドル）の3つの固定マジック名だけを特別扱いする。それ以外の文字列は「そのSPIFFE IDへのSVIDリクエスト」と解釈されるため、信頼ドメイン名のような任意の文字列を渡すと、該当するworkload registration entryが存在せず拒否される。

**対応**：`validation_context_sds_secret_config.name`を`"ROOTCA"`に固定した。

### account-serviceの共有ingressリスナーにmTLSを必須化すると、SPIRE化していない既存ホップが壊れる

**症状**：account-serviceのingressリスナー（単一）にmTLS必須の`transport_socket`を設定したところ、fraud-mcp-server→account-service（今回の対象）は通ったが、既に検証済みだったfraud-detection-engine→account-service（パターン②、client_credentials、SPIRE化はスコープ外）が`503 upstream connect error ... reset reason: connection termination`で壊れた。

**原因**：account-serviceのingressリスナーは全呼び出し元が共有する単一のリスナーであり、SPIRE化した呼び出し元専用のmTLS要件を「そのリスナー全体」に課すと、SPIRE化していない他の呼び出し元も等しく拒否される。ADR 0012のスコープはfraud-mcp-server→account-serviceの1ホップのみで、fraud-detection-engineのSPIRE化は明示的にスコープ外としていたため、この副作用は避ける必要があった。

**対応**：`filter_chain_match.transport_protocol`でTLS接続とplaintext接続を別の`filter_chains`エントリに振り分け、同じHTTPフィルタチェーン（jwt_authn/rbac/lua/router）を両方に適用する構成にした。ただしこれには重要な限界がある：**plaintextでの到達自体は依然として可能であり、mTLSは「TLSを選んだ場合にのみ強制される」任意の防御層にとどまる**。account-service側はL4（filter_chain選択）の時点ではHTTPパスを見られないため、「読み取り・提案系のパスだけmTLS必須、freezeパスだけplaintext許可」のようなパス単位の強制はできない。この構成でR2（相互認証）を額面通り満たすのは実質的にfraud-mcp-server経由の呼び出しのみであり、account-service全体としては「plaintextでの到達自体を遮断できていない」ことを既知の限界としてADR 0012・backlog.mdに明記した。

### `filter_chain_match.transport_protocol`は`tls_inspector`リスナーフィルタなしでは機能しない

**症状**：上記のfilter_chain分割を導入した直後、今度はfraud-mcp-server→account-serviceの方が`TLS_error:...WRONG_VERSION_NUMBER`で失敗するようになった（TLSで接続しているはずなのにplaintext側のfilter_chainに落ちていた）。

**原因**：`filter_chain_match.transport_protocol: "tls"`は、接続がTLSかどうかを判定済みの実行時メタデータを参照するだけであり、その判定自体は`envoy.filters.listener.tls_inspector`リスナーフィルタがClientHelloを覗き見て行う。このリスナーフィルタを追加し忘れていたため、全接続が「未判定」＝`raw_buffer`扱いになり、TLS用のfilter_chainに一切到達していなかった。

**対応**：リスナーに`listener_filters: [{ name: envoy.filters.listener.tls_inspector }]`を追加した。

### `bitnami/kubectl`はバージョン固定タグを提供しなくなっていた（2025年のBitnami Secure Images移行）

**症状**：`bitnami/kubectl:1.31`で`ImagePullBackOff`（`not found`）になった。

**原因**：Bitnamiが2025年に実施したBitnami Secure Imagesへの移行で、無料で公開されるタグが`latest`のみになり、過去のようなバージョン固定タグ（`1.31.1`等）は有料サブスクリプション向けになった。このリポジトリの「イメージは全てバージョン固定する」慣習と両立しない。

**対応**：`rancher/kubectl`（シェルを一切含まないscratch系イメージで、bashスクリプトの実行自体ができなかった）を経て、最終的に`alpine/k8s:1.35.5`（kubectl＋bash＋標準ユーティリティ同梱、タグをk8sサーバーバージョン`v1.35.5+k3s1`に一致させられる）に切り替えた。

### 公式`ghcr.io/spiffe/spire-server`イメージにはシェルがなく、バイナリもPATH上にない

**症状**：`kubectl exec spire-server-0 -- spire-server entry create ...`が`exec: "spire-server": executable file not found in $PATH`で失敗した。`sh -c`でラップして調査しようとしても`exec: "sh": executable file not found in $PATH`で同様に失敗した。

**原因**：公式イメージはdistroless系で、シェルを含まない。`spire-server`バイナリ自体は`/opt/spire/bin/spire-server`に存在するが、`PATH`には含まれていない。

**対応**：`kubectl exec`では常に`/opt/spire/bin/spire-server`を絶対パスで直接起動するようにした（`kexec()`ヘルパーに集約）。

### `envoyproxy/envoy`イメージにはcurl/wgetが入っていない

**症状**：Envoy管理API（`:9901/stats`）をPod内から叩いて統計を確認しようとしたところ、`curl`が`exec: "curl": executable file not found in $PATH`で失敗した。

**原因**：Envoyの公式イメージはHTTPクライアントツールを同梱しない。ただし`bash`自体は含まれている。

**対応**：`bash`の`/dev/tcp/<host>/<port>`疑似デバイスで生のTCPソケットを開き、素のHTTPリクエストを`printf`で組み立てて送る方式にした（[scripts/verify-hop.sh](../scripts/verify-hop.sh)）。

## NetworkPolicy（gekko namespace全体のL3/4 default-deny、ADR 0018）

### kube-router netpolはDROPではなくREJECT(即時RST)でブロックする

**確認内容**：default-deny適用後、ラベルの無いエフェメラルPodからpostgres:5432・keycloakのhttp-mgmt:9000へ`curl -v`で接続を試みたところ、いずれも`Connection refused`（`failed to connect ... after 0-1 ms`）で即座に失敗した。事前は「DROPによる`--max-time`一杯までのタイムアウト」を想定していたが、実際はREJECT相当（TCP RST即返却）だった。このクラスタのkube-router netpol実装の挙動として記録する。

### kubeletのprobe・kubectl port-forwardは、ノードが属するdocker networkのサブネットからのingress許可で問題なく機能した

**確認内容**：Keycloakのhttp-mgmt:9000（readiness/liveness/startupProbe）とedge-proxyの80番（`kubectl port-forward`経由の外部アクセス、ADR 0004）を、ノードIP単体ではなくk3dのdocker networkサブネット全体（`172.19.0.0/16`）からのingressとして許可した。`make deploy-network-policy`適用後、Keycloak Podに再起動・CrashLoopBackOffは発生せず（probe疎通は継続）、`make keycloak-forward`経由の`scripts/verify-hop.sh`（ROPCログイン等、port-forward前提のステップ含む）も全ステップ成功した。事前にbacklog.mdで「default-denyにすると素朴にはプローブが壊れる」と懸念していた点は、ノードIPを含むCIDR単位での許可で解消できることを確認した。

### DNS解決は`kube-system`/`kube-dns`への53番egress許可のみで全Podに行き渡った

**確認内容**：`podSelector: {}`で全Pod共通の1本のNetworkPolicy（`k8s/network-policy/allow-dns.yaml`）だけを追加し、個々のサービスのNetworkPolicyには一切DNS関連のegressルールを書いていない。この状態で`postgres`・`keycloak.gekko.svc.cluster.local`等、全てのService名前解決を伴う既存フローが問題なく成功した。namespaceラベル`kubernetes.io/metadata.name: kube-system`はKubernetes標準の自動付与ラベルで、k3d(v1.35系)でも別途手動付与する必要はなかった。

## DPoP送信者拘束（fraud-mcp-server→account-serviceの1ホップ、ADR 0013。ADR 0015で撤去済み）

**このセクションが指す実装（`k8s/dpop-verifier/`等）はADR 0015で撤去済み。** 以下は撤去前の実機検証で得た知見で、将来DPoPを再検討する際の参考として残す。

（追記）ADR 0015でマニフェストは削除されたが、クラスタ上の`Deployment/dpop-verifier`・`ConfigMap/dpop-verifier-app`自体は削除し忘れられ、対応するマニフェストが無いまま稼働し続けていた。ADR 0018のNetworkPolicy接続グラフ調査で発覚し、`kubectl delete`で削除済み（2026-09-16）。

このPodにはNetworkPolicyの許可ルールが一つも存在しなかったため、ADR 0018のdefault-deny適用後は（削除前の時点でも）ingress/egressともに事実上封じ込められていた。マニフェストに存在しない野良Podは対応する許可ルールも持ち得ないため自動的に隔離される、という副次的な安全効果をNetworkPolicyのdefault-denyが持つことの実例として記録する。

[k8s/ext-authz/app-configmap.yaml](../k8s/ext-authz/app-configmap.yaml)・`k8s/dpop-verifier/`（削除済み）・[k8s/account-service/envoy-configmap.yaml](../k8s/account-service/envoy-configmap.yaml)で実施。正常系（proof検証成功、200）・異常系（鍵不一致・iat失効、いずれも401）を`dpop-verifier`への直接呼び出しで確認し、fraud-mcp-server→account-serviceの実際の経路（DPoP拘束されたトークン、`Authorization: DPoP <token>`スキーム）でも200が通ることを確認した。

### Token ExchangeでのDPoP拘束は「引き継がれる」のではなく、要求者が自分の鍵で作り直す

**症状**：ドキュメントの「同一クライアント・同一鍵でなければ自己再交換のDPoP拘束は成立しない」という記述から、fraud-mcp-serverがfrontend発行のsubject_token（azpがfrontendのまま）を別クライアント・別鍵で再exchangeすると失敗するのではと懸念した。

**原因/実機確認**：実際には2パターンに分かれる。subject_tokenに**既存の拘束が無い**場合（今回採用した構成。frontendはDPoPを有効化していない）、fraud-mcp-serverが自分のクライアント（`dpop.bound.access.tokens=true`）で自分の鍵のproofを添えて再exchangeすると、`cnf.jkt`がfraud-mcp-server自身の鍵に新しく拘束されたトークンが**成功裏に**発行される（200）。一方、subject_tokenに**既存の拘束がある**場合（frontend自身もDPoPを有効化し、frontend自身の鍵で拘束済みのトークンをfraud-mcp-serverが別鍵で再exchangeしようとするケースを実機で再現）、Keycloakは`400 invalid_request: "Sender-constrained token exchange rejected as the token was not issued for the requesting client"`でexchange自体を拒否する（Keycloak issue #51205が指摘する状況）。

**対応**：このプロジェクトの委任チェーン設計では、後続で再exchangeされることの無い「チェーンの最後のクライアント」だけがDPoP拘束を安全に有効化できる、という結論に至った。fraud-mcp-server→account-serviceはまさにこの位置に当たるため採用し、frontend→fraud-mcp-server向けのexchangeへのDPoP適用は（frontend実装時であっても）見送ることをADR 0013に明記した。

### `ecdsa`パッケージの起動時pip installがreadinessProbe無しだとEnvoyのext_authzに403を出させる

**症状**：`make deploy-verify-hop`直後に`scripts/verify-hop.sh`を実行すると、fraud-mcp-server→account-serviceの呼び出しが`403`（本文なし）で失敗することがあった。ext-authz-serviceのログを確認すると、該当リクエストの時間帯に`ALLOW`/`DENY`のログ行が一切無く、リクエスト自体がハンドラへ到達していなかった。

**原因**：`command: pip install --quiet ecdsa && exec python3 /scripts/app.py`は、`pip install`の数秒間はポート8080でリッスンしていない。`kubectl rollout status`はコンテナプロセスが起動したことしか見ておらず（readinessProbe未設定だったため）、Podは実際にはまだ`ecdsa`をインストール中でもReady扱いになっていた。この間にEnvoyのext_authzがconnection refusedを受け、`failure_mode_allow: false`によりfail closeして403を返していた。

**対応**：`ext-authz-service`・`dpop-verifier`双方のDeploymentに、ポート8080へのTCP `readinessProbe`（`initialDelaySeconds: 2`）を追加した。これにより`kubectl rollout status`が実際にリッスンを開始するまで待つようになり、`make deploy-verify-hop`直後に`scripts/verify-hop.sh`を実行しても再現しなくなったことを確認済み。

### Envoyの`jwt_authn`は既定で`Authorization: Bearer <token>`しか見ない

**症状**：ext-authz-serviceがDPoP拘束されたトークンを`Authorization: DPoP <token>`スキームで返すよう変更したところ（RFC 9449の仕様通り）、account-service側の`jwt_authn`がトークンを一切抽出できず認証エラーになった。

**原因**：`jwt_authn`の`providers`は`from_headers`を明示しない場合、既定で`Authorization`ヘッダーの`Bearer `プレフィックスのみを見る。

**対応**：account-serviceのTLS filter_chain（fraud-mcp-server専用）のjwt_authn providerに`from_headers: [{name: "Authorization", value_prefix: "DPoP "}]`を追加した。plaintext filter_chain（fraud-detection-engine用、DPoP非対象）は既定の`Bearer `のままにした（同じjwt_authn設定を全filter_chainで共有していないため、片方だけ変更できる。ADR 0012の実機検証で導入したfilter_chain分割の副産物）。

## ext-authz-serviceの身元検証ギャップとKeycloakクライアント認証方式の調査（gekko_07本体は未変更、スパイクのみ）

現行のext-authz-service（ADR 0002/0016）は、呼び出し元（例：fraud-mcp-server）のKeycloakクライアントのclient_secretを保持し、呼び出し元に代わってToken Exchangeを行う。この構造には身元検証上のギャップがある：Keycloakが検証するmTLS接続の身元（ext-authz-service自身のSPIFFE ID）と、Keycloakへ主張しているclient_id（呼び出し元のもの）が一致しない。Keycloakの認可判定は最終的に「client_secretを知っているか」に基づいており、「本当にそのワークロードが要求しているか」を検証できていない。この欠落を埋める方式として、RFC 8705（mTLSクライアント認証）・Delegationモデル（`act`/`actor_token`）・KeycloakネイティブのSPIFFE対応、の3方向を使い捨てDockerコンテナ（`docker run quay.io/keycloak/keycloak:26.7.0`、gekko_07クラスタ本体には一切触れず）で調査した。**以下はいずれもスパイク段階の記録であり、gekko_07本体（`k8s/`以下）はまだ変更していない。**

### RFC 8705（`client-x509`）はSubject DNのみを見る。SPIFFEのURI SANは見ない

**症状**：呼び出し元自身のSPIRE発行X.509-SVID（URI SANにSPIFFE IDを持つ）を、Keycloakの`clientAuthenticatorType: client-x509`でそのままクライアント証明書として使えないか検証した。

**原因**：`X509ClientAuthenticator.java`（Keycloak 26.7.0）をバイトコードレベルで確認したところ、識別子の抽出は`certificate.getSubjectDN().getName()`のみで、SAN（Subject Alternative Name）は一切参照しない。`x509.subjectdn`属性（正規表現可）でのSubject DN一致だけがサポート対象。SPIFFE仕様はリーフSVIDのSubject DNを空にすることを推奨しており、SPIRE本体もそれに準拠しているため、実際のSVIDでは一致させる対象そのものが存在しない。gekko_07の`k8s/spire/server-configmap.yaml`の`ca_subject`はルートCA自身の発行者名の設定であり、ワークロードへ発行するリーフSVIDのSubject DNをテンプレート化する仕組みではない。Keycloak公式Issue #41907（2025年8月、Open）が「SPIFFE/SPIREでのクライアント認証は未対応」と明記しており、設定不足ではなくKeycloak本体の既知の未対応機能であることを確認した。

**対応**：X.509-SVID/RFC 8705経由の道は棄却し、JWT-SVIDベースの方式（下記）を採用する方向とした。

### KeycloakネイティブのSPIFFE JWT-SVID対応（`federated-jwt`、Preview機能）は動く。ただし`client_assertion_type`を間違えると無言で失敗する

**症状**：Keycloak 26.7.0には`spiffe`・`client-auth-federated`というfeature flag、`clientAuthenticatorType: federated-jwt`（表示名"Signed JWT - Federated"）、`identity-provider`の`providerId: spiffe`（`trustDomain`・`bundleEndpoint`設定）が実在する。これらを設定し、クライアント属性`jwt.credential.issuer`（IdPエイリアス参照）・`jwt.credential.sub`（期待するSPIFFE ID文字列）を正しく設定した上で、`iss`/`sub`が一致し正しく署名されたJWTを`client_assertion`として送っても、`client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer`（汎用RFC 7523の値）を使うと**常に`invalid_client`で失敗し、エラーメッセージも一切のTRACEログも手がかりを残さない**（自前で立てたJWKSバンドルエンドポイントへのHTTPリクエストすら発生しない＝署名検証まで到達していない）。

**原因**：`FederatedJWTClientAuthenticator.authenticateClient()`をバイトコードレベルで確認したところ、`client_assertion_type`の値で`findStrategy()`が担当ストラテジーを検索し、一致するストラテジーが無ければ（あるいは`lookup()`が呼び出し元クライアントを特定できなければ）**例外もfailure()も呼ばず黙ってreturnする**。汎用の`urn:ietf:params:oauth:client-assertion-type:jwt-bearer`は、SPIFFE用ではなく「`sub`＝`client_id`」を前提とする旧来のデフォルトストラテジーにマッチしてしまい、`sub`にSPIFFE IDそのものを入れている今回のJWTでは当然クライアントが見つからず、素通りしていた。`SpiffeConstants.class`を直接読んだところ、SPIFFE用ストラテジーに対応する正しい値は`urn:ietf:params:oauth:client-assertion-type:jwt-spiffe`だった。

**対応**：`client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe`に修正したところ、Keycloakが実際にバンドルエンドポイントへHTTPリクエストを送り、署名検証に成功し、client_secret無しで`"azp": "fraud-mcp-server"`のアクセストークンが発行されることを確認した（HTTP 200）。第三者製SPI（`christian-posta/spiffe-svid-client-authenticator`）を使わずとも、Keycloak本体のPreview機能だけでJWT-SVIDベースのクライアント認証が成立することを実証した。ただし`spiffe`はKeycloakの成熟度区分で"Preview"（`token-exchange-delegation`等の"Experimental"より一段階上だが安定版ではない）であり、関連するAdmin UI側には既知の未解決バグ（Issue #42634・#42044・#51682）がある点は留意する。gekko_07本体（実際のSPIRE JWT-SVID発行・Envoy/ext-authz-serviceの置き換え）への統合はまだ行っていない。

### Stage 1a：gekko_07の実クラスタ上で、SPIRE発行の本物のJWT-SVID＋SPIRE Serverのbundle endpointでToken Exchangeが成立することを確認した（gekko_07本体は未コミット）

前項の使い捨てDockerコンテナでの検証を、gekko_07の実k3dクラスタ（本物のSPIRE Server/Agent、本物のKeycloak）で再現した。以下は全て実機で確認済みだが、まだ`k8s/`配下のファイルには反映していない（`kubectl`で一時的に生きているクラスタへ直接適用しただけ）。

**SPIRE Server側**：`server.conf`に以下の`federation.bundle_endpoint`ブロックを追加すると、SPIRE ServerがHTTPSでtrust bundle（JWKS形式、X.509-SVID用CAと`"use": "jwt-svid"`のJWT署名鍵の両方を含む）を公開する。

```hcl
federation {
  bundle_endpoint {
    address = "0.0.0.0"
    port    = 8443
    refresh_hint = "5m"
    profile "https_web" {
      serving_cert_file {
        cert_file_path = "..."
        key_file_path  = "..."
        file_sync_interval = "1h"
      }
    }
  }
}
```

`serving_cert_file`ブロックの`file_sync_interval`を省略すると`time: invalid duration ""`で起動時に即クラッシュする（エラーメッセージにどの設定キーが原因かの手がかりが一切無い。`refresh_hint`が原因ではないかとまず疑ったが無関係だった）。証明書はこのbundle endpoint自体のTLS終端用（trust bundleの中身とは無関係）で、SPIRE発行のSVIDではなく別途用意した自己署名証明書で問題ない。Keycloak側にはこの証明書（またはその発行者）を`KC_TRUSTSTORE_PATHS`で信頼させる必要がある。

**JWT-SVIDの取得**：SPIRE Workload API（gRPC）をPythonから直接叩く代わりに、`ghcr.io/spiffe/spire-agent`イメージに同梱の`/opt/spire/bin/spire-agent api fetch jwt -audience <aud> -socketPath /run/spire/sockets/agent.sock`をサブプロセス実行するだけで取得できた（standalone実行、シェル不要）。取得したJWT-SVIDは`sub`にSPIFFE IDを持つがKeycloakが要求する`iss`クレームは持たない（実機確認済み。`SpiffeClientAssertionStrategy`は`iss`ではなく`sub`のtrust domain部分とクライアント属性`jwt.credential.sub`の一致だけを見ている）。attestationは実行するPod自身のラベル/サービスアカウントに紐づくため、呼び出し元(fraud-mcp-server)と同じselector（`k8s:pod-label:app:fraud-mcp-server`等）を満たすPodからでないと`rpc error: code = PermissionDenied desc = no identity issued`になる——共有Podでは呼び出し元自身のJWT-SVIDを取得できないという制約を実機でも再確認した。

**Keycloak側**：`identity-provider`(`providerId: spiffe`、`trustDomain`は`spiffe://`スキーム付きで指定しないと"Invalid trust domain name"で弾かれる)を追加し、`fraud-mcp-server`クライアントを`clientAuthenticatorType: federated-jwt`＋`jwt.credential.issuer`(IdPエイリアス)/`jwt.credential.sub`(SPIFFE ID)に変更。

**実際に通った検証**：`client_credentials`グラントでは`{"error":"unauthorized_client","error_description":"Client not enabled to retrieve service account"}`（=クライアント認証自体は成功、fraud-mcp-serverの`serviceAccountsEnabled: false`が理由でグラント自体が拒否されただけ）。既存のverify-hop.sh同様の2段階委任（frontendでログイン→frontendがfraud-mcp-server宛てにToken Exchange→そのDELEGATED_TOKENをsubject_tokenにfraud-mcp-server自身がaccount-service宛てにToken Exchange、ただし`client_secret`の代わりに`client_assertion_type=...jwt-spiffe`＋`client_assertion=<JWT-SVID>`を使用）を実行したところ、**HTTP 200でaccount-service向けアクセストークンが発行された**。RFC 8705が不成立と判明した際の懸念（Keycloakネイティブpreview機能が実際に機能するか）は、この実クラスタでの成功により解消したと判断できる。
