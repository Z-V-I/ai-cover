---
name: wsl2-audio-inference-deploy
description: 在本机 WSL2 (Ubuntu) 上从零部署 so-vits-svc / ContentVec 系语音推理层（含 fairseq 编译、cu118 torch、systemd 常驻、frp 反代到云服务器）。当用户要求「把推理层装上」「WSL 里装 so-vits / svc / 语音克隆推理」「装 fairseq」「配 frp 打通内网推理机」「国内网络装 torch+fairseq 老版本」时使用。
agent_created: true
---

# WSL2 语音推理层部署（so-vits-svc / ContentVec）

把散落的 so-vits-svc 4.x 推理代码在 WSL2 上跑成 systemd 常驻服务，并通过 frp 暴露给远端决策层。

已验证组合：Ubuntu 26.04 / Python 3.10.22 / torch 2.0.1+cu118 / fairseq 0.12.2 / NVIDIA 驱动 472.12（CUDA 11.4）。
配套脚本见 `scripts/install-wsl.sh`（分阶段一键安装）、`scripts/scan-imports.py`（扫缺失依赖）。

## 0. 铁律（先看这条，能省 80% 的返工）

1. **所有 WSL 命令都写成 `.sh` 文件再执行**：`export MSYS_NO_PATHCONV=1; wsl -d <distro> -u root -- bash /mnt/c/.../x.sh`。
   直接 `wsl -- bash -lc '<多行/含 $() /含内嵌双引号>'` 会被 Windows↔bash 层拆坏参数，报 `syntax error near unexpected token`。
2. **非 ASCII 路径不要直接传给 wsl.exe**：在 WSL 里 `ln -sfn "<中文路径脚本>" /usr/local/bin/<ascii-name>`，之后调 ASCII 名。
3. **`/tmp` 会被 systemd-tmpfiles 定期清空**：安装日志、测试音频、wheel 缓存一律放 `/opt/...`。
4. **sudo 需要密码时用 `wsl -u root`**：脚本里 `[ "$(id -u)" -eq 0 ] && SUDO="" || SUDO=sudo` 自动适配。
5. **长任务用 `setsid ... &` 脱离**，再单独轮询日志，别让前台命令被超时杀掉。
6. 轮询脚本要**从日志里最后一条 `RUNSTART` 之后找 `EXITMARK`**，否则会被历史运行的 marker 误导成"已完成"。
7. **不要把 token / IP / 本机绝对路径硬编码进脚本**：从环境变量或 `.env` 读。
   注意 `sudo` 默认会丢环境变量 —— 让脚本自己 `source` 仓库根的 `.env` 才能同时照顾 `sudo` 与 `wsl -u root` 两种入口。

## 1. 预检（顺序执行，缺一不可）

```bash
wsl -l -v                                   # 确认发行版名（别猜！自启脚本里写错名字 = 空转）
wsl -d <distro> -u root -- bash -c 'cat /etc/os-release | head -2; python3 -V; ps -p 1 -o comm='   # systemd 是否为 pid1
wsl -d <distro> -u root -- bash -c 'df -BG / | tail -1'          # 要 >=12G（模型+torch）
wsl -d <distro> -u root -- bash -c '/usr/lib/wsl/lib/nvidia-smi --query-gpu=name,driver_version --format=csv,noheader'
```

- **驱动版本决定 torch 版本**：驱动 < 520（如 472.12 = CUDA 11.4）时**不要按 README 装 cu121**，装 **torch 2.0.1 + cu118**（靠 CUDA minor version compatibility）。
- torch 2.0.1 还有个隐性好处：torch>=2.6 的 `torch.load` 默认 `weights_only=True`，读不了 so-vits / fairseq 的老 ckpt。
- **Python 版本**：fairseq 0.12.2 只认 3.8~3.10。Ubuntu 24.04+ 自带 3.12/3.13/3.14，必须另装 3.10。首选 `uv python install 3.10`（秒级，独立解释器，不污染系统）。

## 2. 安装阶段拆分

`base → pyenv → torch → deps → model → svc → frp → verify`，每段可单独重跑（断点续传）。参见本 skill 的 `scripts/install-wsl.sh`。

