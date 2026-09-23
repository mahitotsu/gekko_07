CLUSTER := gekko07
NAMESPACE := gekko

# -------------------------
# ローカル専用シークレット
# -------------------------
# PostgreSQL永続化（ADR 0008）以降、値が変わると既存DBのパスワードと食い違うため、
# 一度だけランダム生成し$(SECRETS_DIR)（.gitignore済み）に保存して使い回す。
# 呼び出し側は":="（即時展開）で一度だけ評価すること。"?="/"="（再帰展開）だと
# $(call ...)が参照のたびに再評価され、Secret作成時と表示時で値がずれる。
SECRETS_DIR := .secrets

define get_secret
$(shell mkdir -p $(SECRETS_DIR) && ( [ -f $(SECRETS_DIR)/$(1) ] || openssl rand -hex 16 > $(SECRETS_DIR)/$(1) ) && cat $(SECRETS_DIR)/$(1))
endef

# Secretを冪等に作成/更新する（`kubectl create ... --dry-run=client -o yaml | kubectl apply -f -`の定型を
# 共通化。$(2)には`--from-literal=key=value`を1つ以上、スペース区切りで渡す）
define upsert_secret
@kubectl create secret generic $(1) -n $(NAMESPACE) $(2) --dry-run=client -o yaml | kubectl apply -f -
endef

# TLS Secretを冪等に作成/更新する（$(2)=namespace, $(3)=証明書ファイル, $(4)=秘密鍵ファイル）
define upsert_tls_secret
@kubectl create secret tls $(1) -n $(2) --cert=$(3) --key=$(4) --dry-run=client -o yaml | kubectl apply -f -
endef

KEYCLOAK_ADMIN_PASSWORD := $(call get_secret,keycloak-admin-password)
POSTGRES_SUPERUSER_PASSWORD := $(call get_secret,postgres-superuser-password)
KEYCLOAK_DB_PASSWORD := $(call get_secret,keycloak-db-password)

# 1ホップ先行検証（ADR 0002/0009/0010）専用のテスト用シークレット。本番の認可設計には使わない
# （deploy-verify-hop/verify-hop参照）。
YAMADA_ANALYST_PASSWORD := $(call get_secret,yamada-analyst-password)
SUZUKI_SENIOR_PASSWORD := $(call get_secret,suzuki-senior-password)
TANAKA_JUNIOR_PASSWORD := $(call get_secret,tanaka-junior-password)

# account-service・analyst-attribute-service・fraud-detection-engine自身のDB接続用パスワード
# (ADR 0008・0026・0027。postgres-superuser-password等と同じ「一度だけ生成しSECRETS_DIRに保存」
# パターン)。
ACCOUNT_SERVICE_DB_PASSWORD := $(call get_secret,account-service-db-password)
ANALYST_ATTRIBUTE_SERVICE_DB_PASSWORD := $(call get_secret,analyst-attribute-service-db-password)
FRAUD_DETECTION_ENGINE_DB_PASSWORD := $(call get_secret,fraud-detection-engine-db-password)

# fraud-agent(ADR 0030)がAnthropic APIを呼ぶための実クレデンシャル(`claude setup-token`で
# 取得したOAuthトークン)。openssl randで自動生成できないため、get_secretとは別に定義する:
# $(SECRETS_DIR)/claude-code-oauth-tokenがあればそれを再利用し、無ければ環境変数
# CLAUDE_CODE_OAUTH_TOKENから読み取って保存する。どちらも無ければ空文字列のままにし、
# deployターゲット側で明確なエラーとして早期に停止する。
CLAUDE_CODE_OAUTH_TOKEN_FILE := $(SECRETS_DIR)/claude-code-oauth-token
CLAUDE_CODE_OAUTH_TOKEN := $(shell mkdir -p $(SECRETS_DIR) && \
	if [ -f $(CLAUDE_CODE_OAUTH_TOKEN_FILE) ]; then cat $(CLAUDE_CODE_OAUTH_TOKEN_FILE); \
	elif [ -n "$$CLAUDE_CODE_OAUTH_TOKEN" ]; then printf '%s' "$$CLAUDE_CODE_OAUTH_TOKEN" > $(CLAUDE_CODE_OAUTH_TOKEN_FILE) && cat $(CLAUDE_CODE_OAUTH_TOKEN_FILE); \
	else echo ""; fi)

