# account-serviceの本実装イメージ(ADR 0007:Java/Spring Boot)。マルチステージビルドで
# ビルド専用イメージ(Maven+JDK)と実行専用イメージ(JRE)を分離する。レジストリは使わず、
# `k3d image import`でローカルビルド成果物をそのままクラスタへ持ち込む
# (Makefileのbuild-account-serviceターゲット参照)。
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml ./
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B package -DskipTests

FROM eclipse-temurin:21-jre-alpine
RUN addgroup -S app && adduser -S app -G app
USER app
COPY --from=build /src/target/account-service-*.jar /app.jar
ENTRYPOINT ["java", "-jar", "/app.jar"]
