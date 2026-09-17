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
# frontend(ADR 0024)・fraud-mcp-server(ADR 0019)・fraud-detection-engine(ADR 0020)はいずれも
# clientAuthenticatorType: federated-jwtへ移行したためclient_secretは不要
# (SPIRE発行JWT-SVIDで認証する)。
YAMADA_ANALYST_PASSWORD := $(call get_secret,yamada-analyst-password)

# SPIRE Serverのbundle endpoint（ADR 0019）自身のTLS終端用証明書。SPIRE発行のSVIDではなく
# （bundle endpointが公開するtrust bundleの中身とは無関係な、この1エンドポイントだけのための
# 使い捨てのTLS証明書）、ここだけ例外的に自己署名証明書をopensslで生成して使い回す
# （postgres-superuser-password等と同じ「一度だけ生成し$(SECRETS_DIR)に保存」パターン）。
# KeycloakがこれをKC_TRUSTSTORE_PATHSで信頼することでbundle endpointをHTTPS越しに検証できる。
SPIRE_BUNDLE_ENDPOINT_CERT_DUMMY := $(shell mkdir -p $(SECRETS_DIR) && \
	( [ -f $(SECRETS_DIR)/spire-bundle-endpoint.crt ] || \
	  openssl req -x509 -newkey rsa:2048 -nodes \
	    -keyout $(SECRETS_DIR)/spire-bundle-endpoint.key \
	    -out $(SECRETS_DIR)/spire-bundle-endpoint.crt \
	    -days 3650 -subj "/CN=spire-server.spire.svc.cluster.local" \
	    -addext "subjectAltName=DNS:spire-server.spire.svc.cluster.local,DNS:spire-server" \
	    >/dev/null 2>&1 ) )

.PHONY: up down stop start status clean deploy undeploy keycloak-forward keycloak-reimport-realm deploy-verify-hop undeploy-verify-hop verify-hop deploy-spire undeploy-spire deploy-network-policy undeploy-network-policy deploy-observability undeploy-observability grafana-forward verify-observability

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
#
# SPIRE（k8s/spire/）はADR 0016でKeycloakのEnvoyサイドカー（当時のext-authz-service(-cc)専用の
# mTLSポート8443、現在はfraud-mcp-server/fraud-detection-engine自身のPod内サイドカーがADR 0019/0020で
# 同じポートへ接続する）の前提になったため、「1ホップ検証スタブ専用」から「base trackの前提
# コンポーネント」へ格上げした。deploy-spireはspire-agent DaemonSetのrollout完了まで待つため、
# Keycloakのデプロイより前に呼べば、KeycloakのEnvoyコンテナがspire-agentソケット
# （hostPath /run/spire/sockets）を確実にマウントできる。
#
# edge-proxy（k8s/edge-proxy/）はADR 0017で追加。Keycloakの8080撤廃に伴い、ブラウザ/kcadm.sh/
# verify-hop.sh向けの非mTLS経路を代理する。Keycloakのrollout後に適用する（keycloak_upstream
# クラスタがKeycloakのService DNSを参照するため、順序はどちらでも動くが、依存関係が分かりやすい
# 順に揃えている）。