# SPIRE bundle endpoint（ADR 0019）自身のTLS終端用の使い捨て自己署名証明書（SPIRE発行SVIDとは
# 無関係。KeycloakがKC_TRUSTSTORE_PATHSで信頼する）。get_secretと同じ「一度だけ生成し使い回す」
# パターンだが、ファイルが2つ（crt/key）あるため専用に定義する。
SPIRE_BUNDLE_ENDPOINT_CERT_DUMMY := $(shell mkdir -p $(SECRETS_DIR) && \
	( [ -f $(SECRETS_DIR)/spire-bundle-endpoint.crt ] || \
	  openssl req -x509 -newkey rsa:2048 -nodes \
	    -keyout $(SECRETS_DIR)/spire-bundle-endpoint.key \
	    -out $(SECRETS_DIR)/spire-bundle-endpoint.crt \
	    -days 3650 -subj "/CN=spire-server.spire.svc.cluster.local" \
	    -addext "subjectAltName=DNS:spire-server.spire.svc.cluster.local,DNS:spire-server" \
	    >/dev/null 2>&1 ) )

.PHONY: up down stop start status network-status clean deploy undeploy sync keycloak-forward keycloak-reimport-realm deploy-verify-hop undeploy-verify-hop verify-hop deploy-spire undeploy-spire deploy-network-policy undeploy-network-policy deploy-observability undeploy-observability grafana-forward verify-observability build-account-service build-analyst-attribute-service build-fraud-detection-engine build-fraud-mcp-server build-fraud-agent build-frontend build-keycloak

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
# デプロイ順序：SPIRE(ADR 0016、Keycloak/postgresのEnvoyサイドカーがspire-agentソケットに
# 依存) → Postgres(ADR 0008、db-init-job.yamlパターンで各サービスが自分のDB・ロールを
# プロビジョニングする) → Keycloak → edge-proxy(ADR 0017) → 各サービスのDB初期化Job →
# 各サービス本体。account-service・analyst-attribute-service・fraud-detection-engineは
# コンパイルを要するためbuild-*ターゲットでdocker buildしたイメージを`k3d image import`で
# クラスタへ持ち込む（レジストリは使わない）。各サービスの実装経緯・base trackへの格上げ理由は
# ADR 0026/0027/0029/0030/0031参照。

# provenance/SBOM attestationはデフォルトで毎回ビルドし直され、全レイヤーがキャッシュヒットして
# 中身が一切変わらなくても最終的なイメージID(manifest)が毎回変わってしまう(buildx/BuildKitの
# 既定動作)。make syncがイメージIDの差分で「実際に変更があったサービスだけ」を判定する前提が
# 崩れるため、無効化して中身が同じビルドは同じIDになるようにする。
DOCKER_BUILD_FLAGS := --provenance=false --sbom=false

# services/account-serviceをビルドし、k3dクラスタへイメージを持ち込む
build-account-service:
	docker build $(DOCKER_BUILD_FLAGS) -t gekko07/account-service:local services/account-service
	k3d image import gekko07/account-service:local -c $(CLUSTER)

# services/analyst-attribute-serviceをビルドし、k3dクラスタへイメージを持ち込む
build-analyst-attribute-service:
	docker build $(DOCKER_BUILD_FLAGS) -t gekko07/analyst-attribute-service:local services/analyst-attribute-service
	k3d image import gekko07/analyst-attribute-service:local -c $(CLUSTER)

# services/fraud-detection-engineをビルドし、k3dクラスタへイメージを持ち込む
build-fraud-detection-engine:
	docker build $(DOCKER_BUILD_FLAGS) -t gekko07/fraud-detection-engine:local services/fraud-detection-engine
	k3d image import gekko07/fraud-detection-engine:local -c $(CLUSTER)

# services/fraud-mcp-serverをビルドし、k3dクラスタへイメージを持ち込む
build-fraud-mcp-server:
	docker build $(DOCKER_BUILD_FLAGS) -t gekko07/fraud-mcp-server:local services/fraud-mcp-server
	k3d image import gekko07/fraud-mcp-server:local -c $(CLUSTER)

# services/fraud-agentをビルドし、k3dクラスタへイメージを持ち込む
build-fraud-agent:
	docker build $(DOCKER_BUILD_FLAGS) -t gekko07/fraud-agent:local services/fraud-agent
	k3d image import gekko07/fraud-agent:local -c $(CLUSTER)

