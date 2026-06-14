#Requires -Version 5.1
<#
.SYNOPSIS
  查看 DeerFlow K8s 部署状态
#>
$Namespace = 'deer-flow'
$EnvFile = Join-Path (Split-Path -Parent $PSScriptRoot) '.env'  # k8s/.env
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        if ($_ -match '^K8S_NAMESPACE=(.+)$') { $Namespace = $Matches[1].Trim() }
        if ($_ -match '^NODE_PORT=(.+)$') { $script:NodePort = $Matches[1].Trim() }
    }
}
if (-not $NodePort) { $NodePort = '32026' }

Write-Host "`n=== Pods ===" -ForegroundColor Cyan
kubectl get pods -n $Namespace -o wide 2>&1

Write-Host "`n=== Services ===" -ForegroundColor Cyan
kubectl get svc -n $Namespace 2>&1

Write-Host "`n=== Sandbox Pods ===" -ForegroundColor Cyan
kubectl get pods -n $Namespace -l app=deer-flow-sandbox 2>&1

Write-Host "`n访问地址: http://localhost:$NodePort`n" -ForegroundColor Green