# PostgreSQL・SPIRE・Keycloak・edge-proxyをデプロイ（クラスタが起動済みであること）
deploy:
	kubectl apply -f k8s/keycloak/namespace.yaml
	$(call upsert_secret,keycloak-admin,--from-literal=username=admin --from-literal=password=$(KEYCLOAK_ADMIN_PASSWORD))
	$(call upsert_secret,postgres-superuser,--from-literal=password=$(POSTGRES_SUPERUSER_PASSWORD))
	$(call upsert_secret,keycloak-db,--from-literal=username=keycloak --from-literal=password=$(KEYCLOAK_DB_PASSWORD))
	kubectl apply -f k8s/postgres/statefulset.yaml -f k8s/postgres/service.yaml
	kubectl -n $(NAMESPACE) rollout status statefulset/postgres --timeout=180s
	@# JobのPod specは不変なので、再実行するにはいったん削除してから作り直す（冪等なスクリプトなので安全）
	kubectl delete job keycloak-db-init -n $(NAMESPACE) --ignore-not-found
	kubectl apply -f k8s/keycloak/db-init-configmap.yaml -f k8s/keycloak/db-init-job.yaml
	kubectl -n $(NAMESPACE) wait --for=condition=complete job/keycloak-db-init --timeout=60s
	$(MAKE) deploy-spire
	@# KeycloakがSPIRE Serverのbundle endpoint(ADR 0019)をHTTPSで検証するためのtruststore。
	@# spire-bundle-endpoint.crtの秘密鍵は含めない(検証側は証明書のみで足りる)
	kubectl create secret generic spire-bundle-endpoint-ca -n $(NAMESPACE) \
		--from-file=ca.crt=$(SECRETS_DIR)/spire-bundle-endpoint.crt --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f k8s/keycloak/realm-configmap.yaml -f k8s/keycloak/envoy-configmap.yaml -f k8s/keycloak/deployment.yaml -f k8s/keycloak/service.yaml
	kubectl -n $(NAMESPACE) rollout status deployment/keycloak --timeout=180s
	kubectl apply -f k8s/edge-proxy/envoy-configmap.yaml -f k8s/edge-proxy/deployment.yaml -f k8s/edge-proxy/service.yaml
	kubectl -n $(NAMESPACE) rollout status deployment/edge-proxy --timeout=120s
	$(MAKE) deploy-observability
	$(MAKE) deploy-network-policy
	@echo "---"
	@echo "Keycloak admin username: admin"
	@echo "Keycloak admin password: $(KEYCLOAK_ADMIN_PASSWORD)"
	@echo "(.secrets/に保存されているため次回make deploy以降も同じ値。ADR 0008でPostgresへ永続化したため"
	@echo " 実際に有効なのはKeycloakの初回起動時にブートストラップされた値のみ。.secrets/を消してPVCも"
	@echo " 作り直した場合のみこの値でのブートストラップが再度行われる)"

# アプリ層を削除する（クラスタ自体は残す。PVCも削除するためPostgresのデータも消える）
undeploy:
	$(MAKE) undeploy-network-policy
	kubectl delete -f k8s/edge-proxy/service.yaml -f k8s/edge-proxy/deployment.yaml -f k8s/edge-proxy/envoy-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/keycloak/service.yaml -f k8s/keycloak/deployment.yaml -f k8s/keycloak/envoy-configmap.yaml -f k8s/keycloak/realm-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/keycloak/db-init-job.yaml -f k8s/keycloak/db-init-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/postgres/service.yaml -f k8s/postgres/statefulset.yaml --ignore-not-found
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

# realm-configmap.yaml変更後にKeycloakへ反映させる（insights.md参照）。--import-realmは
# データディレクトリが空の初回起動時のみ有効なため、Postgresへ永続化した状態で
# realm-configmap.yamlだけ書き換えても自動では反映されない。gekko realmを明示的に削除してから
# Keycloakを再起動し、次回起動時の--import-realmに新しい内容を再インポートさせる。
# テストデータ（ユーザー・クライアントシークレット）は消えるため、直後にmake deploy-verify-hopで
# 再構築すること。realm-configmap.yaml変更のたびに手動で実行する必要がある（自動化しない理由：
# make deploy自体が毎回realmを作り直す挙動になるとADR 0008が検証したい「Postgresへの永続化」の
# 意味が薄れるため）。
keycloak-reimport-realm:
	kubectl apply -f k8s/keycloak/realm-configmap.yaml
	kubectl -n $(NAMESPACE) exec deploy/keycloak -- /opt/keycloak/bin/kcadm.sh config credentials \
		--server http://localhost:8080 --realm master --user admin --password $(KEYCLOAK_ADMIN_PASSWORD)
	kubectl -n $(NAMESPACE) exec deploy/keycloak -- /opt/keycloak/bin/kcadm.sh delete realms/gekko
	kubectl -n $(NAMESPACE) rollout restart deployment/keycloak
	kubectl -n $(NAMESPACE) rollout status deployment/keycloak --timeout=180s

