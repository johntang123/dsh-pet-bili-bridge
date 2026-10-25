#Requires -Version 5.1
<#
.SYNOPSIS
  dsh-pet-bili-bridge 卸载（只清理本插件自己写的东西）。

.DESCRIPTION
  · 停掉 watcher 进程
  · 删掉启动项 dsh-pet-bili-bridge.vbs
  · 从桌宠 config.json 的 agent_link.custom_agents 里摘掉 key=bili / workbuddy 两项
  · 删掉 %LOCALAPPDATA%\dsh-pet-bili-bridge
  事件文件默认保留（里面有排障日志），加 -Purge 一并删除。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 -Purge
#>
[CmdletBinding()]
param(
  [string]$PetConfig = '',
  [switch]$Purge
)

$ErrorActionPreference = 'Continue'
$InstallDir = Join-Path $env:LOCALAPPDATA 'dsh-pet-bili-bridge'
$EventDir = Join-Path $HOME '.dsh-pet-bridge'
# 无 BOM：桌宠用 Python json.load 读 config.json，带 BOM 会解析失败
$NoBom = New-Object System.Text.UTF8Encoding($false)

function Say  { param([string]$m) Write-Host $m -ForegroundColor Cyan }
function Ok   { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }

Write-Host ''
Write-Host '  dsh-pet-bili-bridge  卸载' -ForegroundColor White
Write-Host ''

# ---------- 1. 停进程 ----------
Say '1/4  停止 watcher'
$procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
         Where-Object { $_.CommandLine -and $_.CommandLine -like '*pet-bridge.ps1*' }
if ($procs) {
  foreach ($p in $procs) {
    try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Ok "已结束进程 $($p.ProcessId)" }
    catch { Warn "停不掉进程 $($p.ProcessId)：$($_.Exception.Message)" }
  }
}
else { Ok '没有在跑的 watcher' }

# ---------- 2. 删启动项 ----------
Say '2/4  移除启动项'
$vbs = Join-Path ([Environment]::GetFolderPath('Startup')) 'dsh-pet-bili-bridge.vbs'
if (Test-Path -LiteralPath $vbs) {
  Remove-Item -LiteralPath $vbs -Force
  Ok "已删除 $vbs"
}
else { Ok '没有启动项需要删除' }

# ---------- 3. 摘桌宠配置 ----------
Say '3/4  还原桌宠配置'
$targets = @()
if ($PetConfig -and (Test-Path -LiteralPath $PetConfig)) { $targets += $PetConfig }
else {
  foreach ($base in @($env:APPDATA, $env:LOCALAPPDATA)) {
    if (-not $base) { continue }
    foreach ($d in (Get-ChildItem -LiteralPath $base -Directory -Filter 'dsh-pet*' -ErrorAction SilentlyContinue)) {
      $f = Join-Path $d.FullName 'config.json'
      if (Test-Path -LiteralPath $f) { $targets += $f }
    }
  }
}

foreach ($f in $targets) {
  try {
    $cfg = (Get-Content -LiteralPath $f -Raw -Encoding UTF8) | ConvertFrom-Json
    if (-not $cfg.PSObject.Properties['agent_link']) { Ok "$f 没有 agent_link，跳过"; continue }
    if (-not $cfg.agent_link.PSObject.Properties['custom_agents']) { Ok "$f 没有 custom_agents，跳过"; continue }

    $kept = @()
    $removed = 0
    foreach ($a in @($cfg.agent_link.custom_agents)) {
      if ($null -eq $a) { continue }
      if (@('bili', 'workbuddy') -contains [string]$a.key) { $removed++; continue }
      $kept += $a
    }
    if ($removed -eq 0) { Ok "$f 没有本插件的条目，跳过"; continue }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item -LiteralPath $f -Destination "$f.bak-$stamp" -Force
    $cfg.agent_link.custom_agents = @($kept)
    [System.IO.File]::WriteAllText($f, ($cfg | ConvertTo-Json -Depth 100), $NoBom)
    Ok "$f 已摘除 $removed 项（备份 $f.bak-$stamp）"
    Warn '别忘了重启桌宠'
  }
  catch { Warn "处理 $f 失败：$($_.Exception.Message)" }
}

# ---------- 4. 删目录 ----------
Say '4/4  删除程序目录'
if (Test-Path -LiteralPath $InstallDir) {
  Remove-Item -LiteralPath $InstallDir -Recurse -Force
  Ok "已删除 $InstallDir"
}
else { Ok '程序目录不存在' }

if ($Purge) {
  if (Test-Path -LiteralPath $EventDir) {
    Remove-Item -LiteralPath $EventDir -Recurse -Force
    Ok "已删除事件目录 $EventDir"
  }
}
else {
  Write-Host "  事件与日志保留在 $EventDir（加 -Purge 可一并删除）" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  卸载完成。' -ForegroundColor White
Write-Host ''
