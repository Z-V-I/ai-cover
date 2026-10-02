"""
决策层配置文件

注意：本文件不含任何真实密钥。所有敏感项都从环境变量读取
（仓库根目录的 `.env` 会被自动加载，见下方 _load_dotenv）。
复制 `.env.example` 为 `.env` 填入自己的值即可。
"""

import os
import sys


def _load_dotenv() -> None:
    """若仓库根目录存在 .env，则把里面的 K=V 注入环境变量（不覆盖已存在的）。"""
    env_path = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env"
    )
    if not os.path.isfile(env_path):
        return
    with open(env_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


_load_dotenv()

# ============================================
# API 安全
# ============================================
API_TOKEN = os.environ.get("API_TOKEN", "").strip()
if not API_TOKEN:
    sys.stderr.write(
        "\n[启动中止] 环境变量 API_TOKEN 未设置。\n"
        "  决策层用它校验前端请求头 X-API-Token；留空会让校验形同虚设，因此拒绝启动。\n"
        "  解决：cp .env.example .env 并填入随机串，或直接 export API_TOKEN='...'\n"
        "  生成随机串：python3 -c \"import secrets; print(secrets.token_urlsafe(32))\"\n\n"
    )
    raise SystemExit(1)

# ============================================
# 并发控制
# ============================================
MAX_QUEUE_SIZE = 20         # 最大排队人数（含处理中）
MAX_CONCURRENT = 2          # 最大并发处理数量

# ============================================
# 文件限制（5分钟以内歌曲的参考大小）
# ============================================
# 44.1kHz 16bit 单声道 WAV ≈ 10.5 MB/分钟
# 5分钟 ≈ 52.5 MB，取安全值 60MB
MAX_FILE_SIZE_BYTES = 60 * 1024 * 1024   # 60 MB

# 音频时长上限（秒）
MAX_AUDIO_DURATION_SECONDS = 300  # 5 分钟

# 允许的音频格式
ALLOWED_EXTENSIONS = {'.wav', '.mp3', '.flac', '.ogg', '.m4a', '.aac'}
ALLOWED_MIMETYPES = {
    'audio/wav', 'audio/x-wav', 'audio/wave',
    'audio/mpeg', 'audio/mp3',
    'audio/flac', 'audio/x-flac',
    'audio/ogg', 'audio/vorbis',
    'audio/mp4', 'audio/aac', 'audio/x-m4a',
    'application/octet-stream'
}

# ============================================
# 推理层配置
# ============================================
# 阿里云 FC 推理服务地址（部署后修改）
INFERENCE_BASE_URL = os.environ.get(
    "INFERENCE_BASE_URL",
    "http://localhost:8081"
)
INFERENCE_TIMEOUT = 600  # 推理超时时间（秒），长歌曲可能较慢

# ============================================
# 服务配置
# ============================================
DECISION_PORT = int(os.environ.get("DECISION_PORT", 5000))
UPLOAD_DIR = os.environ.get("UPLOAD_DIR", os.path.join(os.path.dirname(__file__), "uploads"))
RESULT_DIR = os.environ.get("RESULT_DIR", os.path.join(os.path.dirname(__file__), "results"))

# 确保目录存在
os.makedirs(UPLOAD_DIR, exist_ok=True)
os.makedirs(RESULT_DIR, exist_ok=True)
