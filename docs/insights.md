# 実装で得た気づき・罠

実装を進める過程で見つかった、再発しそうな罠や実機検証で判明した仕様上の落とし穴を記録するナレッジベース。設計判断そのものは[architecture.md](architecture.md)、未着手の改善項目は[backlog.md](backlog.md)を参照。

**注意**：以下は発見当時の実装（サービス名・ファイルパス）に基づく記述をそのまま残している。`ext-authz-service`・`ext-authz-service-cc`・`dpop-verifier`は、[ADR 0019](adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)/[0020](adr/0020-fraud-detection-engine-identity-gap-and-client-credentials-federated-jwt.md)/[ADR 0015](adr/0015-dpop-removal-and-fraud-detection-engine-mtls.md)でいずれも撤去済みで、現在は存在しない（現在の構成は[architecture.md](architecture.md)参照）。ただしEnvoy/Keycloak/SPIREそのものの仕様に関する知見は、後継のサイドカー（`token-exchange`・`client-credentials`）にもそのまま当てはまる。

各項目は原則として次の構造で記述する（当てはまらない要素は省略する）。

- **症状**：どんな問題・違和感が観察されたか
- **原因**：実機検証や調査で判明した根本原因
- **対応**：実際に取った対応・回避策

## Envoy / ext_authz / Token Exchange（1ホップ先行検証、fraud-mcp-server→account-service）

[k8s/account-service/](../k8s/account-service/)・[k8s/fraud-mcp-server/](../k8s/fraud-mcp-server/)・[scripts/verify-hop.sh](../scripts/verify-hop.sh)で実施（当時のToken Exchange実行主体は共有`ext-authz-service`。現在は`k8s/fraud-mcp-server/token-exchange-app-configmap.yaml`のPod内サイドカー、[ADR 0019](adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)）。`account:read`/`account:propose`いずれもEnvoy egress(ext_authzによるToken Exchange)→Envoy ingress(jwt_authn/rbac/合言葉)→アプリ、という経路全体が200で通り、期待した`x-auth-*`ヘッダーが転送されることを確認した。Pod外からアプリポートへの直接到達が拒否されることも確認した（ADR 0009主対策①）。

### ext_authz(HTTPモード)のcontext_extensionsはgRPCモード限定

**症状**：ADR 0010の設計通り`ExtAuthzPerRoute.check_settings.context_extensions`でscopeをext_authzサービスへ渡そうとしたが、Envoy公式v3 APIリファレンスを確認すると「These settings are only applied to a filter configured with a grpc_service.」と明記されていた。ADR 0002はHTTPモードのext_authzを採用しているため、この方式はそもそも機能しない。

**原因**：`context_extensions`はgRPCモードのCheckRequest.attributes専用の仕組みで、HTTPモードには伝達経路がない。

**対応**：HTTPモードのext_authzは、`Host`・`Method`・`Path`・`Content-Length`・`Authorization`を`authorization_request.allowed_headers`の設定と無関係に常に自動転送することも確認済み。ext_authzサービス自身が、この自動転送される`Host`（audience）と`Path`+`Method`（access-control-design.md 表2の対応表で解決するscope）だけからToken Exchangeリクエストを組み立てるよう設計を訂正した（現在は[k8s/fraud-mcp-server/token-exchange-app-configmap.yaml](../k8s/fraud-mcp-server/token-exchange-app-configmap.yaml)）。ADR 0010・architecture.md §3を直接訂正済み（決定自体ではなく実装メカニズムの誤りだったため、新ADRは起こしていない）。

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

[k8s/fraud-detection-engine/](../k8s/fraud-detection-engine/)・[scripts/verify-hop.sh](../scripts/verify-hop.sh)で実施（[ADR 0010](adr/0010-egress-listener-granularity.md)パターン②。当時のToken取得実行主体は共有`ext-authz-service-cc`。現在は`k8s/fraud-detection-engine/client-credentials-app-configmap.yaml`のPod内サイドカー、[ADR 0020](adr/0020-fraud-detection-engine-identity-gap-and-client-credentials-federated-jwt.md)）。呼び出し元がsubject_tokenを一切持たない（Authorizationヘッダーなしでリクエストを組み立てる）点が①と異なり、ext_authz側が自分の資格情報でclient_credentialsトークンを取得・キャッシュしてから転送する構成にした。`account:freeze`のみを持つトークンでfreezeエンドポイントは200、read系エンドポイントは403（RBAC）になることを確認し、fraud-detection-engineがそれ以外の権限を持たないことも実機で裏付けた。

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

### `spire-entries` Jobの完了待ちが60秒だと初回実行時にタイムアウトすることがある

**症状**：`make deploy-spire`実行時、`kubectl wait --for=condition=complete job/spire-entries --timeout=60s`が、特に新規クラスタでの初回実行時にタイムアウトすることがあった。

**原因**：`spire-entries` Jobの`wait-for-spire-server` initコンテナが、spire-server/agentが起動直後でまだ準備できていない状態からポーリングを始めるため、実測で60秒を超えることがある。

**対応**：`Makefile`の`deploy-spire`ターゲットでタイムアウトを180秒に拡張した。

## NetworkPolicy（gekko namespace全体のL3/4 default-deny、ADR 0018）

### kube-router netpolはDROPではなくREJECT(即時RST)でブロックする

**確認内容**：default-deny適用後、ラベルの無いエフェメラルPodからpostgres:5432・keycloakのhttp-mgmt:9000へ`curl -v`で接続を試みたところ、いずれも`Connection refused`（`failed to connect ... after 0-1 ms`）で即座に失敗した。事前は「DROPによる`--max-time`一杯までのタイムアウト」を想定していたが、実際はREJECT相当（TCP RST即返却）だった。このクラスタのkube-router netpol実装の挙動として記録する。

### kubeletのprobe・kubectl port-forwardは、ノードが属するdocker networkのサブネットからのingress許可で問題なく機能した

**確認内容**：Keycloakのhttp-mgmt:9000（readiness/liveness/startupProbe）とedge-proxyの80番（`kubectl port-forward`経由の外部アクセス、ADR 0004）を、ノードIP単体ではなくk3dのdocker networkサブネット全体（`172.19.0.0/16`）からのingressとして許可した。`make deploy-network-policy`適用後、Keycloak Podに再起動・CrashLoopBackOffは発生せず（probe疎通は継続）、`make keycloak-forward`経由の`scripts/verify-hop.sh`（ROPCログイン等、port-forward前提のステップ含む）も全ステップ成功した。事前にbacklog.mdで「default-denyにすると素朴にはプローブが壊れる」と懸念していた点は、ノードIPを含むCIDR単位での許可で解消できることを確認した。

**後日談（[ADR 0022](adr/0022-keycloak-mgmt-probe-exec.md)）**：この`ipBlock`許可自体、第三者レビューで「kubeletのhttpGetプローブがService/NetworkPolicyの通常モデルを迂回してPod IPへ直接到達する」という構造的な弱点として指摘され、execプローブ化(下記)によって不要になった。当時は「NetworkPolicyでノードIPからのみ絞る」ことを解決策として採用したが、より根本的には「そもそもネットワークに公開しない」選択肢があったことになる。

### KeycloakのhttpGetプローブをexecプローブに置き換えても、`/dev/tcp`ワンライナーで問題なく機能した

**確認内容**：`kubectl exec`でKeycloak Pod(keycloakコンテナ)に入り、`{ printf 'HEAD /health/ready HTTP/1.0\r\n\r\n' >&0; grep 'HTTP/1.0 200'; } 0<>/dev/tcp/localhost/9000`を実行したところ、`/health/ready`・`/health/live`・`/health/started`いずれも`HTTP/1.0 200 OK`が返った。`/bin/sh`は`bash`へのシンボリックリンク（`ls -l /bin/sh`で確認）で、`which`コマンドは無いがbashの`/dev/tcp`疑似デバイスは利用できる。Keycloak公式ドキュメント(observability/health)がcurl非同梱環境向けに推奨している構成そのままで動作した。これは`envoyproxy/envoy`イメージ（上記）と同じ「curl/wgetは無いがbashはある」パターンで、本プロジェクトで2件目の実例になる。

