你当前机器上 **只有 `rancher-desktop` 这一个上下文**，还没有 `docker-desktop`。所以要分两种情况：

## 一、要用 `k8s/`（Docker Desktop K8s）

### 1. 先启用 Docker Desktop 的 Kubernetes

1. 打开 **Docker Desktop**
2. 进入 **Settings（设置）→ Kubernetes**
3. 勾选 **Enable Kubernetes**
4. 点击 **Apply & Restart**，等待左下角显示 Kubernetes 为绿色运行中

启用成功后，再执行：

```powershell
kubectl config get-contexts
```

应能看到 `docker-desktop` 这一项。

### 2. 切换到 docker-desktop

```powershell
kubectl config use-context docker-desktop
```

### 3. 确认已切换

```powershell
kubectl config current-context
kubectl get nodes
```

期望输出类似：

```
docker-desktop
NAME             STATUS   ROLES           AGE   VERSION
docker-desktop   Ready    control-plane   ...   v1.x.x
```

### 4. 再部署

```powershell
cd d:\cursor\df_ov_k8s\k8s
.\scripts\deploy.ps1
```

---

## 二、继续用 Rancher（你现在的环境）

**不用切换**，保持 `rancher-desktop` 即可：

```powershell
kubectl config current-context   # 应显示 rancher-desktop
cd d:\cursor\df_ov_k8s\k3s
.\scripts\deploy.ps1
```

---

## 常用切换命令

| 操作 | 命令 |
|------|------|
| 查看所有上下文 | `kubectl config get-contexts` |
| 切换到 Docker Desktop | `kubectl config use-context docker-desktop` |
| 切回 Rancher | `kubectl config use-context rancher-desktop` |
| 查看当前上下文 | `kubectl config current-context` |

---

**建议：** 你已在 Rancher 上跑通 nerdctl 构建，若暂不装/不启 Docker Desktop Kubernetes，继续用 **`k3s/`** 即可，不必切换上下文。只有明确要用 **Docker Desktop 自带 K8s** 时，才需要启用并切换到 `docker-desktop`。