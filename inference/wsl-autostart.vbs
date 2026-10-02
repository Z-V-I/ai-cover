' ============================================================
'  AI 翻唱 · 推理层开机自启 (WSL2)
' ------------------------------------------------------------
'  用法：把本文件放到「启动」文件夹
'        （Win+R 输入 shell:startup 回车，把文件拖进去）
'  作用：登录 Windows 后自动拉起 WSL 里的 Ubuntu 发行版，
'        并启动 svc-inference 服务（监听 127.0.0.1:8081）。
'  说明：svc-inference 在 systemd 里已经是 enabled，
'        这里再显式 start 一次只是保险（已运行时为 no-op）。
'  修正记录：原脚本写的发行版名是 "Ubuntu-Agent"（不存在），
'            且调用的是旧的 autostart.sh —— 已改为真实的 Ubuntu +
'            systemd 服务，否则这条自启一直是空转。
'  注意：下面 -d 后面必须是 `wsl -l -v` 里真实的发行版名。
'        本机是 Ubuntu；你若装的是 Ubuntu-22.04 / Debian 等，请改成对应名字。
' ============================================================
Option Explicit
Dim ws
Set ws = CreateObject("WScript.Shell")

' 1) 拉起发行版并启动推理服务（同时会 boot 整个 WSL）
ws.Run "wsl.exe -d Ubuntu -u root -- systemctl start svc-inference", 0, False

' 2) 等 10 秒再确认一次，避免首次 boot 时服务还没就绪
WScript.Sleep 10000
ws.Run "wsl.exe -d Ubuntu -u root -- systemctl start svc-inference", 0, False