# services/frontendをビルドし、k3dクラスタへイメージを持ち込む(ADR 0031)
build-frontend:
	docker build $(DOCKER_BUILD_FLAGS) -t gekko07/frontend:local services/frontend
	k3d image import gekko07/frontend:local -c $(CLUSTER)

# services/keycloakで`kc.sh build`済みの最適化イメージをビルドし、k3dクラスタへ持ち込む
build-keycloak:
	docker build $(DOCKER_BUILD_FLAGS) -t gekko07/keycloak:local services/keycloak
	k3d image import gekko07/keycloak:local -c $(CLUSTER)

# PostgreSQL・SPIRE・Keycloak・edge-proxy・account-service・analyst-attribute-service・
# fraud-detection-engine・fraud-mcp-server・fraud-agent・frontendをデプロイ（クラスタが起動済みであること）
deploy:
	kubectl apply -f k8s/keycloak/namespace.yaml
	$(call upsert_secret,keycloak-admin,--from-literal=username=admin --from-literal=password=$(KEYCLOAK_ADMIN_PASSWORD))
	$(call upsert_secret,postgres-superuser,--from-literal=password=$(POSTGRES_SUPERUSER_PASSWORD))
	$(call upsert_secret,keycloak-db,--from-literal=username=keycloak --from-literal=password=$(KEYCLOAK_DB_PASSWORD))
	@# postgresもEnvoyサイドカーを持つため、deploy-spireを先に呼ぶ(ADR 0028)。
	$(MAKE) deploy-spire
	kubectl apply -f k8s/postgres/envoy-configmap.yaml -f k8s/postgres/statefulset.yaml -f k8s/postgres/service.yaml
	kubectl -n $(NAMESPACE) rollout status statefulset/postgres --timeout=180s
	@# postgres接続用の新ポート(6432)を使う5サービスのNetworkPolicyは各Deploymentより前倒しで
	@# 適用する。既存クラスタへの再デプロイ時にdefault-denyへ反映漏れるとconnection refusedに
	@# なるため(ADR 0028、insights.md参照)。
	kubectl apply -f k8s/postgres/networkpolicy.yaml -f k8s/keycloak/networkpolicy.yaml \
		-f k8s/account-service/networkpolicy.yaml -f k8s/analyst-attribute-service/networkpolicy.yaml \
		-f k8s/fraud-detection-engine/networkpolicy.yaml
	@# JobのPod specは不変なので、再実行するにはいったん削除してから作り直す（冪等なスクリプトなので安全）
	kubectl delete job keycloak-db-init -n $(NAMESPACE) --ignore-not-found
	kubectl apply -f k8s/keycloak/db-init-configmap.yaml -f k8s/keycloak/db-init-envoy-configmap.yaml -f k8s/keycloak/db-init-job.yaml
	kubectl -n $(NAMESPACE) wait --for=condition=complete job/keycloak-db-init --timeout=60s
	@# KeycloakがSPIRE Serverのbundle endpoint(ADR 0019)をHTTPSで検証するためのtruststore。
	@# spire-bundle-endpoint.crtの秘密鍵は含めない(検証側は証明書のみで足りる)
	kubectl create secret generic spire-bundle-endpoint-ca -n $(NAMESPACE) \
		--from-file=ca.crt=$(SECRETS_DIR)/spire-bundle-endpoint.crt --dry-run=client -o yaml | kubectl apply -f -
	$(MAKE) build-keycloak
	kubectl apply -f k8s/keycloak/realm-configmap.yaml -f k8s/keycloak/envoy-configmap.yaml -f k8s/keycloak/deployment.yaml -f k8s/keycloak/service.yaml
	kubectl -n $(NAMESPACE) rollout status deployment/keycloak --timeout=180s
	kubectl apply -f k8s/edge-proxy/envoy-configmap.yaml -f k8s/edge-proxy/deployment.yaml -f k8s/edge-proxy/service.yaml
	kubectl -n $(NAMESPACE) rollout status deployment/edge-proxy --timeout=120s
	$(call upsert_secret,account-service-db,--from-literal=username=account_service --from-literal=password=$(ACCOUNT_SERVICE_DB_PASSWORD))
	$(call upsert_secret,analyst-attribute-service-db,--from-literal=username=analyst_attribute_service --from-literal=password=$(ANALYST_ATTRIBUTE_SERVICE_DB_PASSWORD))
	$(call upsert_secret,fraud-detection-engine-db,--from-literal=username=fraud_detection_engine --from-literal=password=$(FRAUD_DETECTION_ENGINE_DB_PASSWORD))
	@# 3サービスのNetworkPolicy(db-init Job自身のegress許可を含む)は上で前倒し適用済み(ADR 0028)。
	kubectl delete job account-service-db-init analyst-attribute-service-db-init fraud-detection-engine-db-init -n $(NAMESPACE) --ignore-not-found
	kubectl apply -f k8s/account-service/db-init-configmap.yaml -f k8s/account-service/db-init-envoy-configmap.yaml -f k8s/account-service/db-init-job.yaml
	kubectl apply -f k8s/analyst-attribute-service/db-init-configmap.yaml -f k8s/analyst-attribute-service/db-init-envoy-configmap.yaml -f k8s/analyst-attribute-service/db-init-job.yaml
	kubectl apply -f k8s/fraud-detection-engine/db-init-configmap.yaml -f k8s/fraud-detection-engine/db-init-envoy-configmap.yaml -f k8s/fraud-detection-engine/db-init-job.yaml
	kubectl -n $(NAMESPACE) wait --for=condition=complete job/account-service-db-init --timeout=60s
	kubectl -n $(NAMESPACE) wait --for=condition=complete job/analyst-attribute-service-db-init --timeout=60s
	kubectl -n $(NAMESPACE) wait --for=condition=complete job/fraud-detection-engine-db-init --timeout=60s
	$(MAKE) build-account-service
	$(MAKE) build-analyst-attribute-service
	$(MAKE) build-fraud-detection-engine
	$(MAKE) build-fraud-mcp-server
	$(MAKE) build-fraud-agent
	kubectl apply -f k8s/analyst-attribute-service/envoy-configmap.yaml -f k8s/analyst-attribute-service/deployment.yaml -f k8s/analyst-attribute-service/service.yaml
	kubectl apply -f k8s/account-service/token-exchange-app-configmap.yaml -f k8s/account-service/envoy-configmap.yaml -f k8s/account-service/deployment.yaml -f k8s/account-service/service.yaml
	@# ADR 0027:fraud-detection-engineはingressを持たないためService(k8s/fraud-detection-engine/
	@# service.yaml相当)は存在しない。
	kubectl apply -f k8s/fraud-detection-engine/client-credentials-app-configmap.yaml -f k8s/fraud-detection-engine/envoy-configmap.yaml -f k8s/fraud-detection-engine/deployment.yaml
	@# ADR 0029:fraud-mcp-serverはaccount-service/fraud-detection-engineと違いapp-configmap.yaml
	@# を持たない(ビルド済みイメージで代替)。token-exchange-app-configmap.yamlはADR 0019のまま無変更。
	kubectl apply -f k8s/fraud-mcp-server/token-exchange-app-configmap.yaml -f k8s/fraud-mcp-server/envoy-configmap.yaml -f k8s/fraud-mcp-server/deployment.yaml -f k8s/fraud-mcp-server/service.yaml
	@# CLAUDE_CODE_OAUTH_TOKEN未設定ならSecret未作成のままCrashLoopBackOFFするより早く停止する。
	@if [ -z "$(CLAUDE_CODE_OAUTH_TOKEN)" ]; then \
		echo "CLAUDE_CODE_OAUTH_TOKENが未設定です。'claude setup-token'で取得したトークンを" >&2; \
		echo "  echo -n 'sk-ant-oat01-...' > $(CLAUDE_CODE_OAUTH_TOKEN_FILE)" >&2; \
		echo "として保存するか、環境変数CLAUDE_CODE_OAUTH_TOKENとして渡してから再実行してください。" >&2; \
		exit 1; \
	fi
	$(call upsert_secret,fraud-agent-claude,--from-literal=oauth-token=$(CLAUDE_CODE_OAUTH_TOKEN))
	@# fraud-agent-stub(ADR 0023)からのリネーム(ADR 0030)に伴う旧Deploymentの後始末。
	kubectl delete deployment fraud-agent-stub -n $(NAMESPACE) --ignore-not-found
	kubectl apply -f k8s/fraud-agent/token-exchange-app-configmap.yaml -f k8s/fraud-agent/envoy-configmap.yaml -f k8s/fraud-agent/deployment.yaml -f k8s/fraud-agent/service.yaml
	$(MAKE) build-frontend
	@# frontend-stub(ADR 0024)からのリネーム(ADR 0031)に伴う旧Deploymentの後始末。
	kubectl delete deployment frontend-stub -n $(NAMESPACE) --ignore-not-found
	kubectl apply -f k8s/frontend/token-exchange-app-configmap.yaml -f k8s/frontend/envoy-configmap.yaml -f k8s/frontend/deployment.yaml -f k8s/frontend/service.yaml
	kubectl -n $(NAMESPACE) rollout status deployment/analyst-attribute-service --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deployment/account-service --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deployment/fraud-detection-engine --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deployment/fraud-mcp-server --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deployment/fraud-agent --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deployment/frontend --timeout=180s
	$(MAKE) deploy-observability
	$(MAKE) deploy-network-policy
	@echo "---"
	@echo "Keycloak admin username: admin"
	@echo "Keycloak admin password: $(KEYCLOAK_ADMIN_PASSWORD)"
	@echo "(.secrets/に保存されているため次回make deploy以降も同じ値。ADR 0008でPostgresへ永続化したため"
	@echo " 実際に有効なのはKeycloakの初回起動時にブートストラップされた値のみ。.secrets/を消してPVCも"
	@echo " 作り直した場合のみこの値でのブートストラップが再度行われる)"

