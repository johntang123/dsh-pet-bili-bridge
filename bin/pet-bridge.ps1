#Requires -Version 5.1
<#
.SYNOPSIS
  dsh-bili-scroll -> dsh-pet 桥接守护进程（Windows / PowerShell，零依赖）。

.DESCRIPTION
  只读 tail  dsh-bili-scroll 的 duty.log，把「开跑 / 结束 / 报错」翻译成桌宠的
  六态事件，追加到 ~/.dsh-pet-bridge/agents/bili.jsonl。

  设计要点（对应 AGENT_LINK_PROTOCOL.md 的写方契约）：
    · 只读 + 追加写，绝不改写 bili-scroll 的任何文件（协议红线：只存元数据）
    · 启动时从文件末尾开始，不回放历史
    · 同一状态去重，避免占住桌宠端换帧节流位
    · 任何异常都自己吞掉，绝不影响 bili-scroll / dsh 宿主

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File pet-bridge.ps1 -Once

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File pet-bridge.ps1
#>
[CmdletBinding()]
param(
  [string]$BiliHome = '',
  [string]$EventDir = '',
  [double]$IntervalSec = 1.0,
  [int]$AttentionHoldSec = 45,
  [int]$ErrorHoldSec = 90,
  [switch]$Once,
  [switch]$FromStart
)

$ErrorActionPreference = 'SilentlyContinue'

# ---------- 路径探测 ----------
function Resolve-BiliHome {
  param([string]$Explicit)
  if ($Explicit -and (Test-Path -LiteralPath $Explicit)) { return $Explicit }
  if ($env:BILI_DUTY_HOME -and (Test-Path -LiteralPath $env:BILI_DUTY_HOME)) { return $env:BILI_DUTY_HOME }
  $cands = @()
  if ($env:DSH_HOME) { $cands += (Join-Path $env:DSH_HOME 'bili-duty') }
  $cands += (Join-Path $HOME '.dsh\bili-duty')
  foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return $c } }
  return $cands[0]
}

$BiliHome = Resolve-BiliHome -Explicit $BiliHome
if (-not $EventDir) { $EventDir = Join-Path $HOME '.dsh-pet-bridge\agents' }
if (-not (Test-Path -LiteralPath $EventDir)) { New-Item -ItemType Directory -Path $EventDir -Force | Out-Null }

$dutyLog   = Join-Path $BiliHome 'duty.log'
$eventFile = Join-Path $EventDir 'bili.jsonl'
$stateFile = Join-Path $EventDir '.bili.state'
$selfLog   = Join-Path $EventDir 'pet-bridge.log'

$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-SelfLog {
  param([string]$Msg)
  try {
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg)
    if ((Test-Path -LiteralPath $selfLog) -and (Get-Item -LiteralPath $selfLog).Length -gt 512KB) {
      Move-Item -LiteralPath $selfLog -Destination ($selfLog + '.1') -Force
    }
    [System.IO.File]::AppendAllText($selfLog, $line + "`r`n", $utf8)
  } catch { }
}

# ---------- 事件写入（去重 + 1MB 轮转） ----------
$script:LastState = ''
if (Test-Path -LiteralPath $stateFile) {
  $script:LastState = ((Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8) -replace '\s', '')
}

function Send-PetEvent {
  param(
    [Parameter(Mandatory)][ValidateSet('thinking', 'working', 'attention', 'error', 'idle', 'sleeping')][string]$State
  )
  try {
    if ($State -eq $script:LastState) { return }
    $rec = [ordered]@{
      ts    = [math]::Round(([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0), 3)
      agent = 'bili'
      state = $State
    }
    $line = ($rec | ConvertTo-Json -Compress -Depth 3)

    if ((Test-Path -LiteralPath $eventFile) -and (Get-Item -LiteralPath $eventFile).Length -gt 1MB) {
      Move-Item -LiteralPath $eventFile -Destination ($eventFile + '.1') -Force
    }
    [System.IO.File]::AppendAllText($eventFile, $line + "`n", $utf8)
    Set-Content -LiteralPath $stateFile -Value $State -Encoding UTF8 -NoNewline
    $script:LastState = $State
    Write-SelfLog "EVENT $State"
  }
  catch { Write-SelfLog "写事件失败（已忽略）：$($_.Exception.Message)" }
}

# ---------- 增量读取：返回原始文本，由调用方按行切 ----------
function Read-NewText {
  param([string]$Path, [long]$From)
  $out = @{ Text = ''; Next = $From; Reset = $false }
  try {
    $len = (Get-Item -LiteralPath $Path).Length
    if ($len -lt $From) {
      $out.Reset = $true
      $From = 0L
    }
    if ($len -le $From) { $out.Next = $From; return $out }

    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $fs.Seek($From, [System.IO.SeekOrigin]::Begin) | Out-Null
      $count = [int][math]::Min(($len - $From), 65536)
      $buf = New-Object byte[] $count
      $read = $fs.Read($buf, 0, $count)
      $out.Next = $From + $read
      $out.Text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
    }
    finally { $fs.Close() }
  }
  catch { Write-SelfLog "读日志失败（已忽略）：$($_.Exception.Message)" }
  return $out
}

