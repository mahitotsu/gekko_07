# 実装で得た気づき・罠

実装を進める過程で見つかった、再発しそうな罠や実機検証で判明した仕様上の落とし穴を記録するナレッジベース。設計判断そのものは[architecture.md](architecture.md)、未着手の改善項目は[backlog.md](backlog.md)を参照。

各項目は原則として次の構造で記述する（当てはまらない要素は省略する）。

- **症状**：どんな問題・違和感が観察されたか
- **原因**：実機検証や調査で判明した根本原因
- **対応**：実際に取った対応・回避策

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