### DNS解決は`kube-system`/`kube-dns`への53番egress許可のみで全Podに行き渡った

**確認内容**：`podSelector: {}`で全Pod共通の1本のNetworkPolicy（`k8s/network-policy/allow-dns.yaml`）だけを追加し、個々のサービスのNetworkPolicyには一切DNS関連のegressルールを書いていない。この状態で`postgres`・`keycloak.gekko.svc.cluster.local`等、全てのService名前解決を伴う既存フローが問題なく成功した。namespaceラベル`kubernetes.io/metadata.name: kube-system`はKubernetes標準の自動付与ラベルで、k3d(v1.35系)でも別途手動付与する必要はなかった。

### 新設したPostgres接続用Job（db-init/seed）は、宛先側の許可だけでは繋がらない。接続元Job自身のegress許可も要る（3回踏んだ）

**症状**：`kubectl logs`で新設のJob（`*-db-init`・`*-seed`等）を見ると、宛先（postgres/edge-proxy）は既にingressを許可しているにもかかわらず`connection refused`で失敗する。宛先側のNetworkPolicyだけを見ると許可漏れが無いように見えるため原因箇所を誤認しやすい。

**原因**：ADR 0018のdefault-denyは名前空間単位ではなくPod単位でingress/egress双方に適用される。宛先PodのingressルールでJobからの接続を許しても、接続元であるJob自身のPodにegress許可のNetworkPolicyが無ければそのPod自体が発信すら出来ない。新しいJobを追加するたびに「宛先側のingress」と「接続元側のegress」の両方を用意し忘れると再発する典型パターン。