# scripts/sync.shを実行する(deploy済みのクラスタへ、編集後の再ビルド・再反映を素早く行う開発
# ループ用。全サービスをビルドし、イメージが実際に変わったサービスだけrollout restartする)
sync:
	./scripts/sync.sh

# アプリ層を削除する（クラスタ自体は残す。PVCも削除するためPostgresのデータも消える）
undeploy:
	$(MAKE) undeploy-network-policy
	kubectl delete -f k8s/account-service/service.yaml -f k8s/account-service/deployment.yaml -f k8s/account-service/envoy-configmap.yaml -f k8s/account-service/token-exchange-app-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/account-service/db-init-job.yaml -f k8s/account-service/db-init-envoy-configmap.yaml -f k8s/account-service/db-init-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/analyst-attribute-service/service.yaml -f k8s/analyst-attribute-service/deployment.yaml -f k8s/analyst-attribute-service/envoy-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/analyst-attribute-service/db-init-job.yaml -f k8s/analyst-attribute-service/db-init-envoy-configmap.yaml -f k8s/analyst-attribute-service/db-init-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/fraud-detection-engine/deployment.yaml -f k8s/fraud-detection-engine/envoy-configmap.yaml -f k8s/fraud-detection-engine/client-credentials-app-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/fraud-detection-engine/db-init-job.yaml -f k8s/fraud-detection-engine/db-init-envoy-configmap.yaml -f k8s/fraud-detection-engine/db-init-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/fraud-mcp-server/service.yaml -f k8s/fraud-mcp-server/deployment.yaml -f k8s/fraud-mcp-server/envoy-configmap.yaml -f k8s/fraud-mcp-server/token-exchange-app-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/fraud-agent/service.yaml -f k8s/fraud-agent/deployment.yaml -f k8s/fraud-agent/envoy-configmap.yaml -f k8s/fraud-agent/token-exchange-app-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/frontend/service.yaml -f k8s/frontend/deployment.yaml -f k8s/frontend/envoy-configmap.yaml -f k8s/frontend/token-exchange-app-configmap.yaml --ignore-not-found
	kubectl delete secret fraud-agent-claude -n $(NAMESPACE) --ignore-not-found
	kubectl delete secret account-service-db analyst-attribute-service-db fraud-detection-engine-db -n $(NAMESPACE) --ignore-not-found
	kubectl delete -f k8s/edge-proxy/service.yaml -f k8s/edge-proxy/deployment.yaml -f k8s/edge-proxy/envoy-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/keycloak/service.yaml -f k8s/keycloak/deployment.yaml -f k8s/keycloak/envoy-configmap.yaml -f k8s/keycloak/realm-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/keycloak/db-init-job.yaml -f k8s/keycloak/db-init-envoy-configmap.yaml -f k8s/keycloak/db-init-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/postgres/service.yaml -f k8s/postgres/statefulset.yaml -f k8s/postgres/envoy-configmap.yaml --ignore-not-found
	kubectl delete pvc -n $(NAMESPACE) -l app=postgres --ignore-not-found
	kubectl delete secret keycloak-admin postgres-superuser keycloak-db -n $(NAMESPACE) --ignore-not-found
	kubectl delete -f k8s/keycloak/namespace.yaml --ignore-not-found
	$(MAKE) undeploy-observability
	$(MAKE) undeploy-spire