- **base**：`ffmpeg libsndfile1 build-essential pkg-config rsync wget`
- **pyenv**：uv 拉 Python 3.10 → `uv venv --seed /opt/<app>/venv`
- **torch**：见第 3 节
- **deps**：fairseq（见第 4 节）+ 其余依赖
- **model**：`rsync -a --exclude venv/` 把源码+权重同步到 `/opt/<app>`
- **svc**：写 `/etc/systemd/system/<svc>.service`，`enable --now`
- **frp**：见第 6 节
- **verify**：健康检查 + 真推理冒烟

## 3. torch cu118 wheel —— 必须走国内镜像

`download-r2.pytorch.org` 在国内**必断**（实测 2062/2267 MB 处连续断 6 次）。镜像实测可用：

| 镜像 | 状态 |
|---|---|
| `https://mirrors.aliyun.com/pytorch-wheels/cu118` | ✅ 实测 ~2.4MB/s |
| `https://mirror.sjtu.edu.cn/pytorch-wheels/cu118` | ✅ |
| `mirrors.ustc.edu.cn` / `tuna` / `bfsu` 的 pytorch-wheels | ❌ 404 |

做法：**直接 curl/wget 拿 wheel 再本地 pip install**（pip 的 `--index-url` 对国内镜像兼容性差，flat 目录需 `--find-links` 且 `+` 要 URL 编码）。

```bash
# 文件名里 + 必须编码成 %2B
W="torch-2.0.1%2Bcu118-cp310-cp310-linux_x86_64.whl"
wget -c -T 30 -t 20 --waitretry=5 --progress=dot:giga \
     -O /opt/<app>/.wheels/torch.whl \
     "https://mirrors.aliyun.com/pytorch-wheels/cu118/$W"
```

- 先 `curl -sIL` 拿 `Content-Length` 做完整性校验；不匹配就换镜像续传。
- **用 `wget -c` 续传**，失败重跑不会从头开始（2.2G 约 10 分钟）。
- 装完补依赖：`filelock typing-extensions sympy networkx jinja2 fsspec "numpy==1.24.3"`（**必须钉 numpy 1.24.3**，torch 2.0.1 / fairseq 都不兼容 numpy 2.x）。

## 4. fairseq 0.12.2 —— 两个必踩的坑

### 坑 1：pip>=24.1 直接装不上
```
WARNING: Ignoring version 2.0.6 of omegaconf since it has invalid metadata
ERROR: ResolutionImpossible
```
新版 pip 判定 `omegaconf<2.1` 的元数据 `PyYAML (>=5.1.*)` 非法并忽略全部候选，而 fairseq 硬依赖 `omegaconf<2.1`。
**修**：`pip install "pip<24.1" "setuptools<70" wheel "Cython<3" "numpy==1.24.3" ninja`

### 坑 2：PyPI 的 sdist 漏打包源码
编译报 `cc1plus: fatal error: <file>: No such file or directory`。已确认 sdist 里缺：
```
fairseq/clib/libbase/balanced_assignment.cpp
fairseq/clib/libnat/edit_dist.cpp
fairseq/clib/cuda/ngram_repeat_block_cuda.cpp
fairseq/clib/libnat_cuda/binding.cpp
examples/operators/alignment_train_cpu.cpp
```
**修**：解包 sdist 后从 jsdelivr 补（国内可达，GitHub raw 也通）：
```bash
curl -fsSL "https://cdn.jsdelivr.net/gh/facebookresearch/fairseq@v0.12.2/$f" -o "$src/$f"
# 遍历 setup.py 里声明的所有源文件，缺谁补谁（注意 examples/ 目录也在里面）：
grep -oE "[\"'](fairseq|examples)/[^\"']+\.(cpp|c|pyx|cu)[\"']" setup.py | tr -d "\"'" | sort -u
```
补齐要写成**非致命**（`warn` 而非 `die`），因为 CUDA 那几个文件本来就不需要。
然后 `pip install --no-build-isolation .`（必须关 build isolation，构建期要用 venv 里的 cython/numpy）。

### 下载 sdist 的陷阱
**绝不写 `pip download --no-binary :all:`** —— 它会把 numpy 也拖去源码编译（拉 meson/ninja/cmake，卡十几分钟）。
正确写法：`pip download fairseq==0.12.2 --no-deps --no-binary fairseq -d <dir>`

### CUDA 扩展不会编译（这是好事）
`setup.py` 里 CUDA 扩展由 `if "CUDA_HOME" in os.environ:` 守卫。WSL 里没装 CUDA toolkit → 不编译 → 不需要 nvcc。**不要**为了装它去 apt 一个 nvidia-cuda-toolkit。

