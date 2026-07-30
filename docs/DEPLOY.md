# 部署指南

## 前置条件

- 一台 ECS (2C2G Debian)
- 本机 WSL2 + NVIDIA GPU
- Cloudflare 账号 + 域名 (zvi.onl)
- 原项目模型文件 (F:\语音)

## 1. 推理层 (WSL2)

```bash
# 复制代码
cp -r ai-cover/inference /opt/svc-inference

# 安装 Python 3.10 + 依赖
cd /opt/svc-inference
python3.10 -m venv venv
source venv/bin/activate
pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install fairseq soundfile librosa pyworld flask flask-cors

# 复制模型文件 (从原项目)
# 见 docs/DEPLOY.md 末尾模型清单

# 启动
source venv/bin/activate
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
python3 server.py
```

## 2. 决策层 (ECS)

```bash
# 上传代码
scp -r ai-cover/decision root@8.134.50.67:/opt/svc-decision/

# SSH 到 ECS
ssh root@8.134.50.67
cd /opt/svc-decision
bash deploy.sh
```

## 3. 前端 (ECS Nginx)

```bash
scp -r ai-cover/frontend/* root@8.134.50.67:/var/www/ai-cover/
ssh root@8.134.50.67
cp nginx.conf /etc/nginx/sites-available/svc-decision
nginx -t && systemctl reload nginx
```

## 4. frp 穿透 (打通 ECS ↔ WSL2)

```bash
# ECS 上: frps
./frps -c frps.toml

# WSL2 上: frpc
./frpc -c frpc.toml
```

## 5. 域名 (Cloudflare)

- DNS: A 记录 `music-ai` → `8.134.50.67`, proxied
- SSL/TLS: Flexible 模式

---

## 模型文件清单

从 `F:\语音` 复制以下文件到 WSL2 `/opt/svc-inference/`:

| 文件 | 大小 | 路径 |
|------|------|------|
| 2602 模型 | 599 MB | `logs/44k/G_129600.pth` |
| DASA 模型 | 599 MB | `logs/44k/G_180000.pth` |
| ContentVec | 1.24 GB | `pretrain/checkpoint_best_legacy_500.pt` |
| HubertSoft | 361 MB | `pretrain/hubert-soft-0d54a1f4.pt` |
| HiFiGAN | 54 MB | `pretrain/nsf_hifigan/` |
| 扩散底模 | 211 MB | `pre_trained_model/diffusion/768l12/model_0.pt` |
| Configs | - | `configs/config.json` |
| SVC 模块 | - | `inference/`, `modules/`, `vencoder/`, `vdecoder/` |

总计约 3.4 GB
