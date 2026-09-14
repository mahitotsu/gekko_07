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

### ログイントークンに`aud`クレームが実は含まれていない（未対応・既知のギャップ）

**症状**：`frontend`クライアントでROPCログインして得たトークンをデコードすると、`aud`クレームが一切存在しなかった（`azp: frontend`はあるが`aud`は無し）。access-control-design.md「認証」節は「ログイントークンの`aud`は`frontend`（単一）」と明記している。

**原因**：`aud`クレームは、要求元クライアントに割り当てられたclient scope上のAudience protocol mapperから生成される（上記「Keycloak Standard Token Exchange V2」の項参照）。ログイン自体（Authorization Code / ROPC）はToken Exchangeではなく、かつfrontend自身への自己audience付与マッパーを持つscopeは一つも定義していないため、素のログイントークンには`aud`が乗らない。

**対応**：未対応。この1ホップ先行検証の経路（フロントエンドが発行済みの委任トークンをsubject_tokenとして使う場面）には影響しないため今回は見送ったが、frontend実装時にはfrontend自身を指す`oidc-audience-mapper`を持つdefault（optionalではなく）client scope、またはfrontendクライアント自身の"dedicated"protocol mapperを追加する必要がある（backlog.md参照）。

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
