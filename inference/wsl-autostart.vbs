' WSL2 开机自启 - 放到 shell:startup 文件夹
Set ws = CreateObject("WScript.Shell")
ws.Run "wsl -d Ubuntu-Agent -- bash /opt/svc-inference/autostart.sh", 0, False