# ホストのlocalhost:3000をKeycloakへport-forwardする（ADR 0004・0017。edge-proxy経由。
# フォアグラウンドで動き続けるプロセス）
keycloak-forward:
	kubectl -n $(NAMESPACE) port-forward svc/edge-proxy 3000:80

# ホストのlocalhost:3000をGrafana(otel-lgtm、ADR 0025)へport-forwardする。keycloak-forwardと
# ローカルポートが競合するため同時には使えない(必要なら片方のローカルポート番号を変えて実行する)
grafana-forward:
	kubectl -n observability port-forward svc/otel-lgtm 3000:3000

# realm-configmap.yaml変更後にKeycloakへ反映させる（--import-realmは初回起動時のみ有効なため。
# 詳細・実行後にmake deploy-verify-hopが必要な理由はinsights.md参照）。
keycloak-reimport-realm:
	kubectl apply -f k8s/keycloak/realm-configmap.yaml
	kubectl -n $(NAMESPACE) exec deploy/keycloak -- /opt/keycloak/bin/kcadm.sh config credentials \
		--server http://localhost:8080 --realm master --user admin --password $(KEYCLOAK_ADMIN_PASSWORD)
	kubectl -n $(NAMESPACE) exec deploy/keycloak -- /opt/keycloak/bin/kcadm.sh delete realms/gekko
	kubectl -n $(NAMESPACE) rollout restart deployment/keycloak
	kubectl -n $(NAMESPACE) rollout status deployment/keycloak --timeout=180s

