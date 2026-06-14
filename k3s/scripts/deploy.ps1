#Requires -Version 5.1
<#
.SYNOPSIS
  DeerFlow 2.0 全自动 K8s 部署脚本（Rancher Desktop / k3s）

.DESCRIPTION
  1. 克隆 deer-flow 源码
  2. 通过 Rancher WSL nerdctl 构建 gateway / frontend / provisioner 镜像（直接写入 k8s.io）
  3. 若镜像仅在 default 命名空间，再逐镜像迁移到 k8s.io
  4. 生成 Secret / ConfigMap 并 apply 全部 manifests
  5. 等待服务就绪

.EXAMPLE
  cd k8s
  copy .env.example .env
  # 编辑 .env 填入 OPENAI_API_KEY
  .\scripts\deploy.ps1
#>
param(
    [switch]$SkipBuild,
    [switch]$SkipClone
)

$ErrorActionPreference = 'Stop'
# 脚本位于 k8s/scripts/，根目录为 k8s/
$RootDir = Split-Path -Parent $PSScriptRoot
Set-Location $RootDir

function Write-Step([string]$Msg) {
    Write-Host "`n==> $Msg" -ForegroundColor Cyan
}

function Write-Ok([string]$Msg) {
    Write-Host "[OK] $Msg" -ForegroundColor Green
}

function Write-Err([string]$Msg) {
    Write-Host "[错误] $Msg" -ForegroundColor Red
}

