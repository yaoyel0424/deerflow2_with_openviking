"""Gateway 启动入口：加载 OpenViking 插件后启动 uvicorn。"""

from __future__ import annotations

import os
import sys


def main() -> None:
    ext_dir = os.path.dirname(os.path.abspath(__file__))
    backend_dir = os.path.join(os.path.dirname(ext_dir), "backend")
    for path in (backend_dir, ext_dir):
        if path not in sys.path:
            sys.path.insert(0, path)

    import deerflow_openviking_plugin as plugin

    plugin.apply_bootstrap()

    import uvicorn

    uvicorn.run(
        "app.gateway.app:app",
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8001")),
        log_level=os.getenv("LOG_LEVEL", "info").lower(),
    )


if __name__ == "__main__":
    main()
