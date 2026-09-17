package com.gekko.accountservice.security;

import jakarta.servlet.Filter;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletRequest;
import jakarta.servlet.ServletResponse;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

// ADR 0009 §2の多層防御をk8s/account-service/app-configmap.yamlのスタブから引き継ぐ:
// 主対策②(接続元loopback再チェック)・②③(合言葉ヘッダー検証)。scope/RBAC検証はEnvoyの責務のため
// ここでは行わない(ADR 0009 §1)。テスト時だけ迂回するフラグは作らない(CWE-489)。
@Component
public class SecurityHeadersFilter implements Filter {

    private final String handshakeHeaderName;
    private final Path handshakeTokenFile;

    public SecurityHeadersFilter(
            @Value("${handshake.header-name}") String handshakeHeaderName,
            @Value("${handshake.token-file}") String handshakeTokenFile) {
        this.handshakeHeaderName = handshakeHeaderName;
        this.handshakeTokenFile = Path.of(handshakeTokenFile);
    }

    @Override
    public void doFilter(ServletRequest servletRequest, ServletResponse servletResponse, FilterChain chain)
            throws IOException, ServletException {
        HttpServletRequest request = (HttpServletRequest) servletRequest;
        HttpServletResponse response = (HttpServletResponse) servletResponse;

        if (!isLoopback(request.getRemoteAddr())) {
            response.sendError(HttpServletResponse.SC_FORBIDDEN);
            return;
        }

        String expected;
        try {
            expected = Files.readString(handshakeTokenFile).strip();
        } catch (IOException e) {
            expected = null;
        }
        String got = request.getHeader(handshakeHeaderName);
        if (expected == null || expected.isEmpty() || got == null || !expected.equals(got)) {
            response.sendError(HttpServletResponse.SC_FORBIDDEN, "handshake verification failed");
            return;
        }

        chain.doFilter(request, response);
    }

    private boolean isLoopback(String remoteAddr) {
        return "127.0.0.1".equals(remoteAddr) || "0:0:0:0:0:0:0:1".equals(remoteAddr) || "::1".equals(remoteAddr);
    }
}
