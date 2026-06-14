"""Gateway 启动前注入 OpenViking Middleware。"""

from __future__ import annotations

import logging
import os

logger = logging.getLogger(__name__)
_applied = False


def apply_bootstrap() -> None:
    """在 make_lead_agent 构建中间件链时注入 OpenVikingMiddleware。"""
    global _applied
    if _applied:
        return
    _applied = True

    if os.getenv("OPENVIKING_SYNC_ENABLED", "true").lower() not in ("1", "true", "yes"):
        logger.info("OpenViking 同步已禁用（OPENVIKING_SYNC_ENABLED=false）")
        return

    import deerflow.agents.lead_agent.agent as lead_agent_module

    from deerflow_openviking.openviking_middleware import OpenVikingMiddleware

    original_build = lead_agent_module._build_middlewares

    def _build_with_openviking(*args, **kwargs):
        """在默认中间件链中追加 OpenVikingMiddleware。"""
        custom = list(kwargs.get("custom_middlewares") or [])
        custom.append(OpenVikingMiddleware())
        kwargs["custom_middlewares"] = custom
        return original_build(*args, **kwargs)

    lead_agent_module._build_middlewares = _build_with_openviking
    logger.info(
        "已注入 OpenVikingMiddleware，base_url=%s",
        os.getenv("OPENVIKING_BASE_URL", "http://openviking:1933"),
    )