# -------------------------
# 1ホップ先行検証（ADR 0002/0009/0010、fraud-mcp-server→account-service・
# fraud-detection-engine→account-service）
# -------------------------
# ここでデプロイするaccount-service/fraud-mcp-server/fraud-detection-engineは
# いずれもスタブ実装であり、各サービスの本実装（未着手）とは別物。既存のdeploy/undeployとは
# 独立させてあるため、Keycloak・Postgresだけを触りたい場合はこのターゲット群を無視してよい。

# スタブ一式＋テスト用Keycloakフィクスチャをデプロイする（make deploy実行済み・クラスタ起動済み前提）
deploy-verify-hop:
	$(call upsert_secret,yamada-analyst,--from-literal=password=$(YAMADA_ANALYST_PASSWORD))
	kubectl delete job keycloak-test-fixtures -n $(NAMESPACE) --ignore-not-found
	kubectl apply -f k8s/keycloak/test-fixtures-configmap.yaml -f k8s/keycloak/test-fixtures-job.yaml
	kubectl -n $(NAMESPACE) wait --for=condition=complete job/keycloak-test-fixtures --timeout=60s
	@# SPIRE(server/agent/registration entries)はmake deploy側で既にデプロイ済み(ADR 0016で
	@# base trackへ格上げ)なので、ここでは呼ばない。
	@# fraud-mcp-server向け(ADR 0019)・fraud-detection-engine向け(ADR 0020)・account-service向け
	@# (表3)のext-authz-service共有インスタンスはいずれも廃止(または最初から作らず)、呼び出し元
	@# 自身のPod内サイドカーへ置き換えた。
	kubectl apply -f k8s/analyst-attribute-service/app-configmap.yaml -f k8s/analyst-attribute-service/envoy-configmap.yaml -f k8s/analyst-attribute-service/deployment.yaml -f k8s/analyst-attribute-service/service.yaml
	kubectl apply -f k8s/account-service/app-configmap.yaml -f k8s/account-service/token-exchange-app-configmap.yaml -f k8s/account-service/envoy-configmap.yaml -f k8s/account-service/deployment.yaml -f k8s/account-service/service.yaml
	kubectl apply -f k8s/fraud-mcp-server/app-configmap.yaml -f k8s/fraud-mcp-server/token-exchange-app-configmap.yaml -f k8s/fraud-mcp-server/envoy-configmap.yaml -f k8s/fraud-mcp-server/deployment.yaml -f k8s/fraud-mcp-server/service.yaml
	kubectl apply -f k8s/fraud-detection-engine/client-credentials-app-configmap.yaml -f k8s/fraud-detection-engine/envoy-configmap.yaml -f k8s/fraud-detection-engine/deployment.yaml
	@# ADR 0023:fraud-agent→fraud-mcp-serverホップ。
	kubectl apply -f k8s/fraud-agent/app-configmap.yaml -f k8s/fraud-agent/token-exchange-app-configmap.yaml -f k8s/fraud-agent/envoy-configmap.yaml -f k8s/fraud-agent/deployment.yaml -f k8s/fraud-agent/service.yaml
	@# ADR 0024:frontend→account-service/fraud-agentホップ。edge-proxy側(base track、make deploy)の
	@# ConfigMap更新も、frontend Service/SPIREエントリが揃った後でなければ意味を持たないため、
	@# ここで念のため再適用・再起動する。
	kubectl apply -f k8s/frontend/app-configmap.yaml -f k8s/frontend/token-exchange-app-configmap.yaml -f k8s/frontend/envoy-configmap.yaml -f k8s/frontend/deployment.yaml -f k8s/frontend/service.yaml
	kubectl apply -f k8s/edge-proxy/envoy-configmap.yaml
	@# EnvoyはConfigMapの静的bootstrap設定を起動時に1度だけ読み込み、変更をホットリロードしない
	@# （Keycloak realmの--import-realmと同種の落とし穴。insights.md参照）。ConfigMap更新が
	@# 既存Podへ確実に反映されるよう、スタブは常に再起動する（いずれも状態を持たないため無害）
	kubectl -n $(NAMESPACE) rollout restart deployment/analyst-attribute-service-stub deployment/account-service-stub deployment/fraud-mcp-server-stub deployment/fraud-detection-engine-stub deployment/fraud-agent-stub deployment/frontend-stub deployment/edge-proxy
	kubectl -n $(NAMESPACE) rollout status deployment/analyst-attribute-service-stub --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/account-service-stub --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/fraud-mcp-server-stub --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/fraud-detection-engine-stub --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/fraud-agent-stub --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/frontend-stub --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deployment/edge-proxy --timeout=120s

