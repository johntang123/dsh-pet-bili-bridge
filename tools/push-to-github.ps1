#Requires -Version 5.1
<#
.SYNOPSIS
  用 GitHub REST API 把本仓库推上去（不依赖 git 协议，专治 github.com:443 被墙/被代理挡）。

.DESCRIPTION
  走 Git Data API 一次性提交整个工作树：
    POST /user/repos            -> 建仓库（已存在则复用）
    POST /git/blobs             -> 每个文件一个 blob
    POST /git/trees             -> 建树
    POST /git/commits           -> 建提交
    PATCH /git/refs/heads/main  -> 移动分支

  HTTP 层用系统自带 curl.exe 而不是 Invoke-RestMethod —— PowerShell 5.1 在
  代理 / 中间人证书环境下 TLS 握手会直接失败（"基础连接已经关闭"），curl 没这个问题。

.PARAMETER Token
  GitHub PAT。不想写在命令行就设环境变量 GITHUB_TOKEN。

.PARAMETER Repo
  仓库名，默认 dsh-pet-bili-bridge。

.PARAMETER Owner
  仓库所属用户/组织，默认取 /user 返回的 login。

.PARAMETER Private
  建成私有仓库。

.PARAMETER Insecure
  跳过 TLS 证书校验（公司代理做 SSL 中间人时需要）。

.EXAMPLE
  $env:GITHUB_TOKEN = 'ghp_xxx'
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/push-to-github.ps1 -Insecure
#>
[CmdletBinding()]
param(
  [string]$Token = $env:GITHUB_TOKEN,
  [string]$Repo = 'dsh-pet-bili-bridge',
  [string]$Owner = '',
  [string]$Branch = 'main',
  [string]$Description = 'dsh-pet × dsh-bili-scroll 状态桥：让桌宠知道 B站值班和 WorkBuddy 在干什么',
  [switch]$Private,
  [switch]$Insecure
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

if (-not $Token) {
  Write-Host ''
  Write-Host '  缺少 GitHub Token。' -ForegroundColor Yellow
  Write-Host '  1) 打开 https://github.com/settings/tokens 新建 token'
  Write-Host '     classic 勾 repo；fine-grained 给 Contents + Administration 读写'
  Write-Host '  2) 设环境变量：  $env:GITHUB_TOKEN = "ghp_xxx"'
  Write-Host '  3) 重跑本脚本'
  Write-Host ''
  exit 1
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
  Write-Host '  找不到 curl.exe（Windows 10 1803+ 自带）。请自行安装 curl，或改用 git push。' -ForegroundColor Red
  exit 1
}

$ApiBase = 'https://api.github.com'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Invoke-GH {
  param(
    [string]$Method = 'GET',
    [string]$Path,
    $Body = $null
  )
  $uri = if ($Path -like 'http*') { $Path } else { "$ApiBase$Path" }
  $tmpBody = [System.IO.Path]::GetTempFileName()
  $tmpOut = [System.IO.Path]::GetTempFileName()

  $curlArgs = @(
    '-sS', '--tlsv1.2', '-X', $Method, $uri,
    '-H', "Authorization: Bearer $Token",
    '-H', 'Accept: application/vnd.github+json',
    '-H', 'X-GitHub-Api-Version: 2022-11-28',
    '-H', 'User-Agent: dsh-pet-bili-bridge',
    '-o', $tmpOut,
    '-w', '%{http_code}'
  )
  if ($Insecure) { $curlArgs = @('-k') + $curlArgs }

  if ($null -ne $Body) {
    $json = ($Body | ConvertTo-Json -Depth 20 -Compress)
    [System.IO.File]::WriteAllText($tmpBody, $json, $script:Utf8NoBom)
    $curlArgs += @('-H', 'Content-Type: application/json; charset=utf-8', '--data-binary', "@$tmpBody")
  }

  $code = 0
  $payload = ''
  try {
    $codeText = (& curl.exe @curlArgs 2>&1 | Out-String).Trim()
    [void][int]::TryParse($codeText, [ref]$code)
    if (Test-Path -LiteralPath $tmpOut) {
      $payload = [System.IO.File]::ReadAllText($tmpOut, [System.Text.Encoding]::UTF8)
    }
  }
  finally {
    Remove-Item -LiteralPath $tmpBody, $tmpOut -Force -ErrorAction SilentlyContinue
  }

  if ($code -lt 200 -or $code -ge 300) {
    $snippet = $payload
    if ($snippet.Length -gt 500) { $snippet = $snippet.Substring(0, 500) }
    throw ("{0} {1} -> HTTP {2}`n{3}" -f $Method, $Path, $code, $snippet)
  }
  if (-not $payload.Trim()) { return $null }
  return ($payload | ConvertFrom-Json)
}

Write-Host ''
Write-Host '  push-to-github' -ForegroundColor White
Write-Host ''

# ---------- 1. 验证身份 ----------
$me = Invoke-GH -Path '/user'
if (-not $me -or -not $me.login) { Write-Host '  拿不到身份信息，token 可能无效。' -ForegroundColor Red; exit 1 }
Write-Host "  身份：$($me.login)" -ForegroundColor Green
if (-not $Owner) { $Owner = $me.login }

# ---------- 2. 建仓库（幂等） ----------
$repoPath = "/repos/$Owner/$Repo"
$exists = $true
try { Invoke-GH -Path $repoPath | Out-Null } catch { $exists = $false }

if ($exists) {
  Write-Host "  仓库已存在，直接推：$Owner/$Repo" -ForegroundColor Green
}
else {
  Invoke-GH -Method POST -Path '/user/repos' -Body @{
    name        = $Repo
    description = $Description
    private     = [bool]$Private
    auto_init   = $false
    has_issues  = $true
    has_wiki    = $false
  } | Out-Null
  Write-Host "  已创建：https://github.com/$Owner/$Repo" -ForegroundColor Green
  Start-Sleep -Seconds 2
}

# ---------- 3. 空仓库必须先有一个 commit ----------
# Git Data API 在完全空的仓库上会 409 "Git Repository is empty"，
# 所以先用 Contents API 放一份 README 打底，拿到 initial commit 的 sha。
$headSha = $null
try { $headSha = (Invoke-GH -Path "/repos/$Owner/$Repo/git/ref/heads/$Branch").object.sha } catch { }

if (-not $headSha) {
  Write-Host '  空仓库，先用 README 打底' -ForegroundColor DarkGray
  Start-Sleep -Seconds 2
  $readmeLocal = Join-Path $Root 'README.md'
  if (Test-Path -LiteralPath $readmeLocal) {
    $seedB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($readmeLocal))
  }
  else {
    $seedB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("# $Repo`n"))
  }
  $init = Invoke-GH -Method PUT -Path "/repos/$Owner/$Repo/contents/README.md" -Body @{ message = 'chore: init'; content = $seedB64 }
  $headSha = $init.commit.sha
  Write-Host ("  已初始化 {0} ({1})" -f $Branch, $headSha.Substring(0, 7)) -ForegroundColor DarkGray
}

