# DeerFlow OpenViking 扩展说明

本目录包含 **DeerFlow Gateway 与 OpenViking 的接入代码**，通过 **外挂插件 + K8s ConfigMap** 实现，**不修改** `deer-flow/` 官方源码。

---

## 目录结构

```text
extensions/
├── README.md                          # 本文档
├── run_gateway.py                     # ✅ 集群使用：自定义 Gateway 启动入口
├── deerflow_openviking_plugin.py        # ✅ 集群使用：Client + Middleware + 注入（单文件）
└── deerflow_openviking/               # 📁 本地模块化源码（便于阅读维护，集群未挂载）
    ├── __init__.py
    ├── bootstrap.py                   # 与 plugin 中 apply_bootstrap() 同逻辑
    ├── openviking_client.py           # REST 客户端
    ├── openviking_middleware.py       # OpenVikingMiddleware（仅 after_agent）
    └── run_gateway.py                 # 子目录版启动入口（未用于部署）
```

### 为何有两套文件？

K8s ConfigMap 的 key **不能包含 `/`**，无法直接把 `deerflow_openviking/openviking_middleware.py` 挂进 Pod。

因此 `deploy.ps1` 只打包 **单文件** `deerflow_openviking_plugin.py`（逻辑与子目录版等价）。修改功能时请同步更新 plugin 文件，或改 deploy 方式（例如打进镜像）。

---

## 总体架构

OpenViking 与 DeerFlow 有 **两条独立通路**：

| 通路 | 配置/代码 | 时机 | 作用 |
|------|-----------|------|------|
| **MCP** | `config/extensions_config.json` | Agent **运行中** | Agent **主动**调用 search/find/read/store **读取或写入** |
| **Middleware** | 本目录插件 + `gateway.yaml` 环境变量 | Agent **结束后**（`after_agent`） | **自动** REST 同步对话并 `commit` 提炼记忆 |

```text
用户发消息
    │
    ├─ before_agent
    │     OpenVikingMiddleware：无操作（不自动从 OpenViking 读）
    │
    ├─ Agent 运行
    │     MCP 工具 → OpenViking /mcp（按需检索/存储）
    │
    └─ after_agent
          OpenVikingMiddleware → OpenViking REST（自动 sync + commit）
```

**读**：靠 MCP + Agent 决策（非 Middleware 自动注入）。  
**写（后台同步）**：靠 `OpenVikingMiddleware.after_agent`。

内置 DeerFlow Memory 已关闭（`config/config.yaml` 中 `memory.enabled: false`），由 OpenViking 替代。

---

## 一、部署阶段：插件如何进入集群

### 1. deploy.ps1 创建 ConfigMap

路径：`k3s/scripts/deploy.ps1`

```powershell
# Gateway OpenViking 扩展（单文件插件，避免 ConfigMap key 含 /）
$PluginFile = Join-Path $ExtensionsDir 'deerflow_openviking_plugin.py'
$RunGatewayFile = Join-Path $ExtensionsDir 'run_gateway.py'

kubectl create configmap deer-flow-gateway-extensions `
    --namespace=$Namespace `
    --from-file="deerflow_openviking_plugin.py=$PluginFile" `
    --from-file="run_gateway.py=$RunGatewayFile"
```

同时 Secret `deer-flow-env` 包含：

- `OPENVIKING_API_KEY` — REST 同步用
- `OPENVIKING_MCP_AUTHORIZATION` — MCP 用（`Bearer <key>`，DeerFlow 解析 `$OPENVIKING_MCP_AUTHORIZATION`）

### 2. gateway.yaml 挂载并改启动命令

路径：`k3s/manifests/gateway.yaml`

**挂载扩展目录：**

```yaml
volumeMounts:
  - name: extensions
    mountPath: /app/extensions
    readOnly: true
volumes:
  - name: extensions
    configMap:
      name: deer-flow-gateway-extensions
```

**替换启动命令（关键）：**

```yaml
command:
  - sh
  - -c
  - cd /app/backend && PYTHONPATH=/app/backend:/app/extensions uv run --no-sync python /app/extensions/run_gateway.py
```

**相关环境变量：** 
| 变量 | 说明 |
|------|------|
| `OPENVIKING_BASE_URL` | REST 地址，默认 `http://openviking:1933` |
| `OPENVIKING_SYNC_ENABLED` | 是否启用 Middleware 同步，默认 `true` |
| `OPENVIKING_COMMIT_EACH_RUN` | 每轮结束后是否 commit，默认 `true` |
| `OPENVIKING_API_KEY` | Secret，REST 认证 |
| `OPENVIKING_MCP_AUTHORIZATION` | Secret，MCP `Authorization` 头 |

