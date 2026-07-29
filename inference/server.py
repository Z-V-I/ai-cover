"""
推理层服务 - 阿里云 FC 兼容

功能：
  1. 接收决策层转发的音频文件
  2. 根据指定的说话人模型进行音色转换推理
  3. 使用 slicer.cut() 进行静音切片
  4. 返回转换后的音频文件

部署方式：
  - 本地开发：python server.py
  - 阿里云 FC：使用 handler.py 作为入口
  - 模型文件通过 NAS / OSS 挂载

两个语音模型：
  - 2602: speaker_id=2602, G_129600.pth (129,600步)
  - DASA: speaker_id=4, G_180000.pth (180,000步)
"""

import os
import io
import sys
import time
import logging
import tempfile
import traceback

import soundfile as sf
import numpy as np
from flask import Flask, request, jsonify, send_file
from flask_cors import CORS

# 推理引擎导入
from svc_engine import get_engine, MODEL_CONFIGS

# ============================================
# 配置
# ============================================
INFERENCE_PORT = int(os.environ.get("INFERENCE_PORT", 8081))
USE_MOCK = os.environ.get("USE_MOCK", "1").lower() in ("1", "true", "yes")
SVC_BASE_DIR = os.environ.get("SVC_BASE_DIR", os.path.dirname(os.path.abspath(__file__)))

# ============================================
# 日志
# ============================================
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(os.path.join(os.path.dirname(__file__), 'inference.log'))
    ]
)
logger = logging.getLogger(__name__)

# ============================================
# Flask 初始化
# ============================================
app = Flask(__name__)
CORS(app)

# 推理引擎初始化（延迟加载）
engine = None


def init_engine():
    """初始化推理引擎"""
    global engine
    if engine is None:
        logger.info(f"初始化推理引擎 (USE_MOCK={USE_MOCK})")
        logger.info(f"可用模型: {list(MODEL_CONFIGS.keys())}")
        engine = get_engine(use_mock=USE_MOCK)
        # 不预加载，按需加载避免同时占满显存


# ============================================
# API 路由
# ============================================

@app.route('/api/health', methods=['GET'])
def health_check():
    """健康检查"""
    return jsonify({
        "status": "ok",
        "models": list(MODEL_CONFIGS.keys()),
        "mock_mode": USE_MOCK,
        "svc_base_dir": SVC_BASE_DIR
    })


@app.route('/api/infer', methods=['POST'])
def infer():
    """
    推理接口
    
    接收音频文件，进行音色转换推理。
    
    参数:
      - audio: 音频文件 (multipart/form-data)
      - voice_model: 语音模型ID ("2602" 或 "DASA")
      - pitch_shift: 音高调整（半音，默认0）
      - task_id: 任务ID（用于日志追踪）
    
    返回:
      - 成功: 转换后的 WAV 音频文件
      - 失败: JSON 错误信息
    """
    # 确保引擎已初始化
    init_engine()
    
    # ---- 1. 校验文件 ----
    if 'audio' not in request.files:
        return jsonify({"error": "缺少音频文件"}), 400
    
    file = request.files['audio']
    if file.filename == '':
        return jsonify({"error": "文件名为空"}), 400
    
    # ---- 2. 提取参数 ----
    voice_model = request.form.get('voice_model', '2602')
    pitch_shift = int(request.form.get('pitch_shift', 0))
    task_id = request.form.get('task_id', 'unknown')
    
    # 校验语音模型
    if voice_model not in MODEL_CONFIGS:
        return jsonify({
            "error": f"不支持的语音模型 '{voice_model}'，可选: {list(MODEL_CONFIGS.keys())}"
        }), 400
    
    # 校验音高范围
    if pitch_shift < -12 or pitch_shift > 12:
        return jsonify({"error": "音高调整范围应在 -12 到 +12 半音之间"}), 400
    
    logger.info(f"收到推理请求: task={task_id}, model={voice_model}, pitch={pitch_shift}")
    
    # ---- 3. 保存上传的音频到临时文件 ----
    try:
        file_data = file.read()
        
        # 创建临时文件
        with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as tmp:
            tmp_path = tmp.name
            
        # 先用 soundfile 读取确保格式正确，再保存为标准 WAV
        try:
            audio_data, sr = sf.read(io.BytesIO(file_data))
            sf.write(tmp_path, audio_data, sr)
        except Exception:
            # 如果 soundfile 读取失败，尝试直接写文件
            with open(tmp_path, 'wb') as f:
                f.write(file_data)
        
        logger.info(f"音频已保存: {tmp_path}, size={len(file_data)/1024:.1f}KB")
        
        # ---- 4. 执行推理 ----
        start_time = time.time()
        
        result_audio, output_sr = engine.infer(
            audio_path=tmp_path,
            model_id=voice_model,
            pitch_shift=pitch_shift,
            f0_predictor="pm",
            noice_scale=0.4,
            slice_db=-40
        )
        
        elapsed = time.time() - start_time
        
        # ---- 5. 写入输出缓冲 ----
        output_buffer = io.BytesIO()
        
        # 确保音频是 float32 且在 [-1, 1] 范围内
        if isinstance(result_audio, np.ndarray):
            audio_to_write = result_audio.astype(np.float32)
            # 裁剪到合理范围
            audio_to_write = np.clip(audio_to_write, -1.0, 1.0)
        else:
            audio_to_write = result_audio
        
        sf.write(output_buffer, audio_to_write, output_sr, format='WAV', subtype='PCM_16')
        output_buffer.seek(0)
        
        output_size = output_buffer.getbuffer().nbytes
        logger.info(f"推理完成: task={task_id}, 耗时={elapsed:.2f}s, "
                   f"输出大小={output_size/1024:.1f}KB, 采样率={output_sr}")
        
        # ---- 6. 返回结果 ----
        response = send_file(
            output_buffer,
            mimetype='audio/wav',
            as_attachment=True,
            download_name=f"output_{voice_model}.wav"
        )
        
        return response
    
    except Exception as e:
        logger.exception(f"推理异常: task={task_id}, error={e}")
        return jsonify({
            "error": f"推理失败: {str(e)}",
            "traceback": traceback.format_exc()[:500]
        }), 500
    
    finally:
        # 清理临时文件
        if 'tmp_path' in locals() and os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except:
                pass


@app.route('/api/models', methods=['GET'])
def list_models():
    """列出可用模型"""
    return jsonify({
        "models": [
            {
                "id": mid,
                "speaker_id": cfg["speaker_id"],
                "description": cfg["description"],
                "model_path": cfg["model_path"],
                "trained_steps": cfg.get("trained_steps", "unknown")
            }
            for mid, cfg in MODEL_CONFIGS.items()
        ]
    })


# ============================================
# 阿里云 FC 入口
# ============================================

def handler(event, context):
    """
    阿里云函数计算 HTTP 触发器入口
    
    部署到 FC 时，将此函数配置为入口函数。
    """
    from flask import request as flask_request
    init_engine()
    
    # FC 会将 HTTP 请求转换为 event
    # 使用 wsgi 适配器
    return app(event, context)


# ============================================
# 启动
# ============================================

if __name__ == '__main__':
    init_engine()
    logger.info(f"推理层服务启动于端口 {INFERENCE_PORT}")
    logger.info(f"模拟模式: {USE_MOCK}")
    app.run(host='0.0.0.0', port=INFERENCE_PORT, debug=False, threaded=False)
