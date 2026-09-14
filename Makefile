CLUSTER := gekko07
NAMESPACE := gekko

# -------------------------
# ローカル専用シークレット
# -------------------------
# PostgreSQL（ADR 0008）に永続化するようになったため、make deployのたびに値が
# 変わると既存DBに設定済みのパスワードと食い違って接続できなくなる。そのため
# 一度だけランダム生成し、$(SECRETS_DIR)（.gitignore済み）に保存して使い回す。
# ":="（即時展開）で一度だけ評価すること。"?="/"="（再帰展開）だと$(call ...)が
# 参照のたびに再評価され、Secret作成時と表示時で値がずれるバグになる。
SECRETS_DIR := .secrets

define get_secret
$(shell mkdir -p $(SECRETS_DIR) && ( [ -f $(SECRETS_DIR)/$(1) ] || openssl rand -hex 16 > $(SECRETS_DIR)/$(1) ) && cat $(SECRETS_DIR)/$(1))
endef

KEYCLOAK_ADMIN_PASSWORD := $(call get_secret,keycloak-admin-password)
POSTGRES_SUPERUSER_PASSWORD := $(call get_secret,postgres-superuser-password)
KEYCLOAK_DB_PASSWORD := $(call get_secret,keycloak-db-password)

# 1ホップ先行検証（ADR 0002/0009/0010）専用のテスト用シークレット。本番の認可設計には使わない
# （deploy-verify-hop/verify-hop参照）。
FRONTEND_CLIENT_SECRET := $(call get_secret,frontend-client-secret)
FRAUD_MCP_SERVER_CLIENT_SECRET := $(call get_secret,fraud-mcp-server-client-secret)
YAMADA_ANALYST_PASSWORD := $(call get_secret,yamada-analyst-password)

.PHONY: up down stop start status clean deploy undeploy keycloak-forward deploy-verify-hop undeploy-verify-hop verify-hop

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
# 現時点ではPostgreSQL（k8s/postgres/、素の共有エンジンのみ）とKeycloak（k8s/keycloak/、
# 自分のDB・ロールを自分のJobでプロビジョニングしてから起動する）。他サービスのマニフェストが
# 増えたら、k8s/postgres/には一切手を入れず、同様に各サービス自身のディレクトリに
# db-init-job.yaml相当を追加する形で横展開する（ADR 0008）。Postgresを先にreadyにし、
# 各サービスのDB初期化Jobを完了させてからそのサービス本体を適用する順序に意味がある。

# PostgreSQL・Keycloakをデプロイ（クラスタが起動済みであること）
deploy:
	kubectl apply -f k8s/keycloak/namespace.yaml
	@kubectl create secret generic keycloak-admin -n $(NAMESPACE) \
		--from-literal=username=admin \
		--from-literal=password=$(KEYCLOAK_ADMIN_PASSWORD) \
		--dry-run=client -o yaml | kubectl apply -f -
	@kubectl create secret generic postgres-superuser -n $(NAMESPACE) \
		--from-literal=password=$(POSTGRES_SUPERUSER_PASSWORD) \
		--dry-run=client -o yaml | kubectl apply -f -
	@kubectl create secret generic keycloak-db -n $(NAMESPACE) \
		--from-literal=username=keycloak \
		--from-literal=password=$(KEYCLOAK_DB_PASSWORD) \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f k8s/postgres/statefulset.yaml -f k8s/postgres/service.yaml
	kubectl -n $(NAMESPACE) rollout status statefulset/postgres --timeout=180s
	@# JobのPod specは不変なので、再実行するにはいったん削除してから作り直す（冪等なスクリプトなので安全）
	kubectl delete job keycloak-db-init -n $(NAMESPACE) --ignore-not-found
	kubectl apply -f k8s/keycloak/db-init-configmap.yaml -f k8s/keycloak/db-init-job.yaml
	kubectl -n $(NAMESPACE) wait --for=condition=complete job/keycloak-db-init --timeout=60s
	kubectl apply -f k8s/keycloak/realm-configmap.yaml -f k8s/keycloak/deployment.yaml -f k8s/keycloak/service.yaml
	kubectl -n $(NAMESPACE) rollout status deployment/keycloak --timeout=180s
	@echo "---"
	@echo "Keycloak admin username: admin"
	@echo "Keycloak admin password: $(KEYCLOAK_ADMIN_PASSWORD)"
	@echo "(.secrets/に保存されているため次回make deploy以降も同じ値。ADR 0008でPostgresへ永続化したため"
	@echo " 実際に有効なのはKeycloakの初回起動時にブートストラップされた値のみ。.secrets/を消してPVCも"
	@echo " 作り直した場合のみこの値でのブートストラップが再度行われる)"

