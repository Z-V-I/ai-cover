#!/bin/bash
# WSL2 开机自启脚本
LOG=/opt/svc-inference/autostart.log
echo "$(date): Starting services..." > $LOG

# 启动推理层
cd /opt/svc-inference
source venv/bin/activate
export USE_MOCK=0
export SVC_BASE_DIR=/opt/svc-inference
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
nohup python3 server.py >> $LOG 2>&1 &
sleep 5

# 启动 frpc
nohup frpc -c /etc/frp/frpc.toml >> $LOG 2>&1 &

echo "$(date): Services started" >> $LOG
