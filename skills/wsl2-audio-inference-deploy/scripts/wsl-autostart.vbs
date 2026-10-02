' ============================================================
'  AI 翻唱 · WSL2 推理层保活（隐藏窗口版）
' ------------------------------------------------------------
'  作用：把 WSL 里的推理服务拉起来，
'        并且**不弹出任何控制台窗口**（计划任务直接跑 console
'        程序会闪黑窗，所以用 wscript 以 window style 0 调起）。
'
'  为什么需要这个脚本：
'    systemd 里 enabled 只在「发行版活着」时有意义。Windows 登录后
'    如果没人碰过 WSL，发行版根本不会启动 —— 需要有人在 Windows 侧
'    踢一脚。
'
'  ⚠ 真正解决「服务莫名掉线」的不是这个脚本，而是 .wslconfig 里的
'    [general] instanceIdleTimeout=-1。默认 15 秒空闲就会把发行版
'    shutdown，导致 svc-inference / frpc 全停。详见 docs/DEPLOY-WSL2.md。
'
'  用法：
'    1) 由 inference/setup-wsl-keepalive.ps1 注册成计划任务（推荐）
'    2) 或者把本文件丢进「启动」文件夹（Win+R → shell:startup），
'       登录时执行一次
'    手动执行验证： wscript //nologo wsl-autostart.vbs
' ============================================================
Option Explicit

' ---------------- 配置 ----------------
Const DISTRO   = "Ubuntu"                 ' WSL 发行版名（wsl -l -v 查看）
Const SERVICES = "svc-inference frpc"     ' 需要保活的 systemd 服务
Const LOG_KEEP = 500                      ' 日志最多保留行数

Dim fso, ws, logDir, logPath, cmd, rc, msg

Set fso = CreateObject("Scripting.FileSystemObject")
Set ws  = CreateObject("WScript.Shell")

logDir = ws.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\ai-cover"
If Not fso.FolderExists(logDir) Then fso.CreateFolder(logDir)
logPath = logDir & "\keepalive.log"

' systemctl start 是幂等的：已在运行的服务会立即返回，不会重启。
cmd = "wsl.exe -d " & DISTRO & " -u root -- systemctl start " & SERVICES

rc = -1
On Error Resume Next
rc = ws.Run(cmd, 0, True)          ' 0 = 隐藏窗口，True = 等它结束
If Err.Number <> 0 Then
    rc = -1
    Err.Clear
End If
On Error GoTo 0

If rc = 0 Then
    msg = "ok"
Else
    msg = "失败 exit=" & rc
End If
WriteLog msg

' ------------------------------------------------------------
Sub WriteLog(msg)
    Dim f, lines, i, startAt
    On Error Resume Next
    Set f = fso.OpenTextFile(logPath, 8, True)      ' 8 = 追加
    f.WriteLine Now & "  " & msg
    f.Close
	
    ' 简单轮转：超过 LOG_KEEP 行就只留最后 LOG_KEEP 行
    Set f = fso.OpenTextFile(logPath, 1)            ' 1 = 只读
    lines = Split(f.ReadAll, vbCrLf)
    f.Close
    If UBound(lines) > LOG_KEEP Then
        startAt = UBound(lines) - LOG_KEEP
        Set f = fso.OpenTextFile(logPath, 2)        ' 2 = 覆盖写
        For i = startAt To UBound(lines)
            f.WriteLine lines(i)
        Next
        f.Close
    End If
    On Error GoTo 0
End Sub
