# 推理层部署（WSL2 + NVIDIA GPU）

本文档只讲**推理层**：把 `inference/` 装到 Windows 的 WSL2 Ubuntu 里，跑成 systemd 常驻服务，
再通过 frp 暴露给云端决策层。决策层 / 前端的部署见 [DEPLOY.md](./DEPLOY.md)。

> 一键脚本：`inference/install-wsl.sh`，分阶段可重跑、可断点续传，本文是它的说明与踩坑记录。

---

## 0. 前置条件

| 项 | 要求 |
|---|---|
| 系统 | Windows 10/11 + WSL2（Ubuntu 22.04 / 24.04 / 26.04 均可） |
| 发行版名 | 先 `wsl -l -v` 确认，**不要猜**（脚本和自启脚本都要用真实名字） |
| GPU | NVIDIA 显卡 + Windows 侧驱动。WSL 里 `nvidia-smi` 应能直接看到卡 |
| systemd | WSL 里 `ps -p 1 -o comm=` 输出 `systemd`（在 `/etc/wsl.conf` 里 `[boot] systemd=true`） |
| 磁盘 | `/opt` 所在分区 **≥ 12 GB**（Python+torch ≈ 5G，模型 3.4G） |
| 模型权重 | 约 3.4 GB，见 [README 模型文件下载](../README.md#模型文件下载) |
| 网络 | 国内网络即可，脚本已内置镜像与重试 |

### 驱动版本决定 torch 版本（最容易踩的一条）

```bash
wsl -d <发行版> -u root -- /usr/lib/wsl/lib/nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
```

- 驱动 **≥ 520**（CUDA 11.8+）→ 可以用 cu118 / cu121。
- 驱动 **< 520**（例如 472.12 = CUDA 11.4）→ **不要按常见教程装 cu121，装完跑不起来**。
  用 **torch 2.0.1 + cu118**，它依赖 CUDA minor version compatibility，能在 11.4 驱动上正常工作。

另外 torch 2.0.1 还有个隐性好处：torch ≥ 2.6 的 `torch.load` 默认 `weights_only=True`，
读不了 so-vits-svc / fairseq 的老 ckpt。

### Python 版本

`fairseq 0.12.2`（ContentVec 编码器必需）只支持 **Python 3.8 ~ 3.10**。
Ubuntu 24.04+ 自带 3.12/3.13/3.14，必须另装 3.10。
脚本优先用 [`uv`](https://astral.sh/uv) 拉一个独立的 3.10 解释器（秒级、不污染系统），
失败则回退 micromamba + 清华源。

---

## 1. 配置

敏感值统一放仓库根目录的 `.env`（已被 `.gitignore` 忽略）：

```bash
cp .env.example .env
# 编辑 .env，至少填 API_TOKEN；要配 frp 还要填 ECS_IP / FRP_TOKEN
```

脚本会自己读取 `.env`，所以 `sudo` 也不会丢配置。
也可以临时用环境变量覆盖：`ECS_IP=1.2.3.4 FRP_TOKEN=xxx bash install-wsl.sh frp`

---

## 2. 一键安装

在 **WSL 的 Ubuntu 终端**里执行（注意先确认发行版名）：

```bash
# 进入仓库所在的 Windows 盘（假设仓库在 E:）
cd /mnt/e/<你的路径>/ai-cover/inference

# 全流程
sudo bash install-wsl.sh

# 或者按需：全流程 + 配好 frp 内网穿透
sudo bash install-wsl.sh --with-frp

# 只重跑某几个阶段（大下载失败后断点续传）
sudo bash install-wsl.sh deps verify

# 看帮助
bash install-wsl.sh -h
```

> 如果当前用户 `sudo` 需要密码，也可以直接用 root 进：
> `wsl -d <发行版> -u root -- bash /mnt/e/<路径>/ai-cover/inference/install-wsl.sh`

### 阶段说明

`base → pyenv → torch → deps → model → svc → frp → verify`

| 阶段 | 做什么 | 备注 |
|---|---|---|
| `base` | `ffmpeg libsndfile1 build-essential pkg-config rsync wget` + `nvidia-smi` 自检 | |
| `pyenv` | uv 拉 Python 3.10，建 `/opt/svc-inference/venv` | 失败回退 micromamba |
| `torch` | torch 2.0.1 + torchaudio 2.0.2（cu118） | **走国内镜像 + 断点续传**，见下 |
| `deps` | fairseq 0.12.2（源码编译）+ 其余依赖 | 见下方两个坑 |
| `model` | `rsync` 把代码 + 模型权重同步到 `/opt/svc-inference` | 跳过 `venv/`、`__pycache__` |
| `svc` | 写 `/etc/systemd/system/svc-inference.service` 并 `enable --now` | 监听 `127.0.0.1:8081` |
| `frp` | 装 frpc、写 `/etc/frp/frpc.toml`、起 `frpc.service` | 需要 `ECS_IP` + `FRP_TOKEN` |
| `verify` | 健康检查 + 真推理冒烟测试 | 见 [第 5 节](#5-验收) |

### frp 拓扑

```
用户浏览器 → 云端 Nginx / 决策层 :5000
                   │  决策层在 ECS 上用 localhost:18081 访问推理层
                   ▼
            云端 frps :7000   ←── frpc（本机 WSL2）
                                        │
                                  推理层 :8081
```

- 云端安全组只需放行 **7000**；`18081` 是 ECS 本机的回环端口，**不需要**对公网开放。
- frpc 连上的日志特征是 `login to server success` + `start proxy success`。
- 判断云端 frps 是否在跑：`timeout 5 bash -c 'exec 3<>/dev/tcp/<ECS_IP>/7000'`，通即在跑。

---

## 3. 踩坑记录（都是实测踩出来的）

### 3.1 torch wheel：`download.pytorch.org` 在国内必断

实测下到 2062 / 2267 MB 处连续断 6 次。可用的镜像：

| 镜像 | 状态 |
|---|---|
| `https://mirrors.aliyun.com/pytorch-wheels/cu118` | ✅ 实测 ~2.4 MB/s |
| `https://mirror.sjtu.edu.cn/pytorch-wheels/cu118` | ✅ |
| `mirrors.ustc.edu.cn` / tuna / bfsu 的 pytorch-wheels | ❌ 404 |

做法是**直接 `wget -c` 拿 wheel 再本地 install**，而不是依赖 pip 的 `--index-url`：

```bash
# wheel 文件名里的 "+" 必须 URL 编码成 %2B
W="torch-2.0.1%2Bcu118-cp310-cp310-linux_x86_64.whl"
wget -c -T 30 -t 20 --waitretry=5 --progress=dot:giga \
     -O /opt/svc-inference/.wheels/torch.whl \
     "https://mirrors.aliyun.com/pytorch-wheels/cu118/$W"
```

脚本会先 `curl -sIL` 取 `Content-Length` 做完整性校验，不匹配就换镜像续传。

### 3.2 fairseq 0.12.2：pip ≥ 24.1 直接装不上

```
WARNING: Ignoring version 2.0.6 of omegaconf since it has invalid metadata
ERROR: ResolutionImpossible
```

新版 pip 判定 `omegaconf<2.1` 的元数据 `PyYAML (>=5.1.*)` 非法并忽略全部候选，
而 fairseq 硬依赖 `omegaconf<2.1`。**修法**：把 pip 钉回 fairseq 时代的版本。

```bash
pip install "pip<24.1" "setuptools<70" wheel "Cython<3" "numpy==1.24.3" ninja
```

### 3.3 fairseq 的 PyPI sdist 漏打包了源码

编译时报 `cc1plus: fatal error: <file>: No such file or directory`。已确认 sdist 里缺这 5 个文件：

```
fairseq/clib/libbase/balanced_assignment.cpp
fairseq/clib/libnat/edit_dist.cpp
fairseq/clib/cuda/ngram_repeat_block_cuda.cpp
fairseq/clib/libnat_cuda/binding.cpp
examples/operators/alignment_train_cpu.cpp
```

**修法**：解包 sdist 后从 jsdelivr 补（国内可达）：

```bash
curl -fsSL "https://cdn.jsdelivr.net/gh/facebookresearch/fairseq@v0.12.2/$f" -o "$src/$f"
```

遍历 `setup.py` 里声明的全部源文件，缺谁补谁：

```bash
grep -oE "[\"'](fairseq|examples)/[^\"']+\.(cpp|c|pyx|cu)[\"']" setup.py | tr -d "\"'" | sort -u
```

然后 `pip install --no-build-isolation .`（必须关掉 build isolation，构建期要用 venv 里的 cython/numpy）。

**两个附带结论：**
- 下载 sdist 时**绝不能写 `pip download --no-binary :all:`** —— 它会把 numpy 也拖去源码编译，卡十几分钟。
  正确写法：`pip download fairseq==0.12.2 --no-deps --no-binary fairseq -d <dir>`
- CUDA 扩展**不会被编译**（好事）：`setup.py` 里由 `if "CUDA_HOME" in os.environ:` 守卫，
  WSL 里没装 CUDA toolkit 就跳过。**不要**为了它去 apt 一个 `nvidia-cuda-toolkit`。

### 3.4 `PYTORCH_CUDA_ALLOC_CONF=expandable_segments` 会直接崩

这是 **torch ≥ 2.1** 才有的选项，torch 2.0.1 首次 CUDA 调用会抛：

```
RuntimeError: Unrecognized CachingAllocator option: expandable_segments
```

要限制碎片就用 `max_split_size_mb:512`。

### 3.5 依赖清单里容易漏的两个

- **`matplotlib`** —— `vdecoder/hifigan/utils.py`、`vdecoder/utils.py`、`utils.py` 在 **import 阶段**
  就 `import matplotlib`（只用来画图 / 存频谱），漏装直接 `ModuleNotFoundError` 起不来。
- **`scikit-learn`** —— `cluster/__init__.py` 在 import 阶段就 `from sklearn.cluster import KMeans`。

开工前先扫一遍，别打完一轮猜一轮（用 `importlib.util.find_spec` 逐个查，不执行模块）：

```bash
/opt/svc-inference/venv/bin/python3 - <<'PY'
import importlib.util, pathlib
mods = set()
for p in pathlib.Path('.').rglob('*.py'):
    for ln in p.read_text(encoding='utf-8', errors='ignore').splitlines():
        ln = ln.strip()
        if ln.startswith('import '):
            mods.add(ln[7:].split('.')[0].split(' ')[0].rstrip(','))
        elif ln.startswith('from ') and ' import ' in ln:
            mods.add(ln[5:].split(' import ')[0].split('.')[0])
local = {p.stem for p in pathlib.Path('.').rglob('*.py')} | {'venv'}
missing = sorted(m for m in mods
                 if m and m not in local and m not in __import__('sys').stdlib_module_names
                 and importlib.util.find_spec(m) is None)
print('缺失:', missing or '无')
PY
```

**不用装**（惰性导入或只训练用）：`torchcrepe`（只在 `f0_predictor="crepe"` 时，默认 `"pm"` 走 parselmouth）、
`maad`（只在 `RealTimeVC.process` 里）、`pynvml`（只在 `cluster/km_train.py`、`train_cluster.py`）、
`hubert`（只在 `infer_tool_grad.py`）。

### 3.6 其它

- **`/tmp` 会被 systemd-tmpfiles 定期清空**：安装日志、wheel 缓存、测试音频一律放 `/opt/...`。
- **`numpy` 必须钉 1.24.3**：torch 2.0.1 和 fairseq 都不兼容 numpy 2.x。

---

## 4. 开机自启

WSL 发行版不会随 Windows 启动而启动，所以用启动文件夹 + `.vbs` 拉起：

```vbs
ws.Run "wsl.exe -d <发行版名> -u root -- systemctl start svc-inference", 0, False
```

把 `inference/wsl-autostart.vbs` 放到 `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\`
（Win+R 输入 `shell:startup` 直接打开该目录），并确认里面的发行版名与 `wsl -l -v` 一致。

`svc-inference` 在 systemd 里已经是 `enabled`，vbs 里再 `start` 一次只是保险（已运行时为 no-op）。

---

## 5. 验收

```bash
# 服务状态
systemctl is-enabled svc-inference frpc
systemctl is-active  svc-inference frpc

# 健康检查（应返回模型列表）
curl -s http://localhost:8081/api/health
```

真推理冒烟（**不是 mock**）：

```bash
curl -s -H "Content-Type: application/json" \
     -d '{"mode":"file","audio_path":"<一段 3~4s 的 wav>","voice_model":"2602"}' \
     http://localhost:8081/api/infer
```

确认输出**确实经过模型**而不是直通：

```bash
md5sum in.wav out.wav     # 必须不同
```

更强的判据是比较平均绝对差与音频 RMS 的量级——两者相当才说明是真正重合成过。

### 重启后自愈

```bash
wsl --shutdown
wsl -d <发行版> -u root -- /bin/true    # 拉起发行版，等 ~30s 让 systemd 起来
systemctl is-active svc-inference frpc
```

两个服务都是 `enabled` 就会自动恢复，frpc 也会重新握手。

### 全链路

从前端上传 → 轮询任务状态 → 下载结果，全程应为 200。

---

## 6. 常见误判

| 现象 | 真因 |
|---|---|
| 上传接口返回空响应 / curl `code=000` | 本地 `-F "audio=@/tmp/xxx.wav"` 的文件被 tmpfiles 清掉了，**不是服务端问题** |
| 服务起不来但日志无异常 | 漏装 `matplotlib` / `scikit-learn`，import 阶段就挂了 |
| `wsl.exe` 传多行命令报 `syntax error near unexpected token` | Windows↔bash 层拆坏了参数，改成**先写 `.sh` 文件再执行** |
| 非 ASCII 路径传给 `wsl.exe` 失败 | 在 WSL 里 `ln -sfn "<中文路径>" /usr/local/bin/<ascii>` 后调 ASCII 名 |

---

## 7. 目录布局

```
/opt/svc-inference/
├── venv/                  # Python 3.10 虚拟环境
├── .wheels/               # torch/fairseq wheel 缓存（可删）
├── server.py  svc_engine.py  ...
├── configs/               # 模型配置（config.json / config_2602.json / diffusion.yaml）
├── logs/44k/              # 模型权重 G_*.pth
├── pretrain/              # ContentVec + HubertSoft + HiFiGAN
└── pre_trained_model/     # 预训练底模 + 扩散模型

/etc/systemd/system/svc-inference.service
/etc/systemd/system/frpc.service
/etc/frp/frpc.toml
/var/log/svc-inference.log
```
