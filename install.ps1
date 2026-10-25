#Requires -Version 5.1
<#
.SYNOPSIS
  dsh-pet-bili-bridge 一键安装（绿色：只写用户目录，不写注册表、不装服务）。

.DESCRIPTION
  做四件事：
    1) 部署 watcher 到 %LOCALAPPDATA%\dsh-pet-bili-bridge
    2) 备份并合并桌宠 config.json 的 agent_link.custom_agents（只增改自己那两项）
    3) 可选：注册到启动文件夹（-Autostart），让 watcher 开机自起
    4) 打印剩下的两步手动操作

.PARAMETER PetConfig
  桌宠 config.json 的完整路径。不填则自动在 %APPDATA%\dsh-pet-* 下查找。

.PARAMETER BiliHome
  dsh-bili-scroll 的家目录（含 duty.log）。不填则自动探测。

.PARAMETER Autostart
  注册到当前用户的启动文件夹（隐藏窗口运行）。

.PARAMETER NoPetConfig
  不碰桌宠配置，只部署 watcher（想自己改 config 的人用这个）。

.PARAMETER Force
  跳过"看起来没装桌宠"的确认。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Autostart
#>
[CmdletBinding()]
param(
  [string]$PetConfig = '',
  [string]$BiliHome = '',
  [switch]$Autostart,
  [switch]$NoPetConfig,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallDir = Join-Path $env:LOCALAPPDATA 'dsh-pet-bili-bridge'
$EventDir = Join-Path $HOME '.dsh-pet-bridge\agents'

# ⚠️ 必须无 BOM：桌宠用 Python json.load 读 config.json，带 BOM 会直接解析失败
$NoBom = New-Object System.Text.UTF8Encoding($false)

function Say  { param([string]$m) Write-Host $m -ForegroundColor Cyan }
function Ok   { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Bad  { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }

Write-Host ''
Write-Host '  dsh-pet-bili-bridge  安装程序' -ForegroundColor White
Write-Host '  桌宠 <-> B站值班 / WorkBuddy 状态桥' -ForegroundColor DarkGray
Write-Host ''

# ---------- 1. 部署 watcher ----------
Say '1/4  部署 watcher'
try {
  if (-not (Test-Path -LiteralPath $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
  Copy-Item -LiteralPath (Join-Path $Root 'bin\pet-bridge.ps1') -Destination $InstallDir -Force
  Copy-Item -LiteralPath (Join-Path $Root 'bin\emit.ps1') -Destination $InstallDir -Force
  if (-not (Test-Path -LiteralPath $EventDir)) { New-Item -ItemType Directory -Path $EventDir -Force | Out-Null }
  Ok "已部署到 $InstallDir"
  Ok "事件目录 $EventDir"
}
catch { Bad "部署失败：$($_.Exception.Message)"; exit 1 }

# ---------- 2. 探测桌宠配置 ----------
Say '2/4  合并桌宠配置'
$petConfigPath = ''
if ($NoPetConfig) {
  Warn '已指定 -NoPetConfig，跳过桌宠配置（请手动把 docs\PET-CONFIG.md 里的片段加进 config.json）'
}
elseif ($PetConfig) {
  if (Test-Path -LiteralPath $PetConfig) { $petConfigPath = (Resolve-Path -LiteralPath $PetConfig).Path }
  else { Bad "指定的 config.json 不存在：$PetConfig" }
}
else {
  $cands = @()
  foreach ($base in @($env:APPDATA, $env:LOCALAPPDATA)) {
    if (-not $base) { continue }
    $dirs = Get-ChildItem -LiteralPath $base -Directory -Filter 'dsh-pet*' -ErrorAction SilentlyContinue
    foreach ($d in $dirs) {
      $f = Join-Path $d.FullName 'config.json'
      if (Test-Path -LiteralPath $f) { $cands += $f }
    }
  }
  if ($cands.Count -eq 1) { $petConfigPath = $cands[0] }
  elseif ($cands.Count -gt 1) {
    Warn '发现多个桌宠数据目录，请用 -PetConfig 指定其一：'
    $cands | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
  }
  elseif (-not $Force) {
    Warn '没找到桌宠 config.json —— 桌宠可能还没装，或数据目录不在默认位置。'
    Warn '装好桌宠后重跑本脚本，或手动按 docs\PET-CONFIG.md 添加配置。'
  }
}

if ($petConfigPath) {
  try {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak = "$petConfigPath.bak-$stamp"
    Copy-Item -LiteralPath $petConfigPath -Destination $bak -Force
    Ok "已备份 $bak"

    $raw = Get-Content -LiteralPath $petConfigPath -Raw -Encoding UTF8
    $cfg = $raw | ConvertFrom-Json

    if (-not $cfg.PSObject.Properties['agent_link']) {
      $cfg | Add-Member -NotePropertyName 'agent_link' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not $cfg.agent_link.PSObject.Properties['custom_agents']) {
      $cfg.agent_link | Add-Member -NotePropertyName 'custom_agents' -NotePropertyValue @() -Force
    }

    $mine = @(
      [pscustomobject]@{ key = 'bili';      name = 'B站值班';  path = '~/.dsh-pet-bridge/agents/bili.jsonl' }
      [pscustomobject]@{ key = 'workbuddy'; name = 'WorkBuddy'; path = '~/.dsh-pet-bridge/agents/workbuddy.jsonl' }
    )

    $kept = @()
    foreach ($a in @($cfg.agent_link.custom_agents)) {
      if ($null -eq $a) { continue }
      if (@('bili', 'workbuddy') -contains [string]$a.key) { continue }   # 幂等：先摘掉旧的本插件项
      $kept += $a
    }
    $cfg.agent_link.custom_agents = @($kept + $mine)

    $json = $cfg | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($petConfigPath, $json, $NoBom)
    Ok "已写入 agent_link.custom_agents（key: bili, workbuddy）"
    Warn '桌宠需要重启（或用它的"重新加载配置"）才会看到这两个 Agent'
    Warn '重启后：右键桌宠 -> Agent 联动 -> 勾选「B站值班」和「WorkBuddy」（默认全关）'
  }
  catch {
    Bad "改配置失败：$($_.Exception.Message)"
    Warn "原文件备份在 $petConfigPath.bak-*，可直接还原"
  }
}

# ---------- 3. 可选自启 ----------
Say '3/4  开机自启'
if ($Autostart) {
  try {
    $startup = [Environment]::GetFolderPath('Startup')
    $vbs = Join-Path $startup 'dsh-pet-bili-bridge.vbs'
    $target = Join-Path $InstallDir 'pet-bridge.ps1'
    $body = @"
' dsh-pet-bili-bridge watcher (hidden)
Set s = CreateObject("WScript.Shell")
s.Run "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$target""", 0, False
"@
    Set-Content -LiteralPath $vbs -Value $body -Encoding ASCII
    Ok "已注册启动项：$vbs"
  }
  catch { Warn "注册自启失败（不影响手动启动）：$($_.Exception.Message)" }
}
else {
  Warn '未注册自启。需要常驻请加 -Autostart 重跑，或手动运行：'
  Write-Host "         powershell -NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\pet-bridge.ps1`"" -ForegroundColor DarkGray
}

# ---------- 4. 探测 bili-scroll ----------
Say '4/4  检查 dsh-bili-scroll'
$resolvedBili = ''
if ($BiliHome -and (Test-Path -LiteralPath $BiliHome)) { $resolvedBili = $BiliHome }
elseif ($env:BILI_DUTY_HOME -and (Test-Path -LiteralPath $env:BILI_DUTY_HOME)) { $resolvedBili = $env:BILI_DUTY_HOME }
else {
  $try = @()
  if ($env:DSH_HOME) { $try += (Join-Path $env:DSH_HOME 'bili-duty') }
  $try += (Join-Path $HOME '.dsh\bili-duty')
  foreach ($t in $try) { if (Test-Path -LiteralPath $t) { $resolvedBili = $t; break } }
}
if ($resolvedBili) {
  Ok "找到 bili-scroll 家目录：$resolvedBili"
  if (Test-Path -LiteralPath (Join-Path $resolvedBili 'duty.log')) { Ok 'duty.log 已存在' }
  else { Warn 'duty.log 还没有 —— 等它跑完第一轮就会出现，watcher 会自动接上' }
}
else {
  Warn '没找到 bili-duty 目录。桌宠与 WorkBuddy 的联动照常可用；'
  Warn '等 dsh-bili-scroll 装好并跑过一轮后，watcher 会自动探测到。'
}

Write-Host ''
Write-Host '  安装完成。还剩两步手动操作：' -ForegroundColor White
Write-Host '    1) 重启桌宠（数据目录里的 config.json 刚被改过）' -ForegroundColor Gray
Write-Host '    2) 右键托盘/桌宠 -> Agent 联动 -> 勾选「B站值班」「WorkBuddy」' -ForegroundColor Gray
Write-Host ''
Write-Host '  WorkBuddy 侧（可选）：把 workbuddy-plugin 目录添加为本地插件市场' -ForegroundColor DarkGray
Write-Host '    WorkBuddy -> 插件/连接器 -> 添加本地市场 -> 选 workbuddy-plugin 目录' -ForegroundColor DarkGray
Write-Host ''
