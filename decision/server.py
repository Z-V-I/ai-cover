"""
决策层服务 - 核心服务器
功能：
  1. 接收用户上传音频
  2. 文件大小校验 -> 超限直接拒绝
  3. 音频时长校验（librosa/soundfile读取）-> 超时直接拒绝
  4. 排队队列管理（最多5人）-> 超出返回 HTTP 429
  5. 并发计数器控制 -> 最多2个并发推理
  6. 转发到推理层（阿里云FC或本地推理服务）
  7. 返回处理结果给前端
"""

import os
import uuid
import time
import json
import hashlib
import logging
import threading
from datetime import datetime
from pathlib import Path

import soundfile as sf
import requests
from flask import Flask, request, jsonify, send_file
from flask_cors import CORS

from config import (
    MAX_QUEUE_SIZE,
    MAX_CONCURRENT,
    MAX_FILE_SIZE_BYTES,
    MAX_AUDIO_DURATION_SECONDS,
    ALLOWED_EXTENSIONS,
    INFERENCE_BASE_URL,
    DECISION_PORT,
    UPLOAD_DIR,
    RESULT_DIR,
    INFERENCE_TIMEOUT
)

# ============================================
# 日志配置
# ============================================
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(os.path.join(os.path.dirname(__file__), 'decision.log'))
    ]
)
logger = logging.getLogger(__name__)

# ============================================
# Flask 初始化
# ============================================
app = Flask(__name__)
CORS(app)

# ============================================
# 队列与并发管理
# ============================================
# 任务存储：{task_id: {status, file_path, voice_model, ...}}
tasks_store = {}
tasks_lock = threading.Lock()

# 队列：简单的列表，存 task_id
task_queue = []
queue_lock = threading.Lock()

# 并发计数器
active_count = 0
active_lock = threading.Lock()

# ============================================
# 语音模型信息
# ============================================
VOICE_MODELS = {
    "2602": {
        "id": "2602",
        "name": "2602 (English)",
        "speaker_id": "2602",
        "model_path": "logs/44k/G_129600.pth",
        "description": "说话人2602 - 英文歌声模型，训练至129,600步",
        "trained_steps": 129600
    },
    "DASA": {
        "id": "DASA",
        "name": "DASA (4)",
        "speaker_id": "4",
        "model_path": "logs/44k/G_180000.pth",
        "description": "说话人DASA - 训练至180,000步",
        "trained_steps": 180000
    }
}


# ============================================
# 工具函数
# ============================================

def validate_file_size(file_size: int) -> tuple[bool, str]:
    """校验文件大小"""
    if file_size > MAX_FILE_SIZE_BYTES:
        max_mb = MAX_FILE_SIZE_BYTES / (1024 * 1024)
        actual_mb = file_size / (1024 * 1024)
        return False, f"文件大小 {actual_mb:.1f}MB 超出限制（最大 {max_mb:.0f}MB），请上传5分钟以内的音频文件"
    return True, ""


