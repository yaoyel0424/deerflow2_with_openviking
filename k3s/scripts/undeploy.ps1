#Requires -Version 5.1
<#
.SYNOPSIS
  卸载 DeerFlow K8s 部署
#>
$ErrorActionPreference = 'Stop'
$RootDir = Split-Path -Parent $PSScriptRoot

$Namespace = 'deer-flow'
$EnvFile = Join-Path $RootDir '.env'
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        if ($_ -match '^K8S_NAMESPACE=(.+)$') { $Namespace = $Matches[1].Trim() }
    }
}

Write-Host "正在删除命名空间 $Namespace（含 PVC，数据将丢失）..." -ForegroundColor Yellow
kubectl delete namespace $Namespace --timeout=120s 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host '删除失败或命名空间不存在' -ForegroundColor Red
} else {
    Write-Host '[OK] 卸载完成' -ForegroundColor Green
}