# -------------------------
# 1ホップ先行検証（ADR 0002/0009/0010、fraud-mcp-server→account-service）
# -------------------------
# 各サービスは全て本実装済みでbase track（make deploy）側に属するため、ここでは表6の
# テストアナリスト属性の投入のみを扱う。deploy/undeployとは独立させてあるため、
# Keycloak・Postgresだけを触りたい場合はこのターゲット群を無視してよい。

# テスト用Keycloakフィクスチャをデプロイする（make deploy実行済み・クラスタ起動済み前提）
deploy-verify-hop:
	$(call upsert_secret,yamada-analyst,--from-literal=password=$(YAMADA_ANALYST_PASSWORD))
	$(call upsert_secret,suzuki-senior,--from-literal=password=$(SUZUKI_SENIOR_PASSWORD))
	$(call upsert_secret,tanaka-junior,--from-literal=password=$(TANAKA_JUNIOR_PASSWORD))
	kubectl delete job keycloak-test-fixtures -n $(NAMESPACE) --ignore-not-found
	kubectl apply -f k8s/keycloak/test-fixtures-configmap.yaml -f k8s/keycloak/test-fixtures-job.yaml
	kubectl -n $(NAMESPACE) wait --for=condition=complete job/keycloak-test-fixtures --timeout=60s
	@# 表6のテストアナリスト属性(Keycloakユーザー確定後でないとUUIDが定まらないためフィクスチャ
	@# 側で投入する)のみを扱う。SPIRE・各サービス本体はmake deploy側で既にデプロイ済み。
	kubectl delete job analyst-attribute-service-seed -n $(NAMESPACE) --ignore-not-found
	kubectl apply -f k8s/analyst-attribute-service/seed-configmap.yaml -f k8s/analyst-attribute-service/seed-job.yaml
	kubectl -n $(NAMESPACE) wait --for=condition=complete job/analyst-attribute-service-seed --timeout=60s

# scripts/verify-hop.shを実行する（deploy-verify-hop実行済み前提）
verify-hop:
	./scripts/verify-hop.sh

# 1ホップ先行検証用のテストフィクスチャを削除する(SPIRE・各サービス本体はbase track側の
# 前提コンポーネントのためここでは扱わない)
undeploy-verify-hop:
	kubectl delete -f k8s/analyst-attribute-service/seed-job.yaml -f k8s/analyst-attribute-service/seed-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/keycloak/test-fixtures-job.yaml -f k8s/keycloak/test-fixtures-configmap.yaml --ignore-not-found
	kubectl delete secret yamada-analyst suzuki-senior tanaka-junior -n $(NAMESPACE) --ignore-not-found

