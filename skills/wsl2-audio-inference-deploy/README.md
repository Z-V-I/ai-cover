# wsl2-audio-inference-deploy

WorkBuddy Skill：在 Windows + WSL2 上从零部署 So-VITS-SVC / ContentVec 系语音推理层。

由 [ai-cover](https://github.com/Z-V-I/ai-cover) 项目的实际部署过程沉淀而成，
包含 fairseq 编译、cu118 torch 国内镜像、systemd 常驻、frp 内网穿透等完整踩坑记录。

## 内容

```
wsl2-audio-inference-deploy/
├── SKILL.md                  # Skill 本体：铁律、预检、分阶段安装、验收标准、常见误判
└── scripts/
    ├── install-wsl.sh        # 分阶段一键安装（base→pyenv→torch→deps→model→svc→frp→verify）
    └── scan-imports.py       # 扫描源码中缺失的第三方模块
```

## 安装

### 方式一：复制到 WorkBuddy 用户级 Skill 目录

```bash
# Linux / macOS
cp -r wsl2-audio-inference-deploy ~/.workbuddy/skills/

# Windows (Git Bash)
cp -r wsl2-audio-inference-deploy "$USERPROFILE/.workbuddy/skills/"
```

放好后对 WorkBuddy 说「把推理层装上」之类的需求即可自动命中。

### 方式二：只当脚本用

不装 Skill，直接拿 `scripts/install-wsl.sh` 在 WSL 里跑：

```bash
cd /mnt/e/<你的路径>/ai-cover/inference
sudo bash install-wsl.sh -h                     # 看帮助与可用阶段
ECS_IP=<你的IP> FRP_TOKEN=<你的token> sudo -E bash install-wsl.sh --with-frp
```

## 适用场景

- 本机有 NVIDIA 显卡，想把 GPU 推理放在本地，云端只放前端 + 决策层
- 国内网络下装 torch / fairseq 的老版本
- 把散落的 so-vits-svc 推理代码跑成 systemd 常驻服务 + frp 反代

## 不适用

- 纯 CPU 部署（脚本会警告但能跑，速度不可用）
- 非 so-vits-svc / ContentVec 系的模型
- Windows 原生（非 WSL）或 Docker 部署

## 许可

与本仓库一致：仅供学术交流使用。
