# WSL2 GPU 推理镜像
# 构建: docker build -t svc-inference:latest .
# 运行: docker compose up -d

FROM nvidia/cuda:12.1.0-cudnn8-runtime-ubuntu22.04

ENV PYTHONUNBUFFERED=1
ENV DEBIAN_FRONTEND=noninteractive

# 系统依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.9 \
    python3.9-dev \
    python3-pip \
    ffmpeg \
    libsndfile1 \
    libsndfile1-dev \
    git \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --install /usr/bin/python python /usr/bin/python3.9 1 \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.9 1

WORKDIR /app

# ---- 第1层: PyTorch (体积大，优先缓存) ----
RUN pip3 install --no-cache-dir \
    torch==2.0.1 \
    torchaudio==2.0.2 \
    --index-url https://download.pytorch.org/whl/cu118

# ---- 第2层: so-vits-svc 依赖 ----
# fairseq 安装（ContentVec 编码器依赖）
RUN pip3 install --no-cache-dir \
    fairseq==0.12.2 \
    librosa==0.10.1 \
    soundfile==0.12.1 \
    numpy==1.24.3 \
    scipy==1.10.1 \
    pyworld==0.3.0 \
    praat-parselmouth \
    pyyaml \
    flask==3.0.0 \
    flask-cors==4.0.0 \
    tensorboardX

# ---- 第3层: 应用代码 (变动频繁，放最后) ----
COPY requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt

# 复制所有代码模块
COPY . /app/

# ---- 第4层: 模型文件 (大体积，构建时不打包，运行时挂载) ----
# 模型文件通过 docker-compose volumes 挂载 host 目录
# Dockerfile 里不 COPY，避免镜像膨胀到 4GB+

ENV SVC_BASE_DIR=/app
ENV USE_MOCK=0
ENV NVIDIA_VISIBLE_DEVICES=all

EXPOSE 8081

CMD ["python", "server.py"]