def validate_audio_duration(file_path: str) -> tuple[bool, str, float]:
    """
    使用 ffmpeg / soundfile 瞬间读取精确音频时长
    - WAV/FLAC/OGG 等: 用 soundfile（无需转换）
    - M4A/AAC/MP3 等: 用 ffmpeg probe（无需转码）
    返回: (是否通过, 消息, 时长的秒数)
    """
    duration = None

    # 第一选择: soundfile（适合 WAV/FLAC/OGG）
    try:
        info = sf.info(file_path)
        duration = info.duration
    except Exception:
        pass

    # 第二选择: ffmpeg probe（适合 M4A/MP3/AAC 等 soundfile 不支持的格式）
    if duration is None:
        try:
            import subprocess
            result = subprocess.run(
                ['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                 '-of', 'default=noprint_wrappers=1:nokey=1', file_path],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0 and result.stdout.strip():
                duration = float(result.stdout.strip())
        except (FileNotFoundError, subprocess.TimeoutExpired, ValueError) as e:
            logger.error(f"ffprobe 调用失败: {e}")
        except Exception as e:
            logger.error(f"读取音频时长失败: {e}")

    if duration is None:
        return False, "无法解析音频文件，请确认文件格式正确", 0.0

    if duration > MAX_AUDIO_DURATION_SECONDS:
        return False, f"音频时长 {duration:.1f}秒 超出限制（最大 {MAX_AUDIO_DURATION_SECONDS}秒），请上传5分钟以内的音频", duration
    if duration < 1.0:
        return False, f"音频时长 {duration:.1f}秒 过短，最少需要1秒", duration
    return True, "", duration


def validate_file_extension(filename: str) -> bool:
    """校验文件扩展名"""
    ext = Path(filename).suffix.lower()
    return ext in ALLOWED_EXTENSIONS


def get_audio_md5(file_path: str) -> str:
    """计算文件MD5（用于去重）"""
    hash_md5 = hashlib.md5()
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(4096), b""):
            hash_md5.update(chunk)
    return hash_md5.hexdigest()


def get_queue_position(task_id: str) -> int:
    """获取当前排队位置（1-based）"""
    with queue_lock:
        if task_id in task_queue:
            return task_queue.index(task_id) + 1
        return -1


def can_accept_new_task() -> bool:
    """检查是否可以接受新任务"""
    with queue_lock:
        with active_lock:
            # 排队中（含处理中）的总数 = 队列长度 + 正在处理的数量
            total = len(task_queue) + active_count
            return total < MAX_QUEUE_SIZE


def try_start_next_task():
    """尝试从队列中启动下一个任务"""
    global active_count
    with active_lock:
        with queue_lock:
            while active_count < MAX_CONCURRENT and task_queue:
                task_id = task_queue[0]
                # 检查任务是否处于 pending 状态
                with tasks_lock:
                    if tasks_store.get(task_id, {}).get("status") == "pending":
                        tasks_store[task_id]["status"] = "processing"
                        active_count += 1
                        task_queue.pop(0)
                        # 在新线程中处理
                        logger.info(f"启动任务 {task_id}，当前并发: {active_count}，队列剩余: {len(task_queue)}")
                        thread = threading.Thread(
                            target=process_task,
                            args=(task_id,),
                            daemon=True
                        )
                        thread.start()
                        return
                    else:
                        # 任务已被取消或状态异常，移出队列
                        task_queue.pop(0)


# ============================================
# 任务处理流程
# ============================================

def process_task(task_id: str):
    """处理单个任务（在独立线程中运行）"""
    global active_count
    
    try:
        with tasks_lock:
            task = tasks_store.get(task_id)
            if not task:
                return
        
        file_path = task["file_path"]
        voice_model = task["voice_model"]
        pitch_shift = task.get("pitch_shift", 0)
        
        # 更新状态
        with tasks_lock:
            tasks_store[task_id]["status"] = "processing"
            tasks_store[task_id]["progress"] = 10
            tasks_store[task_id]["message"] = "正在发送到推理引擎..."
        
        # 二次校验：精确音频时长
        is_valid, msg, duration = validate_audio_duration(file_path)
        if not is_valid:
            with tasks_lock:
                tasks_store[task_id]["status"] = "failed"
                tasks_store[task_id]["error"] = msg
            logger.warning(f"任务 {task_id} 音频时长校验失败: {msg}")
            return
        
        logger.info(f"任务 {task_id}: 音频时长 {duration:.1f}s, 语音模型 {voice_model}")
        
        with tasks_lock:
            tasks_store[task_id]["duration"] = duration
            tasks_store[task_id]["progress"] = 20
            tasks_store[task_id]["message"] = f"音频时长 {duration:.1f}秒，正在推理处理..."
            tasks_store[task_id]["estimated_time"] = int(duration * 1.5)  # 估算时间
        
        # 调用推理层
        result = call_inference_service(file_path, voice_model, pitch_shift, task_id)
        
        if result["success"]:
            output_path = result["output_path"]
            with tasks_lock:
                tasks_store[task_id]["status"] = "completed"
                tasks_store[task_id]["progress"] = 100
                tasks_store[task_id]["message"] = "处理完成！"
                tasks_store[task_id]["output_path"] = output_path
                tasks_store[task_id]["completed_at"] = time.time()
            logger.info(f"任务 {task_id} 完成")
        else:
            with tasks_lock:
                tasks_store[task_id]["status"] = "failed"
                tasks_store[task_id]["error"] = result.get("error", "推理服务返回未知错误")
            logger.error(f"任务 {task_id} 失败: {result.get('error')}")
    
    except Exception as e:
        logger.exception(f"任务 {task_id} 处理异常: {e}")
        with tasks_lock:
            if task_id in tasks_store:
                tasks_store[task_id]["status"] = "failed"
                tasks_store[task_id]["error"] = f"服务内部错误: {str(e)}"
    
    finally:
        # 释放并发槽位
        with active_lock:
            global active_count
            active_count = max(0, active_count - 1)
        
        # 尝试启动下一个任务
        try_start_next_task()


def call_inference_service(file_path: str, voice_model: str, pitch_shift: int, task_id: str) -> dict:
    """
    调用推理层服务（阿里云FC或本地推理服务）
    
    在实际部署中，这里会向阿里云FC发送HTTP请求。
    在本地开发模式下，直接调用本地推理服务。
    """
    logger.info(f"调用推理服务: model={voice_model}, file={file_path}")
    
    try:
        # 更新进度
        with tasks_lock:
            tasks_store[task_id]["progress"] = 30
            tasks_store[task_id]["message"] = "正在连接推理引擎..."
        
        # 准备请求数据
        with open(file_path, 'rb') as f:
            files = {'audio': (os.path.basename(file_path), f, 'audio/wav')}
            data = {
                'voice_model': voice_model,
                'pitch_shift': str(pitch_shift),
                'task_id': task_id
            }
            
            # 发送到推理层
            response = requests.post(
                f"{INFERENCE_BASE_URL}/api/infer",
                files=files,
                data=data,
                timeout=INFERENCE_TIMEOUT
            )
        
        if response.status_code == 200:
            # 保存推理结果
            output_filename = f"{task_id}_{voice_model}.wav"
            output_path = os.path.join(RESULT_DIR, output_filename)
            with open(output_path, 'wb') as f:
                f.write(response.content)
            
            logger.info(f"推理完成，输出保存至: {output_path}")
            return {"success": True, "output_path": output_path}
        
        else:
            error_msg = f"推理服务返回错误: HTTP {response.status_code}"
            try:
                error_detail = response.json()
                error_msg += f" - {error_detail.get('error', '')}"
            except:
                pass
            logger.error(error_msg)
            return {"success": False, "error": error_msg}
    
    except requests.exceptions.Timeout:
        return {"success": False, "error": "推理超时，请稍后重试"}
    except requests.exceptions.ConnectionError:
        return {"success": False, "error": "无法连接到推理服务，请检查服务是否启动"}
    except Exception as e:
        logger.exception(f"调用推理服务异常: {e}")
        return {"success": False, "error": f"推理服务调用失败: {str(e)}"}


# ============================================
# API 路由
# ============================================

@app.route('/api/health', methods=['GET'])
def health_check():
    """健康检查"""
    with queue_lock:
        queue_len = len(task_queue)
    with active_lock:
        active = active_count
    
    return jsonify({
        "status": "ok",
        "active_tasks": active,
        "queue_length": queue_len,
        "max_queue": MAX_QUEUE_SIZE,
        "models": list(VOICE_MODELS.keys())
    })


@app.route('/api/models', methods=['GET'])
def list_models():
    """获取可用语音模型列表"""
    return jsonify({
        "models": [
            {
                "id": m["id"],
                "name": m["name"],
                "description": m["description"],
                "trained_steps": m["trained_steps"]
            }
            for m in VOICE_MODELS.values()
        ]
    })


@app.route('/api/upload', methods=['POST'])
def upload_audio():
    """
    上传音频文件并排队处理
    
    流程：
      1. 校验文件是否存在
      2. 校验文件格式
      3. 校验文件大小 → 不合格直接拒绝
      4. 校验音频时长（soundfile） → 不合格直接拒绝
      5. 检查队列容量 → 满员返回 HTTP 429
      6. 创建任务并入队
    """
    # ---- 1. 校验文件 ----
    if 'audio' not in request.files:
        return jsonify({"error": "请上传音频文件"}), 400
    
    file = request.files['audio']
    if file.filename == '':
        return jsonify({"error": "文件名为空"}), 400
    
    # ---- 2. 校验格式 ----
    if not validate_file_extension(file.filename):
        ext = Path(file.filename).suffix.lower()
        allowed = ', '.join(ALLOWED_EXTENSIONS)
        return jsonify({
            "error": f"不支持的音频格式 '{ext}'，支持格式: {allowed}"
        }), 400
    
    # ---- 3. 获取语音模型 ----
    voice_model = request.form.get('voice_model', '2602')
    if voice_model not in VOICE_MODELS:
        return jsonify({
            "error": f"不支持的语音模型 '{voice_model}'，可选: {list(VOICE_MODELS.keys())}"
        }), 400
    
    pitch_shift = int(request.form.get('pitch_shift', 0))
    if pitch_shift < -12 or pitch_shift > 12:
        return jsonify({"error": "音高调整范围应在 -12 到 +12 半音之间"}), 400
    
    # ---- 4. 读取文件内容并校验大小 ----
    file_data = file.read()
    file_size = len(file_data)
    
    is_valid, msg = validate_file_size(file_size)
    if not is_valid:
        return jsonify({"error": msg, "code": "FILE_TOO_LARGE"}), 413
    
    # ---- 5. 生成任务ID并保存文件 ----
    task_id = str(uuid.uuid4())
    file_ext = Path(file.filename).suffix.lower()
    save_path = os.path.join(UPLOAD_DIR, f"{task_id}{file_ext}")

    with open(save_path, 'wb') as f:
        f.write(file_data)

    # ---- 6. 音频时长校验（soundfile 或 ffprobe） ----
    is_valid, msg, duration = validate_audio_duration(save_path)
    if not is_valid:
        # 删除文件
        try:
            os.remove(save_path)
        except:
            pass
        return jsonify({"error": msg, "code": "DURATION_INVALID"}), 400

    # ---- 6.5 非 WAV 格式自动转换为 WAV（保证推理层兼容） ----
    wav_path = save_path
    if file_ext.lower() != '.wav':
        wav_path = os.path.join(UPLOAD_DIR, f"{task_id}_converted.wav")
        try:
            import subprocess
            result = subprocess.run(
                ['ffmpeg', '-y', '-i', save_path, '-ar', '44100', '-ac', '1', wav_path],
                capture_output=True, timeout=60
            )
            if result.returncode == 0 and os.path.exists(wav_path):
                os.remove(save_path)  # 删除原文件
                save_path = wav_path
                logger.info(f"已将 {file_ext} 转换为 WAV: {wav_path}")
            else:
                os.remove(wav_path) if os.path.exists(wav_path) else None
                os.remove(save_path) if os.path.exists(save_path) else None
                return jsonify({"error": f"音频格式转换失败"}), 400
        except Exception as e:
            logger.error(f"ffmpeg 转换失败: {e}")
            return jsonify({"error": f"音频处理失败: {str(e)}"}), 400
    
    logger.info(f"收到上传: task_id={task_id}, model={voice_model}, "
                f"file={file.filename}, size={file_size/1024/1024:.1f}MB, duration={duration:.1f}s")
    
    # ---- 7. 检查队列容量 + 入队（原子操作，防并发绕过） ----
    with queue_lock:
        with active_lock:
            total = len(task_queue) + active_count
        if total >= MAX_QUEUE_SIZE:
            try:
                os.remove(save_path)
            except:
                pass
            return jsonify({
                "error": "当前排队人数已满，请稍后再来！",
                "code": "QUEUE_FULL",
                "retry_after": 30
            }), 429
        
        task_queue.append(task_id)
        position = len(task_queue)
    
    # ---- 8. 创建任务 ----
    task_info = {
        "task_id": task_id,
        "status": "pending",
        "progress": 0,
        "message": "已加入排队...",
        "file_path": save_path,
        "original_filename": file.filename,
        "file_size": file_size,
        "duration": duration,
        "voice_model": voice_model,
        "pitch_shift": pitch_shift,
        "created_at": time.time(),
        "completed_at": None,
        "output_path": None,
        "error": None,
        "estimated_time": int(duration * 1.5)
    }
    
    with tasks_lock:
        tasks_store[task_id] = task_info
    
    logger.info(f"任务 {task_id} 入队，位置: {position}/{MAX_QUEUE_SIZE}，排队人数: {position}")
    
    if position == 1:
        response_data = {
            "task_id": task_id,
            "status": "pending",
            "position": position,
            "message": "正在排队处理...",
            "estimated_time": task_info["estimated_time"],
            "voice_model": voice_model,
            "model_name": VOICE_MODELS[voice_model]["name"]
        }
    else:
        response_data = {
            "task_id": task_id,
            "status": "pending",
            "position": position,
            "message": f"前方还有 {position - 1} 人排队，预计等待 {task_info['estimated_time'] * position} 秒",
            "estimated_time": task_info["estimated_time"],
            "voice_model": voice_model,
            "model_name": VOICE_MODELS[voice_model]["name"]
        }
    
    # 延迟 5 秒启动，让前端有时间轮询显示"排队中"
    threading.Timer(5.0, try_start_next_task).start()
    
    return jsonify(response_data), 202


@app.route('/api/status/<task_id>', methods=['GET'])
def get_task_status(task_id: str):
    """
    轮询任务状态
    
    返回任务进度、排队位置、状态等信息
    """
    with tasks_lock:
        task = tasks_store.get(task_id)
    
    if not task:
        return jsonify({"error": "任务不存在"}), 404
    
    position = get_queue_position(task_id)
    
    response = {
        "task_id": task_id,
        "status": task["status"],
        "progress": task.get("progress", 0),
        "message": task.get("message", ""),
        "position": position,
        "voice_model": task.get("voice_model"),
        "model_name": VOICE_MODELS.get(task.get("voice_model", ""), {}).get("name", ""),
        "estimated_time": task.get("estimated_time", 0),
        "duration": task.get("duration", 0),
        "created_at": task.get("created_at"),
    }
    
    if task["status"] == "failed":
        response["error"] = task.get("error", "未知错误")
    
    if task["status"] == "completed":
        response["download_url"] = f"/api/download/{task_id}"
        response["completed_at"] = task.get("completed_at")
    
    return jsonify(response)


@app.route('/api/download/<task_id>', methods=['GET'])
def download_result(task_id: str):
    """下载处理完成的音频文件"""
    with tasks_lock:
        task = tasks_store.get(task_id)
    
    if not task:
        return jsonify({"error": "任务不存在"}), 404
    
    if task["status"] != "completed":
        return jsonify({"error": "任务尚未完成"}), 400
    
    output_path = task.get("output_path")
    if not output_path or not os.path.exists(output_path):
        return jsonify({"error": "输出文件不存在，可能已被清理"}), 404
    
    # 生成下载文件名
    voice_model = task.get("voice_model", "unknown")
    download_name = f"ai_cover_{voice_model}_{task_id[:8]}.wav"
    
    return send_file(
        output_path,
        mimetype='audio/wav',
        as_attachment=True,
        download_name=download_name
    )


@app.route('/api/cancel/<task_id>', methods=['POST'])
def cancel_task(task_id: str):
    """取消排队中的任务"""
    with tasks_lock:
        task = tasks_store.get(task_id)
    
    if not task:
        return jsonify({"error": "任务不存在"}), 404
    
    if task["status"] not in ("pending",):
        return jsonify({"error": "只能取消排队中的任务"}), 400
    
    # 从队列中移除
    with queue_lock:
        if task_id in task_queue:
            task_queue.remove(task_id)
    
    # 删除上传的文件
    try:
        os.remove(task["file_path"])
    except:
        pass
    
    with tasks_lock:
        tasks_store[task_id]["status"] = "cancelled"
        tasks_store[task_id]["message"] = "任务已取消"
    
    # 尝试启动下一个任务
    try_start_next_task()
    
    return jsonify({"message": "任务已取消"})


@app.route('/api/queue_status', methods=['GET'])
def get_queue_status():
    """获取队列整体状态"""
    with queue_lock:
        queue_len = len(task_queue)
    with active_lock:
        active = active_count
    
    # 返回完整的服务器状态
    return jsonify({
        "active_tasks": active,
        "max_concurrent": MAX_CONCURRENT,
        "queue_length": queue_len,
        "max_queue": MAX_QUEUE_SIZE,
        "available_slots": MAX_QUEUE_SIZE - (queue_len + active),
        "is_full": (queue_len + active) >= MAX_QUEUE_SIZE
    })


# ============================================
# 定期清理任务（避免内存泄漏）
# ============================================

def cleanup_old_tasks():
    """清理超过1小时的已完成任务"""
    while True:
        time.sleep(300)  # 每5分钟清理一次
        now = time.time()
        with tasks_lock:
            to_delete = []
            for tid, task in tasks_store.items():
                if task["status"] in ("completed", "failed", "cancelled"):
                    if task.get("completed_at", 0) > 0:
                        if now - task["completed_at"] > 3600:  # 1小时
                            to_delete.append(tid)
                    elif now - task.get("created_at", 0) > 7200:  # 2小时
                        to_delete.append(tid)
            
            for tid in to_delete:
                task = tasks_store[tid]
                # 清理文件
                if task.get("file_path") and os.path.exists(task["file_path"]):
                    try:
                        os.remove(task["file_path"])
                    except:
                        pass
                if task.get("output_path") and os.path.exists(task["output_path"]):
                    try:
                        os.remove(task["output_path"])
                    except:
                        pass
                del tasks_store[tid]
            
            if to_delete:
                logger.info(f"清理了 {len(to_delete)} 个过期任务")


# ============================================
# 启动
# ============================================

if __name__ == '__main__':
    # 启动清理线程
    cleanup_thread = threading.Thread(target=cleanup_old_tasks, daemon=True)
    cleanup_thread.start()
    
    logger.info(f"决策层服务启动于端口 {DECISION_PORT}")
    logger.info(f"最大排队人数: {MAX_QUEUE_SIZE}, 最大并发: {MAX_CONCURRENT}")
    logger.info(f"可用语音模型: {list(VOICE_MODELS.keys())}")
    
    app.run(host='0.0.0.0', port=DECISION_PORT, debug=False, threaded=True)