# アプリ層を削除する（クラスタ自体は残す。PVCも削除するためPostgresのデータも消える）
undeploy:
	kubectl delete -f k8s/keycloak/service.yaml -f k8s/keycloak/deployment.yaml -f k8s/keycloak/realm-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/keycloak/db-init-job.yaml -f k8s/keycloak/db-init-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/postgres/service.yaml -f k8s/postgres/statefulset.yaml --ignore-not-found
	kubectl delete pvc -n $(NAMESPACE) -l app=postgres --ignore-not-found
	kubectl delete secret keycloak-admin postgres-superuser keycloak-db -n $(NAMESPACE) --ignore-not-found
	kubectl delete -f k8s/keycloak/namespace.yaml --ignore-not-found

# ホストのlocalhost:3000をKeycloakへport-forwardする（ADR 0004。フォアグラウンドで動き続けるプロセス）
keycloak-forward:
	kubectl -n $(NAMESPACE) port-forward svc/keycloak 3000:8080

# -------------------------
# 1ホップ先行検証（ADR 0002/0009/0010、fraud-mcp-server→account-service）
# -------------------------
# ここでデプロイするaccount-service/fraud-mcp-server/ext-authz-serviceはいずれもスタブ実装であり、
# 各サービスの本実装（未着手）とは別物。既存のdeploy/undeployとは独立させてあるため、
# Keycloak・Postgresだけを触りたい場合はこのターゲット群を無視してよい。

# スタブ一式＋テスト用Keycloakフィクスチャをデプロイする（make deploy実行済み・クラスタ起動済み前提）
deploy-verify-hop:
	@kubectl create secret generic frontend-client -n $(NAMESPACE) \
		--from-literal=client-secret=$(FRONTEND_CLIENT_SECRET) \
		--dry-run=client -o yaml | kubectl apply -f -
	@kubectl create secret generic fraud-mcp-server-client -n $(NAMESPACE) \
		--from-literal=client-secret=$(FRAUD_MCP_SERVER_CLIENT_SECRET) \
		--dry-run=client -o yaml | kubectl apply -f -
	@kubectl create secret generic yamada-analyst -n $(NAMESPACE) \
		--from-literal=password=$(YAMADA_ANALYST_PASSWORD) \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl delete job keycloak-test-fixtures -n $(NAMESPACE) --ignore-not-found
	kubectl apply -f k8s/keycloak/test-fixtures-configmap.yaml -f k8s/keycloak/test-fixtures-job.yaml
	kubectl -n $(NAMESPACE) wait --for=condition=complete job/keycloak-test-fixtures --timeout=60s
	kubectl apply -f k8s/ext-authz/app-configmap.yaml -f k8s/ext-authz/deployment.yaml -f k8s/ext-authz/service.yaml
	kubectl apply -f k8s/account-service/app-configmap.yaml -f k8s/account-service/envoy-configmap.yaml -f k8s/account-service/deployment.yaml -f k8s/account-service/service.yaml
	kubectl apply -f k8s/fraud-mcp-server/app-configmap.yaml -f k8s/fraud-mcp-server/envoy-configmap.yaml -f k8s/fraud-mcp-server/deployment.yaml
	kubectl -n $(NAMESPACE) rollout status deployment/ext-authz-service --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/account-service-stub --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/fraud-mcp-server-stub --timeout=120s

# scripts/verify-hop.shを実行する（deploy-verify-hop実行済み前提）
verify-hop:
	./scripts/verify-hop.sh

# 1ホップ先行検証用のスタブ一式・テストフィクスチャを削除する
undeploy-verify-hop:
	kubectl delete -f k8s/fraud-mcp-server/deployment.yaml -f k8s/fraud-mcp-server/envoy-configmap.yaml -f k8s/fraud-mcp-server/app-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/account-service/service.yaml -f k8s/account-service/deployment.yaml -f k8s/account-service/envoy-configmap.yaml -f k8s/account-service/app-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/ext-authz/service.yaml -f k8s/ext-authz/deployment.yaml -f k8s/ext-authz/app-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/keycloak/test-fixtures-job.yaml -f k8s/keycloak/test-fixtures-configmap.yaml --ignore-not-found
	kubectl delete secret frontend-client fraud-mcp-server-client yamada-analyst -n $(NAMESPACE) --ignore-not-found

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
