# DeerFlow 2.0 — k3s / Rancher Desktop 部署

将 [DeerFlow 2.0](https://github.com/bytedance/deer-flow) 一键部署到 **Rancher Desktop（k3s）**。

> **Docker Desktop Kubernetes** 请使用同级目录 [`k8s/`](../k8s/)（`docker build` + 本地镜像共享）。

## 架构

```text
http://localhost:32026 (NodePort)
        │
   deer-flow-nginx
    ┌───┴───┐
    │       │
frontend  gateway (Lead Agent + Subagent + SSE)
              │
         provisioner ──► Sandbox Pod × N
              │
         PVC (data + skills)
```

| 组件 | 说明 |
|------|------|
| `deer-flow-gateway` | Agent 运行时、REST API、LangGraph 兼容 SSE |
| `deer-flow-frontend` | Next.js Web UI |
| `deer-flow-nginx` | 统一入口（/api/langgraph → gateway） |
| `deer-flow-provisioner` | 在集群内动态创建 Sandbox Pod |
| `deer-flow-skills-init` | 首次 Job：从 GitHub 拉取 skills 到 PVC |

## 前置条件

1. **Rancher Desktop** 已安装，Kubernetes 已启用且 `kubectl get nodes` 正常
2. **WSL 2.7+**（已升级）
3. **Docker** 可用于构建镜像
4. **Git** 用于克隆源码
5. Rancher VM 建议 **4 CPU / 8GB RAM**（Preferences → Virtual Machine）

## 快速开始（3 步）

```powershell
cd d:\cursor\df_ov_k8s\k8s

# 1. 创建并编辑环境变量
copy .env.example .env
notepad .env          # 填入 OPENAI_API_KEY

# 2. 可选：自定义 config（模型、工具等）
copy config\config.yaml.template config\config.yaml
notepad config\config.yaml

# 3. 一键部署（首次约 15-40 分钟：clone + build + 启动）
.\scripts\deploy.ps1
```

部署成功后访问：**http://localhost:32026**

## 常用命令

```powershell
# 查看状态
.\scripts\status.ps1

# 查看 Gateway 日志
kubectl logs -n deer-flow deploy/deer-flow-gateway -f

# 查看 Sandbox Pod
kubectl get pods -n deer-flow -l app=deer-flow-sandbox

# 跳过重新构建（仅更新配置后重新 apply）
.\scripts\deploy.ps1 -SkipBuild

# 卸载（删除命名空间及 PVC 数据）
.\scripts\undeploy.ps1
```

## 目录结构

```text
k8s/
├── .env.example          # 环境变量模板
├── config/
│   ├── config.yaml.template   # DeerFlow 配置模板
│   ├── config.yaml            # 实际配置（gitignore，需自行创建）
│   ├── extensions_config.json
│   └── nginx.conf             # K8s 版 Nginx 配置
├── manifests/            # Kubernetes 清单
│   ├── namespace.yaml
│   ├── rbac.yaml
│   ├── pvc.yaml
│   ├── provisioner.yaml
│   ├── gateway.yaml
│   ├── frontend.yaml
│   ├── nginx.yaml
│   └── service-nodeport.yaml
└── scripts/
    ├── deploy.ps1        # 全自动部署
    ├── undeploy.ps1      # 卸载
    └── status.ps1        # 状态检查
```

## 配置说明

### `.env` 关键变量

| 变量 | 说明 |
|------|------|
| `OPENAI_API_KEY` | LLM API Key（必填其一） |
| `NODE_PORT` | 对外端口，默认 `32026` |
| `NODE_HOST` | Provisioner 返回的 Sandbox 地址，留空自动检测节点 IP |
| `SANDBOX_IMAGE` | Sandbox 容器镜像 |
| `DEER_FLOW_SRC` | 源码路径，默认 `../deer-flow` |

### `config/config.yaml`

- 默认使用 **Provisioner + K8s Sandbox** 模式
- `provisioner_url: http://deer-flow-provisioner:8002`
- 可按 [官方配置文档](https://github.com/bytedance/deer-flow/blob/main/backend/docs/CONFIGURATION.md) 扩展模型、MCP、skills

### 国内网络加速

在 `.env` 中取消注释：

```ini
APT_MIRROR=mirrors.aliyun.com
UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
NPM_REGISTRY=https://registry.npmmirror.com
```

## 故障排查

| 现象 | 处理 |
|------|------|
| `kubectl` 连接拒绝 | 等待 Rancher Desktop 完全启动 1-2 分钟 |
| 镜像导入失败 | 确认 `wsl -d rancher-desktop` 可用；重启 Rancher |
| Gateway CrashLoopBackOff | `kubectl logs -n deer-flow deploy/deer-flow-gateway`；检查 API Key |
| Sandbox 创建失败 | 检查 `kubectl logs -n deer-flow deploy/deer-flow-provisioner`；确认 `NODE_HOST` |
| SSE 断流 | Nginx 已配置 600s 超时；检查代理层 |
| skills Job 失败 | `kubectl logs -n deer-flow job/deer-flow-skills-init`；检查网络 |

```powershell
# Provisioner 使用的节点 IP
kubectl get nodes -o wide

# 手动 patch NODE_HOST
kubectl set env deployment/deer-flow-provisioner -n deer-flow NODE_HOST=<节点IP>
```

## 安全提示

DeerFlow 默认无认证或使用内置认证，**请勿将 NodePort 暴露到公网**。详见 [官方安全说明](https://github.com/bytedance/deer-flow#%EF%B8%8F-security-notice)。

## 参考

- 源码：https://github.com/bytedance/deer-flow
- Provisioner：https://github.com/bytedance/deer-flow/tree/main/docker/provisioner
- 配置指南：https://github.com/bytedance/deer-flow/blob/main/backend/docs/CONFIGURATION.md