$script:Offset        = 0L
$script:Pending       = ''
$script:PendingIdleAt = $null

if (Test-Path -LiteralPath $dutyLog) {
  if ($FromStart) { $script:Offset = 0L } else { $script:Offset = (Get-Item -LiteralPath $dutyLog).Length }
}
else {
  Write-SelfLog "还没发现 duty.log，等它出现：$dutyLog"
}

function Step-Once {
  if (-not (Test-Path -LiteralPath $dutyLog)) { return }

  $r = Read-NewText -Path $dutyLog -From $script:Offset
  if ($r.Reset) {
    $script:Offset = 0L
    $script:Pending = ''
    Write-SelfLog 'duty.log 变小了（轮转/清空），offset 归零'
  }
  $script:Offset = $r.Next

  $text = $script:Pending + $r.Text
  # 兼容被编辑器加过 BOM 的 duty.log（首行会带 U+FEFF）
  if ($text.Length -gt 0) { $text = $text.TrimStart([char]0xFEFF) }
  if (-not $text) {
    if ($script:PendingIdleAt -and (Get-Date) -ge $script:PendingIdleAt) {
      Send-PetEvent -State 'idle'
      $script:PendingIdleAt = $null
    }
    return
  }

  $parts = $text -split "`n"
  $script:Pending = $parts[$parts.Count - 1]     # 最后一段可能不完整，留到下一轮
  $complete = @()
  if ($parts.Count -gt 1) { $complete = $parts[0..($parts.Count - 2)] }

  foreach ($raw in $complete) {
    $line = ($raw -replace "`r", '').Trim()
    if (-not $line) { continue }

    if ($line -match '刷B站开跑') {
      $script:PendingIdleAt = $null
      Send-PetEvent -State 'working'
      continue
    }

    if ($line -match '刷B站结束') {
      if ($line -match 'code=0') {
        Send-PetEvent -State 'attention'
        $script:PendingIdleAt = (Get-Date).AddSeconds($AttentionHoldSec)
      }
      else {
        Send-PetEvent -State 'error'
        $script:PendingIdleAt = (Get-Date).AddSeconds($ErrorHoldSec)
      }
      continue
    }

    if ($line -match '刷B站起不来|刷B站开跑失败') {
      Send-PetEvent -State 'error'
      $script:PendingIdleAt = (Get-Date).AddSeconds($ErrorHoldSec)
      continue
    }

    if ($line -match '这一轮没跑') {
      Send-PetEvent -State 'attention'
      $script:PendingIdleAt = (Get-Date).AddSeconds(15)
      continue
    }

    if ($line -match '今天挑到') {
      Send-PetEvent -State 'working'
      continue
    }
  }

  if ($script:PendingIdleAt -and (Get-Date) -ge $script:PendingIdleAt) {
    Send-PetEvent -State 'idle'
    $script:PendingIdleAt = $null
  }
}

Write-SelfLog "启动：biliHome=$BiliHome  eventDir=$EventDir  offset=$script:Offset  once=$Once"

if ($Once) { Step-Once; exit 0 }

while ($true) {
  try { Step-Once } catch { Write-SelfLog "主循环异常（已忽略）：$($_.Exception.Message)" }
  Start-Sleep -Milliseconds ([int]($IntervalSec * 1000))
}