---

## 二、Gateway 启动：注入 Middleware

### 对应代码：`run_gateway.py`

```python
def main() -> None:
    # 1. 把 /app/extensions 加入 Python 路径
    ext_dir = os.path.dirname(os.path.abspath(__file__))
    backend_dir = os.path.join(os.path.dirname(ext_dir), "backend")
    for path in (backend_dir, ext_dir):
        if path not in sys.path:
            sys.path.insert(0, path)

    # 2. 在启动 Web 服务之前注入 OpenViking
    import deerflow_openviking_plugin as plugin
    plugin.apply_bootstrap()

    # 3. 启动标准 DeerFlow Gateway
    import uvicorn
    uvicorn.run("app.gateway.app:app", host="0.0.0.0", port=8001, ...)
```

顺序：**先注入 → 再 uvicorn**。之后每个请求的 Agent 都会走「被改过的」`_build_middlewares`。

### 对应代码：`apply_bootstrap()`（`deerflow_openviking_plugin.py`）

DeerFlow 原生支持 `custom_middlewares` 参数（见 `deer-flow/.../lead_agent/agent.py` 的 `_build_middlewares`）。  
插件通过 **monkey-patch** 在不改源码的情况下插入 Middleware：

```python
import deerflow.agents.lead_agent.agent as lead_agent_module

original_build = lead_agent_module._build_middlewares

def _build_with_openviking(*args, **kwargs):
    custom = list(kwargs.get("custom_middlewares") or [])
    custom.append(OpenVikingMiddleware())
    kwargs["custom_middlewares"] = custom
    return original_build(*args, **kwargs)

lead_agent_module._build_middlewares = _build_with_openviking
```

DeerFlow 会在 ClarificationMiddleware 之前插入 `custom_middlewares` 中的项。

---

## 三、运行时：一轮对话的完整流程

### 时序图

```text
┌──────────┐     ┌─────────────┐     ┌─────────────┐     ┌────────────┐
│  UI 用户  │────►│ deer-flow-  │────►│ Lead Agent  │────►│ OpenViking │
│          │     │ gateway     │     │ + Middleware│     │            │
└──────────┘     └─────────────┘     └─────────────┘     └────────────┘
                        │                    │                    │
                        │  创建 Agent        │                    │
                        │  _build_middlewares│                    │
                        │  (含 OV Middleware)│                    │
                        │                    │                    │
                        │  before_agent      │                    │
                        │  (OV 无操作)       │                    │
                        │                    │                    │
                        │                    │  MCP search/find   │
                        │                    │───────────────────►│
                        │                    │◄───────────────────│
                        │                    │  (Agent 主动检索)   │
                        │                    │                    │
                        │  after_agent       │  REST sync+commit  │
                        │                    │───────────────────►│
                        │◄───────────────────│  (后台线程)        │
                        │  返回回复给用户     │                    │
```

### 阶段说明

#### 1）before_agent — OpenVikingMiddleware **不读**

本插件 **未实现** `before_agent`。不会在 Agent 开始前自动从 OpenViking 拉记忆。

（DeerFlow 内置 Memory 的「注入」由 `DynamicContextMiddleware.before_agent` 完成，已通过 `memory.injection_enabled: false` 关闭。）

#### 2）Agent 运行中 — MCP **按需读/写**

配置：`k3s/config/extensions_config.json`

```json
{
  "mcpServers": {
    "openviking": {
      "enabled": true,
      "type": "http",
      "url": "http://openviking.deer-flow.svc:1933/mcp",
      "headers": {
        "Authorization": "$OPENVIKING_MCP_AUTHORIZATION"
      }
    }
  }
}
```

Gateway 启动后读取 `/config/extensions_config.json`，首次对话时懒加载 MCP 工具。  
Agent 根据 Skill `openviking-memory` 的指引，在需要时调用 `search` / `find` / `read` / `store`。

#### 3）after_agent — Middleware **自动写**

对应代码：`OpenVikingMiddleware.after_agent()`（`deerflow_openviking_plugin.py` 或 `deerflow_openviking/openviking_middleware.py`）

```python
def after_agent(self, state, runtime):
    thread_id = ...           # DeerFlow 对话 ID
    session_id = str(thread_id)
    ov_messages = ...         # 过滤后的 user/assistant 文本

    # 后台线程，不阻塞 Gateway 响应
    client.ensure_session(session_id)          # GET/POST /api/v1/sessions
    client.batch_add_messages(session_id, delta)  # POST .../messages/batch
    client.commit_session(session_id)          # POST .../commit
```

REST 客户端：`OpenVikingClient`（同文件）