# -------------------------
# SPIFFE/SPIRE（ADR 0012/0015/0016/0019/0020。account-service・fraud-mcp-server・
# fraud-detection-engine・keycloakへのmTLS）
# -------------------------
# server→agent→registration entriesの順に起動・疎通を待つ必要がある（agentはserverに疎通できて
# 初めてk8s_psatでattestできる。entries Jobはspire-serverの管理APIをkubectl execで叩く）。
# ADR 0016でKeycloakのEnvoyサイドカーがこのSPIRE基盤に依存するようになったため、deploy target
# 自身から(Keycloak applyより前に)呼ばれるbase trackの前提コンポーネントになった。

# SPIRE server/agent/registration entriesをデプロイする（namespace gekkoとは別。クラスタ起動済み前提）
deploy-spire:
	kubectl apply -f k8s/spire/namespace.yaml
	$(call upsert_tls_secret,spire-bundle-endpoint-tls,spire,$(SECRETS_DIR)/spire-bundle-endpoint.crt,$(SECRETS_DIR)/spire-bundle-endpoint.key)
	kubectl apply -f k8s/spire/server-account.yaml -f k8s/spire/spire-bundle-configmap.yaml \
		-f k8s/spire/server-configmap.yaml -f k8s/spire/server-service.yaml -f k8s/spire/server-statefulset.yaml
	kubectl -n spire rollout status statefulset/spire-server --timeout=120s
	kubectl apply -f k8s/spire/agent-account.yaml -f k8s/spire/agent-configmap.yaml -f k8s/spire/agent-daemonset.yaml
	kubectl -n spire rollout status daemonset/spire-agent --timeout=120s
	kubectl apply -f k8s/spire/entries-account.yaml -f k8s/spire/entries-configmap.yaml
	@# Jobのpod specは不変なので、再実行するにはいったん削除してから作り直す（create-entries.sh自体は
	@# entry showで存在確認してから作成するため、冪等に再実行できる）
	kubectl delete job spire-entries -n spire --ignore-not-found
	kubectl apply -f k8s/spire/entries-job.yaml
	@# 60sだと初回実行時にタイムアウトする例があったため180sへ拡張（insights.md参照）
	kubectl -n spire wait --for=condition=complete job/spire-entries --timeout=180s

# SPIRE server/agent/registration entries一式を削除する（spire namespaceごと削除）
undeploy-spire:
	kubectl delete -f k8s/spire/entries-job.yaml -f k8s/spire/entries-configmap.yaml -f k8s/spire/entries-account.yaml --ignore-not-found
	kubectl delete -f k8s/spire/agent-daemonset.yaml -f k8s/spire/agent-configmap.yaml -f k8s/spire/agent-account.yaml --ignore-not-found
	kubectl delete -f k8s/spire/server-statefulset.yaml -f k8s/spire/server-service.yaml -f k8s/spire/server-configmap.yaml \
		-f k8s/spire/spire-bundle-configmap.yaml -f k8s/spire/server-account.yaml --ignore-not-found
	kubectl delete pvc -n spire -l app=spire-server --ignore-not-found
	kubectl delete -f k8s/spire/namespace.yaml --ignore-not-found

# -------------------------
# 監査ログ集約（ADR 0025。Alloy+otel-lgtmでEnvoyアクセスログ・Keycloakイベントログを集約する）
# -------------------------
# gekko/spireとは別のobservability namespaceに置く。deploy-spireの後・deploy-network-policyの前に
# 呼ぶ（Envoy/Keycloakのaccess_log/eventsListeners出力を後からAlloyが拾えれば十分なため、
# 呼び出し順序自体に強い依存はない）。

# Alloy（収集・転送）+ otel-lgtm（Loki+Grafana+OTel Collector一体型）をデプロイする
deploy-observability:
	kubectl apply -f k8s/observability/namespace.yaml
	kubectl apply -f k8s/observability/alloy-account.yaml -f k8s/observability/alloy-configmap.yaml
	kubectl apply -f k8s/observability/otel-lgtm-deployment.yaml -f k8s/observability/otel-lgtm-service.yaml
	kubectl -n observability rollout status deployment/otel-lgtm --timeout=180s
	kubectl apply -f k8s/observability/alloy-daemonset.yaml
	kubectl -n observability rollout status daemonset/alloy --timeout=120s
	kubectl apply -f k8s/observability/default-deny.yaml -f k8s/observability/allow-dns.yaml -f k8s/observability/networkpolicy.yaml