## 5. 依赖清单容易漏的两个

- **`matplotlib`**：`vdecoder/hifigan/utils.py`、`vdecoder/utils.py`、`utils.py` 在 **import 阶段**就 `import matplotlib`（只用于画图），漏装 → `ModuleNotFoundError` 直接起不来。
- **`scikit-learn`**：`cluster/__init__.py` 在 import 阶段就 `from sklearn.cluster import KMeans`。

**开工前先扫一遍**，别打完一轮猜一轮：见 `scripts/scan-imports.py`（用 `importlib.util.find_spec` 逐个查，不执行模块）。只挑真正的第三方包；`cluster/diffusion/models/utils/vencoder/vdecoder` 这类是项目本地模块，属误报。

**不用装**（惰性导入或训练脚本）：`torchcrepe`（只在 `f0_predictor="crepe"` 时，默认 `"pm"` 走 parselmouth）、`maad`（只在 `RealTimeVC.process` 里）、`pynvml`（只在 `cluster/km_train.py`、`train_cluster.py`）、`hubert`（只在 `infer_tool_grad.py`）。

## 6. systemd + frp

### service 里**不要**写这两个
- ❌ `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` —— 这是 **torch>=2.1** 的选项，torch 2.0.1 首次 CUDA 调用直接抛 `RuntimeError: Unrecognized CachingAllocator option: expandable_segments`。要设就用 `max_split_size_mb:512`。
- ❌ 忘了 `Environment=PATH=/usr/lib/wsl/lib:...` —— `nvidia-smi` 和 `libcuda.so.1` 在 WSL 的这个目录下。

其余：`Restart=always`、`StandardOutput=append:/var/log/<svc>.log`。

### 保活（**必做，否则服务一定会掉**）

**根因：`.wslconfig` 里 `[general] instanceIdleTimeout` 默认只有 15000 ms（15 秒）。**
发行版空闲 15 秒就被 shutdown，里面的 systemd 服务随之全停 —— 服务不是自己挂了，
是整台发行版被收走了。所以 `systemd` 里 `enable` **完全解决不了这个问题**。

两个键极易搞混（都在 `%UserProfile%\.wslconfig`）：

| 键 | 段 | 默认 | 管什么 |
|---|---|---|---|
| `instanceIdleTimeout` | `[general]` | **15000 ms** | 发行版空闲多久被 shutdown ← **元凶** |
| `vmIdleTimeout` | `[wsl2]` | 60000 ms | 虚拟机（VM）空闲多久被回收 |

```ini
[general]
instanceIdleTimeout=-1        # -1 = 永不自动关闭
[wsl2]
vmIdleTimeout=604800000
```

改完必须 `wsl --shutdown` 才生效。
**只改 `[wsl2] vmIdleTimeout` 是没用的** —— 发行版被回收后 VM 才跟着回收，这是最容易踩的坑。

**症状判据**（三条一起看，少看一条容易被骗）：
- `journalctl -u <svc>` 里出现密集的 `Stopping/Stopped`，且每次只活十几秒；
- `journalctl -b --no-pager | grep 'power off'` 有 `systemd-logind: The system will power off now!`
  —— **决定性证据**；
- ⚠️ 那一瞬间 `systemctl is-active <svc>` 往往仍返回 `active`，**只看 is-active 会被骗**。

**严格验证**（不能靠 is-active，要用 `boot_id`）：

```bash
wsl -d <distro> -u root -- bash -c "cat /proc/sys/kernel/random/boot_id"
# 之后什么都别做，静置 90 秒以上（期间不要执行任何 wsl 命令！）
wsl -d <distro> -u root -- bash -c "cat /proc/sys/kernel/random/boot_id; systemctl show <svc> -p ActiveEnterTimestamp"
```

`boot_id` 不变、`ActiveEnterTimestamp` 仍是最初那一刻 → 没被回收。
实测对比：修复前 `boot_id` 每 2 分钟变一次、服务每 16 秒重启一次；修复后静置 90 秒
`boot_id` 不变、服务只启动过 1 次、`power off` 计数为 0。