- 认证：`Authorization: Bearer <OPENVIKING_API_KEY>`
- v0.3.x 租户 API 还需：`X-OpenViking-Account`、`X-OpenViking-User`

---

## 四、代码与职责对照表

| 文件 | 函数/类 | 职责 |
|------|---------|------|
| `run_gateway.py` | `main()` | 扩展入口；调用 bootstrap 后启动 uvicorn |
| `deerflow_openviking_plugin.py` | `apply_bootstrap()` | monkey-patch `_build_middlewares` |
| `deerflow_openviking_plugin.py` | `OpenVikingMiddleware` | 仅 `after_agent`：对话同步 + commit |
| `deerflow_openviking_plugin.py` | `OpenVikingClient` | OpenViking REST API 封装 |
| `deerflow_openviking/bootstrap.py` | `apply_bootstrap()` | 与子目录 import 版等价（未部署） |
| `deerflow_openviking/openviking_middleware.py` | `OpenVikingMiddleware` | 模块化 Middleware 源码（未部署） |
| `deerflow_openviking/openviking_client.py` | `OpenVikingClient` | 模块化 Client 源码（未部署） |
| `k3s/manifests/gateway.yaml` | Deployment | 挂载 extensions、环境变量、启动命令 |
| `k3s/scripts/deploy.ps1` | ConfigMap 创建 | 将 plugin 打入集群 |
| `k3s/config/extensions_config.json` | MCP 配置 | Agent 工具链（读/主动写） |
| `k3s/config/config.yaml` | `memory.*` | 关闭内置 Memory |
| `k3s/config/skills/openviking-memory/SKILL.md` | Skill | 引导 Agent 使用 MCP 检索 |

---

## 五、与内置 Memory 的对比

| | DeerFlow 内置 Memory | OpenViking 接入 |
|---|---------------------|-----------------|
| 写 | `MemoryMiddleware.after_agent` | `OpenVikingMiddleware.after_agent` |
| 读 | `DynamicContextMiddleware.before_agent` 自动注入 facts | **MCP 工具** + Agent 主动 search/find/read |
| 存储 | 本地 JSON / 队列 | OpenViking 向量库 + 分层上下文 |
| 配置 | `config.yaml` → `memory.*` | 本插件 + `extensions_config.json` + OpenViking `ov.conf` |

---

## 六、OpenViking 跑在集群外

可以。Gateway 只需能访问 OpenViking HTTP 端点：

1. 修改 `extensions_config.json` 中 MCP `url`
2. 修改 `gateway.yaml` 中 `OPENVIKING_BASE_URL`
3. 更新 Secret 中的 API Key
4. 可选：关闭 `k3s/manifests/openviking.yaml` 部署（`OPENVIKING_ENABLED=false`）

Middleware 与 MCP 均通过 URL + Bearer Token 连接，不要求 OpenViking 必须在同一 K8s 集群。

---

## 七、禁用或调试

### 关闭 Middleware 同步

```yaml
# gateway.yaml
- name: OPENVIKING_SYNC_ENABLED
  value: "false"
```

### 关闭 MCP

```json
// extensions_config.json
"openviking": { "enabled": false }
```

### 验证 MCP 是否加载

```powershell
kubectl logs -n deer-flow deploy/deer-flow-gateway | Select-String "MCP tools"
# 期望：MCP tools: N（N > 0）
```

### 验证 OpenViking 健康

```powershell
kubectl exec -n deer-flow deploy/openviking -- python3 -c `
  "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:1933/health').read().decode())"
```

### 验证 Middleware 同步日志

```powershell
kubectl logs -n deer-flow deploy/deer-flow-gateway | Select-String "OpenViking"
# 成功：OpenViking session ... commit task_id=...
# 失败：OpenViking 同步失败 session=...
```

---

## 八、修改扩展后的生效方式

1. 编辑 `deerflow_openviking_plugin.py` 和/或 `run_gateway.py`
2. 重新运行部署（至少更新 ConfigMap 并重启 Gateway）：

```powershell
cd d:\cursor\df_ov_k8s\k3s
.\scripts\deploy.ps1 -SkipBuild -SkipClone
kubectl rollout restart deployment/deer-flow-gateway -n deer-flow
```

3. **新开对话线程**测试（MCP 工具列表在首次对话时懒加载，旧线程可能缓存旧状态）

---

## 九、相关文档

- OpenViking K8s 部署：`k3s/manifests/openviking.yaml`
- 一键部署脚本：`k3s/scripts/deploy.ps1`
- DeerFlow MCP 官方说明：`deer-flow/backend/docs/MCP_SERVER.md`
- OpenViking MCP 认证：https://docs.openviking.ai/en/guides/06-mcp-integration
