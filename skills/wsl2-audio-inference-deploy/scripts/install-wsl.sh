#!/usr/bin/env bash
# ============================================================================
#  AI 翻唱 · 推理层 —— WSL2 (Ubuntu) 一键安装脚本
# ----------------------------------------------------------------------------
#  用法（在 WSL2 Ubuntu 里执行）：
#      sudo bash install-wsl.sh                 # 全流程
#      sudo bash install-wsl.sh deps verify     # 只跑指定阶段
#      sudo bash install-wsl.sh --with-frp      # 全流程 + 配置 frp 内网穿透
#
#  可用阶段： base  系统依赖
#             pyenv 安装 Python 3.10 并建 venv
#             torch PyTorch (CUDA)
#             deps  fairseq 及其余 Python 依赖
#             model 拷贝代码 + 模型权重到 /opt/svc-inference
#             svc   systemd 服务
#             frp   frp 内网穿透（frpc → 云端 frps:7000）
#             verify 健康检查 + 端到端冒烟推理
#
#  配置来源（优先级从高到低）：
#      1) 命令行环境变量
#      2) 仓库根目录的 .env（由 .env.example 复制而来，.env 不入库）
#
#  可用环境变量：
#      SRC_DIR           源码目录（默认 = 本脚本所在目录，即 inference/）
#      DST_DIR           安装目录（默认 /opt/svc-inference）
#      PY_VER            Python 版本（默认 3.10）
#      TORCH_VER/TORCH_INDEX_URL
#      PIP_MIRROR        pip 镜像
#      ECS_IP            云端服务器公网 IP（frps 所在机器）—— 跑 frp 阶段必需
#      FRP_TOKEN         frp 认证 token（frps/frpc 两端须一致）—— 跑 frp 阶段必需
# ============================================================================

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 配置加载：优先用已导出的环境变量，其次读仓库根目录的 .env
# ---------------------------------------------------------------------------
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ENV_FILE="${ENV_FILE:-$_SELF_DIR/../.env}"
if [ -f "$_ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$_ENV_FILE"
  set +a
fi

SRC_DIR="${SRC_DIR:-$_SELF_DIR}"
DST_DIR="${DST_DIR:-/opt/svc-inference}"
PY_VER="${PY_VER:-3.10}"

TORCH_VER="${TORCH_VER:-2.0.1}"
TORCHAUDIO_VER="${TORCHAUDIO_VER:-2.0.2}"
TORCH_CUDA="${TORCH_CUDA:-cu118}"
TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/${TORCH_CUDA}}"
# 备用镜像：download.pytorch.org 在国内极易下载中断，优先走国内镜像
TORCH_MIRRORS="${TORCH_MIRRORS:-https://mirrors.aliyun.com/pytorch-wheels/${TORCH_CUDA} https://mirror.sjtu.edu.cn/pytorch-wheels/${TORCH_CUDA} ${TORCH_INDEX_URL}}"

PIP_MIRROR="${PIP_MIRROR:-https://pypi.tuna.tsinghua.edu.cn/simple}"
CONDA_MIRROR="${CONDA_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge}"
UV_PYTHON_MIRROR="${UV_PYTHON_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/github-release/astral-sh/python-build-standalone}"

ECS_IP="${ECS_IP:-}"
FRP_TOKEN="${FRP_TOKEN:-}"
FRP_VERSION="${FRP_VERSION:-0.61.1}"

WITH_FRP=0
STAGES=()

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[36m'; RST=$'\033[0m'
say()  { echo -e "${BLU}==>${RST} $*"; }
ok()   { echo -e "${GRN}  ✓${RST} $*"; }
warn() { echo -e "${YEL}  !${RST} $*"; }
die()  { echo -e "${RED}  ✗ $*${RST}" >&2; exit 1; }

trap 'echo -e "${RED}\n[失败] 第 $LINENO 行，命令: $BASH_COMMAND${RST}" >&2' ERR

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --with-frp) WITH_FRP=1 ;;
    -h|--help) sed -n '3,/^# =\{20,\}$/p' "$0"; exit 0 ;;
    base|pyenv|torch|deps|model|svc|frp|verify) STAGES+=("$arg") ;;
    *) die "未知参数: $arg（-h 查看帮助）" ;;
  esac
