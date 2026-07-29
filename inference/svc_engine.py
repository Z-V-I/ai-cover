"""
推理层 - SVC 推理引擎封装

基于 so-vits-svc 4.0 的推理逻辑封装。
支持两个说话人模型：
  - 2602 (speaker_id=2602, G_129600.pth)
  - DASA  (speaker_id=4,     G_180000.pth)

推理流程：
  1. 接收音频文件
  2. 使用 slicer.cut() 进行静音切片
  3. 逐段送入 Svc 模型推理
  4. 拼接结果并返回
"""

import os
import io
import time
import logging
import numpy as np
import soundfile as sf

# so-vits-svc 模块（需在部署环境中可用）
try:
    import librosa
    import torch
    HAS_SVC = True
except ImportError:
    HAS_SVC = False

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


# ============================================
# 模型配置
# ============================================
# 基础路径：部署时指向项目根目录
BASE_DIR = os.environ.get("SVC_BASE_DIR", os.path.dirname(os.path.abspath(__file__)))

MODEL_CONFIGS = {
    "2602": {
        "speaker_id": "2602",
        "model_path": "logs/44k/G_129600.pth",
        "config_path": "configs/config_2602.json",
        "cluster_model_path": "logs/44k/kmeans_10000.pt",
        "diffusion_model_path": "logs/44k/diffusion/model_0.pt",
        "diffusion_config_path": "configs/diffusion.yaml",
        "description": "说话人2602 (129,600步)",
    },
    "DASA": {
        "speaker_id": "4",
        "model_path": "logs/44k/G_180000.pth",
        "config_path": "configs/config.json",
        "cluster_model_path": "logs/44k/kmeans_10000.pt",
        "diffusion_model_path": "logs/44k/diffusion/model_0.pt",
        "diffusion_config_path": "configs/diffusion.yaml",
        "description": "说话人DASA (180,000步)",
    }
}


class SVCEngine:
    """
    SVC 推理引擎
    
    管理两个语音模型的加载与推理。
    在阿里云 FC 上，模型文件通过 NAS 或 OSS 挂载。
    本地开发时，直接使用项目目录下的模型文件。
    """
    
    def __init__(self, base_dir: str = None):
        self.base_dir = base_dir or BASE_DIR
        self.models = {}  # 缓存已加载的模型: {model_id: Svc_instance}
        self.device = None
    
    def _get_device(self):
        """获取推理设备"""
        if self.device is None:
            if torch.cuda.is_available():
                self.device = torch.device("cuda")
                logger.info("使用 GPU (CUDA) 推理")
            else:
                self.device = torch.device("cpu")
                logger.info("使用 CPU 推理")
        return self.device
    
    def _resolve_path(self, relative_path: str) -> str:
        """解析相对路径为绝对路径"""
        full_path = os.path.join(self.base_dir, relative_path)
        return full_path
    
    def load_model(self, model_id: str):
        """
        加载指定的语音模型
        
        Args:
            model_id: "2602" 或 "DASA"
        """
        if model_id not in MODEL_CONFIGS:
            raise ValueError(f"不支持的模型: {model_id}，可选: {list(MODEL_CONFIGS.keys())}")
        
        # 检查是否已缓存
        if model_id in self.models:
            logger.info(f"模型 {model_id} 已缓存，复用")
            return self.models[model_id]
        
        # 卸载其他模型释放显存 (12G显存放不下两个模型)
        for other_id in list(self.models.keys()):
            if other_id != model_id:
                logger.info(f"卸载模型 {other_id} 以释放显存...")
                try:
                    self.models[other_id].unload_model()
                except:
                    pass
                del self.models[other_id]
                import torch
                torch.cuda.empty_cache()
                logger.info(f"模型 {other_id} 已卸载")
        
        config = MODEL_CONFIGS[model_id]
        
        # 检查模型文件是否存在
        model_path = self._resolve_path(config["model_path"])
        config_path = self._resolve_path(config["config_path"])
        
        if not os.path.exists(model_path):
            raise FileNotFoundError(f"模型文件不存在: {model_path}")
        if not os.path.exists(config_path):
            raise FileNotFoundError(f"配置文件不存在: {config_path}")
        
        logger.info(f"加载模型 {model_id} ({config['description']})...")
        logger.info(f"  模型文件: {model_path}")
        logger.info(f"  配置文件: {config_path}")
        
        try:
            from inference.infer_tool import Svc
            
            device = self._get_device()
            svc_model = Svc(
                net_g_path=model_path,
                config_path=config_path,
                device=device,
                cluster_model_path=self._resolve_path(config.get("cluster_model_path", "")),
                nsf_hifigan_enhance=False,
                diffusion_model_path=self._resolve_path(config.get("diffusion_model_path", "")),
                diffusion_config_path=self._resolve_path(config.get("diffusion_config_path", "")),
                shallow_diffusion=False,
                only_diffusion=False,
            )
            
            self.models[model_id] = svc_model
            logger.info(f"模型 {model_id} 加载完成")
            return svc_model
            
        except Exception as e:
            logger.exception(f"加载模型 {model_id} 失败: {e}")
            raise
    
    def infer(self, audio_path: str, model_id: str, pitch_shift: int = 0,
              f0_predictor: str = "pm", noice_scale: float = 0.4,
              slice_db: int = -40) -> tuple:
        """
        执行推理
        
        Args:
            audio_path: 输入音频文件路径
            model_id: 语音模型ID ("2602" 或 "DASA")
            pitch_shift: 音高调整（半音）
            f0_predictor: F0预测器 (pm/crepe/harvest/dio)
            noice_scale: 噪声级别
            slice_db: 静音切片阈值
        
        Returns:
            (audio_array, sample_rate)
        """
        config = MODEL_CONFIGS[model_id]
        speaker_id = config["speaker_id"]
        
        # 加载模型
        svc_model = self.load_model(model_id)
        
        logger.info(f"开始推理: 模型={model_id}, 说话人={speaker_id}, 音高调整={pitch_shift}")
        start_time = time.time()
        
        try:
            # 使用 slice_inference 进行自动切片推理
            # clip_seconds=15: 强制每段不超过15秒，172秒音频切成12段，避免OOM
            # slice_db=-30: 提高检测灵敏度（原-40太宽松，连续唱歌无法切分）
            audio = svc_model.slice_inference(
                raw_audio_path=audio_path,
                spk=speaker_id,
                tran=pitch_shift,
                slice_db=-30,
                cluster_infer_ratio=0,
                auto_predict_f0=False,
                noice_scale=noice_scale,
                pad_seconds=0.5,
                clip_seconds=15,
                lg_num=0,
                lgr_num=0.75,
                f0_predictor=f0_predictor,
                enhancer_adaptive_key=0,
                cr_threshold=0.05,
                k_step=100
            )
            
            elapsed = time.time() - start_time
            logger.info(f"推理完成: 耗时 {elapsed:.2f}s, "
                       f"输出长度 {len(audio)/svc_model.target_sample:.1f}s")
            
            return audio, svc_model.target_sample
            
        except Exception as e:
            logger.exception(f"推理失败: {e}")
            raise
        finally:
            svc_model.clear_empty()
    
    def unload_model(self, model_id: str = None):
        """卸载模型释放内存"""
        if model_id:
            if model_id in self.models:
                self.models[model_id].unload_model()
                del self.models[model_id]
                logger.info(f"模型 {model_id} 已卸载")
        else:
            for mid in list(self.models.keys()):
                self.models[mid].unload_model()
                del self.models[mid]
            self.models.clear()
            logger.info("所有模型已卸载")


