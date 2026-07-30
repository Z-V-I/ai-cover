# AI Vocal Cover Generator

基于 So-VITS-SVC 4.0 的在线 AI 翻唱生成网站。上传纯人声英文歌曲，选择目标音色，一键生成 AI 翻唱。

**在线地址**: [https://music-ai.zvi.onl](https://music-ai.zvi.onl)

---

## 架构

```
Browser ──HTTPS──▶ Cloudflare ──HTTP──▶ ECS (2C2G) ──frp──▶ WSL2 RTX3060
   │                                       │                    │
   │  :80 前端 + 决策层                      │                    │
   │  /api/ → 排队/审核/转发                └── :18081 ──────────┘  :8081 GPU推理
   │
   └── music-ai.zvi.onl
```

| 层级 | 部署位置 | 职责 |
|------|---------|------|
| 前端 | ECS Nginx | 纯静态 SPA，上传/下载 UI |
| 决策层 | ECS Gunicorn | 文件校验、排队 (上限20人)、并发控制、转发推理 |
| 推理层 | 本地 WSL2 + GPU | So-VITS-SVC 音色转换，支持两个英文歌声模型 |
| 穿透 | frp + Cloudflare | frp 打通 ECS↔WSL2，Cloudflare 提供 HTTPS |

---

## 语音模型

| 模型 | 说话人 | 训练步数 | 语言 |
|------|--------|---------|------|
| 2602 | 2602 | 129,600 | 英文 |
| DASA | 4 | 180,000 | 英文 |

### 模型文件下载

模型文件总计 3.9 GB，需手动下载并解压到 `inference/` 目录：

**[云盘下载](https://1812063966.share.123pan.cn/123pan/kD4rVv-PqflA)**

解压后结构：
```
inference/
├── logs/44k/G_129600.pth  (2602 模型, 599 MB)
├── logs/44k/G_180000.pth  (DASA 模型, 599 MB)
├── pretrain/              (ContentVec + HubertSoft + HiFiGAN)
└── pre_trained_model/     (预训练底模 + 扩散模型)
```

---

## 目录结构

```
ai-cover/
├── frontend/         # 前端页面 (HTML/CSS/JS)
├── decision/         # 决策层 (Flask + gunicorn)
├── inference/        # 推理层 (Flask + So-VITS-SVC)
├── docs/             # 文档
└── README.md
```

## 部署

详见 [docs/DEPLOY.md](docs/DEPLOY.md)

---

## 作者

zvi — [zviman888@163.com](mailto:zviman888@163.com)

## 许可

仅供学术交流使用。请遵守相关法律法规，不得用于侵权或违法行为。