# ---------- 4. 收集文件 ----------
$skipDirs = @('.git', 'dist', 'node_modules', '__pycache__')
$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Where-Object {
  $rel = $_.FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'
  $parts = $rel -split '/'
  $bad = $false
  foreach ($d in $skipDirs) { if ($parts -contains $d) { $bad = $true } }
  if ($_.Name -like '*.bak-*' -or $_.Name -like '*.log' -or $_.Name -eq '.DS_Store') { $bad = $true }
  -not $bad
})
Write-Host "  待推送 $($files.Count) 个文件" -ForegroundColor DarkGray

# ---------- 4. 建 blob ----------
$treeItems = @()
$i = 0
foreach ($f in $files) {
  $i++
  $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'
  $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($f.FullName))
  $blob = Invoke-GH -Method POST -Path "/repos/$Owner/$Repo/git/blobs" -Body @{ content = $b64; encoding = 'base64' }
  $treeItems += [pscustomobject]@{ path = $rel; mode = '100644'; type = 'blob'; sha = $blob.sha }
  Write-Host ("    [{0}/{1}] {2}" -f $i, $files.Count, $rel) -ForegroundColor DarkGray
}

# ---------- 5. 树 -> 提交 -> 分支 ----------
$tree = Invoke-GH -Method POST -Path "/repos/$Owner/$Repo/git/trees" -Body @{ tree = $treeItems }

$commitBody = @{ message = 'feat: dsh-pet × dsh-bili-scroll 状态桥 v0.1.0'; tree = $tree.sha }
if ($headSha) { $commitBody['parents'] = @($headSha) }
$commit = Invoke-GH -Method POST -Path "/repos/$Owner/$Repo/git/commits" -Body $commitBody

if ($headSha) {
  Invoke-GH -Method PATCH -Path "/repos/$Owner/$Repo/git/refs/heads/$Branch" -Body @{ sha = $commit.sha; force = $true } | Out-Null
}
else {
  Invoke-GH -Method POST -Path "/repos/$Owner/$Repo/git/refs" -Body @{ ref = "refs/heads/$Branch"; sha = $commit.sha } | Out-Null
}

Write-Host ''
Write-Host '  推送完成' -ForegroundColor Green
Write-Host "    https://github.com/$Owner/$Repo" -ForegroundColor White
Write-Host ("    commit {0}  /  {1} 个文件" -f $commit.sha.Substring(0, 7), $files.Count) -ForegroundColor DarkGray
Write-Host ''
