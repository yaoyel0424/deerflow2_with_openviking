"""OpenViking 会话同步 Middleware（替代 DeerFlow 内置 Memory）。"""

from __future__ import annotations

import logging
import os
import threading
from typing import Any, override

from langchain.agents import AgentState
from langchain.agents.middleware import AgentMiddleware
from langgraph.config import get_config
from langgraph.runtime import Runtime

from deerflow.agents.memory.message_processing import extract_message_text, filter_messages_for_memory
from deerflow.runtime.user_context import get_effective_user_id

from deerflow_openviking.openviking_client import get_openviking_client

logger = logging.getLogger(__name__)

# 每个 thread 已同步的消息数量（进程内缓存）
_synced_counts: dict[str, int] = {}
_sync_lock = threading.Lock()


def _is_enabled() -> bool:
    """是否启用 OpenViking 同步。"""
    return os.getenv("OPENVIKING_SYNC_ENABLED", "true").lower() in ("1", "true", "yes")


def _should_commit() -> bool:
    """每轮 Agent 结束后是否 commit（触发记忆提取）。"""
    return os.getenv("OPENVIKING_COMMIT_EACH_RUN", "true").lower() in ("1", "true", "yes")


def _messages_to_ov_payload(messages: list[Any]) -> list[dict[str, str]]:
    """将 LangChain 消息转为 OpenViking batch 格式。"""
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
    """与 ThreadState 兼容的中间件状态。"""

    pass


class OpenVikingMiddleware(AgentMiddleware[OpenVikingMiddlewareState]):
    """Agent 结束后将对话同步到 OpenViking Session 并 commit。

    - DeerFlow thread_id 映射为 OpenViking session_id
    - 仅同步 user / 最终 assistant 文本（与 MemoryMiddleware 一致）
    - commit 在后台线程执行，不阻塞 Gateway 响应
    """

    state_schema = OpenVikingMiddlewareState

    @override
    def after_agent(self, state: OpenVikingMiddlewareState, runtime: Runtime) -> dict | None:
        """Agent 运行结束后异步同步 OpenViking。"""
        if not _is_enabled():
            return None

        thread_id = runtime.context.get("thread_id") if runtime.context else None
        if thread_id is None:
            config_data = get_config()
            thread_id = config_data.get("configurable", {}).get("thread_id")
        if not thread_id:
            return None

        messages = state.get("messages", [])
        if not messages:
            return None

        filtered = filter_messages_for_memory(messages)
        ov_messages = _messages_to_ov_payload(filtered)
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
                        logger.info(
                            "OpenViking session %s 已 commit，task_id=%s",
                            session_id,
                            task_id,
                        )
            except Exception:
                logger.exception("OpenViking 同步失败 session=%s", session_id)

        threading.Thread(target=_sync_worker, daemon=True, name=f"ov-sync-{session_id[:8]}").start()
        return None