**対応**：初出は`k8s/keycloak/networkpolicy.yaml`（`keycloak-db-init` Job、ADR 0018時点でコメントとして記録）。[ADR 0026](adr/0026-account-service-analyst-attribute-service-implementation.md)でaccount-service/analyst-attribute-serviceのdb-init/seed Jobを新設した際に同じ症状を2度（`account-service-db-init`・`analyst-attribute-service-db-init`・`analyst-attribute-service-seed`の3 Job分)踏み、`k8s/account-service/networkpolicy.yaml`・`k8s/analyst-attribute-service/networkpolicy.yaml`にそれぞれ専用のegress許可ルールを追加して解消した。各k8s/*/networkpolicy.yamlに個別コメントとして残っていたためこのファイルに一元化して記録する。**今後、他サービス（fraud-mcp-server等）の本実装でPostgresやKeycloak等に接続するJob（db-init/seed/migration等）を新設する際は、宛先側のingress許可の有無だけでなく、Job自身（接続元）のegress許可を必ず併せて用意すること。**

### 同じパターンの新しい現れ方：マニフェストに接続元Job自身のegress許可を最初から書いても、`make deploy`の実行順序次第では初回だけ間に合わない

**症状**：[ADR 0027](adr/0027-fraud-detection-engine-implementation.md)でfraud-detection-engine-db-init Jobを新設した際、`k8s/fraud-detection-engine/networkpolicy.yaml`に接続元Job自身のegress許可ルールを（上記insightを踏まえて）最初から書いていたにもかかわらず、`make deploy`実行時に`connection refused`でJobがbackoffLimitを使い切って失敗した。

**原因**：`make deploy`は`deploy-network-policy`（全サービスのNetworkPolicyを`kubectl apply`する）をターゲット末尾でしか呼ばない。default-deny自体が存在しないまっさらなクラスタでの初回`make deploy`ではこの順序は無害（Jobは事実上無制限のネットワークで動く）だが、**過去の`make deploy`で既にdefault-denyが有効になっているクラスタ**（`make down`していない開発中のクラスタ等）に新しいサービスのdb-init Jobを初めて追加すると、そのJob自身のegress許可はまだ`deploy-network-policy`が実行されておらず存在しないため、default-denyだけが先に効いてJobが即座に拒否される。宛先側・接続元側どちらのNetworkPolicyも正しく書けていても、単純に「まだ`kubectl apply`されていない」ために起きる、既存insightとは別種のタイミング問題。

**対応**：`Makefile`の`deploy`ターゲットで、`k8s/postgres/networkpolicy.yaml`（宛先postgres側のingress許可。fraud-detection-engine・fraud-detection-engine-db-initからの着信を追加）と`k8s/fraud-detection-engine/networkpolicy.yaml`（接続元fraud-detection-engine本体・db-init Job自身のegress許可）の両方を、db-init Jobを`kubectl apply`する直前に前倒しで適用するようにした。片方だけ前倒ししても解決しない（実際に接続元側だけ先に直しても`connection refused`が再現し、postgres側のingress許可漏れが別途見つかった）。`deploy-network-policy`側の一括適用は冪等なので二重適用しても害はなく、末尾での適用はそのまま残してある。**今後、Postgres等に接続するJobを新設するサービスでは、接続元・宛先(postgres)双方のNetworkPolicyをdb-init Job適用より前に前倒しで適用することを検討すること**（account-service/analyst-attribute-serviceは、このクラスタでは初回追加時に同じ問題を踏んでいない可能性があるが、これは当時のクラスタがまだdefault-deny適用前だったなど環境依存の偶然であり、一般的には同じ問題を持つ）。

## DPoP送信者拘束（fraud-mcp-server→account-serviceの1ホップ、ADR 0013。ADR 0015で撤去済み）

**このセクションが指す実装（`k8s/dpop-verifier/`等）はADR 0015で撤去済み。** 以下は撤去前の実機検証で得た知見で、将来DPoPを再検討する際の参考として残す。

（追記）ADR 0015でマニフェストは削除されたが、クラスタ上の`Deployment/dpop-verifier`・`ConfigMap/dpop-verifier-app`自体は削除し忘れられ、対応するマニフェストが無いまま稼働し続けていた。ADR 0018のNetworkPolicy接続グラフ調査で発覚し、`kubectl delete`で削除済み（2026-09-16）。

このPodにはNetworkPolicyの許可ルールが一つも存在しなかったため、ADR 0018のdefault-deny適用後は（削除前の時点でも）ingress/egressともに事実上封じ込められていた。マニフェストに存在しない野良Podは対応する許可ルールも持ち得ないため自動的に隔離される、という副次的な安全効果をNetworkPolicyのdefault-denyが持つことの実例として記録する。

`k8s/ext-authz/app-configmap.yaml`（削除済み）・`k8s/dpop-verifier/`（削除済み）・[k8s/account-service/envoy-configmap.yaml](../k8s/account-service/envoy-configmap.yaml)で実施。正常系（proof検証成功、200）・異常系（鍵不一致・iat失効、いずれも401）を`dpop-verifier`への直接呼び出しで確認し、fraud-mcp-server→account-serviceの実際の経路（DPoP拘束されたトークン、`Authorization: DPoP <token>`スキーム）でも200が通ることを確認した。

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

## ext-authz-serviceの身元検証ギャップとKeycloakクライアント認証方式の調査

**この調査結果は、後日[ADR 0019](adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)/[0020](adr/0020-fraud-detection-engine-identity-gap-and-client-credentials-federated-jwt.md)/[0021](adr/0021-account-service-analyst-attribute-service-spiffe-jwt-svid.md)でgekko_07本体に反映済み。**以下は反映前に使い捨て環境で行ったスパイクの記録で、調査の経緯・判明した事実（バイトコードレベルの原因特定を含む）を残す。

当時のext-authz-service（ADR 0002/0016）は、呼び出し元（例：fraud-mcp-server）のKeycloakクライアントのclient_secretを保持し、呼び出し元に代わってToken Exchangeを行っていた。この構造には身元検証上のギャップがあった：Keycloakが検証するmTLS接続の身元（ext-authz-service自身のSPIFFE ID）と、Keycloakへ主張しているclient_id（呼び出し元のもの）が一致しない。Keycloakの認可判定は最終的に「client_secretを知っているか」に基づいており、「本当にそのワークロードが要求しているか」を検証できていなかった。この欠落を埋める方式として、RFC 8705（mTLSクライアント認証）・Delegationモデル（`act`/`actor_token`）・KeycloakネイティブのSPIFFE対応、の3方向を使い捨てDockerコンテナ（`docker run quay.io/keycloak/keycloak:26.7.0`、gekko_07クラスタ本体には一切触れず）で調査した。

### RFC 8705（`client-x509`）はSubject DNのみを見る。SPIFFEのURI SANは見ない

**症状**：呼び出し元自身のSPIRE発行X.509-SVID（URI SANにSPIFFE IDを持つ）を、Keycloakの`clientAuthenticatorType: client-x509`でそのままクライアント証明書として使えないか検証した。

**原因**：`X509ClientAuthenticator.java`（Keycloak 26.7.0）をバイトコードレベルで確認したところ、識別子の抽出は`certificate.getSubjectDN().getName()`のみで、SAN（Subject Alternative Name）は一切参照しない。`x509.subjectdn`属性（正規表現可）でのSubject DN一致だけがサポート対象。SPIFFE仕様はリーフSVIDのSubject DNを空にすることを推奨しており、SPIRE本体もそれに準拠しているため、実際のSVIDでは一致させる対象そのものが存在しない。gekko_07の`k8s/spire/server-configmap.yaml`の`ca_subject`はルートCA自身の発行者名の設定であり、ワークロードへ発行するリーフSVIDのSubject DNをテンプレート化する仕組みではない。Keycloak公式Issue #41907（2025年8月、Open）が「SPIFFE/SPIREでのクライアント認証は未対応」と明記しており、設定不足ではなくKeycloak本体の既知の未対応機能であることを確認した。

**対応**：X.509-SVID/RFC 8705経由の道は棄却し、JWT-SVIDベースの方式（下記）を採用する方向とした。

### KeycloakネイティブのSPIFFE JWT-SVID対応（`federated-jwt`、Preview機能）は動く。ただし`client_assertion_type`を間違えると無言で失敗する

**症状**：Keycloak 26.7.0には`spiffe`・`client-auth-federated`というfeature flag、`clientAuthenticatorType: federated-jwt`（表示名"Signed JWT - Federated"）、`identity-provider`の`providerId: spiffe`（`trustDomain`・`bundleEndpoint`設定）が実在する。これらを設定し、クライアント属性`jwt.credential.issuer`（IdPエイリアス参照）・`jwt.credential.sub`（期待するSPIFFE ID文字列）を正しく設定した上で、`iss`/`sub`が一致し正しく署名されたJWTを`client_assertion`として送っても、`client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer`（汎用RFC 7523の値）を使うと**常に`invalid_client`で失敗し、エラーメッセージも一切のTRACEログも手がかりを残さない**（自前で立てたJWKSバンドルエンドポイントへのHTTPリクエストすら発生しない＝署名検証まで到達していない）。

**原因**：`FederatedJWTClientAuthenticator.authenticateClient()`をバイトコードレベルで確認したところ、`client_assertion_type`の値で`findStrategy()`が担当ストラテジーを検索し、一致するストラテジーが無ければ（あるいは`lookup()`が呼び出し元クライアントを特定できなければ）**例外もfailure()も呼ばず黙ってreturnする**。汎用の`urn:ietf:params:oauth:client-assertion-type:jwt-bearer`は、SPIFFE用ではなく「`sub`＝`client_id`」を前提とする旧来のデフォルトストラテジーにマッチしてしまい、`sub`にSPIFFE IDそのものを入れている今回のJWTでは当然クライアントが見つからず、素通りしていた。`SpiffeConstants.class`を直接読んだところ、SPIFFE用ストラテジーに対応する正しい値は`urn:ietf:params:oauth:client-assertion-type:jwt-spiffe`だった。

**対応**：`client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe`に修正したところ、Keycloakが実際にバンドルエンドポイントへHTTPリクエストを送り、署名検証に成功し、client_secret無しで`"azp": "fraud-mcp-server"`のアクセストークンが発行されることを確認した（HTTP 200）。第三者製SPI（`christian-posta/spiffe-svid-client-authenticator`）を使わずとも、Keycloak本体のPreview機能だけでJWT-SVIDベースのクライアント認証が成立することを実証した。ただし`spiffe`はKeycloakの成熟度区分で"Preview"（`token-exchange-delegation`等の"Experimental"より一段階上だが安定版ではない）であり、関連するAdmin UI側には既知の未解決バグ（Issue #42634・#42044・#51682）がある点は留意する。gekko_07本体（実際のSPIRE JWT-SVID発行・Envoy/ext-authz-serviceの置き換え）への統合はまだ行っていない。

### Stage 1a：gekko_07の実クラスタ上で、SPIRE発行の本物のJWT-SVID＋SPIRE Serverのbundle endpointでToken Exchangeが成立することを確認した

前項の使い捨てDockerコンテナでの検証を、gekko_07の実k3dクラスタ（本物のSPIRE Server/Agent、本物のKeycloak）で再現した。以下は全て実機で確認済みの内容で、後日ADR 0019で`k8s/`配下へ反映された（このセクション自体は反映前、`kubectl`で一時的に生きているクラスタへ直接適用して検証した時点の記録）。

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

## frontend/fraud-agent実装（ADR 0023/0024）

### `account:read`のaudienceマッパー共有スコープは、requesting client側でaudienceを技術的に制限しない

**症状**：ADR 0024でfrontendのToken Exchange呼び出しを、各サービス自身のtoken-exchangeサイドカー経由に置き換える前は、verify-hop.shがKeycloakへ直接`client_id=frontend`で`audience=fraud-mcp-server`を要求してもエラーにならず成功していた。しかしaccess-control-design.md 表1では、frontend→fraud-mcp-serverの直接exchangeは明示的にDENYとされている（frontendの正しい委任経路はfraud-agent経由のみ）。

**原因**：`account:read`client scopeは、account-service・fraud-agent・fraud-mcp-serverの3つのaudienceに対する`oidc-audience-mapper`を持つ（frontend・fraud-agent・fraud-mcp-serverの3クライアントがこの1つのscopeを共有し、それぞれ自分の正しいaudienceだけを要求する設計。architecture.md §3）。しかしKeycloakのToken Exchangeは、要求元クライアントが`account:read`scopeを持ってさえいれば、`audience`パラメータでその3つのうちどれでも要求でき、要求先のaudience自体がリクエスト元クライアントを制限するような仕組みは無い。つまりtable 1のDENYは、Keycloakのクライアント設定や認可ポリシーによってサーバー側で強制されているわけではなく、**各クライアントの実装（token-exchangeサイドカーが何を要求するか）が正しいaudienceだけを要求することに依存している**。architecture.md §4が明記する「Client Policiesは使わない」設計上、この監査ギャップは現状放置されている。

**対応**：今回は範囲外として是正しなかった（Client Policies導入は既存の設計判断を覆すため、行うなら独立したADRが必要）。ただし今回、verify-hop.sh自身がこの抜け道（frontendを名乗って直接fraud-mcp-server宛てexchangeする）を使っていたことに気づき、frontend→fraud-agent→fraud-mcp-serverの実チェーン（各サービス自身のtoken-exchangeサイドカーを経由）に置き換えて解消した。全クライアントの実装（サイドカーのSCOPE_RULES）は正しいaudienceしか要求しないため、現状はリスクが顕在化していない。

**実際に通った検証**：`client_credentials`グラントでは`{"error":"unauthorized_client","error_description":"Client not enabled to retrieve service account"}`（=クライアント認証自体は成功、fraud-mcp-serverの`serviceAccountsEnabled: false`が理由でグラント自体が拒否されただけ）。既存のverify-hop.sh同様の2段階委任（frontendでログイン→frontendがfraud-mcp-server宛てにToken Exchange→そのDELEGATED_TOKENをsubject_tokenにfraud-mcp-server自身がaccount-service宛てにToken Exchange、ただし`client_secret`の代わりに`client_assertion_type=...jwt-spiffe`＋`client_assertion=<JWT-SVID>`を使用）を実行したところ、**HTTP 200でaccount-service向けアクセストークンが発行された**。RFC 8705が不成立と判明した際の懸念（Keycloakネイティブpreview機能が実際に機能するか）は、この実クラスタでの成功により解消したと判断できる。

## 監査ログ集約（ADR 0025）

### Grafana Alloyの設定言語（River）の行コメントは`//`であり、`#`ではない

**症状**：`k8s/observability/alloy-configmap.yaml`の`config.alloy`内にYAML/shell感覚で`#`コメントを書いたところ、Alloy起動時に`illegal character U+30FB '・'`等、コメント以降の全角文字を含む行が軒並み構文エラーになり、`could not perform the initial load successfully`でクラッシュループした。

**原因**：AlloyのRiver構文はHCL系で、行コメントは`//`。`#`は単なる不正なトークンとして扱われ、それ以降の行がコメントとして無視されない。

**対応**：`config.alloy`ブロック内のコメントを全て`//`に置き換えた（`config.alloy: |`より外側、ConfigMap自体のYAMLコメントは`#`のままでよい。両者が同じファイルに混在する点に注意）。

### `discovery.relabel`のreplacementの`$N`は、regexのキャプチャグループであってsource_labelsの各要素ではない

**症状**：Podのログファイルパス（`/var/log/pods/<namespace>_<podname>_<uid>/<container>/*.log`）を組み立てるために、`source_labels = [namespace, podname, uid, container]`を`separator: "/"`で連結し、`replacement: "/var/log/pods/*$1_$2_$3/*$4/*.log"`のように「4つの要素に$1〜$4がそれぞれ対応する」と誤解して書いたところ、`discovery.relabel`の絞り込み（`action: keep`）自体は正しく機能する一方、後段の`local.file_match`が全namespace・全コンテナのログファイルを拾ってしまった。

**原因**：`replacement`の`$N`はPrometheus/Alloyのrelabelingにおける「`regex`フィールドの正規表現キャプチャグループ」を指す。`regex`を明示的に指定しない場合、既定値`(.*)`が連結後の文字列**全体**を単一の`$1`として捕捉するため、`$2`以降は常に空文字列になる。結果として生成される`__path__`が想定と異なる壊れたグロブパターンになり、意図せず広い範囲にマッチしていた。

**対応**：Grafanaの公式サンプルと同じ手法へ変更した。`source_labels = [pod_uid, container_name]`のみを`separator: "/"`で連結し、`replacement: "/var/log/pods/*$1/*.log"`とする（`$1`は連結後の文字列全体＝`"<uid>/<container>"`）。kubeletのディレクトリ名`<namespace>_<podname>_<uid>`は先頭に`*`グロブを置くことで吸収し、末尾に来るUID（グローバルに一意）と`/<container>/*.log`だけで十分に一意な絞り込みになる。namespace/containerでの事前フィルタ（`action: keep`）と組み合わせて実機で意図通りの絞り込みを確認済み。

### grafana/otel-lgtmの実際の内部構成（イメージ調査で確認）

`grafana/otel-lgtm:0.33.0`（`docker pull`でローカル検証。DockerfileのEXPOSEは3000/3200/4040/4317/4318/9090のみ）は、Grafana・Loki・Prometheus・Tempo・Pyroscope・OTel Collectorの6プロセスを`/otel-lgtm/run-all.sh`が一括起動する単一コンテナ。今回の用途（Loki+Grafanaのみ）ではPrometheus/Tempo/Pyroscope/OTel Collectorは起動するが未使用（個別無効化の方法は未調査）。

Lokiは`http_listen_port: 3100`（`/otel-lgtm/loki-config.yaml`）で待ち受けているが、Dockerfile上のEXPOSEには含まれない。EXPOSEはドキュメント目的でありK8s Serviceは任意のリスニングポートを対象にできるため、`targetPort: 3100`を明示すれば問題なく到達できる（実機確認済み。Grafana自身のデータソース定義`grafana-datasources.yaml`も`http://127.0.0.1:3100`を参照している）。

### Keycloakの`jboss-logging`イベントリスナーは、成功イベントをDEBUGレベル・エラーイベントをWARNレベルで出力する

**症状**：`eventsEnabled: true`・`eventsListeners: ["jboss-logging"]`を設定しただけでは、実際にログへ出力されるのは`TOKEN_EXCHANGE_ERROR`のような失敗系イベントのみで、成功した`LOGIN`・`TOKEN_EXCHANGE`は一切出力されなかった（`org.keycloak.events`ロガーの出力を`kubectl logs`で直接確認して判明）。BR8が本来必要とするのは「誰が実行したか」＝成功した操作の記録であり、エラーだけでは監査要件を満たせない。

**原因**：Keycloakの既定ログレベルはINFOだが、`jboss-logging`イベントリスナーは成功イベントをDEBUGレベルで、エラーイベントをWARNレベルでログに出す実装になっている（ルートロガーの既定INFOでは前者が握りつぶされる）。

**対応**：`k8s/keycloak/deployment.yaml`に`KC_LOG_LEVEL: "INFO,org.keycloak.events:DEBUG"`を追加し、`org.keycloak.events`カテゴリだけDEBUGへ引き上げた。この変更はKeycloakのQuarkusビルド設定に影響するため、Pod再起動直後は`Quarkus augmentation`の再実行で通常より起動が遅くなる（実機で70秒以上かかった。`rollout status`のtimeoutを短く設定していると誤って失敗扱いにするので注意）。

### アクセストークンに`sub`クレームが乗らない（Keycloak 26.7.0、原因未特定・dedicated mapperで回避）

**症状**：frontendの`/login`（ROPC）で発行されたアクセストークンをデコードすると、`sub`クレームが存在しない（`azp`/`sid`/`jti`等はある）。この状態はrealm importの構成（defaultClientScopesが空、`--import-realm`で標準scopeが生成されない等）とは無関係で、**masterrealmの組み込みクライアント`admin-cli`（標準scope完備、client_secret認証）でも同様に`sub`が欠落する**ことを実機で確認した。`client.use.lightweight.access.token.enabled`をクライアント属性で明示的に`false`にしても症状は変わらず、`scope=openid`を明示的に要求してもアクセストークン自体には影響しない（同時に発行されるID Tokenには`sub`が乗る）ため、根本原因はこの2つのどちらでもないと判断した（Keycloak 26.7.0自体の挙動である可能性が高いが、未特定のまま）。

一方、Token Exchange（委任チェーンの②③④ホップ）で発行されるトークンは、このマッパーを追加する前から`sub`を正しく引き継いでいた（実機確認済み）。つまり影響範囲はfrontendの生ログイントークン（および、それを直接subject_tokenにする以降の全ホップ）に限られていた。

**対応**：frontendクライアントの`protocolMappers`に、`oidc-usermodel-property-mapper`（`user.attribute: id`→`claim.name: sub`）の明示的なdedicated mapperを追加した（`aud`クレームの欠落を補った既存の`audience-self`マッパーと同じ手法）。追加後、frontendの生ログイントークンにも`sub`が正しく乗り、それをsubject_tokenとする以降の全ホップ（frontend→account-service/fraud-agent直接exchangeを含む）でも`sub`が一貫して伝播することを`scripts/verify-hop.sh`で実機確認した。frontend以外のクライアントには追加していない（Token Exchange側は元々問題が無かったため）。

### Token ExchangeイベントログのsessionIdが、委任チェーン1インスタンスの相関キーになる

`type="TOKEN_EXCHANGE"`イベントには`sessionId`（Keycloakのログインセッションid）が含まれ、**同一ログインセッション内で発生した全ホップのToken Exchangeイベントで同じ値になる**ことを実機確認した（frontend→fraud-agent、frontend→fraud-mcp-server、account-service→analyst-attribute-service等、1回のfrontend操作に由来する全イベントが同一`sessionId`を持つ）。`sub`/`userId`だけでは「誰か」しか分からず、同一アナリストの複数の並行操作（別タブでの別操作等）を区別できないため、委任チェーン1インスタンスの再構成には`sessionId`を主キーとし、`sub`/`userId`/`username`（誰が）・`token_id`/`scope`/`audience`（各ホップで何をしたか）を組み合わせる設計とした（architecture.md §8参照）。client_credentialsグラント（fraud-detection-engineの自動凍結処理）には`sessionId`自体が存在せず、これはBR7（アナリストの代理ではない）の設計とも整合する。

### edge-proxyの`/admin/`パスがKeycloakではなくfrontendへ誤配送される（ADR 0024の実装漏れ）

**症状**：Keycloakのrealmを再import後、`k8s/keycloak/test-fixtures-job.yaml`のkcadm.shが`SERVER=http://edge-proxy...`経由で`/admin/realms/gekko/users`等を呼ぶと、一貫して`401 Unauthorized`になった。edge-proxy自身のアクセスログ（ADR 0025で追加）を見ると、この呼び出しの実際の宛先（`upstream_host`）はKeycloakではなく**frontendのService IP**だった。

**原因**：ADR 0024でedge-proxyのroute_configを`/realms/`(Keycloak)と`/`(frontend、catch-all)に分割した際、コメントには「kcadm.sh等はKeycloak Pod内へkubectl execで直接到達するため対象外」と書かれていたが、実際にはtest-fixtures-configmap.yamlのkcadm.shがedge-proxy経由で`/admin/`配下を叩いており、この想定は誤りだった。`/admin/`はcatch-allの`/`ルートにマッチしてfrontendへ配送され、frontendのjwt_authnまたはアプリ自体が401を返していた。

**対応**：`k8s/edge-proxy/envoy-configmap.yaml`のroute_configに`{match: {prefix: "/admin/"}, route: {cluster: keycloak_upstream}}`を`/realms/`ルートの次に追加した。ADR 0025の監査ログ集約作業（realm再import）で偶然発覚したが、ADR 0024自体のバグであり新規ADRは起こさず、このADRのコミットで一緒に是正した。

### k3d(kube-router)のNetworkPolicyは、KubernetesのAPIサーバー(`kubernetes` Service)宛てのegressをClusterIPではなくDNAT後の実IPで評価する

**症状**：Alloyの`discovery.kubernetes`（Podメタデータ取得用）に`kubernetes` ServiceのClusterIP（`10.43.0.1/32:443`）へのegressを許可するNetworkPolicyを追加しても、`observability` namespaceにdefault-denyを適用したままだと`discovery.kubernetes.pods`のtargetsが0件のまま変化しなくなった（RBAC＝ClusterRoleは正しく、`kubectl auth can-i`も許可を返す）。Alloy Pod内の`/proc/net/tcp`を見ると、APIサーバーへのTCP接続試行自体が一切記録されておらず（SYN_SENTすら無い）、NetworkPolicyがDROPしているというより経路自体が塞がれているように見えた。

**原因**：`kubernetes` Service（selectorなしの特殊なService）は`ClusterIP=10.43.0.1:443`だが、実体（`kubectl get endpoints kubernetes`で確認できる）はk3dノード自身のIP:6443（例：`172.19.0.2:6443`）。k3dの既定CNIであるkube-routerは、NetworkPolicyをkube-proxyのDNAT**後**の宛先（＝ノードの実IP:6443）に対して評価するため、ClusterIP:443宛てのipBlockルールでは一致しない。NetworkPolicyを完全に外すと即座に解決した（Alloyが正常にPodを発見・tailを開始した）ことから、NetworkPolicyそのものが原因であることを切り分けた。

**対応**：`k8s/observability/networkpolicy.yaml`のAlloy向けegressルールを、k3dノードのCIDR（`172.19.0.0/16`、edge-proxy（ADR 0004/0017）のingress例外と同じCIDR）宛て・ポート6443へのipBlockに変更した。他のNetworkPolicy（`k8s/network-policy/`・各サービスの`networkpolicy.yaml`）はいずれもPod間通信（podSelector）のみで完結しており、KubernetesのAPIサーバー自体にegressする必要があるコンポーネントはAlloyが最初だったため、この罠はこれまで顕在化していなかった。

### k3d(containerd)のPodログは`/var/log/pods/<namespace>_<podname>_<uid>/<container>/<restart>.log`に標準CRI形式で実在する

Alloyのhostpath収集方式（`/var/log/pods`をDaemonSetでマウント）が実際に機能するか未検証だった点について、k3dノードコンテナ内を直接確認し、標準的なkubelet/containerdのログレイアウト（`<timestamp> <stream> <F|P> <line>`のCRI形式）で存在することを確認した。Alloyの`stage.cri`でエンベロープを剥がすだけで中身（Envoyのjson_formatアクセスログ・Keycloakのjson出力）をそのまま扱える。

### `k8s/keycloak/test-fixtures-configmap.yaml`のパスワード設定に再現性のある問題がある（未解決）

**症状**：realm再import直後に`make deploy-verify-hop`（test-fixtures-job）を実行すると、ジョブ自体は正常終了する（"Created new user"まで到達する）が、そのユーザーで実際にログインすると`401 Unauthorized`になることがあった。Keycloak側でkcadmから`set-password`を打ち直す（`.secrets/yamada-analyst-password`と同じ値を明示的に再設定する）と直った。

**原因**：未特定。Secret（`yamada-analyst`）の値と`.secrets/yamada-analyst-password`ファイルの内容は一致しており、生成される認証情報（argon2ハッシュ）自体は存在するため、fixtures.sh側のcreate-user時のパスワード設定手順（インライン`credentials`指定か、Keycloak側の何らかのタイミング要因か）に問題がある可能性がある。

**対応**：今回は範囲外として深追いしなかった（ADR 0025の監査ログ集約とは無関係な既存スクリプトの問題）。backlog.mdに未解決事項として記録する。

## Postgres mTLS（ADR 0028）

### 長時間稼働Podの静的Envoy bootstrap設定は、ConfigMapを更新しただけでは再読み込みされない

**症状**：`k8s/postgres/envoy-configmap.yaml`のmTLS許可SAN一覧にdb-init/seed Job用の5エントリを追加し`kubectl apply`したが、その後db-init Jobから接続すると`psql: error: connection to server at "postgres" (127.0.0.1), port 5432 failed: server closed the connection unexpectedly`で失敗した（Job側は接続待機リトライを使い切って終了）。

**原因**：Envoyの`envoy.yaml`（`node`/`static_resources`を含むbootstrap設定）はxDS経由の動的設定と異なり、プロセスが起動時に一度だけ読み込むファイルであり、マウント元ConfigMapの内容が更新されても実行中のEnvoyプロセスには反映されない（kubeletはConfigMapボリュームの中身自体は同期するが、それを読みに行くかどうかはアプリ側の実装次第）。postgres StatefulSetは今回`k8s/postgres/statefulset.yaml`（Podテンプレート）自体を変更していなかったため、`kubectl apply`では既存のpostgres-0 Podが再作成されず、古いSAN一覧を積んだままのEnvoyプロセスが動き続けていた。account-service等の常駐アプリでは、Envoy設定変更が大抵`hostAliases`等のPodテンプレート変更と同時に起きるため、この罠はこれまで顕在化していなかった。

**対応**：`kubectl -n gekko delete pod postgres-0`でPodを再作成し（StatefulSetなので自動的に作り直される。PVCは保持される）、Envoy admin API（`/config_dump?resource=static_listeners`）で新しいSAN一覧が実際に読み込まれたことを確認した。今後postgres-envoy ConfigMapの内容だけを変更する場合（Podテンプレート自体の変更を伴わない場合）は、同様に手動でpostgres-0を再作成する必要がある。

### Kubernetesネイティブsidecarコンテナ（`initContainers`の`restartPolicy: Always`）はJobと問題なく組み合わせられた

**症状（想定していたリスク）**：Jobの`psql`スクリプトは1回きりの実行であり、Envoyサイドカーが起動直後でSDS証明書配信・TCPリスニングが完了していないタイミングで接続を試みる競合を懸念していた。

**確認結果**：既存の接続待機リトライループ（`for i in $(seq 1 10); do $PSQL ...; sleep 1; done`。NetworkPolicy反映待ちのために元々存在していた）がこの競合にもそのまま対応し、新しいstartupProbe等の追加は不要だった。またメインコンテナ（`db-init`/`seed`）が終了すると、kubeletが`restartPolicy: Always`のEnvoyサイドカーへ自動的にSIGTERMを送り、Job自体も正常にCompletedへ遷移することを実機で複数パターン（単一initContainer構成・`resolve-subs`と共存する2 initContainers構成）確認した。

### 常駐Deployment（Job以外）では同じ競合が実際にCrashLoopBackOffとして顕在化した

**症状**：`make up`実行直後、account-service・analyst-attribute-serviceのappコンテナが数回（3〜4回）再起動してからようやく安定した。ログはいずれもPostgresへの接続失敗（account-service：FlywayのJDBC接続がEOFException、analyst-attribute-service：`context deadline exceeded`）。`make stop`→`make start`でノードが再起動した際にも同様の再起動が発生しうる。

**原因**：account-service（Java/Spring Boot）・analyst-attribute-service（Go）のappコンテナは、同じPod内のEnvoyサイドカー（通常の`containers`。Job用のネイティブsidecarパターンは当時Deploymentには未適用）と並行して起動する。EnvoyがSPIRE Agent Workload APIからSDS経由で証明書配信を受け終える前にappが127.0.0.1:5432（Envoyのegressリスナー）へ接続を試みると失敗する。analyst-attribute-serviceはアプリ自身に30秒のリトライループ（`main.go`の`openDB`）を持っていたが、それでも複数回クラッシュした——1回の接続試行自体がハングすると、リトライループがあってもリトライ予算を1回で使い切ってしまうことがあるため、アプリ側のリトライだけでは不十分だと分かった。

**対応**：db-init Jobで確認済みだったネイティブsidecarパターン（`initContainers`の`restartPolicy: Always`）を、keycloak・account-service・analyst-attribute-service・fraud-detection-engineの4常駐DeploymentのEnvoyにも適用し（[ADR 0028](adr/0028-postgres-mtls-tcp-proxy.md) Consequences追記）、その後ろに`wait-for-postgres`（`pg_isready`リトライループ）initContainerを追加してappコンテナの起動をPostgres疎通確認後まで遅らせた。適用後、`make up`直後・rollout直後とも再起動なしで安定することを実機で複数回確認した。Postgres接続を持たないfraud-mcp-server・fraud-agent・frontend、およびpostgres本体のEnvoyもネイティブsidecar化して構成を統一したが、これらはwait-for-X initContainerを追加する実害が無いため、起動順序ガードは追加していない（edge-proxyはEnvoy単体Podのため`containers`を空にできず対象外）。

## fraud-mcp-server本実装（Python/FastMCP、ADR 0029）

### FastMCPのStreamable HTTPアプリを他のStarletteアプリへマウントする際、`lifespan`を明示的に共有しないとセッションが機能しない

**症状**：`mcp.http_app()`が返すASGIアプリを素の`Starlette(routes=[...])`に`Mount("/", app=mcp_app)`で組み込んだだけでは、外側のStarletteアプリ自体のlifespanイベントに`mcp_app`のセッションマネージャーの起動処理が含まれない（FastMCPのStreamable HTTP transportはセッション管理に内部でstartup/shutdownフックを使う）。

**原因**：ASGIの`Mount`はサブアプリのルーティングを委譲するだけで、lifespanイベントを自動的に合成しない。FastMCP自身のドキュメント・実装例でも「外側のアプリ作成時に`lifespan=mcp_app.lifespan`を明示的に渡す」ことが前提になっている。

**対応**：`services/fraud-mcp-server/app.py`で`mcp_app = mcp.http_app(path="/mcp")`を作り、`Starlette(routes=[...], lifespan=mcp_app.lifespan)`として外側のアプリを作成してから`asgi_app.mount("/", mcp_app)`する構成にした。この構成で`initialize`→`notifications/initialized`→`tools/list`→`tools/call`の一連のMCPセッションが実機（ローカルDocker実行、後にk3dクラスタ内）で正常に動作することを確認した。

### `get_http_headers()`/`get_http_request()`はcontextvarベースで、Envoy ingressが転送する`Authorization`ヘッダーをツール関数内から素直に読める

`fastmcp.server.dependencies.get_http_headers(include={"authorization"})`は例外を投げずに空dictを返す安全なAPIで、`@mcp.tool`関数の中からEnvoy ingress(`jwt_authn`の`forward: true`で保持された元のAuthorizationヘッダー)をそのまま読み取り、account-serviceへの呼び出しにも転送できることを確認した（`services/fraud-mcp-server/app.py`の`_delegated_authorization`）。アプリ自身はToken Exchangeを一切行わず、受け取ったヘッダーを右から左へ転送するだけでよい（account-serviceの`AnalystAttributeClient.java`と同型のパターンがPython/FastMCPでも成立する）。

### 合言葉ヘッダー検証ミドルウェアはStarletteの`BaseHTTPMiddleware`ではなく素のASGIミドルウェアで実装する

**症状**：ADR 0009 §2の多層防御（接続元loopback再チェック・合言葉ヘッダー検証）を他サービスと同じ形で移植する際、最初`starlette.middleware.base.BaseHTTPMiddleware`を使う案を検討した。

**原因**：`BaseHTTPMiddleware`はレスポンスを内部でバッファする実装になっており、MCP Streamable HTTP transportが使うSSE（Server-Sent Events）ストリーミングレスポンスと相性が悪いことが知られている（Starletteの既知の制限）。

**対応**：`class HandshakeMiddleware`を素のASGIミドルウェア（`__call__(self, scope, receive, send)`を直接実装する形）として書き、`app(scope, receive, send)`をそのまま委譲する構成にした。実機確認（`tools/list`・`tools/call`のSSEレスポンスを含む）でストリーミングが問題なく通ることを確認した。

### MCPエンドポイントの実パスは`mcp.http_app(path="/mcp")`で明示指定し、`/mcp`に確定した

FastMCPは`http_app()`の`path`引数でマウントパスを指定できる。fraud-mcp-serverでは`/mcp`を明示指定した（Envoy ingress側は`prefix: "/"`のワイルドカードルートのため、パス自体はEnvoy設定に影響しない。将来fraud-agentの本実装がMCPクライアントとしてこのURLを組み立てる際は`http://fraud-mcp-server/mcp`を使う）。

### `python:3.12-slim`ベースの実行イメージでも、`kubectl exec`での即興`python3 -c`呼び出しはそのまま機能する

fraud-detection-engine本実装（ADR 0027）ではRustの静的バイナリ化によりコンテナ内のシェル・curlが失われ、`scripts/verify-hop.sh`の手動リクエスト組み立て箇所を診断用ループバックAPIへ置き換える対応が必要になった。fraud-mcp-serverは同じく「スタブのPythonスクリプトから本実装イメージへ」の置き換えだが、実行イメージが`python:3.12-slim`（distrolessではない）であるため`python3`バイナリ自体はそのまま残っており、`scripts/verify-hop.sh`の既存ステップ（`kubectl exec -c app -- python3 -c '...'`でaccount-serviceへ手動HTTPリクエストを送る箇所）は無変更で動作した（実機確認済み）。

### fraud-agent-stubの疎通確認先を`/healthz`に切り替えた

fraud-agent-stub（`k8s/fraud-agent/app-configmap.yaml`）は元々fraud-mcp-serverのスタブ実装（素のGETに任意のJSONを返す）への疎通確認として`http://fraud-mcp-server/`へ素のGETを送っていた。fraud-mcp-server本実装後、MCPプロトコル外の素のGETは`/mcp`エンドポイントでは200を返さない（FastMCP Streamable HTTPは`initialize`から始まる正規のJSON-RPCセッションを要求する）ため、`scripts/verify-hop.sh`のstep 7（`"fraud_mcp_server": {"status": 200`を期待するアサーション）が壊れる。fraud-agent自体は本実装のスコープ外のため、`FRAUD_MCP_SERVER_URL`の既定値を`http://fraud-mcp-server/healthz`に変更するだけで対応した（`app.py`に追加した`/healthz`はEnvoy ingressの同じscope検証(`account:read`)配下にある単純な200固定エンドポイント）。実機確認済み。

## fraud-agent本実装（TypeScript/Claude Agent SDK、ADR 0030）

### `@anthropic-ai/claude-agent-sdk`は独自のCLIランタイムを同梱した自己完結パッケージで、別途`claude`バイナリのインストールは不要

**症状**：Claude Agent SDKがClaude Code CLIの薄いラッパーなのか、それとも別途CLIバイナリのインストールを要するのかが公開ドキュメントだけでは不明瞭だった。

**確認方法**：`npm install @anthropic-ai/claude-agent-sdk@0.1.77`を実行し、パッケージ内容を実際に検査した。

**判明した事実**：パッケージ自身が`cli.js`（約11MB、自己完結型のバンドル）・`sdk.mjs`・`resvg.wasm`・`tree-sitter*.wasm`を同梱しており、`query()`はこの同梱`cli.js`を子プロセスとして起動する（推定）。`package.json`に`bin`エントリは無く、他パッケージへの実行時依存（`dependencies`）も無い。そのため`services/fraud-agent/Dockerfile`は`npm ci`だけで完結し、fraud-mcp-server（Python/FastMCP）のように別途ランタイムを用意する必要が無かった。

### `@ag-ui/claude-agent-sdk`の`ClaudeAgentAdapter`はリクエスト単位で作り直す前提の設計

公式のAG-UIプロトコル用Claude Agent SDKアダプタ（2026-09-17公開、`@ag-ui/claude-agent-sdk@0.0.4`）を発見し採用した。`peerDependencies`が`@anthropic-ai/claude-agent-sdk: ^0.2.58`を要求するため、当初pinしていた`0.1.77`から`0.2.141`へ上げた。アダプタのREADME内コメントに明示されている通り、`headers`プロパティ（CopilotKit Runtime向けのper-request転送ヘッダー機構）は「Claude Agent SDKがプロセスベース（`query()`が子プロセスを起動する方式）であるため、LLM呼び出し自体へのヘッダー注入手段が無い」ことが理由でAnthropic API呼び出しには機能しない。ただし本リポジトリが必要としているのはLLM呼び出しへのヘッダーではなく、**MCPサーバー（fraud-mcp-server）向け**の委任トークン転送であり、これは`Options.mcpServers`（`ClaudeAgentAdapterConfig`が`Options`を継承するため利用可能）経由で実現できる。`ClaudeAgentAdapter`のコンストラクタで設定が固定されるため、リクエストごとに異なる`Authorization`を渡すには**リクエストごとに新しいアダプタインスタンスを作る**必要がある（`run(input)`の引数では変更できない）。1リクエスト1インスタンスは無駄に見えるが、アダプタ自体は状態を持たない薄いラッパーのため実害は無い。

### `RunAgentInputSchema`は`@ag-ui/core`本体ではなく`@ag-ui/core/schemas`サブパスからimportする

`@ag-ui/core`のメインエントリ（`import { RunAgentInputSchema } from "@ag-ui/core"`）はZodスキーマをエクスポートしていない（`RunAgentInput`という型だけ）。`tsc`のビルドエラー（`TS2724: has no exported member named 'RunAgentInputSchema'`）で気づいた。`package.json`の`exports`/`typesVersions`を確認したところ、スキーマ群は`"./schemas"`サブパス（`@ag-ui/core/schemas`）に分離されていた。型（`@ag-ui/core`）とランタイム検証用スキーマ（`@ag-ui/core/schemas`）が別エクスポートである点は、ドキュメントだけでは分からずパッケージ自体の`package.json`を確認して判明した。

### `tools: []`＋`allowedTools`の明示リストで、SDKレベルでも組み込みツール（Bash/Read/Write等）を一切使わせない構成にできる

`Options.tools`（`string[] | { type: 'preset'; preset: 'claude_code' }`）に空配列を渡すと組み込みツールが全て無効化され、`mcpServers`で渡したMCPサーバーのツールのみが使用可能になる。`allowedTools`にfraud-mcp-serverの3ツール名（`mcp__fraud_mcp_server__get_frozen_accounts`等）を明示し、`permissionMode: "dontAsk"`（許可リスト外は確認無しで拒否、`bypassPermissions`と違い`allowDangerouslySkipPermissions`も不要）にすることで、万一プロンプトインジェクション等でモデルが想定外のツール名を呼ぼうとしても、SDKの権限層で構造的に拒否される（実際の防御の主体はToken Exchangeのスコープ設計だが、これは多層防御の1枚として機能する）。

### hostAliasesはPod内の全コンテナで共有されるため、Envoy自身のクラスタ名前解決と衝突しうる

**症状**：Anthropic API（`api.anthropic.com`）向けegressの最初の実装案（appのhostAliasesで実ホスト名自体を127.0.0.1へ横取りし、Envoyがtransport_socket無しのblind tcp_proxyでTLSバイト列をそのまま転送する方式）で、Envoyのegressサイドカーが`envoy_bug failure: socket(2) failed, got error: Too many open files`で繰り返しクラッシュした。

**原因**：`hostAliases`はPod内の全コンテナ（Envoy自身を含む）で共有される`/etc/hosts`への追記である。appを127.0.0.1へ誘導するために`api.anthropic.com`自体をhostAliasesへ登録すると、Envoy自身が`anthropic_upstream`クラスタ（`LOGICAL_DNS`）で同じホスト名を解決しようとした際にも同じエントリを引いてしまい、127.0.0.1（＝自分自身のリスナー）への自己参照ループになる。接続が失敗しては即座に再接続を試みる挙動が暴走し、fd（ファイルディスクリプタ）を急速に消費してクラッシュした。内部サービス（account-service等）ではapp向けの短縮名（`account-service`）とEnvoy向けのFQDN（`account-service.gekko.svc.cluster.local`）が異なるためこの種の衝突は起きないが、Anthropicのような公開ホスト名が1つしかない宛先では同じ手が使えない。

**対応**：appの接続先を実ホスト名とは異なる内部専用の別名（`anthropic-gateway`）にし、Claude Agent SDKが標準で尊重する`ANTHROPIC_BASE_URL`環境変数（`http://anthropic-gateway`）でそれを指定した。Envoy側は`anthropic-gateway`ではなく本物の`api.anthropic.com`をクラスタのアップストリームとして解決するため、衝突が起きない（内部サービスの「短縮名(app向け) vs FQDN(Envoy向け)」パターンと同じ考え方）。Envoyはこの新しいegress:80仮想ホストでTLSを終端し、公開CAバンドル（`/etc/ssl/certs/ca-certificates.crt`。envoyproxyの公式イメージに同梱済み）で実際のAnthropicサーバーへ改めて接続する。この構成に切り替えたところ、fd枯渇は再発しなかった（envoyコンテナの起動コマンドに追加した`ulimit -n 65536`は原因解消後も安全側の設定として残した）。

### app向けの別名＋EnvoyでTLS終端する構成へ切り替えた後も、3段階の実機特有の問題が続けて見つかった

いずれも`k8s/fraud-agent/envoy-configmap.yaml`のanthropic_gateway仮想ホスト・anthropic_upstreamクラスタで発生。

1. **ALPNとHTTPコーデックの不一致**：`alpn_protocols: ["h2", "http/1.1"]`と指定すると、Anthropic側がTLSネゴシエーションでh2を選択した場合に、Envoy側のHTTP層（`typed_extension_protocol_options`でhttp2_protocol_optionsを明示していないため既定でHTTP/1.1コーデックのまま）との不一致が生じ、`reset reason: protocol error`でリクエストが失敗した。**対応**：`alpn_protocols: ["http/1.1"]`のみに絞った（downstream側=egress:80リスナーもHTTP/1.1のため、コーデックを揃える形になる）。
2. **Hostヘッダーの不一致による421**：appは接続先URL（`http://anthropic-gateway`）のホスト名をそのままHostヘッダーに送るが、Envoyのupstream TLS接続のSNIは`api.anthropic.com`（クラスタ設定）。この不一致により、Anthropic側のエッジが`421 Misdirected Request`で拒否した。**対応**：ルートに`host_rewrite_literal: api.anthropic.com`を追加し、Envoyが転送時にHostヘッダーを実際のホスト名へ書き換えるようにした。
3. **HTTP/1.1 keep-alive接続の失効**：1回の会話ターン（AG-UIの1リクエスト）でAnthropic APIを複数回（ツール呼び出しを挟んで）呼ぶ構成のため、呼び出しの間隔が空くとAnthropic側のエッジが先にkeep-alive接続を閉じることがあり、Envoyが失効した接続を掴んで再利用しようとすると`API Error: The socket connection was closed unexpectedly`になった（`kubectl logs -c app`で確認、Envoy自身のaccess_logには該当リクエストの記録が残らなかった＝レスポンスヘッダー到達前に切れた）。**対応**：ルートに`retry_policy: { retry_on: "reset,connect-failure,refused-stream", num_retries: 2 }`を追加した。Envoyの再試行はレスポンスヘッダー到達前の失敗のみが対象のため、二重実行の心配は無い。

3つとも修正後、`make verify-hop`で`/chat`が実際にAnthropic APIを呼び・fraud-mcp-server経由でaccount-serviceのデータを取得し・`RUN_FINISHED`（`isError: false`、実際のトークン使用量・コスト情報込み）まで到達することを実機（k3dクラスタ内、`CLAUDE_CODE_OAUTH_TOKEN`使用）で確認した。

### Nitroで`throw createError()`すると、Nuxtのエラーページへの内部再ディスパッチがグローバルミドルウェアへ再突入し、loopbackチェックに失敗して意図しない403で上書きされる（ADR 0031）

**症状**：frontend（`services/frontend`、Nitro）のAPIルート（`server/routes/me.get.ts`等）で、未ログイン時に`throw createError({ statusCode: 401, ... })`を投げたところ、クライアントが実際に受け取るレスポンスは`401`ではなく`403 forbidden`（`server/middleware/0.security.ts`の①loopback再チェックの拒否メッセージそのもの）になった。

**原因**：`createError()`を投げるとNitroはNuxtの既定エラーページを描画しようとして`/__nuxt_error?...`への**内部**再ディスパッチを行う。この仮想リクエストは実TCP接続を伴わないため`event.node.req.socket.remoteAddress`が空文字列になるが、グローバルミドルウェア（`server/middleware/0.security.ts`、ADR 0009 §2の多層防御）は全リクエストに一律適用されるため、この内部リクエストにもloopbackチェックが働き、`remoteAddress`が空＝loopbackでないと判定されて403で弾かれる。この403がクライアントに見える最終レスポンスとして返ってしまい、本来返すはずだった401は握りつぶされる。

**対応**：API的な401（未ログイン）を返す全ルート（`me.get.ts`・`accounts/[...].ts`・`chat.post.ts`）で`throw createError()`をやめ、`setResponseStatus(event, 401); return {...}`という直接レスポンス方式に統一した。Nitroの内部エラーページ描画パイプライン自体を経由しないため、この問題を回避できる。多層防御ミドルウェアを「全リクエストに一律適用」する設計（CWE-489対策）を維持したまま、フレームワークが生成する内部リクエストとの相性問題を避けるパターンとして記録する。

### KC_HOSTNAME固定（ADR 0004）により、Keycloakが返すリダイレクト先URL・ログインフォームのaction属性は常に`http://localhost:3000`になる。異なるport-forwardポートから叩くテストスクリプトはホスト部分の付け替えが必要（ADR 0031）

**症状**：`scripts/verify-hop.sh`は`kubectl port-forward svc/edge-proxy $LOCAL_EDGE_PORT:80`（`18080`。`make keycloak-forward`の`3000`と衝突しないよう別ポートにしてある）経由でedge-proxyへアクセスするが、frontendの`/login`が返す302 LocationヘッダーやKeycloakログインフォームの`action`属性は、KC_HOSTNAME固定値（`http://localhost:3000`、ADR 0004）のままの絶対URLになっている。これをそのまま`curl`で辿ると`localhost:3000`（`make keycloak-forward`を同時に起動していない限り何も listenしていない）に接続しようとして失敗し、`set -e`環境下でスクリプトが何のエラーメッセージも出さずに早期終了する。

**原因**：KC_HOSTNAMEは「ホストから到達する固定URL」として意図的に固定されている（ADR 0004。ブラウザは常に`localhost:3000`でアクセスする前提）。Envoy（edge-proxy・frontend）自体のルーティングはHost非依存でpathのみで決まるため、実際の到達性には影響しないが、レスポンスボディ・ヘッダーに埋め込まれた絶対URLの「見た目」の値は変わらない。

**対応**：`scripts/verify-hop.sh`の`keycloak_login_redirect()`・`login_via_frontend()`で、Location/action属性から取得した絶対URLのホスト部分（`sed -E 's#^https?://[^/]+##'`でpath+query以降だけ残す）を`$EDGE`（スクリプト自身のport-forward先）へ付け替えてから`curl`する。実際のブラウザ（`localhost:3000`で一貫してアクセスする）ではこの付け替えは不要——テストスクリプトが別ポートを使う場合特有の対応。

### Envoyの固定`timeout`はLLM呼び出しの不定長な実行時間に対して根本的に相性が悪く、`idle_timeout`へ切り替えた

**症状**：`/chat`のEnvoyルートタイムアウトを既定の15秒から120秒へ緩めても、実機で`upstream connect error or disconnect/reset before headers. reset reason: connection termination`が発生する事例があった。

**原因**：固定タイムアウトは「リクエスト開始から完了までの総時間」に上限を課す仕組みであり、LLM呼び出し（ツール呼び出しを挟む複数ターンの合計）のように実行時間が本質的に不定長な処理には、どんな値を設定しても「たまたま収まるかどうか」でしかない。

**対応**：`/chat`が通る全ホップ（edge-proxy→frontend、frontend→fraud-agent、fraud-agent自身のingress）のEnvoyルートを`timeout: 0s`（総時間の上限を無効化）＋`idle_timeout: 300s`（無活動時間の上限）に変更した。あわせてfrontend-stub（`k8s/frontend/app-configmap.yaml`）の`/chat`中継を、応答を全部読み切ってから返す`forward()`から、1行ずつ即座に中継する`stream_forward()`に変更した（バッファ方式のままだとfraud-agentの処理中ずっとedge-proxy⇔frontend間の接続が無活動になり、idle_timeout化の恩恵を受けられないため）。`make verify-hop`で`/chat`がタイムアウトせず`RUN_FINISHED`まで完走することを実機確認した。