function Load-DotEnv([string]$Path) {
    $vars = @{}
    if (-not (Test-Path $Path)) { return $vars }
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { return }
        if ($line -match '^([^=]+)=(.*)$') {
            $vars[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    return $vars
}

function New-RandomHex([int]$Len = 32) {
    -join ((1..$Len) | ForEach-Object { '{0:x2}' -f (Get-Random -Maximum 256) })
}

# Rancher Desktop WSL 发行版名称（统一使用 nerdctl 构建，不使用 Windows Docker）
$script:WslDistro = 'rancher-desktop'
# k3s 使用的 containerd 命名空间；构建直接写入此处可跳过 save/import
$script:K8sNamespace = 'k8s.io'
# Rancher Desktop k3s 的 containerd socket（ctr 默认路径不可用）
$script:CtrSocket = '/run/k3s/containerd/containerd.sock'
# 预拉取成功后构建时加 --pull=false，避免 buildkit 直连 Docker Hub
$script:UseLocalBuildCache = $false

# 执行外部命令并返回退出码（避免 $ErrorActionPreference=Stop 时 stderr 触发异常）
function Invoke-External {
    param([scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command *> $null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

# 带超时的 WSL 命令（避免 rancher-desktop 僵死时脚本无限卡住）
function Invoke-WslCommand {
    param(
        [string]$Distro = $script:WslDistro,
        [string[]]$Command,
        [int]$TimeoutSec = 30
    )
    $job = Start-Job -ScriptBlock {
        param($DistroName, [string[]]$CmdArgs)
        & wsl -d $DistroName -- @CmdArgs 2>&1 | Out-Null
        return $LASTEXITCODE
    } -ArgumentList $Distro, $Command
    $completed = Wait-Job $job -Timeout $TimeoutSec
    if (-not $completed) {
        Stop-Job $job -Force -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        return $null
    }
    $exitCode = Receive-Job $job
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    return $exitCode
}

# 检测 WSL 发行版是否存在（直接探测，避免 wsl -l 输出含空字节导致匹配失败）
function Test-WslDistroExists([string]$Name) {
    $code = Invoke-WslCommand -Distro $Name -Command @('true') -TimeoutSec 15
    return ($code -eq 0)
}

# 检测 Rancher WSL 内 nerdctl 是否可用
function Test-NerdctlWsl {
    Write-Host '  正在检测 Rancher nerdctl（最多等待 30 秒）...'
    if (-not (Test-WslDistroExists $script:WslDistro)) { return $false }
    $code = Invoke-WslCommand -Command @('nerdctl', 'version') -TimeoutSec 30
    return ($code -eq 0)
}

# 将 Windows 路径转为 WSL 路径（手动转换，避免 wslpath/wsl 警告干扰 PowerShell）
function Get-WslPath([string]$WinPath) {
    $resolved = (Resolve-Path $WinPath -ErrorAction SilentlyContinue).Path
    if (-not $resolved) { $resolved = $WinPath }
    if ($resolved -match '^([A-Za-z]):[/\\](.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = $Matches[2] -replace '\\', '/'
        return "/mnt/$drive/$rest"
    }
    return ($resolved -replace '\\', '/')
}

# 在 Rancher WSL 内配置 containerd 镜像加速（需 .env 中设置 DOCKER_REGISTRY_MIRROR）
function Configure-RegistryMirror {
    if ([string]::IsNullOrWhiteSpace($env:DOCKER_REGISTRY_MIRROR)) {
        Write-Host '  [提示] 未设置 DOCKER_REGISTRY_MIRROR，拉取 Docker Hub 基础镜像可能较慢或失败' -ForegroundColor Yellow
        return
    }
    $mirror = $env:DOCKER_REGISTRY_MIRROR.TrimEnd('/')
    $ghcrMirror = if ($env:GHCR_REGISTRY_MIRROR) { $env:GHCR_REGISTRY_MIRROR.TrimEnd('/') } else { $mirror }

    $dockerToml = @"
server = "https://registry-1.docker.io"

[host."$mirror"]
  capabilities = ["pull", "resolve"]
"@
    $ghcrToml = @"
server = "https://ghcr.io"

[host."$ghcrMirror"]
  capabilities = ["pull", "resolve"]
"@

    $buildkitToml = @"
[registry."docker.io"]
  mirrors = ["$mirror"]

[registry."ghcr.io"]
  mirrors = ["$ghcrMirror"]
"@

    $tmpDir = Join-Path $env:TEMP 'deer-flow-registry'
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $dockerFile = Join-Path $tmpDir 'docker.io-hosts.toml'
    $ghcrFile = Join-Path $tmpDir 'ghcr.io-hosts.toml'
    $buildkitFile = Join-Path $tmpDir 'buildkitd.toml'
    # 使用无 BOM 的 UTF-8，避免 hosts.toml 解析失败
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($dockerFile, $dockerToml, $utf8NoBom)
    [System.IO.File]::WriteAllText($ghcrFile, $ghcrToml, $utf8NoBom)
    [System.IO.File]::WriteAllText($buildkitFile, $buildkitToml, $utf8NoBom)

    $wslDockerFile = Get-WslPath $dockerFile
    $wslGhcrFile = Get-WslPath $ghcrFile
    $wslBuildkitFile = Get-WslPath $buildkitFile
    $setupCmd = @(
        'mkdir -p /etc/containerd/certs.d/docker.io /etc/containerd/certs.d/ghcr.io /etc/buildkit',
        "cp '$wslDockerFile' /etc/containerd/certs.d/docker.io/hosts.toml",
        "cp '$wslGhcrFile' /etc/containerd/certs.d/ghcr.io/hosts.toml",
        "cp '$wslBuildkitFile' /etc/buildkit/buildkitd.toml"
    ) -join ' && '
    $setupExit = Invoke-External { wsl -d $script:WslDistro -- sh -c $setupCmd }
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($setupExit -ne 0) {
        Write-Host '  [提示] 镜像加速配置未生效，构建时将直连 Docker Hub' -ForegroundColor Yellow
        return
    }
    # 重启 buildkit 使镜像加速配置生效
    Invoke-External { wsl -d $script:WslDistro -- sh -c 'nerdctl restart buildkit 2>/dev/null || nerdctl rm -f buildkit 2>/dev/null || true' } | Out-Null
    Write-Ok "已配置镜像加速: docker.io / ghcr.io -> $mirror"
}

# 生成构建用临时 Dockerfile（镜像站 + uv 超时/国内源，不修改 deer-flow 源码）
function New-PatchedDockerfile {
    param(
        [string]$DockerfilePath,
        [string]$MirrorHost
    )
    $content = Get-Content $DockerfilePath -Raw -Encoding UTF8
    $patched = $false

    # Docker Hub 镜像站（buildkit 不读取宿主机 buildkitd.toml）
    if (-not [string]::IsNullOrWhiteSpace($MirrorHost)) {
        $content = $content -replace 'FROM python:', "FROM ${MirrorHost}/library/python:"
        $content = $content -replace 'FROM docker:', "FROM ${MirrorHost}/library/docker:"
        $content = $content -replace 'FROM node:', "FROM ${MirrorHost}/library/node:"
        $content = $content -replace 'COPY --from=docker:cli', "COPY --from=${MirrorHost}/library/docker:cli"
        $patched = $true
    }

    # uv sync：增大超时、降低并发，默认国内 PyPI 源（慢网下避免 30s 超时卡死）
    if ($content -match 'uv sync') {
        if ($content -notmatch 'ARG UV_HTTP_TIMEOUT') {
            $content = $content -replace 'ARG UV_INDEX_URL', "ARG UV_INDEX_URL`nARG UV_HTTP_TIMEOUT`nARG UV_CONCURRENT_DOWNLOADS"
        }
        $content = $content -replace 'UV_INDEX_URL=\$\{UV_INDEX_URL:-https://pypi\.org/simple\} uv sync', 'UV_HTTP_TIMEOUT=${UV_HTTP_TIMEOUT:-600} UV_CONCURRENT_DOWNLOADS=${UV_CONCURRENT_DOWNLOADS:-2} UV_INDEX_URL=${UV_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple} uv sync'
        $patched = $true
    }

    if (-not $patched) {
        return $DockerfilePath
    }
    $tmpFile = Join-Path $env:TEMP "deer-flow-dockerfile-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmpFile, $content, $utf8NoBom)
    return $tmpFile
}

# 拉取单个镜像并打本地标签（支持多个来源依次重试）
function Pull-AndTagImage {
    param(
        [string]$Tag,
        [string[]]$Sources
    )
    foreach ($src in $Sources) {
        $pullExit = Invoke-External { wsl -d $script:WslDistro -- nerdctl pull $src }
        if ($pullExit -eq 0) {
            if ($src -ne $Tag) {
                Invoke-External { wsl -d $script:WslDistro -- nerdctl tag $src $Tag } | Out-Null
            }
            return $true
        }
    }
    return $false
}

# 检查镜像是否已在 k8s.io（k3s 实际拉取位置）
function Test-K8sImage([string]$Tag) {
    $listed = wsl -d $script:WslDistro -- nerdctl -n $script:K8sNamespace images --format '{{.Repository}}:{{.Tag}}' 2>$null
    return ($listed -match [regex]::Escape($Tag))
}

# 检查镜像是否在 default 命名空间（旧版构建遗留）
function Test-DefaultImage([string]$Tag) {
    $listed = wsl -d $script:WslDistro -- nerdctl images --format '{{.Repository}}:{{.Tag}}' 2>$null
    return ($listed -match [regex]::Escape($Tag))
}

# 检查本地是否已有指定镜像（k8s.io 或 default 均算存在）
function Test-LocalImage([string]$Tag) {
    if (Test-K8sImage $Tag) { return $true }
    if (Test-DefaultImage $Tag) { return $true }
    return $false
}

# 组装 nerdctl build 公共参数（不含 -t / --output）
function Get-NerdctlBuildArgs {
    param(
        [string]$WslDockerfile,
        [string]$WslContext,
        [string]$Target,
        [string[]]$ImageBuildArgList
    )
    $args = @('build', '--progress=plain', '-f', $WslDockerfile)
    if ($script:UseLocalBuildCache) { $args += '--pull=false' }
    if ($Target) { $args += @('--target', $Target) }
    foreach ($ba in $ImageBuildArgList) { $args += @('--build-arg', $ba) }
    $args += $WslContext
    return , $args
}

# buildkit 导出成功但 nerdctl 未入库时，用 docker tar + load 兜底
function Import-ImageFromBuildTar {
    param(
        [string]$Tag,
        [string]$WslDockerfile,
        [string]$WslContext,
        [string]$Target,
        [string[]]$ImageBuildArgList
    )
    $safeName = ($Tag -replace '[:/]', '-')
    $wslTar = "/tmp/deer-flow-$safeName.tar"
    $tarArgs = Get-NerdctlBuildArgs -WslDockerfile $WslDockerfile -WslContext $WslContext `
        -Target $Target -ImageBuildArgList $ImageBuildArgList
    $tarArgs += @('-t', $Tag, '--output', "type=docker,dest=$wslTar")
    Write-Host "  [提示] 镜像未入库，改用 docker tar 导出并 load（命中缓存时较快）..." -ForegroundColor Yellow
    wsl -d $script:WslDistro -- nerdctl -n $script:K8sNamespace @tarArgs
    $exportExit = $LASTEXITCODE
    $loadExit = Invoke-External {
        wsl -d $script:WslDistro -- sh -c "test -f '$wslTar' && nerdctl -n $($script:K8sNamespace) load -i '$wslTar'"
    }
    Invoke-External { wsl -d $script:WslDistro -- rm -f $wslTar } | Out-Null
    if (Test-LocalImage $Tag) { return 0 }
    if ($exportExit -ne 0) { return $exportExit }
    return $loadExit
}

# 通过镜像站预拉取构建所需基础镜像（构建时使用 --pull=false 命中本地缓存）
function Prepull-BuildBaseImages {
    $mirrorHost = $null
    if (-not [string]::IsNullOrWhiteSpace($env:DOCKER_REGISTRY_MIRROR)) {
        $mirrorHost = ($env:DOCKER_REGISTRY_MIRROR -replace '^https?://', '').TrimEnd('/')
    }

    $baseImages = @(
        @{
            Tag = 'python:3.12-slim-bookworm'
            Sources = @(
                $(if ($mirrorHost) { "${mirrorHost}/library/python:3.12-slim-bookworm" }),
                'python:3.12-slim-bookworm'
            ) | Where-Object { $_ }
        },
        @{
            Tag = 'ghcr.io/astral-sh/uv:0.7.20'
            Sources = @(
                $(if ($mirrorHost) { "${mirrorHost}/ghcr.io/astral-sh/uv:0.7.20" }),
                'ghcr.io/astral-sh/uv:0.7.20'
            ) | Where-Object { $_ }
        },
        @{
            Tag = 'docker:cli'
            Sources = @(
                $(if ($mirrorHost) { "${mirrorHost}/library/docker:cli" }),
                'docker:cli'
            ) | Where-Object { $_ }
        },
        @{
            Tag = 'node:22-alpine'
            Sources = @(
                $(if ($mirrorHost) { "${mirrorHost}/library/node:22-alpine" }),
                'node:22-alpine'
            ) | Where-Object { $_ }
        }
    )

    Write-Host '  预拉取基础镜像...'
    $script:PrepullFailed = @()
    foreach ($img in $baseImages) {
        if (Test-LocalImage $img.Tag) {
            Write-Host "    $($img.Tag) [已存在]"
            continue
        }
        Write-Host "    $($img.Tag)"
        if (-not (Pull-AndTagImage -Tag $img.Tag -Sources $img.Sources)) {
            $script:PrepullFailed += $img.Tag
            Write-Host "    [警告] 预拉取失败: $($img.Tag)" -ForegroundColor Yellow
        }
    }
    if ($script:PrepullFailed.Count -gt 0) {
        Write-Host "  [提示] $($script:PrepullFailed.Count) 个镜像未预拉取，构建将从镜像站拉取" -ForegroundColor Yellow
    } else {
        $script:UseLocalBuildCache = $true
    }
}

# 检查 nerdctl 本地是否已有构建好的镜像
function Test-BuiltImageExists([string]$Tag) {
    return Test-LocalImage $Tag
}

# 确认 Rancher nerdctl 构建环境可用（统一走 nerdctl，不使用 Windows Docker）
function Initialize-NerdctlBuild {
    if (-not (Test-NerdctlWsl)) {
        Write-Err @'
Rancher Desktop 的 Kubernetes / containerd 未就绪。

常见现象：
  nerdctl version → cannot access containerd socket ... containerd.sock: no such file
  kubectl get nodes → 6443 connection refused

请按顺序修复：
  1. 打开 Rancher Desktop 应用（不只是 WSL 能响应 true）
  2. Settings → Kubernetes → 勾选 Enable Kubernetes
  3. 等待界面显示 Kubernetes 已启动（约 1–3 分钟）
  4. 验证：
       kubectl get nodes
       wsl -d rancher-desktop -- nerdctl version
  5. 两者都正常后再执行: .\scripts\deploy.ps1

若刚执行过 wsl --terminate，必须托盘退出并重新打开 Rancher Desktop。
'@
        exit 1
    }
    Write-Ok '使用 Rancher Desktop nerdctl 构建镜像'
}

# 构建单个镜像
function Invoke-ImageBuild {
    param(
        [string]$ImageName,
        [string]$Dockerfile,
        [string]$Context,
        [string]$Target,
        # 注意：不可命名为 BuildArgs，PowerShell 变量不区分大小写会与 nerdctl 参数数组冲突
        [string[]]$ImageBuildArgList
    )
    $tag = "${ImageName}:latest"
    $dockerfilePath = Join-Path $Context $Dockerfile
    $mirrorHost = $null
    if (-not [string]::IsNullOrWhiteSpace($env:DOCKER_REGISTRY_MIRROR)) {
        $mirrorHost = ($env:DOCKER_REGISTRY_MIRROR -replace '^https?://', '').TrimEnd('/')
    }
    $patchedDockerfile = New-PatchedDockerfile -DockerfilePath $dockerfilePath -MirrorHost $mirrorHost
    $wslDockerfile = Get-WslPath $patchedDockerfile
    $wslContext = Get-WslPath $Context
    $nerdctlArgs = Get-NerdctlBuildArgs -WslDockerfile $wslDockerfile -WslContext $wslContext `
        -Target $Target -ImageBuildArgList $ImageBuildArgList
    $nerdctlArgs += @('-t', $tag)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # 直接构建到 k8s.io，避免后续 nerdctl save 阻塞 WSL
        wsl -d $script:WslDistro -- nerdctl -n $script:K8sNamespace @nerdctlArgs
        $exitCode = $LASTEXITCODE
        # buildkit 导出完成后镜像注册可能略有延迟；WSL 代理警告也可能导致非零退出码
        $imageReady = $false
        for ($retry = 0; $retry -lt 10; $retry++) {
            if (Test-LocalImage $tag) {
                $imageReady = $true
                break
            }
            Start-Sleep -Seconds 2
        }
        if ($imageReady) {
            if ($exitCode -ne 0) {
                Write-Host "  [提示] nerdctl 退出码 $exitCode，但镜像 $tag 已存在，视为构建成功" -ForegroundColor Yellow
            }
            return 0
        }
        # 日志里已有 DONE 但 nerdctl 未入库：走 tar + load 兜底
        $fallbackExit = Import-ImageFromBuildTar -Tag $tag -WslDockerfile $wslDockerfile `
            -WslContext $wslContext -Target $Target -ImageBuildArgList $ImageBuildArgList
        if ($fallbackExit -eq 0 -and (Test-LocalImage $tag)) { return 0 }
        if ($fallbackExit -ne 0) { return $fallbackExit }
        return $exitCode
    } finally {
        if ($patchedDockerfile -ne $dockerfilePath) {
            Remove-Item $patchedDockerfile -Force -ErrorAction SilentlyContinue
        }
        $ErrorActionPreference = $prev
    }
}

# nerdctl save 管道导入 k8s.io（Rancher Desktop 须指定 ctr socket）
function Get-NerdctlToK8sPipeCmd([string]$Tag) {
    $ctr = $script:CtrSocket
    return "set -o pipefail; nerdctl save '$Tag' | ctr --address '$ctr' -n k8s.io images import -"
}

function Import-ImageTarToK8s([string]$TarPath) {
    $ctr = $script:CtrSocket
    wsl -d $script:WslDistro -- sh -c "ctr --address '$ctr' -n k8s.io images import '$TarPath'"
}

# 导出镜像并导入 k3s containerd（k8s.io 命名空间）
function Import-ImagesToK3s {
    param([string[]]$ImageNames)
    if (-not (Test-WslDistroExists $script:WslDistro)) {
        Write-Err '未找到 rancher-desktop WSL 发行版，请确认 Rancher Desktop 已安装'
        exit 1
    }

    $total = $ImageNames.Count
    Write-Host "  检查/导入 $total 个镜像到 k8s.io（已在 k8s.io 的会跳过；从 default 迁移约 1–5 分钟/个）" -ForegroundColor Cyan

    $idx = 0
    foreach ($name in $ImageNames) {
        $idx++
        $tag = "${name}:latest"
        if (Test-K8sImage $tag) {
            Write-Host "  [$idx/$total] $tag 已在 k8s.io，跳过"
            continue
        }
        if (-not (Test-DefaultImage $tag)) {
            Write-Err "镜像 $tag 不存在，请先完成构建"
            exit 1
        }
        Write-Host "  [$idx/$total] 从 default 迁移 $tag 到 k8s.io（约 1–5 分钟，请耐心等待）..."

        # 逐镜像管道导入；save 会占满 containerd，期间勿再开 wsl -d rancher-desktop 命令
        $pipeCmd = Get-NerdctlToK8sPipeCmd $tag
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            wsl -d $script:WslDistro -- sh -c $pipeCmd
            $importExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prev
        }

        if ($importExit -ne 0) {
            Write-Host "  [提示] 管道导入失败，改用 tar 方式重试 $tag ..." -ForegroundColor Yellow
            $wslTar = "/tmp/deer-flow-$name.tar"
            wsl -d $script:WslDistro -- sh -c "nerdctl save '$tag' -o '$wslTar'"
            if ($LASTEXITCODE -ne 0) {
                Write-Err "导出 $tag 失败"
                exit 1
            }
            Import-ImageTarToK8s $wslTar
            if ($LASTEXITCODE -ne 0) {
                wsl -d $script:WslDistro -- sh -c "nerdctl -n k8s.io load -i '$wslTar'"
                if ($LASTEXITCODE -ne 0) {
                    Write-Err "镜像 $tag 导入 k3s 失败"
                    exit 1
                }
            }
            wsl -d $script:WslDistro -- rm -f $wslTar
        }

        Write-Host "  [$idx/$total] $tag 已导入 k8s.io"
    }
}

# 生成镜像站拉取地址列表（国内环境）
function Get-MirrorPullSources([string]$Tag) {
    $sources = [System.Collections.Generic.List[string]]::new()
    [void]$sources.Add($Tag)
    if ([string]::IsNullOrWhiteSpace($env:DOCKER_REGISTRY_MIRROR)) { return $sources }
    $mirrorHost = ($env:DOCKER_REGISTRY_MIRROR -replace '^https?://', '').TrimEnd('/')
    if ($Tag -match '^[^/]+:[^:]+$') {
        [void]$sources.Insert(0, "${mirrorHost}/library/${Tag}")
    } elseif ($Tag -match '^[^/]+/') {
        [void]$sources.Insert(0, "${mirrorHost}/${Tag}")
    }
    return ($sources | Select-Object -Unique)
}

# 拉取 Docker Hub 公共镜像并导入 k8s.io（避免 Pod ImagePullBackOff）
function Ensure-ImageInK8s {
    param([string]$Tag)
    if (Test-K8sImage $Tag) {
        Write-Host "  $Tag 已在 k8s.io，跳过"
        return
    }
    if (Test-DefaultImage $Tag) {
        Write-Host "  将本地 $Tag 导入 k8s.io ..."
        $pipeCmd = Get-NerdctlToK8sPipeCmd $Tag
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            wsl -d $script:WslDistro -- sh -c $pipeCmd
        } finally {
            $ErrorActionPreference = $prev
        }
        if (Test-K8sImage $Tag) { return }
    }
    Import-PublicImageToK8s -Tag $Tag
}

function Import-PublicImageToK8s {
    param([string]$Tag)
    if (Test-K8sImage $Tag) {
        Write-Host "  $Tag 已在 k8s.io，跳过"
        return
    }
    Write-Host "  拉取并导入 $Tag 到 k8s.io ..."
    $pulled = $false
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($src in (Get-MirrorPullSources $Tag)) {
            wsl -d $script:WslDistro -- nerdctl pull $src 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                if ($src -ne $Tag) {
                    wsl -d $script:WslDistro -- nerdctl tag $src $Tag 2>&1 | Out-Null
                }
                $pulled = $true
                break
            }
        }
    } finally {
        $ErrorActionPreference = $prev
    }
    if (-not $pulled) {
        Write-Err "无法拉取镜像 $Tag，请在 .env 中设置 DOCKER_REGISTRY_MIRROR，或确保基础镜像已预拉取"
        exit 1
    }
    if (-not (Test-K8sImage $Tag)) {
        if (-not (Test-DefaultImage $Tag)) {
            Write-Err "镜像 $Tag 拉取后仍未在 nerdctl 中找到"
            exit 1
        }
        $pipeCmd = Get-NerdctlToK8sPipeCmd $Tag
        wsl -d $script:WslDistro -- sh -c $pipeCmd
        if ($LASTEXITCODE -ne 0 -or -not (Test-K8sImage $Tag)) {
            Write-Err "镜像 $Tag 导入 k8s.io 失败"
            exit 1
        }
    }
    Write-Host "  $Tag 已就绪"
}

# 用本地 node:22-alpine 构建 nginx 反向代理镜像（避免拉 docker.io/library/nginx）
function Build-NginxProxyImage {
    $tag = 'deer-flow-nginx-local:latest'
    if (Test-K8sImage $tag) {
        Write-Host '  deer-flow-nginx-local:latest 已在 k8s.io，跳过构建'
        return
    }
    Ensure-ImageInK8s -Tag 'node:22-alpine'
    $dockerDir = Join-Path $RootDir 'docker/nginx'
    $wslContext = Get-WslPath $dockerDir
    $wslDockerfile = Get-WslPath (Join-Path $dockerDir 'Dockerfile')
    Write-Host '  构建 deer-flow-nginx-local（基于 node:22-alpine + apk nginx）...'
    $buildArgs = @('build', '--progress=plain', '--pull=false', '-t', $tag, '-f', $wslDockerfile, $wslContext)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        wsl -d $script:WslDistro -- nerdctl -n $script:K8sNamespace @buildArgs
        if ($LASTEXITCODE -ne 0 -and -not (Test-K8sImage $tag)) {
            Write-Err 'deer-flow-nginx-local 构建失败'
            exit 1
        }
    } finally {
        $ErrorActionPreference = $prev
    }
    Write-Ok 'deer-flow-nginx-local 已构建'
}

# 等待 PVC 进入 Bound（k3s/local-path 通常只有 status.phase，无 condition=Bound，不能用 kubectl wait --for=condition=Bound）
function Wait-PvcPhaseBound {
    param(
        [string]$Name,
        [string]$Namespace,
        [int]$TimeoutSec = 120
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $phase = (kubectl get pvc $Name -n $Namespace -o jsonpath='{.status.phase}' 2>$null)
        if ($phase -eq 'Bound') { return $true }
        if ($phase -eq 'Lost') {
            Write-Err "PVC $Name 状态为 Lost，请执行: kubectl delete pvc $Name -n $Namespace 后重新部署"
            exit 1
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

# 复制 skills 前释放 RWO 卷（gateway 等已挂载时 loader Pod 无法启动）
function Release-SkillsPvcConsumers {
    param([string]$Namespace)
    $consumers = @(
        @{ Kind = 'deployment'; Name = 'deer-flow-gateway' },
        @{ Kind = 'job'; Name = 'deer-flow-skills-init' }
    )
    foreach ($c in $consumers) {
        if ($c.Kind -eq 'deployment') {
            $exists = kubectl get deployment $c.Name -n $Namespace -o name 2>$null
            if ($LASTEXITCODE -eq 0 -and $exists) {
                Write-Host "  暂时停止 $($c.Name) 以释放 skills PVC ..."
                kubectl scale deployment $c.Name -n $Namespace --replicas=0 2>&1 | Out-Null
            }
        } else {
            kubectl delete job $c.Name -n $Namespace --ignore-not-found 2>&1 | Out-Null
        }
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        kubectl wait --for=delete pod -l app=deer-flow-gateway -n $Namespace --timeout=90s 2>&1 | Out-Null
    } finally {
        $ErrorActionPreference = $prev
    }
}

# 将本地目录复制到 Pod（Windows：先打 tar 再 cp 单文件，避免目录 cp 失败）
function Copy-LocalDirToPod {
    param(
        [string]$LocalDir,
        [string]$Namespace,
        [string]$PodName,
        [string]$RemoteDir
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    $localTar = Join-Path $env:TEMP "deer-flow-skills-$([guid]::NewGuid().ToString('N').Substring(0,8)).tar"
    $remoteTar = '/tmp/deer-flow-skills.tar'

    try {
        if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
            Write-Err '未找到 tar 命令，无法复制 skills（Windows 10+ 应自带 tar.exe）'
            return 1
        }
        & tar -C $LocalDir -cf $localTar .
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $localTar)) {
            Write-Err '打包 skills 目录失败'
            return 1
        }

        # Windows kubectl cp 要求 src 为相对路径或短路径，且 dest 中冒号需避免被 PowerShell 误解析
        $tarName = Split-Path $localTar -Leaf
        $remoteSpec = "${Namespace}/${PodName}:${remoteTar}"
        Push-Location $env:TEMP
        try {
            kubectl cp $tarName $remoteSpec
        } finally {
            Pop-Location
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Err '上传 skills 压缩包到 Pod 失败'
            return 1
        }

        kubectl exec -n $Namespace $PodName -- tar -xf $remoteTar -C $RemoteDir
        if ($LASTEXITCODE -ne 0) {
            Write-Err '在 Pod 内解压 skills 失败'
            return 1
        }
        kubectl exec -n $Namespace $PodName -- rm -f $remoteTar 2>$null | Out-Null
        return 0
    } finally {
        Remove-Item $localTar -Force -ErrorAction SilentlyContinue
        $ErrorActionPreference = $prev
    }
}

# 从本地 deer-flow/skills 复制到 PVC（避免 Job 拉 alpine/git 与 clone GitHub）
function Initialize-SkillsFromLocal {
    param(
        [string]$SkillsDir,
        [string]$Namespace
    )
    $skillsPath = (Resolve-Path $SkillsDir -ErrorAction Stop).Path
    if (-not (Test-Path $skillsPath)) {
        Write-Err "skills 目录不存在: $skillsPath"
        exit 1
    }

    Write-Host '  等待 deer-flow-skills PVC 绑定...'
    if (-not (Wait-PvcPhaseBound -Name 'deer-flow-skills' -Namespace $Namespace -TimeoutSec 120)) {
        Write-Err 'deer-flow-skills PVC 未就绪（请检查: kubectl describe pvc deer-flow-skills -n deer-flow）'
        exit 1
    }
    Write-Ok 'deer-flow-skills PVC 已绑定'

    Release-SkillsPvcConsumers -Namespace $Namespace

    Ensure-ImageInK8s -Tag 'python:3.12-slim-bookworm'

    $loaderPod = 'deer-flow-skills-loader'
    kubectl delete pod $loaderPod -n $Namespace --ignore-not-found --wait=true 2>&1 | Out-Null

    $loaderYaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: $loaderPod
  namespace: $Namespace
spec:
  restartPolicy: Never
  containers:
    - name: loader
      image: python:3.12-slim-bookworm
      imagePullPolicy: IfNotPresent
      command: ['sleep', '600']
      volumeMounts:
        - name: skills
          mountPath: /skills
  volumes:
    - name: skills
      persistentVolumeClaim:
        claimName: deer-flow-skills
"@
    $loaderYaml | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { exit 1 }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        kubectl wait --for=condition=Ready pod/$loaderPod -n $Namespace --timeout=120s 2>&1 | Out-Null
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Err 'skills 加载 Pod 启动失败（可能被其他 Pod 占用 PVC，查看: kubectl describe pod -n deer-flow deer-flow-skills-loader）'
        exit 1
    }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    kubectl exec -n $Namespace $loaderPod -- test -f /skills/.initialized 2>&1 | Out-Null
    $skillsInitialized = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
    if ($skillsInitialized) {
        Write-Ok 'skills 已初始化，跳过'
    } else {
        Write-Host "  从本地复制 skills: $skillsPath"
        $copyExit = Copy-LocalDirToPod -LocalDir $skillsPath -Namespace $Namespace `
            -PodName $loaderPod -RemoteDir '/skills'
        if ($copyExit -ne 0) {
            Write-Err '复制 skills 到 PVC 失败'
            exit 1
        }
        kubectl exec -n $Namespace $loaderPod -- touch /skills/.initialized 2>&1 | Out-Null
        Write-Ok 'skills 已从本地源码写入 PVC'
    }

    kubectl delete pod $loaderPod -n $Namespace --wait=true 2>&1 | Out-Null
}

# 复制 k3s/config/skills 下的额外 skill 到 PVC
function Copy-ExtraSkillsToPvc {
    param(
        [string]$Namespace
    )
    $extraSkillsRoot = Join-Path $RootDir 'config/skills'
    if (-not (Test-Path $extraSkillsRoot)) { return }

    $skillDirs = Get-ChildItem $extraSkillsRoot -Directory -ErrorAction SilentlyContinue
    if (-not $skillDirs -or $skillDirs.Count -eq 0) { return }

    Write-Host '  复制 OpenViking 等扩展 skills ...'
    Ensure-ImageInK8s -Tag 'python:3.12-slim-bookworm'
    Release-SkillsPvcConsumers -Namespace $Namespace

    $loaderPod = 'deer-flow-extra-skills-loader'
    kubectl delete pod $loaderPod -n $Namespace --ignore-not-found --wait=true 2>&1 | Out-Null

    $loaderYaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: $loaderPod
  namespace: $Namespace
spec:
  restartPolicy: Never
  containers:
    - name: loader
      image: python:3.12-slim-bookworm
      imagePullPolicy: IfNotPresent
      command: ['sleep', '600']
      volumeMounts:
        - name: skills
          mountPath: /skills
  volumes:
    - name: skills
      persistentVolumeClaim:
        claimName: deer-flow-skills
"@
    $loaderYaml | kubectl apply -f -
    kubectl wait --for=condition=Ready pod/$loaderPod -n $Namespace --timeout=120s 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err '扩展 skills 加载 Pod 启动失败'
        exit 1
    }

    foreach ($dir in $skillDirs) {
        $dest = Join-Path '/skills' $dir.Name
        kubectl exec -n $Namespace $loaderPod -- mkdir -p $dest 2>&1 | Out-Null
        $copyExit = Copy-LocalDirToPod -LocalDir $dir.FullName -Namespace $Namespace `
            -PodName $loaderPod -RemoteDir $dest
        if ($copyExit -ne 0) {
            Write-Err "复制 skill $($dir.Name) 失败"
            exit 1
        }
        Write-Ok "skill $($dir.Name) 已写入 PVC"
    }

    kubectl delete pod $loaderPod -n $Namespace --wait=true 2>&1 | Out-Null
}

# 生成 OpenViking ov.conf（从模板 + .env 注入模型 Key）
function Resolve-OpenVikingRootApiKey {
    # 确保 OpenViking root_api_key 已就绪（绑定 0.0.0.0 时必需）
    $rootKey = $env:OPENVIKING_ROOT_API_KEY
    if ([string]::IsNullOrWhiteSpace($rootKey)) { $rootKey = $env:OPENVIKING_API_KEY }
    if ([string]::IsNullOrWhiteSpace($rootKey)) {
        $rootKey = -join ((48..57) + (97..102) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
        Write-Host '  [提示] 未配置 OPENVIKING_ROOT_API_KEY，已自动生成' -ForegroundColor Yellow
    }
    $env:OPENVIKING_ROOT_API_KEY = $rootKey
    if ([string]::IsNullOrWhiteSpace($env:OPENVIKING_API_KEY)) {
        $env:OPENVIKING_API_KEY = $rootKey
    }
    return $rootKey
}

function New-OpenVikingConfigFile {
    param([string]$OutPath)

    $templatePath = Join-Path $RootDir 'config/openviking.ov.conf.template'
    if (-not (Test-Path $templatePath)) {
        Write-Err "缺少 OpenViking 配置模板: $templatePath"
        exit 1
    }

    $embKey = $env:OPENVIKING_EMBEDDING_API_KEY
    if ([string]::IsNullOrWhiteSpace($embKey)) { $embKey = $env:VOLCENGINE_API_KEY }
    if ([string]::IsNullOrWhiteSpace($embKey)) { $embKey = $env:OPENAI_API_KEY }
    if ([string]::IsNullOrWhiteSpace($embKey)) { $embKey = $env:DEEPSEEK_API_KEY }
    if ([string]::IsNullOrWhiteSpace($embKey)) {
        Write-Err 'OpenViking 需要 embedding API Key：请配置 VOLCENGINE_API_KEY、OPENAI_API_KEY 或 OPENVIKING_EMBEDDING_API_KEY'
        exit 1
    }

    $useVolcengine = -not [string]::IsNullOrWhiteSpace($env:VOLCENGINE_API_KEY) -or
        ($embKey -eq $env:VOLCENGINE_API_KEY)

    $embBase = $env:OPENVIKING_EMBEDDING_API_BASE
    if ([string]::IsNullOrWhiteSpace($embBase)) { $embBase = $env:VOLCENGINE_API_BASE }
    if ([string]::IsNullOrWhiteSpace($embBase)) {
        if ($env:OPENAI_API_KEY) {
            $embBase = 'https://api.openai.com/v1'
        } else {
            $embBase = 'https://api.siliconflow.cn/v1'
            Write-Host '  [提示] 未配置 embedding 端点，使用 SiliconFlow 默认地址' -ForegroundColor Yellow
        }
    }
    $embModel = $env:OPENVIKING_EMBEDDING_MODEL
    if ([string]::IsNullOrWhiteSpace($embModel)) { $embModel = $env:VOLCENGINE_EMBEDDING_MODEL }
    if ([string]::IsNullOrWhiteSpace($embModel)) {
        $embModel = if ($env:OPENAI_API_KEY) { 'text-embedding-3-small' } else { 'BAAI/bge-m3' }
    }
    $embProvider = if ($useVolcengine -or $embBase -match 'volces\.com') { 'volcengine' } else { 'openai' }
    $embInput = if ($embProvider -eq 'volcengine' -and $embModel -match 'vision|embedding-vision') {
        'multimodal'
    } else {
        'text'
    }

    # VLM：优先 DeepSeek（与 DeerFlow config.yaml 主模型一致），embedding 仍走火山 Ark
    $vlmKey = $env:OPENVIKING_VLM_API_KEY
    if ([string]::IsNullOrWhiteSpace($vlmKey)) { $vlmKey = $env:DEEPSEEK_API_KEY }
    if ([string]::IsNullOrWhiteSpace($vlmKey)) { $vlmKey = $env:VOLCENGINE_API_KEY }
    if ([string]::IsNullOrWhiteSpace($vlmKey)) { $vlmKey = $env:OPENAI_API_KEY }
    if ([string]::IsNullOrWhiteSpace($vlmKey)) {
        Write-Err 'OpenViking VLM 需要 API Key：请配置 DEEPSEEK_API_KEY、VOLCENGINE_API_KEY 或 OPENVIKING_VLM_API_KEY'
        exit 1
    }

    $vlmBase = $env:OPENVIKING_VLM_API_BASE
    if ([string]::IsNullOrWhiteSpace($vlmBase)) {
        if ($vlmKey -eq $env:DEEPSEEK_API_KEY) {
            $vlmBase = 'https://api.deepseek.com/v1'
        } elseif (-not [string]::IsNullOrWhiteSpace($env:VOLCENGINE_VLM_API_BASE)) {
            $vlmBase = $env:VOLCENGINE_VLM_API_BASE
        } elseif ($vlmKey -eq $env:VOLCENGINE_API_KEY -and $env:VOLCENGINE_API_BASE) {
            $vlmBase = $env:VOLCENGINE_API_BASE
        } elseif ($env:OPENAI_API_KEY) {
            $vlmBase = 'https://api.openai.com/v1'
        } else {
            $vlmBase = 'https://api.deepseek.com/v1'
        }
    }
    $vlmModel = $env:OPENVIKING_VLM_MODEL
    if ([string]::IsNullOrWhiteSpace($vlmModel)) { $vlmModel = $env:DEEPSEEK_VLM_MODEL }
    if ([string]::IsNullOrWhiteSpace($vlmModel)) { $vlmModel = $env:VOLCENGINE_VLM_MODEL }
    if ([string]::IsNullOrWhiteSpace($vlmModel)) {
        if ($vlmBase -match 'deepseek\.com') {
            $vlmModel = 'deepseek-v4-pro'
        } elseif ($vlmBase -match 'volces\.com') {
            $vlmModel = 'doubao-seed-2-0-pro-260215'
        } elseif ($env:OPENAI_API_KEY) {
            $vlmModel = 'gpt-4o-mini'
        } else {
            $vlmModel = 'deepseek-v4-pro'
        }
    }
    $vlmProvider = if ($vlmBase -match 'volces\.com') { 'volcengine' } else { 'openai' }

    $rootKey = Resolve-OpenVikingRootApiKey

    $content = Get-Content $templatePath -Raw -Encoding UTF8
    $content = $content -replace 'REPLACE_ROOT_API_KEY', $rootKey
    $content = $content -replace 'REPLACE_EMBEDDING_PROVIDER', $embProvider
    $content = $content -replace 'REPLACE_EMBEDDING_API_BASE', $embBase
    $content = $content -replace 'REPLACE_EMBEDDING_API_KEY', $embKey
    $content = $content -replace 'REPLACE_EMBEDDING_MODEL', $embModel
    $content = $content -replace 'REPLACE_EMBEDDING_INPUT', $embInput
    $content = $content -replace 'REPLACE_VLM_PROVIDER', $vlmProvider
    $content = $content -replace 'REPLACE_VLM_API_BASE', $vlmBase
    $content = $content -replace 'REPLACE_VLM_API_KEY', $vlmKey
    $content = $content -replace 'REPLACE_VLM_MODEL', $vlmModel

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($OutPath, $content, $utf8NoBom)
    Write-Ok "OpenViking ov.conf 已生成: $OutPath"
}

# 获取集群第一个节点的 InternalIP（避免 PowerShell 解析 jsonpath 中的 @ 符号）
function Get-NodeInternalIP {
    try {
        $json = kubectl get nodes -o json 2>&1
        if ($LASTEXITCODE -ne 0) { return '' }
        $nodes = $json | ConvertFrom-Json
        if (-not $nodes.items -or $nodes.items.Count -eq 0) { return '' }
        $addr = $nodes.items[0].status.addresses |
            Where-Object { $_.type -eq 'InternalIP' } |
            Select-Object -First 1 -ExpandProperty address
        if ($addr) { return [string]$addr.Trim() }
    } catch {
        return ''
    }
    return ''
}

# -- 加载环境变量 --
Write-Step '加载配置'
$EnvFile = Join-Path $RootDir '.env'
if (-not (Test-Path $EnvFile)) {
    Copy-Item (Join-Path $RootDir '.env.example') $EnvFile
    Write-Err ".env 已从 .env.example 创建，请编辑 $EnvFile 填入 OPENAI_API_KEY 后重新运行"
    exit 1
}
$Env = Load-DotEnv $EnvFile
foreach ($k in $Env.Keys) {
    if (-not [string]::IsNullOrWhiteSpace($Env[$k])) {
        Set-Item -Path "env:$k" -Value $Env[$k]
    }
}

if ([string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY) -and
    [string]::IsNullOrWhiteSpace($env:ANTHROPIC_API_KEY) -and
    [string]::IsNullOrWhiteSpace($env:DEEPSEEK_API_KEY)) {
    Write-Err '请在 .env 中至少配置一个 LLM API Key（OPENAI_API_KEY 等）'
    exit 1
}

if ([string]::IsNullOrWhiteSpace($env:BETTER_AUTH_SECRET)) {
    $env:BETTER_AUTH_SECRET = New-RandomHex 32
    Write-Ok '已自动生成 BETTER_AUTH_SECRET'
}
if ([string]::IsNullOrWhiteSpace($env:DEER_FLOW_INTERNAL_AUTH_TOKEN)) {
    $env:DEER_FLOW_INTERNAL_AUTH_TOKEN = New-RandomHex 24
    Write-Ok '已自动生成 DEER_FLOW_INTERNAL_AUTH_TOKEN'
}

$SrcDir = if ($env:DEER_FLOW_SRC) { Resolve-Path $env:DEER_FLOW_SRC -ErrorAction SilentlyContinue } else { $null }
if (-not $SrcDir) {
    $SrcDir = Join-Path (Split-Path $RootDir -Parent) 'deer-flow'
}
$SrcDir = [string]$SrcDir
$RepoUrl = if ($env:DEER_FLOW_REPO) { $env:DEER_FLOW_REPO } else { 'https://github.com/bytedance/deer-flow.git' }
$Branch = if ($env:DEER_FLOW_BRANCH) { $env:DEER_FLOW_BRANCH } else { 'main' }
$StorageClass = if ($env:STORAGE_CLASS) { $env:STORAGE_CLASS } else { 'local-path' }
$Namespace = if ($env:K8S_NAMESPACE) { $env:K8S_NAMESPACE } else { 'deer-flow' }
$NodePort = if ($env:NODE_PORT) { [int]$env:NODE_PORT } else { 32026 }
$SandboxImage = if ($env:SANDBOX_IMAGE) { $env:SANDBOX_IMAGE } else {
    'enterprise-public-cn-beijing.cr.volces.com/vefaas-public/all-in-one-sandbox:latest'
}
# OpenViking 容器镜像（国内默认南京大学 ghcr 镜像站 v0.3.24，含 CPU SIMD 运行时适配）
$OpenVikingImage = if ($env:OPENVIKING_IMAGE) { $env:OPENVIKING_IMAGE } else {
    'ghcr.nju.edu.cn/volcengine/openviking:v0.3.24'
}

# -- 检查依赖 --
Write-Step '检查依赖'
foreach ($cmd in @('kubectl', 'wsl')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Err "未找到 $cmd，请先安装并加入 PATH"
        exit 1
    }
}
kubectl cluster-info 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Err @'
kubectl 无法连接集群（6443 connection refused）。

请打开 Rancher Desktop → Settings → Kubernetes → 启用并等待就绪，然后执行：
  kubectl get nodes
'@
    exit 1
}
Write-Ok 'kubectl 集群可用'
if (-not $SkipBuild) {
    Initialize-NerdctlBuild
}

# -- 克隆源码 --
if (-not $SkipClone) {
    Write-Step '准备 DeerFlow 源码'
    if (-not (Test-Path $SrcDir)) {
        git clone --depth 1 --branch $Branch $RepoUrl $SrcDir
        if ($LASTEXITCODE -ne 0) { exit 1 }
        Write-Ok "已克隆到 $SrcDir"
    } else {
        Write-Ok "使用已有源码 $SrcDir"
    }
} else {
    if (-not (Test-Path $SrcDir)) {
        Write-Err "源码目录不存在: $SrcDir"
        exit 1
    }
}

# -- 准备 config.yaml --
Write-Step '生成配置文件'
$ConfigDir = Join-Path $RootDir 'config'
$ConfigFile = Join-Path $ConfigDir 'config.yaml'
if (-not (Test-Path $ConfigFile)) {
    Copy-Item (Join-Path $ConfigDir 'config.yaml.template') $ConfigFile
    Write-Ok '已从模板创建 config/config.yaml'
}
$ExtensionsFile = Join-Path $ConfigDir 'extensions_config.json'

# -- 构建镜像 --
$Images = @(
    # backend/Dockerfile 最终阶段无 stage 名，不可使用 --target prod
    @{ Name = 'deer-flow-gateway'; Dockerfile = 'backend/Dockerfile'; Context = $SrcDir; Target = $null },
    @{ Name = 'deer-flow-frontend'; Dockerfile = 'frontend/Dockerfile'; Context = $SrcDir; Target = 'prod' },
    @{ Name = 'deer-flow-provisioner'; Dockerfile = 'Dockerfile'; Context = (Join-Path $SrcDir 'docker/provisioner'); Target = $null }
)

if (-not $SkipBuild) {
    Write-Step '构建容器镜像（nerdctl，首次约 10-30 分钟）'
    Configure-RegistryMirror
    Prepull-BuildBaseImages
    $BuildArgs = @()
    if ($env:APT_MIRROR) { $BuildArgs += "APT_MIRROR=$($env:APT_MIRROR)" }
    if ($env:UV_INDEX_URL) { $BuildArgs += "UV_INDEX_URL=$($env:UV_INDEX_URL)" }
    if (-not $env:UV_HTTP_TIMEOUT) { $env:UV_HTTP_TIMEOUT = '600' }
    $BuildArgs += "UV_HTTP_TIMEOUT=$($env:UV_HTTP_TIMEOUT)"
    if (-not $env:UV_CONCURRENT_DOWNLOADS) { $env:UV_CONCURRENT_DOWNLOADS = '2' }
    $BuildArgs += "UV_CONCURRENT_DOWNLOADS=$($env:UV_CONCURRENT_DOWNLOADS)"
    if ($env:NPM_REGISTRY) { $BuildArgs += "NPM_REGISTRY=$($env:NPM_REGISTRY)" }
    if ($env:PIP_INDEX_URL) { $BuildArgs += "PIP_INDEX_URL=$($env:PIP_INDEX_URL)" }

    foreach ($img in $Images) {
        $imgTag = "$($img.Name):latest"
        if (Test-BuiltImageExists $imgTag) {
            Write-Host "  $($img.Name) [已存在，跳过构建]"
            continue
        }
        if ($img.Name -eq 'deer-flow-gateway') {
            Write-Host '  构建 deer-flow-gateway（uv sync 依赖较多，慢网下可能需 15-30 分钟，请耐心等待）...'
        } else {
            Write-Host "  构建 $($img.Name) ..."
        }
        $exitCode = Invoke-ImageBuild -ImageName $img.Name `
            -Dockerfile $img.Dockerfile -Context $img.Context `
            -Target $img.Target -ImageBuildArgList $BuildArgs
        if ($exitCode -ne 0) {
            Write-Err "构建 $($img.Name) 失败"
            exit 1
        }
    }
    Write-Ok '镜像构建完成'

    # -- 导入到 k3s --
    Write-Step '导入镜像到 Rancher Desktop k3s'
    Import-ImagesToK3s -ImageNames @(
        'deer-flow-gateway', 'deer-flow-frontend', 'deer-flow-provisioner'
    )
    Write-Ok '镜像已导入 k8s.io'
} else {
    Write-Ok '跳过构建（-SkipBuild）'
}

# -- 检测节点 IP (Provisioner NODE_HOST) --
Write-Step '检测集群节点 IP'
$NodeHost = $env:NODE_HOST
if ([string]::IsNullOrWhiteSpace($NodeHost)) {
    $NodeHost = Get-NodeInternalIP
}
if ([string]::IsNullOrWhiteSpace($NodeHost)) {
    Write-Err '无法获取节点 InternalIP，请在 .env 中手动设置 NODE_HOST'
    exit 1
}
Write-Ok "NODE_HOST = $NodeHost"

# -- 创建命名空间（Secret/ConfigMap 依赖此 namespace）--
$ManifestDir = Join-Path $RootDir 'manifests'
kubectl apply -f (Join-Path $ManifestDir 'namespace.yaml')
if ($LASTEXITCODE -ne 0) {
    Write-Err '创建命名空间 deer-flow 失败'
    exit 1
}

$OpenVikingEnabled = -not ($env:OPENVIKING_ENABLED -and $env:OPENVIKING_ENABLED.ToLower() -in @('0', 'false', 'no'))
if ($OpenVikingEnabled) {
    Resolve-OpenVikingRootApiKey | Out-Null
}

# -- 生成并应用 Secret / ConfigMap --
Write-Step '生成 Secret 与 ConfigMap'
$SecretsDir = Join-Path $RootDir 'secrets'
New-Item -ItemType Directory -Force -Path $SecretsDir | Out-Null
$nginxConfPath = Join-Path $ConfigDir 'nginx.conf'

# Secret
$secretArgs = @(
    'create', 'secret', 'generic', 'deer-flow-env',
    "--namespace=$Namespace",
    '--dry-run=client', '-o', 'yaml'
)
if ($env:OPENAI_API_KEY) { $secretArgs += @("--from-literal=OPENAI_API_KEY=$($env:OPENAI_API_KEY)") }
if ($env:ANTHROPIC_API_KEY) { $secretArgs += @("--from-literal=ANTHROPIC_API_KEY=$($env:ANTHROPIC_API_KEY)") }
if ($env:DEEPSEEK_API_KEY) { $secretArgs += @("--from-literal=DEEPSEEK_API_KEY=$($env:DEEPSEEK_API_KEY)") }
if ($env:OPENVIKING_API_KEY) { $secretArgs += @("--from-literal=OPENVIKING_API_KEY=$($env:OPENVIKING_API_KEY)") }
if ($OpenVikingEnabled -and $env:OPENVIKING_API_KEY) {
    if (-not $env:OPENVIKING_MCP_AUTHORIZATION) {
        $env:OPENVIKING_MCP_AUTHORIZATION = "Bearer $($env:OPENVIKING_API_KEY)"
    }
    $secretArgs += @("--from-literal=OPENVIKING_MCP_AUTHORIZATION=$($env:OPENVIKING_MCP_AUTHORIZATION)")
}
$secretArgs += @(
    "--from-literal=BETTER_AUTH_SECRET=$($env:BETTER_AUTH_SECRET)",
    "--from-literal=DEER_FLOW_INTERNAL_AUTH_TOKEN=$($env:DEER_FLOW_INTERNAL_AUTH_TOKEN)"
)
kubectl @secretArgs | kubectl apply -f -
if ($LASTEXITCODE -ne 0) {
    Write-Err 'Secret deer-flow-env 创建失败'
    exit 1
}

# ConfigMap: deer-flow-config（直接 create 避免 YAML 管道中 # 注释破坏解析）
kubectl delete configmap deer-flow-config -n $Namespace --ignore-not-found 2>&1 | Out-Null
kubectl create configmap deer-flow-config `
    --namespace=$Namespace `
    --from-file="config.yaml=$ConfigFile" `
    --from-file="extensions_config.json=$ExtensionsFile"
if ($LASTEXITCODE -ne 0) {
    Write-Err 'ConfigMap deer-flow-config 创建失败'
    exit 1
}

# ConfigMap: nginx
kubectl delete configmap deer-flow-nginx -n $Namespace --ignore-not-found 2>&1 | Out-Null
kubectl create configmap deer-flow-nginx `
    --namespace=$Namespace `
    --from-file="nginx.conf=$nginxConfPath"
if ($LASTEXITCODE -ne 0) {
    Write-Err 'ConfigMap deer-flow-nginx 创建失败'
    exit 1
}

# ConfigMap: provisioner app.py
$ProvisionerApp = Join-Path $SrcDir 'docker/provisioner/app.py'
if (-not (Test-Path $ProvisionerApp)) {
    Write-Err "Provisioner 源码不存在: $ProvisionerApp"
    exit 1
}
kubectl delete configmap deer-flow-provisioner-app -n $Namespace --ignore-not-found 2>&1 | Out-Null
kubectl create configmap deer-flow-provisioner-app `
    --namespace=$Namespace `
    --from-file="app.py=$ProvisionerApp"
if ($LASTEXITCODE -ne 0) {
    Write-Err 'ConfigMap deer-flow-provisioner-app 创建失败'
    exit 1
}

Write-Ok 'Secret / ConfigMap 已应用'

# Gateway OpenViking 扩展（单文件插件，避免 ConfigMap key 含 /）
$ExtensionsDir = Join-Path $RootDir 'extensions'
$PluginFile = Join-Path $ExtensionsDir 'deerflow_openviking_plugin.py'
$RunGatewayFile = Join-Path $ExtensionsDir 'run_gateway.py'
foreach ($f in @($PluginFile, $RunGatewayFile)) {
    if (-not (Test-Path $f)) {
        Write-Err "Gateway 扩展文件不存在: $f"
        exit 1
    }
}
kubectl delete configmap deer-flow-gateway-extensions -n $Namespace --ignore-not-found 2>&1 | Out-Null
kubectl create configmap deer-flow-gateway-extensions `
    --namespace=$Namespace `
    --from-file="deerflow_openviking_plugin.py=$PluginFile" `
    --from-file="run_gateway.py=$RunGatewayFile"
if ($LASTEXITCODE -ne 0) {
    Write-Err 'ConfigMap deer-flow-gateway-extensions 创建失败'
    exit 1
}
Write-Ok 'Gateway OpenViking 扩展 ConfigMap 已应用'

# OpenViking 服务（可选，默认启用）
if ($OpenVikingEnabled) {
    Write-Step '配置 OpenViking'
    $OvConfTmp = Join-Path $env:TEMP "openviking-ov-$([guid]::NewGuid().ToString('N').Substring(0,8)).conf"
    New-OpenVikingConfigFile -OutPath $OvConfTmp
    kubectl delete configmap openviking-config -n $Namespace --ignore-not-found 2>&1 | Out-Null
    kubectl create configmap openviking-config `
        --namespace=$Namespace `
        --from-file="ov.conf=$OvConfTmp"
    Remove-Item $OvConfTmp -Force -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0) {
        Write-Err 'ConfigMap openviking-config 创建失败'
        exit 1
    }
    Write-Ok 'OpenViking ConfigMap 已应用'
}

# 清理旧版 skills Job（已改为本地复制）
kubectl delete job deer-flow-skills-init -n $Namespace --ignore-not-found 2>&1 | Out-Null

# -- 应用 manifests (替换 NODE_HOST 和 nodePort) --
Write-Step '应用 Kubernetes 清单'
$TmpDir = Join-Path $env:TEMP "deer-flow-k8s-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null

Get-ChildItem $ManifestDir -Filter '*.yaml' | ForEach-Object {
    $content = Get-Content $_.FullName -Raw -Encoding UTF8
    $content = $content -replace 'REPLACE_NODE_HOST', $NodeHost
    $content = $content -replace 'nodePort: 32026', "nodePort: $NodePort"
    $content = $content -replace 'storageClassName: local-path', "storageClassName: $StorageClass"
    $content = $content -replace 'REPLACE_OPENVIKING_IMAGE', $OpenVikingImage
    $content = $content -replace 'enterprise-public-cn-beijing.cr.volces.com/vefaas-public/all-in-one-sandbox:latest', $SandboxImage
    Set-Content -Path (Join-Path $TmpDir $_.Name) -Value $content -Encoding UTF8 -NoNewline
}

function Apply-ManifestFromTmp([string]$FileName) {
    $file = Join-Path $TmpDir $FileName
    if (-not (Test-Path $file)) {
        Write-Err "缺少清单文件: $FileName"
        exit 1
    }
    kubectl apply -f $file
    if ($LASTEXITCODE -ne 0) {
        Write-Err "apply 失败: $FileName"
        exit 1
    }
}

foreach ($name in @('rbac.yaml', 'pvc.yaml')) {
    Apply-ManifestFromTmp $name
}

Write-Step '初始化 skills 与公共镜像'
Build-NginxProxyImage
if (-not [string]::IsNullOrWhiteSpace($SandboxImage)) {
    Write-Host "  预拉 Sandbox 镜像（Agent 执行代码时需要，首次可能较慢）..."
    $prevEapSandbox = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if (Test-K8sImage $SandboxImage) {
            Write-Host "  $SandboxImage 已在 k8s.io，跳过"
        } else {
            Import-PublicImageToK8s -Tag $SandboxImage
        }
    } catch {
        Write-Host "  [警告] Sandbox 镜像预拉失败: $_ — Agent 首次执行时会现场拉取，可能较慢" -ForegroundColor Yellow
    } finally {
        $ErrorActionPreference = $prevEapSandbox
    }
}
Initialize-SkillsFromLocal -SkillsDir (Join-Path $SrcDir 'skills') -Namespace $Namespace
Copy-ExtraSkillsToPvc -Namespace $Namespace

if ($OpenVikingEnabled) {
    Write-Host "  预拉 OpenViking 镜像: $OpenVikingImage"
    Ensure-ImageInK8s -Tag $OpenVikingImage
    Apply-ManifestFromTmp 'openviking.yaml'
}

foreach ($name in @(
        'provisioner.yaml', 'gateway.yaml', 'frontend.yaml',
        'nginx.yaml', 'service-nodeport.yaml'
    )) {
    Apply-ManifestFromTmp $name
}
Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Ok '清单已应用'

# -- 等待就绪 --
Write-Step '等待服务就绪（可能需要 2-5 分钟）'

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$Deployments = @('deer-flow-provisioner', 'deer-flow-gateway', 'deer-flow-frontend', 'deer-flow-nginx')
if ($OpenVikingEnabled) { $Deployments = @('openviking') + $Deployments }
foreach ($dep in $Deployments) {
    Write-Host "  等待 $dep ..."
    kubectl rollout status deployment/$dep -n $Namespace --timeout=300s 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $ErrorActionPreference = $prevEap
        Write-Err ('{0} 启动超时，请检查: kubectl describe pod -n {1} -l app={0}' -f $dep, $Namespace)
        exit 1
    }
}
$ErrorActionPreference = $prevEap

# -- 完成 --
Write-Host ''
Write-Host '========================================' -ForegroundColor Green
Write-Host ' DeerFlow 2.0 部署完成!' -ForegroundColor Green
Write-Host '========================================' -ForegroundColor Green
Write-Host ''
Write-Host ('  Web UI:  http://localhost:{0}' -f $NodePort)
Write-Host ('  API:     http://localhost:{0}/api/' -f $NodePort)
Write-Host ('  健康检查: http://localhost:{0}/health' -f $NodePort)
if ($OpenVikingEnabled) {
    Write-Host ''
    Write-Host '  OpenViking:'
    Write-Host '    MCP:     http://openviking.deer-flow.svc:1933/mcp（集群内）'
    Write-Host '    内置 Memory 已关闭，Agent 通过 MCP search/find/read 检索记忆'
}
Write-Host ''
Write-Host '  常用命令:'
Write-Host ('    kubectl get pods -n {0}' -f $Namespace)
Write-Host ('    kubectl logs -n {0} deploy/deer-flow-gateway -f' -f $Namespace)
Write-Host '    .\scripts\undeploy.ps1'
Write-Host ''
