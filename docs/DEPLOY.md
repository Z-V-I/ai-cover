# 部署指南

> 本文档覆盖**决策层 + 前端 + frp**。
> **推理层（WSL2）的部署另见 [DEPLOY-WSL2.md](./DEPLOY-WSL2.md)**，那里有一键脚本和完整踩坑记录。

## 前置条件

- 一台 ECS (2C2G Debian)
- 本机 WSL2 + NVIDIA GPU
- Cloudflare 账号 + 域名
- 模型文件（约 3.4 GB，见 [README 模型文件下载](../README.md#模型文件下载)）
- 本地 `.env`（`cp .env.example .env`，填 `API_TOKEN` 等）

## 0. 敏感配置

仓库不含真实密钥，全部走环境变量 / `.env`：

| 变量 | 用途 |
|---|---|
| `API_TOKEN` | 决策层校验前端 `X-API-Token` 头；未设置时决策层拒绝启动 |
| `INFERENCE_BASE_URL` | 决策层转发推理的地址（生产用 `http://localhost:18081`，即 frp 隧道出口） |
| `ECS_IP` / `FRP_TOKEN` | 推理层 `install-wsl.sh` 配 frp 时用 |

前端需要同一份 token，见 `frontend/js/config.example.js`。

## 1. 推理层 (WSL2)

```bash
cd inference/
sudo bash install-wsl.sh              # 一键：依赖 → Python 3.10 → torch → fairseq → 模型 → systemd
sudo bash install-wsl.sh --with-frp   # 再顺带配好 frp 隧道
```

详细说明、驱动/torch 版本选择、fairseq 编译坑见 **[DEPLOY-WSL2.md](./DEPLOY-WSL2.md)**。

## 2. 决策层 (ECS)

```bash
# 上传代码
scp -r ai-cover/decision root@<ECS_IP>:/opt/svc-decision/

# SSH 到 ECS
ssh root@<ECS_IP>
cd /opt/svc-decision
bash deploy.sh
```

## 3. 前端 (ECS Nginx)

```bash
scp -r ai-cover/frontend/* root@<ECS_IP>:/var/www/ai-cover/
ssh root@<ECS_IP>
cp nginx.conf /etc/nginx/sites-available/svc-decision
nginx -t && systemctl reload nginx
```

## 4. frp 穿透 (打通 ECS ↔ WSL2)

```bash
# ECS 上: frps
./frps -c frps.toml

# WSL2 上: frpc（install-wsl.sh 的 frp 阶段会自动生成 /etc/frp/frpc.toml 并托管）
./frpc -c /etc/frp/frpc.toml
```

## 5. 域名 (Cloudflare)

- DNS: A 记录指向 ECS 公网 IP, proxied
- SSL/TLS: Flexible 模式

---

## 模型文件清单

模型约 3.4 GB，从 [README 的云盘链接](../README.md#模型文件下载) 下载后解压到 `inference/`，
`install-wsl.sh` 的 `model` 阶段会把它们同步到 `/opt/svc-inference/`：

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
