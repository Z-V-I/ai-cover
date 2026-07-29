#!/bin/bash
# ==============================================
# WSL2 推理层 一键部署脚本
# 在 WSL2 Ubuntu 中运行: bash deploy.sh
# ==============================================
set -e

echo "======================================"
echo " AI 翻唱推理层 - WSL2 Docker 部署"
echo "======================================"

# ---- 1. 检查 NVIDIA 驱动 ----
echo "[1/5] 检查 GPU..."
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
else
    echo "错误: 未检测到 nvidia-smi"
    echo "请安装 NVIDIA 驱动: https://www.nvidia.com/download/"
    exit 1
fi

# ---- 2. 安装 Docker（如果未安装）----
echo "[2/5] 检查 Docker..."
if ! command -v docker &> /dev/null; then
    echo "安装 Docker..."
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker $USER
    echo "请退出终端重新登录后再运行此脚本"
    exit 0
fi

# 安装 NVIDIA Container Toolkit
if ! docker run --rm --gpus all nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi &> /dev/null; then
    echo "安装 NVIDIA Container Toolkit..."
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo apt-get update
    sudo apt-get install -y nvidia-container-toolkit
    sudo systemctl restart docker
fi

# ---- 3. 构建镜像 ----
echo "[3/5] 构建 Docker 镜像 (首次需下载 PyTorch, 约10分钟)..."
docker compose build

# ---- 4. Cloudflare Tunnel 配置 ----
echo "[4/5] 配置 Cloudflare Tunnel..."
if [ ! -f "cloudflared-credentials.json" ]; then
    echo ""
    echo "请先在 Cloudflare Zero Trust 创建 Tunnel:"
    echo "  1. 访问 https://one.dash.cloudflare.com/"
    echo "  2. Networks → Tunnels → Create a tunnel"
    echo "  3. 选择 Docker 环境, 复制 tunnel token"
    echo "  4. 将 token 粘贴到下方:"
    echo ""
    read -p "Tunnel Token: " TUNNEL_TOKEN
    echo "{\"AccountTag\":\"\",\"TunnelSecret\":\"$TUNNEL_TOKEN\",\"TunnelID\":\"\"}" > cloudflared-credentials.json
    
    read -p "你的域名 (如 api.example.com): " DOMAIN
    sed -i "s/api.YOUR-DOMAIN.com/$DOMAIN/g" cloudflared-config.yml
    
    echo "Tunnel 配置已创建"
else
    echo "cloudflared-credentials.json 已存在，跳过"
fi

# ---- 5. 创建缺失目录 ----
echo "[5/5] 创建模型目录..."
mkdir -p logs/44k pretrain/nsf_hifigan pre_trained_model/768l12 pre_trained_model/diffusion/768l12 configs raw results

# ---- 完成 ----
echo ""
echo "======================================"
echo " 部署完成！"
echo ""
echo " 启动命令:"
echo "   docker compose up -d"
echo ""
echo " 查看日志:"
echo "   docker compose logs -f svc-inference"
echo "   docker compose logs -f cloudflared"
echo ""
echo " 推理层 API (内网): http://localhost:8081/api/health"
echo " 推理层 API (公网): https://你的域名/api/health"
echo "======================================"
