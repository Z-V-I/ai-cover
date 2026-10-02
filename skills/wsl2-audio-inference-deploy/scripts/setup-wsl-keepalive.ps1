# ============================================================
#  AI Cover · WSL2 推理层保活配置（在 Windows 侧执行）
# ------------------------------------------------------------
#  它做三件事：
#
#   1) 修正 %UserProfile%\.wslconfig
#        [general] instanceIdleTimeout = -1
#        ★ 这才是「服务莫名掉线」的真正根因。该键默认 15000（毫秒）
#          = 15 秒：发行版一旦空闲 15 秒就被 shutdown，里面的
#          svc-inference / frpc 随之全部停止，frp 隧道断开，网页报
#          「无法连接到推理服务，请检查服务是否启动」。
#          典型日志：
#              systemd-logind: The system will power off now!
#        ⚠ [wsl2] vmIdleTimeout 是**另一个**键，只管虚拟机本身，
#          单改它没用（实测默认 15000 的 instanceIdleTimeout 才是元凶）。
#
#   2) 把隐藏窗口的启动脚本放到 %LOCALAPPDATA%\ai-cover\
#        （计划任务直接跑 wsl.exe 会闪黑窗，所以用 wscript 以
#          window style 0 调起）
#
#   3) 注册计划任务 AI-Cover Inference Guard
#        - 登录时执行一次（Windows 登录后如果没人碰过 WSL，发行版
#          根本不会启动，必须踢一脚）
#        - 之后每 2 分钟执行一次（兜底：万一发行版被 wsl --shutdown
#          之类的外部动作停掉，2 分钟内自动恢复）
#
#  用法（普通权限即可，不需要管理员）：
#      powershell -ExecutionPolicy Bypass -File setup-wsl-keepalive.ps1
#      powershell -ExecutionPolicy Bypass -File setup-wsl-keepalive.ps1 -RestartWsl
#
#  验证：
#      Get-ScheduledTask -TaskName "AI-Cover*" | Select TaskName,State
#      Get-Content "$env:LOCALAPPDATA\ai-cover\keepalive.log" -Tail 10
#
#  卸载：
#      Unregister-ScheduledTask -TaskName "AI-Cover Inference Guard" -Confirm:$false
# ============================================================

param(
    # WSL 发行版名，用 `wsl -l -v` 查看
    [string]$Distro = "Ubuntu",
    # 需要保活的 systemd 服务（空格分隔）
    [string]$Services = "svc-inference frpc",
    # 兜底巡检间隔（分钟）
    [int]$IntervalMinutes = 2,
    # 顺手执行 wsl --shutdown 让 .wslconfig 立刻生效
    [switch]$RestartWsl
)

$ErrorActionPreference = "Stop"
$wsl  = "$env:SystemRoot\System32\wsl.exe"
$user = "$env:USERDOMAIN\$env:USERNAME"
$cfgPath = Join-Path $env:USERPROFILE ".wslconfig"

Write-Host "=== 配置 WSL2 推理层保活 ===" -ForegroundColor Cyan
Write-Host "  发行版   : $Distro"
Write-Host "  服务     : $Services"
Write-Host "  巡检间隔 : $IntervalMinutes 分钟"
Write-Host ""

# ------------------------------------------------------------
# INI 读写（.wslconfig 是 INI 格式；必须写成 UTF-8 无 BOM，
# 带 BOM 会导致 WSL 解析失败并静默忽略整个文件）
# ------------------------------------------------------------
function Write-Utf8NoBom {
    param([string]$Path, [string[]]$Lines)
    # 强制 LF 换行：CRLF 会让某些 INI 解析器把值读成 "-1\r"
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), $enc)
}

