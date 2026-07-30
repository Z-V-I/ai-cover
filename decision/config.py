"""
决策层配置文件
"""

import os

# ============================================
# API 安全
# ============================================
API_TOKEN = os.environ.get("API_TOKEN", "aicover-api-key-2026")

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