done
if [ ${#STAGES[@]} -eq 0 ]; then
  STAGES=(base pyenv torch deps model svc verify)
  if [ "$WITH_FRP" -eq 1 ]; then
    STAGES=(base pyenv torch deps model svc frp verify)
  fi
fi

run_stage() {
  local s="$1" x
  for x in "${STAGES[@]}"; do
    if [ "$x" = "$s" ]; then return 0; fi
  done
  return 1
}

VENV="$DST_DIR/venv"
VPY="$VENV/bin/python3"

# ---------------------------------------------------------------------------
# 0. 预检
# ---------------------------------------------------------------------------
preflight() {
  say "预检环境"
  grep -qi microsoft /proc/version 2>/dev/null || warn "看起来不是 WSL 环境，继续执行"
  [ -d "$SRC_DIR" ] || die "源码目录不存在: $SRC_DIR"
  [ -f "$SRC_DIR/server.py" ] || die "$SRC_DIR 里没有 server.py，路径不对"

  # GPU
  if [ -x /usr/lib/wsl/lib/nvidia-smi ]; then
    export PATH="/usr/lib/wsl/lib:$PATH"
  fi
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | sed 's/^/     /'
    ok "GPU 可用"
  else
    warn "WSL 里检测不到 nvidia-smi —— 推理会退化成 CPU（很慢）"
    warn "请在 Windows 侧确认 NVIDIA 驱动已安装，然后重启 WSL：wsl --shutdown"
  fi

  # 磁盘空间
  local avail
  avail=$(df -BG --output=avail "$(dirname "$DST_DIR")" | tail -1 | tr -dc '0-9')
  if [ "${avail:-0}" -lt 12 ]; then
    warn "剩余空间 ${avail}G，建议 >=12G（模型 3.4G + torch 3G + 依赖）"
  fi
  mkdir -p "$DST_DIR"
}

# ---------------------------------------------------------------------------
# 1. 系统依赖
# ---------------------------------------------------------------------------
stage_base() {
  say "安装系统依赖 (ffmpeg / libsndfile / 编译工具链)"
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq --no-install-recommends \
      ca-certificates curl wget git xz-utils \
      ffmpeg libsndfile1 \
      build-essential pkg-config \
      python3 python3-venv python3-pip \
      rsync
  ok "系统依赖就绪"
}

# ---------------------------------------------------------------------------
# 2. Python 3.10 + venv
#   Ubuntu 26.04 自带 python3.14，fairseq 不兼容，必须单独搞一个 3.10
# ---------------------------------------------------------------------------
stage_pyenv() {
  if [ -x "$VPY" ]; then
    ok "venv 已存在: $VPY -> $("$VPY" -V 2>&1)"
    return 0
  fi
  say "准备 Python $PY_VER"

  # (a) 系统里已经有 python3.10
  if command -v "python$PY_VER" >/dev/null 2>&1; then
    ok "使用系统 python$PY_VER"
    "python$PY_VER" -m venv "$VENV"
    "$VPY" -m pip install -U pip -i "$PIP_MIRROR"
    return 0
  fi

  # (b) uv（首选，秒级）
  export UV_PYTHON_INSTALL_DIR="$DST_DIR/.python"
  if ! command -v uv >/dev/null 2>&1; then
    say "安装 uv"
    if curl -fsSL --max-time 60 https://astral.sh/uv/install.sh -o /tmp/uv-install.sh; then
      sh /tmp/uv-install.sh >/dev/null 2>&1 || true
      export PATH="$HOME/.local/bin:$PATH"
    fi
    command -v uv >/dev/null 2>&1 || pip3 install -q uv -i "$PIP_MIRROR" 2>/dev/null || true
    export PATH="$HOME/.local/bin:$PATH"
  fi

  if command -v uv >/dev/null 2>&1; then
    say "用 uv 安装 Python $PY_VER"
    if uv python install "$PY_VER" >/dev/null 2>&1 \
       || UV_PYTHON_INSTALL_MIRROR="$UV_PYTHON_MIRROR" uv python install "$PY_VER" >/dev/null 2>&1; then
      uv venv --python "$PY_VER" --seed "$VENV" >/dev/null
      ok "uv 建好 venv: $("$VPY" -V 2>&1)"
      return 0
    fi
    warn "uv 下载 Python 失败，回退 micromamba"
  fi

  # (c) micromamba / conda-forge（国内稳）
  say "用 micromamba 创建 Python $PY_VER 环境（走清华镜像）"
  export MAMBA_ROOT_PREFIX="/opt/mamba"
  if [ ! -x /opt/bin/micromamba ]; then
    curl -fsSL https://micro.mamba.pm/api/micromamba/linux-64/latest \
      | tar -xj -C /opt bin/micromamba
  fi
  /opt/bin/micromamba create -y -q -p "$VENV" -c "$CONDA_MIRROR" "python=$PY_VER" pip
  ok "micromamba 建好环境: $("$VPY" -V 2>&1)"
}

# ---------------------------------------------------------------------------
# 3. PyTorch
# ---------------------------------------------------------------------------
#  直接 pip 从 download.pytorch.org 拉 2.3G 的 cu118 wheel 在国内基本必然中断，
#  这里改成：国内镜像 + wget 断点续传 + 无限重试，再本地安装。
#  失败后重跑本阶段会自动续传，不会从 0 开始。
# ---------------------------------------------------------------------------
wheel_name() {  # $1=包名 $2=版本  ->  已 URL 编码的文件名
  echo "$1-$2%2B$TORCH_CUDA-cp310-cp310-linux_x86_64.whl"
}

fetch_wheel() {  # $1=包名 $2=版本
  local pkg="$1" ver="$2"
  local enc plain out want have base wlog
  enc=$(wheel_name "$pkg" "$ver")
  plain="${enc//%2B/+}"
  mkdir -p "$DST_DIR/.wheels"
  out="$DST_DIR/.wheels/$plain"
  wlog="$DST_DIR/.wheels/wget-$pkg.log"

  # 问一遍各镜像的 Content-Length，拿来做完整性校验
  want=""
  for base in $TORCH_MIRRORS; do
    want=$(curl -sIL --max-time 20 "$base/$enc" | tr -d '\r' \
           | awk 'tolower($1)=="content-length:"{v=$2} END{if(v)print v}')
    if [ -n "$want" ] && [ "$want" -gt 1000000 ] 2>/dev/null; then
      break
    fi
    want=""
  done

  have=0
  if [ -f "$out" ]; then
    have=$(stat -c%s "$out" 2>/dev/null || echo 0)
  fi
  if [ -n "$want" ] && [ "$have" = "$want" ]; then
    ok "$plain 已完整下载 ($(numfmt --to=iec "$want"))"
    return 0
  fi
  if [ "$have" -gt 0 ] 2>/dev/null; then
    say "已有 $(numfmt --to=iec "$have")，续传 $plain"
  fi

  for base in $TORCH_MIRRORS; do
    say "下载 $plain  <- $base"
    say "  (进度: wsl -d Ubuntu -u root -- ls -l $out)"
    if wget -c -T 30 -t 20 --waitretry=5 --progress=dot:giga \
            -o "$wlog" -O "$out" "$base/$enc"; then
      have=$(stat -c%s "$out" 2>/dev/null || echo 0)
      if [ -z "$want" ] || [ "$have" = "$want" ]; then
        ok "$plain 完成 ($(numfmt --to=iec "$have"))"
        return 0
      fi
      warn "大小不符 ($have/$want)，换下一个镜像续传"
    else
      tail -5 "$wlog" 2>/dev/null | sed 's/^/     /' || true
      warn "$base 失败，换下一个镜像"
    fi
  done
  die "无法下载 $plain，请手动下载后放入 $DST_DIR/.wheels/"
}

stage_torch() {
  say "安装 PyTorch $TORCH_VER + torchaudio $TORCHAUDIO_VER (CUDA $TORCH_CUDA)"
  fetch_wheel torch "$TORCH_VER"
  fetch_wheel torchaudio "$TORCHAUDIO_VER"

  "$VPY" -m pip install -q --no-deps \
      "$DST_DIR/.wheels/torch-$TORCH_VER+$TORCH_CUDA-cp310-cp310-linux_x86_64.whl" \
      "$DST_DIR/.wheels/torchaudio-$TORCHAUDIO_VER+$TORCH_CUDA-cp310-cp310-linux_x86_64.whl"
  say "补齐 torch 运行时依赖"
  # 注意：torch 2.0.1 / fairseq 都不兼容 numpy 2.x，这里就钉死 1.24.3
  "$VPY" -m pip install -q -i "$PIP_MIRROR" \
      filelock typing-extensions sympy networkx jinja2 fsspec "numpy==1.24.3"

  "$VPY" - <<'PY'
import torch
print("     torch", torch.__version__, "| CUDA build:", torch.version.cuda)
print("     cuda available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("     device:", torch.cuda.get_device_name(0),
          "| cap:", torch.cuda.get_device_capability(0))
else:
    raise SystemExit("CUDA 不可用：检查 Windows 侧 NVIDIA 驱动，或 wsl --shutdown 后重试")
PY
  ok "PyTorch 就绪"
}

# ---------------------------------------------------------------------------
# 4. fairseq + 其余依赖
# ---------------------------------------------------------------------------
# fairseq 0.12.2 装不上的两个真实坑（都踩过了）：
#   坑 1：pip>=24.1 会因为 omegaconf<2.1 的旧式元数据（PyYAML (>=5.1.*)）判为非法并忽略
#        全部候选版本，而 fairseq 0.12.2 硬依赖 omegaconf<2.1 → ResolutionImpossible。
#        => 必须把 pip 钉回 24.0（<24.1）。
#   坑 2：PyPI 上的 fairseq-0.12.2.tar.gz 漏打包了 fairseq/clib/libbase/balanced_assignment.cpp，
#        编译报 "No such file or directory"。
#        => 从 jsdelivr 的 github 镜像把缺失源码补齐后再本地编译。
# ---------------------------------------------------------------------------
FAIRSEQ_GH="${FAIRSEQ_GH:-https://cdn.jsdelivr.net/gh/facebookresearch/fairseq@v0.12.2}"

install_fairseq() {
  local tar="$DST_DIR/.wheels/fairseq-0.12.2.tar.gz"
  local src="$DST_DIR/.src/fairseq-0.12.2"
  mkdir -p "$DST_DIR/.wheels" "$DST_DIR/.src"

  if [ ! -s "$tar" ]; then
    say "下载 fairseq 0.12.2 sdist"
    # 注意必须是 --no-binary fairseq（只对 fairseq 要 sdist）；
    # 写成 --no-binary :all: 会把 numpy 也拉去源码编译，卡十几分钟甚至直接失败。
    "$VPY" -m pip download fairseq==0.12.2 --no-deps --no-binary fairseq \
        -d "$DST_DIR/.wheels" -i "$PIP_MIRROR" -q || die "fairseq sdist 下载失败"
  fi
  rm -rf "$src"
  tar xzf "$tar" -C "$DST_DIR/.src"

  # 补齐 sdist 里缺的源码文件（setup.py 声明了但没打包进 sdist 的）
  local f got=0
  while IFS= read -r f; do
    if [ ! -f "$src/$f" ]; then
      mkdir -p "$(dirname "$src/$f")"
      if curl -fsSL --max-time 90 --retry 3 "$FAIRSEQ_GH/$f" -o "$src/$f"; then
        got=$((got + 1))
      else
        warn "补齐失败（可能是不参与本次构建的 CUDA 扩展源文件）: $f"
      fi
    fi
  done < <(grep -oE "[\"']fairseq/[^\"']+\.(cpp|c|pyx)[\"']|[\"']examples/[^\"']+\.(cpp|c|pyx|cu)[\"']" "$src/setup.py" \
            | tr -d "\"'" | sort -u)
  [ "$got" -gt 0 ] && ok "从 GitHub 镜像补齐了 $got 个 sdist 缺失文件"

  say "编译并安装 fairseq（约 3~6 分钟）"
  ( cd "$src" && "$VPY" -m pip install --no-build-isolation . -i "$PIP_MIRROR" ) \
    2>&1 | grep -viE '^\s+(cc|c\+\+|creating|building|copying)' | tail -15
  "$VPY" -c 'import fairseq; print("     fairseq", fairseq.__version__)' \
    || die "fairseq 安装后 import 失败"
}

stage_deps() {
  say "安装 fairseq 0.12.2（ContentVec 编码器依赖）"
  "$VPY" -m pip install -q -i "$PIP_MIRROR" \
      "pip<24.1" "setuptools<70" wheel "Cython<3" "numpy==1.24.3" ninja
  install_fairseq

  say "安装其余 Python 依赖"
  # requirements-linux.txt 可能还没被 model 阶段拷进 DST_DIR，回退到源码目录
  local req="$DST_DIR/requirements-linux.txt"
  [ -f "$req" ] || req="$SRC_DIR/requirements-linux.txt"
  [ -f "$req" ] || die "找不到 requirements-linux.txt"
  "$VPY" -m pip install -q -r "$req" -i "$PIP_MIRROR"

  say "自检 import"
  "$VPY" - <<'PY'
import importlib, sys
mods = ["torch","torchaudio","fairseq","librosa","soundfile","numpy","scipy",
        "yaml","tqdm","sklearn","parselmouth","flask","flask_cors"]
bad = []
for m in mods:
    try: importlib.import_module(m)
    except Exception as e: bad.append(f"{m}: {e}")
if bad:
    print("     以下模块导入失败:"); [print("       -", b) for b in bad]; sys.exit(1)
print("     全部", len(mods), "个模块 OK")
PY
}

# ---------------------------------------------------------------------------
# 5. 拷贝代码 + 模型权重
# ---------------------------------------------------------------------------
stage_model() {
  say "同步代码与模型权重 -> $DST_DIR  (约 3.4 GB，首次较慢)"
  rsync -a --info=progress2 \
      --exclude 'venv/' --exclude '__pycache__/' --exclude '*.pyc' \
      --exclude 'inference.log' --exclude 'autostart.log' \
      "$SRC_DIR"/ "$DST_DIR"/

  say "校验关键文件"
  local missing=0 f
  for f in server.py svc_engine.py utils.py models.py \
           configs/config.json configs/config_2602.json \
           logs/44k/G_129600.pth logs/44k/G_180000.pth \
           pretrain/checkpoint_best_legacy_500.pt; do
    if [ -s "$DST_DIR/$f" ]; then ok "$f"; else warn "缺失! $f"; missing=1; fi
  done
  [ "$missing" -eq 0 ] || die "关键文件缺失，无法推理"
  chmod +x "$DST_DIR"/*.sh 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 6. systemd 服务
# ---------------------------------------------------------------------------
stage_svc() {
  say "注册 systemd 服务 svc-inference"
  cat >/etc/systemd/system/svc-inference.service <<EOF
[Unit]
Description=AI Cover - So-VITS-SVC Inference Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$DST_DIR
Environment=USE_MOCK=0
Environment=SVC_BASE_DIR=$DST_DIR
Environment=INFERENCE_PORT=8081
# 注意：不要设 PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True —— 那是 torch>=2.1 的选项，
# torch 2.0.1 会直接抛 "Unrecognized CachingAllocator option" 导致首次 CUDA 调用失败。
Environment=PATH=/usr/lib/wsl/lib:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$VPY $DST_DIR/server.py
Restart=always
RestartSec=5
StandardOutput=append:/var/log/svc-inference.log
StandardError=append:/var/log/svc-inference.log

[Install]
WantedBy=multi-user.target
EOF

  # 兼容旧的自启脚本
  sed -i "s#^cd /opt/svc-inference\$#cd $DST_DIR#" "$DST_DIR/start_server.sh" 2>/dev/null || true
  sed -i "s#^LOG=/opt/svc-inference/autostart.log#LOG=$DST_DIR/autostart.log#" "$DST_DIR/autostart.sh" 2>/dev/null || true

  systemctl daemon-reload
  systemctl enable svc-inference >/dev/null 2>&1 || warn "enable 失败（WSL 里 systemd 没开？见 /etc/wsl.conf）"
  systemctl restart svc-inference
  sleep 6
  systemctl --no-pager --lines=15 status svc-inference || true
  ok "服务已启动（日志：/var/log/svc-inference.log）"
}

# ---------------------------------------------------------------------------
# 7. frp 内网穿透
# ---------------------------------------------------------------------------
stage_frp() {
  [ -n "$ECS_IP" ]    || die "未设置 ECS_IP（云端 frps 的公网 IP）。\n     在仓库根目录 .env 里写 ECS_IP=<你的IP>，或：ECS_IP=<你的IP> FRP_TOKEN=<你的token> bash install-wsl.sh frp"
  [ -n "$FRP_TOKEN" ] || die "未设置 FRP_TOKEN（frps/frpc 的 auth.token，两端必须一致）。\n     在仓库根目录 .env 里写 FRP_TOKEN=<你的token>，或：ECS_IP=<你的IP> FRP_TOKEN=<你的token> bash install-wsl.sh frp"
  say "配置 frp 穿透 -> $ECS_IP:7000 (remote :18081)"
  if ! command -v frpc >/dev/null 2>&1; then
    local tgz="frp_${FRP_VERSION}_linux_amd64.tar.gz"
    local url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${tgz}"
    say "下载 frp $FRP_VERSION"
    curl -fL --retry 3 --connect-timeout 20 "$url" -o "/tmp/$tgz" \
      || curl -fL --retry 3 "https://ghproxy.net/$url" -o "/tmp/$tgz" \
      || die "frp 下载失败，请手动下载后放到 /usr/local/bin/frpc"
    tar -xzf "/tmp/$tgz" -C /tmp
    install -m 0755 "/tmp/frp_${FRP_VERSION}_linux_amd64/frpc" /usr/local/bin/frpc
  fi

  mkdir -p /etc/frp
  cat >/etc/frp/frpc.toml <<EOF
serverAddr = "$ECS_IP"
serverPort = 7000
auth.method = "token"
auth.token = "$FRP_TOKEN"

[[proxies]]
name = "svc-inference"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8081
remotePort = 18081
EOF

  cat >/etc/systemd/system/frpc.service <<'EOF'
[Unit]
Description=frp client (AI Cover tunnel)
After=network-online.target svc-inference.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c /etc/frp/frpc.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now frpc
  sleep 4
  systemctl --no-pager --lines=15 status frpc || true
  ok "frpc 已启动（ECS 侧需已运行 frps，且安全组放行 7000）"
}

# ---------------------------------------------------------------------------
# 8. 验证
# ---------------------------------------------------------------------------
stage_verify() {
  say "健康检查 http://localhost:8081/api/health"
  local out=""
  for i in $(seq 1 20); do
    out=$(curl -s --max-time 5 http://localhost:8081/api/health || true)
    if [ -n "$out" ]; then break; fi
    sleep 3
  done
  [ -n "$out" ] || die "服务没起来，看 /var/log/svc-inference.log"
  echo "$out" | "$VPY" -m json.tool 2>/dev/null || echo "$out"

  say "生成 3 秒测试音频并跑一次真实推理（首次会加载模型，约 30~60s）"
  "$VPY" - <<'PY'
import numpy as np, soundfile as sf
sr = 44100
t = np.linspace(0, 3, sr*3, False)
wav = 0.2*np.sin(2*np.pi*220*t) + 0.1*np.sin(2*np.pi*440*t)
sf.write("/tmp/smoke_in.wav", wav.astype(np.float32), sr)
print("     /tmp/smoke_in.wav 已生成")
PY
  local code
  code=$(curl -s -o /tmp/smoke_out.wav -w '%{http_code}' --max-time 600 \
      -F "audio=@/tmp/smoke_in.wav" -F "voice_model=2602" -F "pitch_shift=0" \
      -F "task_id=smoke" http://localhost:8081/api/infer || echo 000)
  if [ "$code" = "200" ] && [ -s /tmp/smoke_out.wav ]; then
    ok "推理成功 -> /tmp/smoke_out.wav ($(du -h /tmp/smoke_out.wav | cut -f1))"
    "$VPY" -c "import soundfile as sf; d,sr=sf.read('/tmp/smoke_out.wav'); print('     输出时长 %.2fs @ %dHz'%(len(d)/sr,sr))"
  else
    warn "推理返回 HTTP $code —— 看 /var/log/svc-inference.log"
    tail -40 /var/log/svc-inference.log 2>/dev/null || true
    return 1
  fi

  echo
  ok "全部完成。"
  echo "     本机： curl http://localhost:8081/api/health"
  echo "     日志： tail -f /var/log/svc-inference.log"
  echo "     重启： systemctl restart svc-inference"
}

# ---------------------------------------------------------------------------
main() {
  echo -e "${BLU}"
  echo "  ============================================================"
  echo "   AI 翻唱 · 推理层安装  (WSL2 Ubuntu)"
  echo "   源码: $SRC_DIR"
  echo "   目标: $DST_DIR     阶段: ${STAGES[*]}"
  echo "  ============================================================"
  echo -e "${RST}"

  preflight
  if run_stage base;   then stage_base;   fi
  if run_stage pyenv;  then stage_pyenv;  fi
  if run_stage torch;  then stage_torch;  fi
  if run_stage deps;   then stage_deps;   fi
  if run_stage model;  then stage_model;  fi
  if run_stage svc;    then stage_svc;    fi
  if run_stage frp;    then stage_frp;    fi
  if run_stage verify; then stage_verify; fi
}

main
