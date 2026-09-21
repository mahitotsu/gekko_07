# quay.io/keycloak/keycloakをベースに`kc.sh build`をイメージビルド時に済ませておき、
# 起動コマンドを`start --optimized`にできるようにする(k8s/keycloak/deployment.yaml参照)。
# start-devは毎回起動時にQuarkusのaugmentationをやり直すため起動が遅い。事前buildして
# --optimizedで起動すればこの再augmentationを省略できる。
#
# 下記ENVはaugmentation時に固定されるbuild-timeオプション(db/features/health-enabled)。
# 実行時にこれらの値を変える場合はイメージの再ビルドが必要(k8s/keycloak/deployment.yamlの
# 同名の環境変数と値を一致させること。不一致でも起動はするがbuild時の値が優先され警告が出る)。
FROM quay.io/keycloak/keycloak:26.7.0 AS builder

ENV KC_DB=postgres
ENV KC_FEATURES=spiffe,client-auth-federated
ENV KC_HEALTH_ENABLED=true

RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.7.0
COPY --from=builder /opt/keycloak/ /opt/keycloak/
