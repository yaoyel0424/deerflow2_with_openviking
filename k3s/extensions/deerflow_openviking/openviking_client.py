"""OpenViking HTTP 客户端（Session 同步与 commit）。"""

from __future__ import annotations

import logging
import os
from typing import Any

import httpx

logger = logging.getLogger(__name__)


class OpenVikingClient:
    """OpenViking REST API 轻量封装。"""

    def __init__(
        self,
        base_url: str | None = None,
        api_key: str | None = None,
        timeout: float = 30.0,
    ) -> None:
        """初始化客户端。

        Args:
            base_url: OpenViking 服务地址，默认读取 OPENVIKING_BASE_URL。
            api_key: API Key，默认读取 OPENVIKING_API_KEY。
            timeout: HTTP 超时秒数。
        """
        self._base_url = (base_url or os.getenv("OPENVIKING_BASE_URL", "http://openviking:1933")).rstrip("/")
        self._api_key = api_key or os.getenv("OPENVIKING_API_KEY") or ""
        self._timeout = timeout

    def _headers(self, user_id: str | None = None) -> dict[str, str]:
        """构建请求头。"""
        headers = {"Content-Type": "application/json"}
        if self._api_key:
            headers["Authorization"] = f"Bearer {self._api_key}"
        if user_id:
            headers["X-User-ID"] = user_id
        return headers

    def _request(
        self,
        method: str,
        path: str,
        *,
        user_id: str | None = None,
        json_body: dict[str, Any] | None = None,
    ) -> dict[str, Any] | None:
        """发送 HTTP 请求并解析 result 字段。"""
        url = f"{self._base_url}{path}"
        try:
            with httpx.Client(timeout=self._timeout) as client:
                response = client.request(
                    method,
                    url,
                    headers=self._headers(user_id),
                    json=json_body,
                )
                if response.status_code == 404:
                    return None
                response.raise_for_status()
                payload = response.json()
                if payload.get("status") == "error":
                    err = payload.get("error") or {}
                    raise RuntimeError(err.get("message") or str(err))
                return payload.get("result")
        except httpx.HTTPError as exc:
            logger.warning("OpenViking 请求失败 %s %s: %s", method, path, exc)
            raise

    def health_ok(self) -> bool:
        """检查 OpenViking 健康状态。"""
        try:
            with httpx.Client(timeout=5.0) as client:
                response = client.get(f"{self._base_url}/health")
                return response.status_code == 200
        except httpx.HTTPError:
            return False

    def ensure_session(self, session_id: str, *, user_id: str | None = None) -> None:
        """确保 Session 存在（DeerFlow thread_id 映射为 OpenViking session_id）。"""
        existing = self._request("GET", f"/api/v1/sessions/{session_id}", user_id=user_id)
        if existing is not None:
            return
        self._request(
            "POST",
            "/api/v1/sessions",
            user_id=user_id,
            json_body={"session_id": session_id},
        )

    def batch_add_messages(
        self,
        session_id: str,
        messages: list[dict[str, str]],
        *,
        user_id: str | None = None,
    ) -> None:
        """批量追加会话消息。"""
        if not messages:
            return
        self._request(
            "POST",
            f"/api/v1/sessions/{session_id}/messages/batch",
            user_id=user_id,
            json_body={"messages": messages},
        )

    def commit_session(self, session_id: str, *, user_id: str | None = None) -> str | None:
        """提交 Session，触发异步记忆提取。返回 task_id。"""
        result = self._request(
            "POST",
            f"/api/v1/sessions/{session_id}/commit",
            user_id=user_id,
            json_body={},
        )
        if not result:
            return None
        return result.get("task_id")


_client: OpenVikingClient | None = None


def get_openviking_client() -> OpenVikingClient:
    """获取 OpenViking 客户端单例。"""
    global _client
    if _client is None:
        _client = OpenVikingClient()
    return _client