**Windows 侧计划任务（只负责「登录后把发行版踢起来」+ 兜底）**：
`.wslconfig` 修好后 VM 不会再被空闲回收，但 Windows 登录后如果没人碰过 WSL，
发行版根本不会启动。脚本见 `scripts/setup-wsl-keepalive.ps1`，注册一个任务：
登录时 + 每 2 分钟执行 `systemctl start <svc...>`（幂等，不会重启已在跑的服务）。

**四个必踩的坑**：

1. **计划任务直接跑 `wsl.exe` 会闪黑窗**。用 `.vbs` 壳以
   `WshShell.Run(cmd, 0, True)`（window style `0`）调起 —— `wscript.exe` 是 GUI 程序，
   不分配控制台。任务动作写 `wscript.exe //nologo "<shim>.vbs"`。
2. **编码（每种文件各不相同，全踩过）**：
   - `.vbs` 带中文 → 必须 **UTF-16LE + BOM**（wscript 默认按 ANSI 读，UTF-8 会乱码甚至解析崩）
   - `.ps1` 带中文 → 必须 **UTF-8 *带* BOM**（PowerShell 5.1 对无 BOM 的 .ps1 按 ANSI 读，
     中文乱码后语法直接崩，报「表达式或语句中包含意外的标记 "}"」）
   - `.sh` → **绝对不能有 BOM**，否则 `bad interpreter`
   - `.wslconfig` → UTF-8 **无** BOM + **LF**（有 BOM 会让 WSL 静默忽略整个文件；
     CRLF 可能让值被读成 `-1\r`）
3. **`LogonTrigger` 上挂 `Repetition` 不会真正重复**。XML 里明明有
   `<Repetition><Interval>PT2M</Interval>`，但 `NextRunTime` 为空，同一次登录内根本不跑。
   **必须额外加 `TimeTrigger(-Once)` 带 Repetition**。
4. **WSL2 所有发行版共享同一个 VM**。机器上别的发行版（如 Debian 跑 docker）会顺带保活你的 VM ——
   **别把保活建立在别人的活动上**，那种活动一停服务照样掉。

**已废弃的历史方案**：一个常驻 `wsl.exe -d <distro> -u root -- sleep infinity` 的「锚点」任务
（靠顶住一个活跃会话阻止回收）。它在 `.wslconfig` 没修好的前提下确实有效（实测能撑住），
但那是治标 —— 根因既然是 `instanceIdleTimeout`，就应当改配置。
`setup-wsl-keepalive.ps1` 会自动移除这个旧任务。

**备选**（无权限建计划任务时）：启动文件夹 + `scripts/wsl-autostart.vbs`（隐藏窗口，
登录时执行一次）。缺点：受限环境里 `wscript` 会被当 LOLBin 拦下，**无法自动化测试**。
与计划任务**不要同时启用**。

### frp 反代（本机推理 → 云端决策层）
```toml
serverAddr = "<ECS_IP>"
serverPort = 7000
auth.method = "token"
auth.token = "<从环境变量/.env 取，不要硬编码>"

[[proxies]]
name = "svc-inference"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8081
remotePort = 18081
```
- 判断 frps 是否在跑：`timeout 5 bash -c 'exec 3<>/dev/tcp/<ECS>/7000'` 通即 frps 在跑。
- **云端 `remotePort` 不通公网是正常的**：决策层在 ECS 上用 `localhost:18081` 访问，不需要安全组放行 18081。
- 客户端连上的日志特征：`login to server success` + `start proxy success`。

**开 debug 日志时注意位置**：`log.to` / `log.level` 必须写在 `[[proxies]]` **之前**。
写在后面会被 TOML 当成 proxy 的字段 → `unmarshal ProxyConfig error: json: unknown field "log"`
→ 服务每 5 秒无限重启。正确写法：

```toml
log.to = "console"
log.level = "debug"

serverAddr = "..."
[[proxies]]
...
```

**别把 frpc 周期性重连当独立故障**：`try to connect to server...` 每隔 1~2 分钟出现一次，
在**刚重启过 frpc / 执行过 `wsl --shutdown`** 之后是正常的 —— frps 要等心跳超时（默认 90s）
才清理旧连接，几轮后才收敛。静置观察 4 分钟，重连次数归零即正常。

## 7. 密钥与配置（公开仓库尤其注意）

