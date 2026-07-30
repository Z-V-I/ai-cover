# AI Vocal Cover Generator

在线 AI 翻唱生成网站，上传纯人声英文歌曲，选择目标音色，一键生成 AI 翻唱。

**在线地址**: [https://music-ai.zvi.onl](https://music-ai.zvi.onl)

---

## 项目故事

2023 年，用开源项目 [So-VITS-SVC](https://github.com/svc-develop-team/so-vits-svc) 4.0（基于 ContentVec 768L12 编码器）训练了两个语音模型——好基友的声音和暗恋对象的声音。当时初中快毕业，想着留个纪念。

一直是在本地跑推理的。2026 年终于把它搬上线，做成了前后端分离的在线服务。现在任何人上传一段英文人声，就能生成两个音色的 AI 翻唱。

---

## 系统架构

```
用户浏览器 ──HTTPS──▶ Cloudflare ──HTTP──▶ 新加坡 ECS (2C2G)
                                            │
         music-ai.zvi.onl                   ├── Nginx :80
                                            │   ├── /      → 前端静态文件
                                            │   └── /api/  → 决策层 :5000
                                            │
                                            ├── 决策层 (Gunicorn 1 worker)
                                            │   ├── 文件大小校验 (≤60MB)
                                            │   ├── 音频时长校验 (ffmpeg, ≤300s)
                                            │   ├── 排队管理 (≤20 人)
                                            │   ├── 格式转换 (M4A/MP3→WAV)
                                            │   └── 转发推理
                                            │
                                            └── frps :7000 ←── frpc ── 本机 WSL2
                                                                     RTX 3060 12GB
                                                                     │
                                                                 推理层 :8081
                                                                 ├── 2602 模型
                                                                 └── DASA 模型
```

| 层级 | 部署位置 | 技术栈 | 职责 |
|------|---------|--------|------|
| 前端 | 新加坡 ECS Nginx | HTML/CSS/JS 原生 | 上传/选择模型/下载 |
| 决策层 | 新加坡 ECS Gunicorn | Flask + ffmpeg | 校验/排队/转发 |
| 推理层 | 本机 WSL2 | Flask + PyTorch | GPU 音色转换 |
| 穿透 | frp (TCP) | frps + frpc | 打通 ECS↔本机 |

### 推理层工作原理

推理层基于 So-VITS-SVC 4.0 的推理管线，流程如下：

1. **接收音频** — Flask API 收到决策层转发的 WAV 文件
2. **静音切片** — 使用 slicer（基于 RMS 能量检测）将长音频按静音段切分为多个短片段；对于无静音的连续唱歌段，强制按 15 秒分段，防止 GPU 显存溢出
3. **特征提取** — ContentVec 768L12 编码器从每段音频提取 768 维语音内容特征（与说话人无关的特征）
4. **音色转换** — So-VITS 生成器（Generator）将内容特征 + 目标说话人 ID + F0 基频 转换为目标音色的声学特征（mel-spectrogram）
5. **声码器合成** — NSF-HiFiGAN 声码器将 mel 频谱还原为音频波形
6. **拼接输出** — 将各段结果按原始顺序拼接，返回完整 WAV 文件

两个模型（2602 / DASA）共享同一个 ContentVec 编码器和 HiFiGAN 声码器，只需切换 Generator 权重。12GB 显存只能同时保留一个模型，切换时自动卸载前一个。

---

## 语音模型

| 模型 | 说话人 ID | 训练步数 | 语言 | 来源 |
|------|----------|---------|------|------|
| 2602 | 2602 | 129,600 | 英文 | 好基友 |
| DASA | 4 | 180,000 | 英文 | 暗恋对象 |

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

## 项目结构

```
ai-cover/
├── frontend/              # 前端页面
│   ├── index.html         # SPA 单页
│   ├── css/style.css      # 样式
│   └── js/app.js          # 逻辑（上传/轮询/下载）
├── decision/              # 决策层
│   ├── server.py          # Flask API（校验/排队/转发）
│   ├── config.py          # 配置（队列上限/文件限制）
│   ├── nginx.conf         # Nginx 配置模板
│   ├── requirements.txt   # Python 依赖
│   └── deploy.sh          # ECS 一键部署
├── inference/             # 推理层
│   ├── server.py          # Flask API（推理入口）
│   ├── svc_engine.py      # SVC 引擎封装（模型管理）
│   ├── slicer.py          # 音频静音切片
│   ├── utils.py           # So-VITS-SVC 工具函数
│   ├── models.py          # So-VITS-SVC 模型定义
│   ├── modules/           # 注意力层/编码器
│   ├── vencoder/          # ContentVec 768L12 编码器
│   ├── vdecoder/          # HiFiGAN 声码器
│   ├── diffusion/         # 浅层扩散模块
│   ├── inference/         # 原项目推理脚本
│   ├── configs/           # 模型配置文件
│   ├── start_server.sh    # 推理层启动脚本
│   ├── autostart.sh       # WSL2 开机自启
│   └── requirements.txt   # Python 依赖
└── docs/
    ├── ARCHITECTURE.md    # 架构详解
    └── DEPLOY.md          # 部署指南
```

---

## 部署

### 推理层 (本机 WSL2)

```bash
cd inference/
python3.10 -m venv venv
source venv/bin/activate
pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install fairseq soundfile librosa pyworld flask flask-cors

# 解压模型文件到 inference/ 目录
unzip ai-cover-models.zip -d inference/

# 启动
USE_MOCK=0 PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True python3 server.py
```

### 决策层 + 前端 (ECS)

```bash
# 决策层
cd decision/
bash deploy.sh

# 前端
cp -r frontend/* /var/www/ai-cover/
cp nginx.conf /etc/nginx/sites-available/ai-cover
nginx -t && systemctl reload nginx
```

### frp 穿透

```bash
# ECS 上
frps -c frps.toml  # bindPort = 7000

# WSL2 上
frpc -c frpc.toml  # serverAddr = ECS_IP, remotePort = 18081
```

ECS 安全组需开放 7000 端口。

---

## 作者

zvi — [zviman888@163.com](mailto:zviman888@163.com)

## 许可

仅供学术交流使用。请遵守相关法律法规，不得用于侵权或违法行为。
