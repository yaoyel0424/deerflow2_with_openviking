"""DeerFlow OpenViking 单文件插件（ConfigMap 挂载，无子目录）。"""

from __future__ import annotations

import logging
import os
import threading
from typing import Any, override

import httpx
from langchain.agents import AgentState
from langchain.agents.middleware import AgentMiddleware
from langgraph.config import get_config
from langgraph.runtime import Runtime

logger = logging.getLogger(__name__)
_bootstrap_applied = False
_synced_counts: dict[str, int] = {}
_sync_lock = threading.Lock()
_ov_client: OpenVikingClient | None = None


class OpenVikingClient:
    """OpenViking REST API 轻量封装。"""

    def __init__(
        self,
        base_url: str | None = None,
        api_key: str | None = None,
        timeout: float = 30.0,
    ) -> None:
        self._base_url = (base_url or os.getenv("OPENVIKING_BASE_URL", "http://openviking:1933")).rstrip("/")
        self._api_key = api_key or os.getenv("OPENVIKING_API_KEY") or ""
        self._timeout = timeout

    def _headers(self, user_id: str | None = None) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self._api_key:
            headers["Authorization"] = f"Bearer {self._api_key}"
        # v0.3.x：ROOT key 访问租户 API 需携带 Account/User 头
        account = os.getenv("OPENVIKING_ACCOUNT_ID", "default")
        effective_user = user_id or os.getenv("OPENVIKING_DEFAULT_USER_ID", "deerflow")
        headers["X-OpenViking-Account"] = account
        headers["X-OpenViking-User"] = effective_user
        return headers

    def _request(
        self,
        method: str,
        path: str,
        *,
        user_id: str | None = None,
        json_body: dict[str, Any] | None = None,
    ) -> dict[str, Any] | None:
        url = f"{self._base_url}{path}"
        with httpx.Client(timeout=self._timeout) as client:
            response = client.request(method, url, headers=self._headers(user_id), json=json_body)
            if response.status_code == 404:
                return None
            response.raise_for_status()
            payload = response.json()
            if payload.get("status") == "error":
                err = payload.get("error") or {}
                raise RuntimeError(err.get("message") or str(err))
            return payload.get("result")

    def ensure_session(self, session_id: str, *, user_id: str | None = None) -> None:
        if self._request("GET", f"/api/v1/sessions/{session_id}", user_id=user_id) is not None:
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
        if not messages:
            return
        self._request(
            "POST",
            f"/api/v1/sessions/{session_id}/messages/batch",
            user_id=user_id,
            json_body={"messages": messages},
        )

    def commit_session(self, session_id: str, *, user_id: str | None = None) -> str | None:
        result = self._request(
            "POST",
            f"/api/v1/sessions/{session_id}/commit",
            user_id=user_id,
            json_body={},
        )
        return result.get("task_id") if result else None


def get_openviking_client() -> OpenVikingClient:
    global _ov_client
    if _ov_client is None:
        _ov_client = OpenVikingClient()
    return _ov_client


def _is_sync_enabled() -> bool:
    return os.getenv("OPENVIKING_SYNC_ENABLED", "true").lower() in ("1", "true", "yes")


def _should_commit() -> bool:
    return os.getenv("OPENVIKING_COMMIT_EACH_RUN", "true").lower() in ("1", "true", "yes")


def _messages_to_ov_payload(messages: list[Any]) -> list[dict[str, str]]:
    from deerflow.agents.memory.message_processing import extract_message_text

    payload: list[dict[str, str]] = []
    for msg in messages:
        msg_type = getattr(msg, "type", None)
        text = extract_message_text(msg).strip()
        if not text:
            continue
        if msg_type == "human":
            payload.append({"role": "user", "content": text})
        elif msg_type == "ai" and not getattr(msg, "tool_calls", None):
            payload.append({"role": "assistant", "content": text})
    return payload


class OpenVikingMiddlewareState(AgentState):
    pass


class OpenVikingMiddleware(AgentMiddleware[OpenVikingMiddlewareState]):
    """Agent 结束后同步 OpenViking Session 并 commit。"""

    state_schema = OpenVikingMiddlewareState

    @override
    def after_agent(self, state: OpenVikingMiddlewareState, runtime: Runtime) -> dict | None:
        if not _is_sync_enabled():
            return None

        thread_id = runtime.context.get("thread_id") if runtime.context else None
        if thread_id is None:
            thread_id = get_config().get("configurable", {}).get("thread_id")
        if not thread_id:
            return None

        messages = state.get("messages", [])
        if not messages:
            return None

        from deerflow.agents.memory.message_processing import filter_messages_for_memory
        from deerflow.runtime.user_context import get_effective_user_id

        ov_messages = _messages_to_ov_payload(filter_messages_for_memory(messages))
        if len(ov_messages) < 2:
            return None

        user_id = get_effective_user_id()
        session_id = str(thread_id)

        with _sync_lock:
            already = _synced_counts.get(session_id, 0)
            delta = ov_messages[already:]

        if not delta and not (_should_commit() and len(ov_messages) >= 2):
            return None

        def _sync_worker() -> None:
            nonlocal already
            try:
                client = get_openviking_client()
                client.ensure_session(session_id, user_id=user_id)
                if delta:
                    client.batch_add_messages(session_id, delta, user_id=user_id)
                    with _sync_lock:
                        _synced_counts[session_id] = already + len(delta)
                if _should_commit() and len(ov_messages) >= 2:
                    task_id = client.commit_session(session_id, user_id=user_id)
                    if task_id:
                        logger.info("OpenViking session %s commit task_id=%s", session_id, task_id)
            except Exception:
                logger.exception("OpenViking 同步失败 session=%s", session_id)

        threading.Thread(target=_sync_worker, daemon=True, name=f"ov-sync-{session_id[:8]}").start()
        return None


def apply_bootstrap() -> None:
    """注入 OpenVikingMiddleware 到 DeerFlow 中间件链。"""
    global _bootstrap_applied
    if _bootstrap_applied:
        return
    _bootstrap_applied = True

    if not _is_sync_enabled():
        logger.info("OpenViking 同步已禁用")
        return

    import deerflow.agents.lead_agent.agent as lead_agent_module

    original_build = lead_agent_module._build_middlewares

    def _build_with_openviking(*args, **kwargs):
        custom = list(kwargs.get("custom_middlewares") or [])
        custom.append(OpenVikingMiddleware())
        kwargs["custom_middlewares"] = custom
        return original_build(*args, **kwargs)

    lead_agent_module._build_middlewares = _build_with_openviking
    logger.info(
        "已注入 OpenVikingMiddleware base_url=%s",
        os.getenv("OPENVIKING_BASE_URL", "http://openviking:1933"),
    )