# 監査ログ集約基盤一式を削除する（observability namespaceごと削除）
undeploy-observability:
	kubectl delete -f k8s/observability/networkpolicy.yaml -f k8s/observability/allow-dns.yaml -f k8s/observability/default-deny.yaml --ignore-not-found
	kubectl delete -f k8s/observability/alloy-daemonset.yaml --ignore-not-found
	kubectl delete -f k8s/observability/otel-lgtm-service.yaml -f k8s/observability/otel-lgtm-deployment.yaml --ignore-not-found
	kubectl delete -f k8s/observability/alloy-configmap.yaml -f k8s/observability/alloy-account.yaml --ignore-not-found
	kubectl delete -f k8s/observability/namespace.yaml --ignore-not-found

# scripts/verify-observability.shを実行する（deploy-observability・deploy-verify-hop実行済み前提）
verify-observability:
	./scripts/verify-observability.sh

# -------------------------
# NetworkPolicy（ADR 0018。gekko namespace全体のL3/4 default-deny）
# -------------------------
# 全サービスのPod/Serviceが既に存在する状態で適用する前提（podSelectorが参照する
# ラベルの存在確認はしないため、順序自体は必須ではないがdeploy末尾で呼ぶ）

# gekko namespaceにdefault-deny＋各サービスの許可ルールを適用する
deploy-network-policy:
	kubectl apply -f k8s/network-policy/default-deny.yaml -f k8s/network-policy/allow-dns.yaml
	kubectl apply -f k8s/postgres/networkpolicy.yaml -f k8s/keycloak/networkpolicy.yaml \
		-f k8s/edge-proxy/networkpolicy.yaml \
		-f k8s/account-service/networkpolicy.yaml -f k8s/fraud-mcp-server/networkpolicy.yaml \
		-f k8s/fraud-detection-engine/networkpolicy.yaml -f k8s/analyst-attribute-service/networkpolicy.yaml \
		-f k8s/fraud-agent/networkpolicy.yaml -f k8s/frontend/networkpolicy.yaml

# NetworkPolicy一式を削除する
undeploy-network-policy:
	kubectl delete -f k8s/postgres/networkpolicy.yaml -f k8s/keycloak/networkpolicy.yaml \
		-f k8s/edge-proxy/networkpolicy.yaml \
		-f k8s/account-service/networkpolicy.yaml -f k8s/fraud-mcp-server/networkpolicy.yaml \
		-f k8s/fraud-detection-engine/networkpolicy.yaml -f k8s/analyst-attribute-service/networkpolicy.yaml \
		-f k8s/fraud-agent/networkpolicy.yaml -f k8s/frontend/networkpolicy.yaml --ignore-not-found
	kubectl delete -f k8s/network-policy/default-deny.yaml -f k8s/network-policy/allow-dns.yaml --ignore-not-found

# クラスタのコンテナを停止する（状態は保持したまま。再開はstartで）
stop:
	k3d cluster stop $(CLUSTER)

# stopで止めたクラスタを再開する
start:
	k3d cluster start $(CLUSTER)

# クラスタとノードの状態を確認する
status:
	k3d cluster list
	@echo "--- nodes ---"
	@kubectl get nodes 2>/dev/null || echo "(cluster not reachable)"
	@echo "--- $(NAMESPACE) ---"
	@kubectl -n $(NAMESPACE) get deployments,services,pods 2>/dev/null || echo "(namespace '$(NAMESPACE)' not reachable)"
	@echo "--- spire ---"
	@kubectl -n spire get statefulsets,daemonsets,services,pods 2>/dev/null || echo "(namespace 'spire' not reachable)"
	@echo "--- observability ---"
	@kubectl -n observability get deployments,daemonsets,services,pods 2>/dev/null || echo "(namespace 'observability' not reachable)"

# ネットワーク構成を確認する。statusがコンテナの起動状況を見せるのに対し、こちらは
# NetworkPolicy(通信許可、ADR 0018)とEnvoyサイドカーの実プロトコル(mTLS/plaintext、
# SPIRE発行SPIFFE IDの許可・検証対象、ADR 0012/0015/0019/0020/0028)を突き合わせて表示する
network-status:
	@python3 scripts/network-status.py