# scripts/verify-hop.shを実行する（deploy-verify-hop実行済み前提）
verify-hop:
	./scripts/verify-hop.sh

# 1ホップ先行検証用のスタブ一式・テストフィクスチャを削除する(SPIRE自体はmake deploy側の
# 前提コンポーネントになった(ADR 0016)ため、ここでは削除しない。Keycloak+SPIREを残したまま
# スタブだけ入れ替えられるようにする)
undeploy-verify-hop:
	kubectl delete -f k8s/frontend/service.yaml -f k8s/frontend/deployment.yaml -f k8s/frontend/envoy-configmap.yaml -f k8s/frontend/token-exchange-app-configmap.yaml -f k8s/frontend/app-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/fraud-agent/service.yaml -f k8s/fraud-agent/deployment.yaml -f k8s/fraud-agent/envoy-configmap.yaml -f k8s/fraud-agent/token-exchange-app-configmap.yaml -f k8s/fraud-agent/app-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/fraud-detection-engine/deployment.yaml -f k8s/fraud-detection-engine/envoy-configmap.yaml -f k8s/fraud-detection-engine/client-credentials-app-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/fraud-mcp-server/service.yaml -f k8s/fraud-mcp-server/deployment.yaml -f k8s/fraud-mcp-server/envoy-configmap.yaml -f k8s/fraud-mcp-server/token-exchange-app-configmap.yaml -f k8s/fraud-mcp-server/app-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/account-service/service.yaml -f k8s/account-service/deployment.yaml -f k8s/account-service/envoy-configmap.yaml -f k8s/account-service/token-exchange-app-configmap.yaml -f k8s/account-service/app-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/analyst-attribute-service/service.yaml -f k8s/analyst-attribute-service/deployment.yaml -f k8s/analyst-attribute-service/envoy-configmap.yaml -f k8s/analyst-attribute-service/app-configmap.yaml --ignore-not-found
	kubectl delete -f k8s/keycloak/test-fixtures-job.yaml -f k8s/keycloak/test-fixtures-configmap.yaml --ignore-not-found
	kubectl delete secret yamada-analyst -n $(NAMESPACE) --ignore-not-found

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
	kubectl -n spire wait --for=condition=complete job/spire-entries --timeout=60s

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
	@echo "---"
	@kubectl get nodes 2>/dev/null || echo "(cluster not reachable)"
	@echo "---"
	@kubectl get namespaces 2>/dev/null || echo "(cluster not reachable)"
	@echo "---"
	@kubectl -n $(NAMESPACE) get deployments,services,pods 2>/dev/null || echo "(namespace '$(NAMESPACE)' not reachable)"
	@echo "---"
	@kubectl -n spire get statefulsets,daemonsets,services,pods 2>/dev/null || echo "(namespace 'spire' not reachable)"
	@echo "---"
	@kubectl -n observability get deployments,daemonsets,services,pods 2>/dev/null || echo "(namespace 'observability' not reachable)"
