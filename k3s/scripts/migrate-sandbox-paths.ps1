# 一次性迁移：将旧 Provisioner subPath（deer-flow/users/...）下的线程数据合并到 users/...
# 修复后 Sandbox 与 Gateway 共用同一路径，artifact 下载才能正常工作。
param(
    [string]$Namespace = 'deer-flow'
)

$ErrorActionPreference = 'Stop'

Write-Host '检查 Gateway Pod...'
kubectl get deploy/deer-flow-gateway -n $Namespace 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "命名空间 $Namespace 中未找到 deer-flow-gateway"
    exit 1
}

Write-Host '迁移 deer-flow/users -> users（合并，不覆盖已有较新文件）...'
$migrateScript = @'
set -e
BASE=/data/.deer-flow
LEGACY=$BASE/deer-flow/users
TARGET=$BASE/users
if [ ! -d "$LEGACY" ]; then
  echo "无需迁移：$LEGACY 不存在"
  exit 0
fi
mkdir -p "$TARGET"
# rsync 优先保留目标侧已有文件，仅补齐缺失项
if command -v rsync >/dev/null 2>&1; then
  rsync -a --ignore-existing "$LEGACY/" "$TARGET/"
else
  cp -an "$LEGACY/." "$TARGET/" 2>/dev/null || cp -a "$LEGACY/." "$TARGET/"
fi
echo "迁移完成。legacy 目录保留在 $LEGACY，确认无误后可手动删除。"
find "$TARGET" -path '*/user-data/outputs/*' -type f 2>/dev/null | head -20
'@

kubectl exec -n $Namespace deploy/deer-flow-gateway -- sh -c $migrateScript
if ($LASTEXITCODE -ne 0) {
    Write-Error '迁移失败'
    exit 1
}

Write-Host '完成。请重启 Gateway 并新建对话测试 artifact 下载。'