# ============================================
# 模拟推理引擎（无 GPU 环境下使用）
# ============================================

class MockSVCEngine:
    """
    模拟推理引擎 - 用于无 GPU 环境的开发测试
    
    生成简单的音色变化模拟输出（实际不会进行真正的推理）。
    """
    
    def __init__(self):
        logger.warning("使用模拟推理引擎，不会产生真正的音色转换效果")
    
    def infer(self, audio_path: str, model_id: str, pitch_shift: int = 0, **kwargs) -> tuple:
        """模拟推理：对原音频进行简单的音高变换"""
        logger.info(f"[模拟] 推理: 模型={model_id}, 音高调整={pitch_shift}")
        
        # 读取音频
        audio, sr = sf.read(audio_path)
        
        # 确保是单声道
        if len(audio.shape) > 1:
            audio = np.mean(audio, axis=1)
        
        # 模拟处理延迟
        duration = len(audio) / sr
        mock_time = duration * 0.5  # 模拟处理时间
        logger.info(f"[模拟] 音频时长: {duration:.1f}s, 模拟处理耗时: {mock_time:.1f}s")
        time.sleep(min(mock_time, 10))  # 最多等10秒
        
        # 对音频做简单的音高变换（使用 librosa）
        try:
            import librosa
            if pitch_shift != 0:
                audio = librosa.effects.pitch_shift(
                    audio, sr=sr, n_steps=pitch_shift
                )
        except ImportError:
            logger.warning("librosa 未安装，跳过音高变换")
        
        logger.info(f"[模拟] 推理完成")
        return audio, sr


# ============================================
# 工厂函数
# ============================================

_engine_instance = None

def get_engine(use_mock: bool = False) -> object:
    """获取推理引擎实例（单例）"""
    global _engine_instance
    
    if _engine_instance is None:
        if use_mock or not HAS_SVC:
            _engine_instance = MockSVCEngine()
        else:
            _engine_instance = SVCEngine()
    
    return _engine_instance
