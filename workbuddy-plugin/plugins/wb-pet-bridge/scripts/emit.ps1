#Requires -Version 5.1
<#
.SYNOPSIS
  向 dsh-pet 桌宠写一条 Agent 状态事件（统一事件协议 v1）。

.DESCRIPTION
  按 MerZlin/dsh-pet-indesktop 的 docs/AGENT_LINK_PROTOCOL.md 写入 JSONL：
    {"ts": 1750000000.0, "agent": "workbuddy", "state": "working"}
  连续相同状态会被去重，避免占住桌宠端的换帧节流位。

  本脚本被 WorkBuddy 的 hooks 调用，必须"绝不阻塞宿主"：
  任何异常都静默吞掉并 exit 0。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File emit.ps1 -State working -Tool bash
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('thinking', 'working', 'attention', 'error', 'idle', 'sleeping')]
  [string]$State,

  [ValidateSet('workbuddy', 'bili')]
  [string]$Agent = 'workbuddy',

  [string]$Tool = '',
  [string]$EventName = '',

  # 事件文件目录；留空则用默认 ~/.dsh-pet-bridge/agents
  [string]$EventDir = ''
)

$ErrorActionPreference = 'SilentlyContinue'

try {
  if (-not $EventDir) {
    $EventDir = Join-Path $HOME '.dsh-pet-bridge\agents'
  }
  if (-not (Test-Path -LiteralPath $EventDir)) {
    New-Item -ItemType Directory -Path $EventDir -Force | Out-Null
  }

  # 去重：同一个 agent 连续同一状态不重复落盘
  $markFile = Join-Path $EventDir (".{0}.state" -f $Agent)
  $last = ''
  if (Test-Path -LiteralPath $markFile) {
    $last = (Get-Content -LiteralPath $markFile -Raw -Encoding UTF8)
    if ($null -ne $last) { $last = $last.Trim() }
  }
  if ($last -eq $State) { exit 0 }

  $rec = [ordered]@{
    ts    = [math]::Round(([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0), 3)
    agent = $Agent
    state = $State
  }
  if ($Tool) { $rec['tool'] = $Tool }
  if ($EventName) { $rec['event'] = $EventName }

  $line = ($rec | ConvertTo-Json -Compress -Depth 3)
  $file = Join-Path $EventDir ("{0}.jsonl" -f $Agent)

  # 大于 1MB 轮转一代（协议建议）
  if (Test-Path -LiteralPath $file) {
    $len = (Get-Item -LiteralPath $file).Length
    if ($len -gt 1MB) {
      Move-Item -LiteralPath $file -Destination ($file + '.1') -Force
    }
  }

  # 追加写：UTF-8 无 BOM，LF 结尾
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $bytes = $utf8.GetBytes($line + "`n")
  $fs = [System.IO.File]::Open($file, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
  try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }

  Set-Content -LiteralPath $markFile -Value $State -Encoding UTF8 -NoNewline
}
catch {
  # 联动是锦上添花，绝不因为写事件失败而影响宿主
}

exit 0
