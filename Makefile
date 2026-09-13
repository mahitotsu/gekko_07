CLUSTER := gekko07
NAMESPACE := gekko
# Keycloak管理者パスワード。既定は毎回ランダム生成（永続化なしのstart-devモードのため
# `make deploy`のたびにKeycloakの状態自体が作り直され、パスワードが変わっても支障がない）。
# 固定したい場合は `make deploy KEYCLOAK_ADMIN_PASSWORD=...` で上書きする
# （コマンドラインで渡した値はmakeの標準動作により以下の既定値より優先される）。
# ":="（即時展開）で一度だけ評価する。"?="/"="（再帰展開）だと$(shell ...)が参照の
# たびに再実行され、Secret作成時と表示時で値がずれるバグになるため使わないこと。
KEYCLOAK_ADMIN_PASSWORD := $(shell openssl rand -hex 12)

.PHONY: up down stop start status clean deploy undeploy keycloak-forward

# -------------------------
# クラスタ操作
# -------------------------
# cluster-up相当の処理（k3dクラスタ自体の生成・破棄・起動停止）と、
# アプリのデプロイ（deploy/undeploy）は分離した。upはクラスタ作成後に
# deployも呼ぶが、クラスタを止めずにアプリ層だけ入れ替えたい場合は
# deploy/undeployを直接使う。

# クラスタを作成し、アプリ（Keycloak等）をデプロイする（既に存在する場合はクラスタ作成をスキップ）
up:
	@k3d cluster list $(CLUSTER) >/dev/null 2>&1 \
		&& echo "cluster '$(CLUSTER)' already exists" \
		|| k3d cluster create --config k3d/cluster-config.yaml
	$(MAKE) deploy

# クラスタを完全に削除する（データも含めて全消去。docker composeのdown -vに相当）
down:
	k3d cluster delete $(CLUSTER)

# downのエイリアス（compose版のcleanとの対称性のため）
clean: down

# -------------------------
# アプリのデプロイ
# -------------------------
# 現時点ではKeycloakのみ（k8s/keycloak/）。他サービスのマニフェストが増えたら
# 同様にk8s/配下へディレクトリを追加し、ここに適用ステップを積み重ねる。

# Keycloakをデプロイ（クラスタが起動済みであること）
deploy:
	kubectl apply -f k8s/keycloak/namespace.yaml
	@kubectl create secret generic keycloak-admin -n $(NAMESPACE) \
		--from-literal=username=admin \
		--from-literal=password=$(KEYCLOAK_ADMIN_PASSWORD) \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f k8s/keycloak/realm-configmap.yaml -f k8s/keycloak/deployment.yaml -f k8s/keycloak/service.yaml
	@# Secret変更はPodへ自動反映されないため、毎回明示的に再起動して新パスワードを確実に適用する
	kubectl -n $(NAMESPACE) rollout restart deployment/keycloak
	kubectl -n $(NAMESPACE) rollout status deployment/keycloak --timeout=180s
	@echo "---"
	@echo "Keycloak admin username: admin"
	@echo "Keycloak admin password: $(KEYCLOAK_ADMIN_PASSWORD)"
	@echo "(この情報は永続化されない。パスワードを忘れたら再度 'make deploy' でPodを作り直すこと)"

# アプリ層を削除する（クラスタ自体は残す）
undeploy:
	kubectl delete -f k8s/keycloak/service.yaml -f k8s/keycloak/deployment.yaml -f k8s/keycloak/realm-configmap.yaml --ignore-not-found
	kubectl delete secret keycloak-admin -n $(NAMESPACE) --ignore-not-found
	kubectl delete -f k8s/keycloak/namespace.yaml --ignore-not-found

# ホストのlocalhost:3000をKeycloakへport-forwardする（ADR 0004。フォアグラウンドで動き続けるプロセス）
keycloak-forward:
	kubectl -n $(NAMESPACE) port-forward svc/keycloak 3000:8080

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
	@echo "---"
	@kubectl -n $(NAMESPACE) get pods 2>/dev/null || echo "(namespace '$(NAMESPACE)' not reachable)"
