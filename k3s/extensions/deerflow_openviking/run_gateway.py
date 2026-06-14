"""DeerFlow Gateway 入口：注入 OpenViking 扩展后启动 uvicorn。"""

from __future__ import annotations

import os
import sys


def _ensure_pythonpath() -> None:
    """确保 extensions 目录在 PYTHONPATH 中。"""
    ext_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    backend_root = os.path.join(os.path.dirname(ext_root), "backend")
    if os.path.isdir(backend_root) and backend_root not in sys.path:
        sys.path.insert(0, backend_root)
    if ext_root not in sys.path:
        sys.path.insert(0, ext_root)


def main() -> None:
    """应用 bootstrap 并启动 Gateway。"""
    _ensure_pythonpath()
    from deerflow_openviking.bootstrap import apply_bootstrap

    apply_bootstrap()

    import uvicorn

    uvicorn.run(
        "app.gateway.app:app",
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8001")),
        log_level=os.getenv("LOG_LEVEL", "info").lower(),
    )


if __name__ == "__main__":
    main()