- 部署脚本里**只留占位默认值**，真实值（`ECS_IP`、`FRP_TOKEN`、`API_TOKEN`）放仓库根的 `.env`，并把 `.env` 加进 `.gitignore`，同时提供 `.env.example` 模板。
- 脚本内自己加载 `.env`（`set -a; . "$_ENV_FILE"; set +a`），这样 `sudo` 和 `wsl -u root` 都不会丢配置。
- **前端里的 token 一定要外置**：写进 `app.js` 等于公开。做法是单独一个 `js/config.js`（gitignore）+ `js/config.example.js`（入库），用 `window.APP_CONFIG` 注入。
- **服务端 token 为空比设弱口令更危险**：形同虚设的鉴权会让 `token != API_TOKEN` 恒为 False。启动时显式检查，为空就 `SystemExit`。
- 交付前扫一遍：`grep -rniE "api[_-]?key|token|secret|password" --include=* .`

## 8. 验收标准（缺一不可）

1. `systemctl is-enabled/is-active` 两个服务都 ok
2. `/api/health` 返回 `models` 列表
3. **真推理**（不是 mock）：POST 一段 3~4s 音频 → HTTP 200 + 输出采样率/时长正确
4. **确认不是直通**：`md5sum 输入 输出` 必须不同；`np.abs(in-out).mean()` 量级应与音频 RMS 相当
5. `wsl --shutdown` 冷启后自动恢复
6. **公网端到端**：从前端 API 上传 → 轮询任务状态 → 下载结果，全链路 200
7. **保活验收（必做，否则前面全白干）**：静置 90 秒不碰 WSL，`boot_id` 不变、
   `journalctl -b | grep 'power off'` 计数为 0 —— 详见 6. 保活

## 9. 常见误判

| 现象 | 真因 |
|---|---|
| 上传接口返回空响应 / curl `code=000` | 本地 `-F "audio=@/tmp/xxx.wav"` 的文件被清空了，**不是服务端问题** |
| 轮询脚本显示 "FINISHED" 但任务还在跑 | 匹配到了历史运行的 EXITMARK |
| 编译报缺文件 | PyPI sdist 漏打包，不是网络问题 |
| 服务起不来但日志无异常 | 漏装 `matplotlib` / `scikit-learn`，import 阶段就挂了 |
| 前端报"无法连接到推理服务"但 `is-active` 仍是 active | **发行版被 `instanceIdleTimeout`（默认 15 秒）回收了，不是服务挂了** —— 看 `journalctl -b \| grep 'power off'`（见 6. 保活）。只看 `is-active` 一定被骗 |
| 服务每十几秒被起停一次 | 同上，那是 WSL 关机留下的痕迹，**去改 `.wslconfig`，别去查服务** |
| 判断服务状态返回"全都正常" | `systemctl is-active --quiet svc1 svc2` 一次传多个服务名**会失效**（某个没跑也返回 0）。必须逐个查：active→0、inactive→3、不存在→4 |
| frpc 每 1~2 分钟重连一次 | 刚重启过 frpc / `wsl --shutdown` 后的正常收敛过程，静置 4 分钟归零即可，**不是 frps 故障** |
| `.ps1` 带中文报「意外的标记 "}"」 | 文件是 **UTF-8 无 BOM**，PowerShell 5.1 按 ANSI 读导致中文乱码破坏语法。存成 UTF-8 **带** BOM（`.sh` 反过来绝不能有 BOM） |
| `.wslconfig` 写了键却不生效 | 文件带了 BOM 或 CRLF —— WSL 会静默忽略整个文件。必须 UTF-8 无 BOM + LF |
| `Get-Content` 读配置文件后行首匹配不到 / 输出为空 | PowerShell 5.1 的 `Get-Content` 按 ANSI 读 UTF-8 **无 BOM** 文件，中文乱码时**会连带吞掉换行、把相邻两行并成一行**（实测），于是 `^\s*key=` 匹配失效。读写这类文件一律用 `[System.IO.File]::ReadAllLines / ReadAllText / WriteAllText` |

## 附：脚本

- `scripts/install-wsl.sh` —— 分阶段一键安装（可直接改用）
- `scripts/scan-imports.py` —— 扫源码里缺失的第三方模块
- `scripts/setup-wsl-keepalive.ps1` —— **部署完必跑**：修正 `.wslconfig`（`instanceIdleTimeout=-1`）+ 注册隐藏窗口的保活计划任务
- `scripts/wsl-autostart.vbs` —— 隐藏窗口拉起脚本；无计划任务权限时可单独放进启动文件夹