function Set-IniKey {
    param([string]$Path, [string]$Section, [string]$Key, [string]$Value)
    $lines = @()
    if (Test-Path $Path) { $lines = @([System.IO.File]::ReadAllLines($Path)) }

    $header = "[$Section]"
    $secIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -ieq $header) { $secIdx = $i; break }
    }

    if ($secIdx -ge 0) {
        $keyIdx = -1
        for ($j = $secIdx + 1; $j -lt $lines.Count; $j++) {
            $t = $lines[$j].Trim()
            if ($t.StartsWith("[")) { break }
            if ($t -match ('^' + [regex]::Escape($Key) + '\s*=')) { $keyIdx = $j; break }
        }
        if ($keyIdx -ge 0) {
            $lines[$keyIdx] = "$Key=$Value"
        } else {
            $before = @($lines[0..$secIdx])
            $after  = @()
            if ($secIdx + 1 -le $lines.Count - 1) { $after = @($lines[($secIdx + 1)..($lines.Count - 1)]) }
            $lines = $before + @("$Key=$Value") + $after
        }
    } else {
        $lines = $lines + @("", $header, "$Key=$Value")
    }
    Write-Utf8NoBom -Path $Path -Lines $lines
}

# ------------------------------------------------------------
# 1) .wslconfig：关掉「发行版空闲回收」——根因所在
# ------------------------------------------------------------
$needRestart = $false
$bak = $null
if (Test-Path $cfgPath) {
    $bak = "$cfgPath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Copy-Item $cfgPath $bak -Force
} else {
    Write-Host "[1/4] 新建 $cfgPath"
}

$before = if (Test-Path $cfgPath) { [System.IO.File]::ReadAllText($cfgPath) } else { "" }
Set-IniKey -Path $cfgPath -Section "general" -Key "instanceIdleTimeout" -Value "-1"
Set-IniKey -Path $cfgPath -Section "wsl2"    -Key "vmIdleTimeout"       -Value "604800000"
$after = [System.IO.File]::ReadAllText($cfgPath)
if ($before -ne $after) {
    $needRestart = $true
    if ($bak) { Write-Host "[1/4] 已备份原配置 -> $bak" }
} else {
    # 内容没变（幂等重跑），别攒一堆没用的备份
    if ($bak -and (Test-Path $bak)) { Remove-Item $bak -Force -ErrorAction SilentlyContinue }
    Write-Host "[1/4] .wslconfig 已是目标状态（未改动）"
}

Write-Host "      [general] instanceIdleTimeout = -1          （发行版永不空闲回收）" -ForegroundColor Green
Write-Host "      [wsl2]    vmIdleTimeout       = 604800000   （虚拟机不自动回收）" -ForegroundColor Green

# ------------------------------------------------------------
# 2) 生成隐藏窗口的启动脚本
# ------------------------------------------------------------
$shimDir = Join-Path $env:LOCALAPPDATA "ai-cover"
New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
$shim = Join-Path $shimDir "wsl-autostart.vbs"

$src = Join-Path $PSScriptRoot "wsl-autostart.vbs"
if (Test-Path $src) {
    $vbs = [System.IO.File]::ReadAllText($src)
} else {
    Write-Host "     [警告] 未找到 $src，将生成最小版本" -ForegroundColor Yellow
    $vbs = @'
Option Explicit
Dim ws
Set ws = CreateObject("WScript.Shell")
ws.Run "wsl.exe -d __DISTRO__ -u root -- systemctl start __SERVICES__", 0, True
'@
}
# 让脚本里的常量与本次参数一致
$vbs = $vbs -replace 'Const DISTRO\s*=\s*"[^"]*"',   ('Const DISTRO   = "' + $Distro + '"')
$vbs = $vbs -replace 'Const SERVICES\s*=\s*"[^"]*"', ('Const SERVICES = "' + $Services + '"')

# wscript 按 ANSI 解读 .vbs；带中文注释就写成 UTF-16LE + BOM 才不乱码
[System.IO.File]::WriteAllText($shim, $vbs, [System.Text.Encoding]::Unicode)
Write-Host "[2/4] 启动脚本 -> $shim" -ForegroundColor Green

# ------------------------------------------------------------
# 3) 注册计划任务（顺便清掉早期那套「常驻锚点」方案）
# ------------------------------------------------------------
$legacy = Get-ScheduledTask -TaskName "AI-Cover WSL Anchor" -ErrorAction SilentlyContinue
if ($legacy) {
    Unregister-ScheduledTask -TaskName "AI-Cover WSL Anchor" -Confirm:$false
    Write-Host "      已移除过时任务：AI-Cover WSL Anchor（新方案不再需要常驻会话）" -ForegroundColor DarkGray
}

$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" -Argument "//nologo `"$shim`""

