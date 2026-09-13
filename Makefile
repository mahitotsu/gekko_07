CLUSTER := gekko07

.PHONY: up down stop start status clean

# -------------------------
# クラスタ操作
# -------------------------
# 現時点ではk3dクラスタ自体の生成・破棄・起動停止のみを扱う。
# アプリのK8sマニフェストを追加したら、up/downはkubectl apply/deleteも
# 行うように拡張する（cluster-up相当の処理とアプリのデプロイを分離するか
# どうかはその時点で判断する）。

# クラスタを作成する（既に存在する場合は何もしない）
up:
	@k3d cluster list $(CLUSTER) >/dev/null 2>&1 \
		&& echo "cluster '$(CLUSTER)' already exists" \
		|| k3d cluster create --config k3d/cluster-config.yaml

# クラスタを完全に削除する（データも含めて全消去。docker composeのdown -vに相当）
down:
	k3d cluster delete $(CLUSTER)

# downのエイリアス（compose版のcleanとの対称性のため）
clean: down

# クラスタのコンテナを停止する（状態は保持したまま。再開はstartで）
stop:
	k3d cluster stop $(CLUSTER)

# stopで止めたクラスタを再開する
start:
	k3d cluster start $(CLUSTER)

# クラスタとノードの状態を確認する
status:
	k3d cluster list
	@echo "---"
	@kubectl get nodes 2>/dev/null || echo "(cluster not reachable)"
