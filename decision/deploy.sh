#!/bin/bash
# ==============================================
# 决策层 ECS 部署脚本 (2核2G)
# 在 ECS 上运行: bash deploy.sh
# ==============================================
set -e

echo "======================================"
echo " AI 翻唱决策层 - ECS 部署"
echo "======================================"

# ---- 环境变量 ----
# 修改为你的实际值
export INFERENCE_BASE_URL="${INFERENCE_BASE_URL:-https://api.your-domain.com}"
export DECISION_PORT="${DECISION_PORT:-5000}"

echo ""
echo "推理层地址: $INFERENCE_BASE_URL"
echo "决策层端口: $DECISION_PORT"
echo ""

# ---- 1. 安装 Python ----
echo "[1/3] 安装依赖..."
sudo apt-get update
sudo apt-get install -y python3 python3-pip python3-venv nginx libsndfile1

# 创建虚拟环境
python3 -m venv venv
source venv/bin/activate

pip install --upgrade pip
pip install flask flask-cors soundfile requests gunicorn librosa

# ---- 2. Nginx 反向代理 ----
echo "[2/3] 配置 Nginx..."

sudo tee /etc/nginx/sites-available/svc-decision > /dev/null << 'NGINX'
server {
    listen 80;
    server_name _;

    client_max_body_size 70M;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
    }
}
NGINX

sudo ln -sf /etc/nginx/sites-available/svc-decision /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx

# ---- 3. Systemd 服务 ----
echo "[3/3] 创建 systemd 服务..."

sudo tee /etc/systemd/system/svc-decision.service > /dev/null << SYSTEMD
[Unit]
Description=AI Cover Decision Layer
After=network.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=$(pwd)
Environment="INFERENCE_BASE_URL=$INFERENCE_BASE_URL"
Environment="DECISION_PORT=$DECISION_PORT"
ExecStart=$(pwd)/venv/bin/gunicorn -w 2 -b 0.0.0.0:$DECISION_PORT server:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SYSTEMD

sudo systemctl daemon-reload
sudo systemctl enable svc-decision
sudo systemctl start svc-decision

# ---- 完成 ----
echo ""
echo "======================================"
echo " 决策层部署完成！"
echo ""
echo " 状态检查:"
echo "   sudo systemctl status svc-decision"
echo "   curl http://localhost:5000/api/health"
echo ""
echo " 日志:"
echo "   sudo journalctl -u svc-decision -f"
echo "======================================"