# 坑：只在 LogonTrigger 上挂 Repetition 是不生效的 —— 同一次登录会话内
#     调度器不会自动重复（导出的 XML 里有 <Repetition> 但 NextRunTime 为空）。
#     必须另外加一个 TimeTrigger(-Once) 带 Repetition。
$t1 = New-ScheduledTaskTrigger -AtLogOn -User $user
$t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)

# -DontStopOnIdleEnd / 电池相关：别让调度器自己把任务掐掉
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -DontStopOnIdleEnd `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName "AI-Cover Inference Guard" `
    -Action $action -Trigger @($t1, $t2) -Settings $settings -Principal $principal `
    -Description "Start / re-ensure the WSL2 AI Cover inference services (svc-inference, frpc) at logon and every $IntervalMinutes min. Needed because Windows does not start a WSL distro on its own. The real 'service keeps dropping' root cause is .wslconfig [general] instanceIdleTimeout (default 15s), fixed by setup-wsl-keepalive.ps1." `
    -Force | Out-Null
Write-Host "[3/4] 计划任务已注册：AI-Cover Inference Guard" -ForegroundColor Green

# ------------------------------------------------------------
# 4) 立刻跑一次 + 校验
# ------------------------------------------------------------
if ($RestartWsl) {
    Write-Host "[4/4] 执行 wsl --shutdown（让 .wslconfig 立刻生效）..." -ForegroundColor Yellow
    & $wsl --shutdown
    Start-Sleep -Seconds 3
}
Start-ScheduledTask -TaskName "AI-Cover Inference Guard"

Write-Host "      等待服务就绪（首次会拉起虚拟机）..."
$ok = $false
for ($i = 1; $i -le 20; $i++) {
    Start-Sleep -Seconds 3
    $state = (& $wsl -d $Distro -u root -- systemctl is-active svc-inference) 2>$null
    if ($state -eq "active") { $ok = $true; break }
}
Write-Host "[4/4] 校验" -ForegroundColor Cyan

Write-Host ""
Write-Host "=== 任务状态 ===" -ForegroundColor Cyan
Get-ScheduledTask -TaskName "AI-Cover*" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host ("  {0}  [{1}]" -f $_.TaskName, $_.State)
    $_.Actions | ForEach-Object { Write-Host ("      -> " + $_.Execute + " " + $_.Arguments) }
}

Write-Host ""
Write-Host "=== 服务状态 ===" -ForegroundColor Cyan
foreach ($svc in $Services.Split(" ")) {
    $s = (& $wsl -d $Distro -u root -- systemctl is-active $svc) 2>$null
    $c = if ($s -eq "active") { "Green" } else { "Red" }
    Write-Host ("  {0,-16} = {1}" -f $svc, $s) -ForegroundColor $c
}

Write-Host ""
Write-Host "=== 取消防空闲回收（关键项）===" -ForegroundColor Cyan
# 注意：这里必须用 [System.IO.File]::ReadAllLines，不能用 Get-Content。
# PowerShell 5.1 的 Get-Content 按 ANSI 读 UTF-8 无 BOM 文件，中文乱码后
# 会**连带吞掉换行、把相邻两行并成一行**，导致行首匹配失效（实测）。
[System.IO.File]::ReadAllLines($cfgPath) |
    Where-Object { $_ -match '^\s*(instanceIdleTimeout|vmIdleTimeout)\s*=' } |
    ForEach-Object { Write-Host ("  " + $_.Trim()) }

Write-Host ""
if ($ok) {
    Write-Host "完成。" -ForegroundColor Green
} else {
    Write-Host "服务尚未就绪，请查看 /var/log/svc-inference.log" -ForegroundColor Yellow
}
if ($needRestart -and -not $RestartWsl) {
    Write-Host ""
    Write-Host "提示：.wslconfig 有改动，需要执行一次 `wsl --shutdown` 才生效：" -ForegroundColor Yellow
    Write-Host "      powershell -ExecutionPolicy Bypass -File setup-wsl-keepalive.ps1 -RestartWsl"
}
Write-Host "注意：本机休眠 / 关机 / 未登录 Windows 期间服务必不可用 —— WSL2 方案的固有限制。" -ForegroundColor Yellow
