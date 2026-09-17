package com.gekko.accountservice.client;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Optional;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

// 表3(account-service→analyst-attribute-service)への委任。呼び出しは常に自身のegress Envoy
// (127.0.0.1:80、hostAliasesで宛先を横取り)を経由し、token-exchangeサイドカーが
// Authorizationヘッダーをsubject_tokenにToken Exchangeしてから転送する(architecture.md §5)。
// 結果はキャッシュしない(unfreeze実行時の多層防御として毎回再照会する必要があるため。backlog.md)。
@Component
public class AnalystAttributeClient {

    private final HttpClient httpClient = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .build();
    private final ObjectMapper objectMapper = new ObjectMapper();
    private final String baseUrl;

    public AnalystAttributeClient(@Value("${analyst-attribute-service.url}") String baseUrl) {
        this.baseUrl = baseUrl.endsWith("/") ? baseUrl : baseUrl + "/";
    }

    /**
     * @param sub 呼び出し元(account-service)自身が受け取ったx-auth-sub。委任チェーン全体で
     *            アナリスト本人のまま維持される(表1)ため、この値がそのままanalyst-attribute-service
     *            への照会キーになる。
     * @param authorizationHeader account-serviceが受け取った元のAuthorizationヘッダー値
     *            (subject_tokenとして転送される)。
     */
    public Optional<AnalystAttributes> fetch(String sub, String authorizationHeader) {
        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(baseUrl + "analysts/" + sub))
                .header("Authorization", authorizationHeader)
                .timeout(Duration.ofSeconds(5))
                .GET()
                .build();
        try {
            HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() != 200) {
                // 未登録・不一致・照会不能はいずれも同じfail closeとして扱う(ADR 0009の思想を
                // 業務データレベルのABAC判定にも適用する)。
                return Optional.empty();
            }
            return Optional.of(objectMapper.readValue(response.body(), AnalystAttributes.class));
        } catch (IOException | InterruptedException e) {
            if (e instanceof InterruptedException) {
                Thread.currentThread().interrupt();
            }
            return Optional.empty();
        }
    }
}
