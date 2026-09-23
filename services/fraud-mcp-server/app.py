# fraud-mcp-serverの本実装(Python/FastMCP。ADR 0007の言語選定・ADR 0029)。
#
# account-serviceの読み取り・提案系機能をMCPツールとして公開し、MCPプロトコルとREST/gRPCの
# 変換を担う(docs/services.md)。scope/RBAC検証はEnvoy ingress(jwt_authn+rbac)が既に完了させて
# いるため、ここでは行わない(account-serviceのAccountController.javaと同じ責務分担。ADR 0009 §1)。
#
# Token Exchangeは自前で行わない。受信した元のAuthorizationヘッダー(jwt_authnのforward: trueで
# Envoy ingressが保持)をそのままaccount-serviceへのリクエストに転送するだけで、egressの
# token-exchangeサイドカー(ADR 0019)がそれをsubject_tokenとして横取りし、新しいトークンへ
# 差し替えてから実際のaccount-serviceへ転送する(architecture.md §3。account-serviceの
# AnalystAttributeClient.javaと同型)。
from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import httpx
import uvicorn
from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from fastmcp.server.dependencies import get_http_headers
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

APP_BIND_HOST = os.environ.get("APP_BIND_HOST", "127.0.0.1")  # ADR 0009 主対策①
APP_PORT = int(os.environ.get("APP_PORT", "9000"))
HANDSHAKE_HEADER = os.environ.get("HANDSHAKE_HEADER_NAME", "x-gekko-handshake")
HANDSHAKE_FILE = Path(os.environ.get("HANDSHAKE_TOKEN_FILE", "/handshake/token"))
ACCOUNT_SERVICE_URL = os.environ.get("ACCOUNT_SERVICE_URL", "http://account-service/")


def _delegated_authorization() -> str:
    headers = get_http_headers(include={"authorization"})
    authorization = headers.get("authorization")
    if not authorization:
        # 委任トークンが無い呼び出しは通さない(fail close。ADR 0009の思想を踏襲)。
        raise ToolError("missing delegated authorization")
    return authorization


async def _call_account_service(method: str, path: str, json_body: dict[str, Any] | None = None) -> Any:
    try:
        async with httpx.AsyncClient(base_url=ACCOUNT_SERVICE_URL, timeout=5.0) as client:
            response = await client.request(
                method, path, headers={"Authorization": _delegated_authorization()}, json=json_body
            )
    except httpx.HTTPError as e:
        raise ToolError("account-service unreachable") from e
    if response.status_code != 200:
        # account-service側のレスポンス本文(存在秘匿の404・権限不足の403等)はそのまま漏らさず、
        # 一律「呼び出し失敗」として返す(ADR 0009のfail-close思想)。
        raise ToolError(f"account-service request failed: {response.status_code}")
    return response.json()


mcp = FastMCP("fraud-mcp-server")


@mcp.tool()
async def get_frozen_accounts() -> Any:
    """凍結中口座とその凍結根拠を照会する(account:read)。"""
    return await _call_account_service("GET", "/accounts/frozen")


@mcp.tool()
async def get_account_history(account_id: str) -> Any:
    """指定口座の取引履歴・凍結根拠を照会する(account:read)。"""
    return await _call_account_service("GET", f"/accounts/{account_id}/transactions")


@mcp.tool()
async def propose_unfreeze(account_id: str, reasoning: str = "") -> Any:
    """精査の結論として指定口座の凍結解除を推奨する場合に呼ぶ(account:propose)。"""
    return await _call_account_service(
        "POST",
        f"/accounts/{account_id}/unfreeze-proposals",
        json_body={"reasoning": reasoning, "recommendation": "unfreeze"},
    )


@mcp.tool()
async def conclude_no_unfreeze(account_id: str, reasoning: str = "") -> Any:
    """精査の結論として指定口座の凍結解除に根拠がないと判断した場合に呼ぶ(account:propose、ADR 0039)。
    凍結を維持するという結論自体も、propose_unfreezeと同様に依頼したアナリスト本人の確認を経て確定する。
    """
    return await _call_account_service(
        "POST",
        f"/accounts/{account_id}/unfreeze-proposals",
        json_body={"reasoning": reasoning, "recommendation": "keep_frozen"},
    )


async def healthz(request: Request) -> JSONResponse:
    # verify-hop.sh・fraud-agent-stub(k8s/fraud-agent/app-configmap.yaml)からの疎通確認用。
    # Envoy ingressの配下でありscope検証(account:read)はそのまま効く(ADR 0029)。
    return JSONResponse({"status": "ok"})


mcp_app = mcp.http_app(path="/mcp")
asgi_app = Starlette(routes=[Route("/healthz", healthz)], lifespan=mcp_app.lifespan)
asgi_app.mount("/", mcp_app)


class HandshakeMiddleware:
    # ADR 0009 §2の多層防御をaccount-serviceのSecurityHeadersFilter.javaと同じ形で移植する
    # (BaseHTTPMiddlewareはレスポンスをバッファするためMCPのSSEストリーミングと相性が悪く、
    # 素のASGIミドルウェアとして実装する)。①接続元loopback再チェック、②合言葉ヘッダー検証。
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        client = scope.get("client")
        client_host = client[0] if client else None
        if client_host not in ("127.0.0.1", "::1"):
            await self._deny(send, 403, b"forbidden")
            return

        try:
            expected = HANDSHAKE_FILE.read_text().strip()
        except OSError:
            expected = None
        headers = {name.decode().lower(): value.decode() for name, value in scope["headers"]}
        got = headers.get(HANDSHAKE_HEADER.lower())
        if not expected or not got or got != expected:
            await self._deny(send, 403, b"handshake verification failed")
            return

        await self.app(scope, receive, send)

    @staticmethod
    async def _deny(send, status: int, body: bytes) -> None:
        await send({"type": "http.response.start", "status": status, "headers": [(b"content-type", b"text/plain")]})
        await send({"type": "http.response.body", "body": body})


app = HandshakeMiddleware(asgi_app)


if __name__ == "__main__":
    uvicorn.run(app, host=APP_BIND_HOST, port=APP_PORT, log_level="info")
