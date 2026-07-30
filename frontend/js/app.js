/**
 * AI 翻唱 - 前端逻辑
 */

const API_BASE = window.API_BASE || '';
const POLL_INTERVAL = 2000;
const API_TOKEN = 'aicover-api-key-2026';

function apiFetch(url, options = {}) {
    options.headers = options.headers || {};
    options.headers['X-API-Token'] = API_TOKEN;
    return fetch(API_BASE + url, options);
}

let appState = { selectedModel: null, selectedFile: null, fileDuration: null, currentTaskId: null, pollTimer: null, models: [] };

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => document.querySelectorAll(sel);

document.addEventListener('DOMContentLoaded', () => {
    initUpload();
    loadModels();
    checkServerHealth();
    setInterval(checkServerHealth, 10000);
});

async function checkServerHealth() {
    try {
        const res = await apiFetch('/api/health');
        const data = await res.json();
        updateServerStatus(true, data);
        updateQueueBar(data);
    } catch (e) {
        updateServerStatus(false);
    }
}

function updateServerStatus(online, data) {
    const dot = $('.status-dot');
    const text = $('.status-text');
    if (online) {
        dot.className = 'status-dot online';
        text.textContent = data ? '在线 | 排队 ' + (data.queue_length||0) + '/' + (data.max_queue||20) : '在线';
    } else {
        dot.className = 'status-dot offline';
        text.textContent = '离线';
    }
}

function updateQueueBar(data) {
    if (!data) return;
    const total = (data.active_tasks||0) + (data.queue_length||0);
    const max = data.max_queue||20;
    $('#queueCount').textContent = total;
    $('#activeCount').textContent = data.active_tasks||0;
    $('#queueFill').style.width = Math.min((total/max)*100, 100) + '%';
}

async function loadModels() {
    try {
        const res = await apiFetch('/api/models');
        const data = await res.json();
        appState.models = data.models || [];
        renderModels(data.models || []);
    } catch (e) {
        showToast('无法加载语音模型列表', 'error');
    }
}

function renderModels(models) {
    const container = $('#modelCards');
    if (!models.length) {
        container.innerHTML = '<div class="model-card loading">暂无可用模型</div>';
        return;
    }
    container.innerHTML = models.map(m => `
        <div class="model-card" data-model="${m.id}" onclick="selectModel('${m.id}')">
            <div class="check-mark">&#10003;</div>
            <div class="model-name">${escapeHtml(m.name)}</div>
            <div class="model-desc">${escapeHtml(m.description||'')}</div>
            <div class="model-stats">${m.trained_steps?.toLocaleString()||'?'} 步</div>
        </div>
    `).join('');
}

function selectModel(modelId) {
    appState.selectedModel = modelId;
    $$('.model-card').forEach(c => c.classList.toggle('selected', c.dataset.model === modelId));
    updateSubmitButton();
}

function initUpload() {
    const ua = $('#uploadArea');
    const fi = $('#fileInput');
    ua.addEventListener('click', () => fi.click());
    fi.addEventListener('change', (e) => handleFile(e.target.files[0]));
    ua.addEventListener('dragover', (e) => { e.preventDefault(); ua.classList.add('drag-over'); });
    ua.addEventListener('dragleave', () => ua.classList.remove('drag-over'));
    ua.addEventListener('drop', (e) => { e.preventDefault(); ua.classList.remove('drag-over'); if (e.dataTransfer.files.length) handleFile(e.dataTransfer.files[0]); });

    const ps = $('#pitchSlider'), pv = $('#pitchValue');
    ps.addEventListener('input', () => pv.textContent = ps.value);
    $('#pitchDown').addEventListener('click', () => { const v = Math.max(-12, +ps.value - 1); ps.value = v; pv.textContent = v; });
    $('#pitchUp').addEventListener('click', () => { const v = Math.min(12, +ps.value + 1); ps.value = v; pv.textContent = v; });
    $('#btnRemove').addEventListener('click', removeFile);
    $('#btnSubmit').addEventListener('click', submitTask);
    $('#btnRetry').addEventListener('click', resetAll);
}

function handleFile(file) {
    if (!file) return;
    const allowed = ['.wav','.mp3','.flac','.ogg','.m4a','.aac'];
    const ext = '.' + file.name.split('.').pop().toLowerCase();
    if (!allowed.includes(ext)) return showToast('不支持的音频格式', 'error');
    if (file.size > 60*1024*1024) return showToast('文件过大（' + (file.size/1e6).toFixed(1) + ' MB），最大 60 MB', 'error');

    appState.selectedFile = file;
    $('#fileName').textContent = file.name;
    $('#fileSize').textContent = formatSize(file.size);
    $('#fileDuration').textContent = estDuration(file);
    $('#fileInfo').style.display = 'block';
    $('#paramsSection').style.display = 'block';
    $('#uploadArea').style.display = 'none';
    hideError(); hideDownloadSection();
    updateSubmitButton();
}

function removeFile() {
    appState.selectedFile = null;
    $('#fileInfo').style.display = 'none';
    $('#paramsSection').style.display = 'none';
    $('#uploadArea').style.display = 'block';
    $('#fileInput').value = '';
    $('#btnSubmit').disabled = true;
    hideError();
}

function estDuration(file) {
    const ext = '.' + file.name.split('.').pop().toLowerCase();
    let sec;
    if (ext === '.wav') sec = file.size / (44100*2);
    else if (ext === '.mp3') sec = file.size / 16000;
    else sec = file.size / 20000;
    const m = Math.floor(sec/60), s = Math.floor(sec%60);
    return '约 ' + m + ':' + String(s).padStart(2,'0');
}

function updateSubmitButton() {
    $('#btnSubmit').disabled = !(appState.selectedModel && appState.selectedFile);
}

async function submitTask() {
    if (!appState.selectedFile || !appState.selectedModel) return;
    hideError(); hideDownloadSection();

    const btn = $('#btnSubmit');
    btn.disabled = true;
    btn.textContent = '提交中...';

    setStage('stageUpload', 'active');

    const fd = new FormData();
    fd.append('audio', appState.selectedFile);
    fd.append('voice_model', appState.selectedModel);
    fd.append('pitch_shift', $('#pitchSlider').value);

    try {
        const res = await apiFetch('/api/upload', { method: 'POST', body: fd });
        const data = await res.json();

        if (res.status === 429) { showError('排队人数已满，请稍后再试。'); resetSubmitBtn(); setStage('stageUpload', ''); return; }
        if (res.status === 413) { showError(data.error); resetSubmitBtn(); removeFile(); return; }
        if (!res.ok) { showError(data.error); resetSubmitBtn(); return; }

        appState.currentTaskId = data.task_id;
        setStage('stageUpload', 'done');
        setStage('stageQueue', 'active');

        $('#statusSection').style.display = 'block';
        $('#detailTaskId').textContent = data.task_id.substring(0,8);
        $('#statusModel').textContent = data.model_name || '';
        updateStatusBadge('排队中', '');

        $('#uploadArea').style.display = 'none';
        $('#paramsSection').style.display = 'none';
        btn.textContent = '已提交';
        btn.style.background = 'var(--success)';

        startPolling();
    } catch (e) {
        showError('网络错误，请检查连接后重试。');
        resetSubmitBtn();
        setStage('stageUpload', '');
    }
}

function resetSubmitBtn() {
    const b = $('#btnSubmit');
    b.disabled = false;
    b.textContent = '开始生成 AI 翻唱';
    b.style.background = 'var(--accent)';
}

function setStage(stageId, state) {
    const el = $(`#${stageId}`);
    if (!el) return;
    el.className = 'stage ' + state;
}

function startPolling() {
    if (appState.pollTimer) clearInterval(appState.pollTimer);
    pollTaskStatus();
    appState.pollTimer = setInterval(pollTaskStatus, POLL_INTERVAL);
}

function stopPolling() {
    if (appState.pollTimer) { clearInterval(appState.pollTimer); appState.pollTimer = null; }
}

async function pollTaskStatus() {
    if (!appState.currentTaskId) return;
    try { const h = await apiFetch('/api/health'); if (h.ok) updateQueueBar(await h.json()); } catch (e) {}
    try {
        const res = await apiFetch('/api/status/' + appState.currentTaskId);
        const data = await res.json();

        // 按顺序点亮阶段，不跳过
        if (data.status === 'pending') {
            // 仍在排队
        } else if (data.status === 'processing') {
            setStage('stageQueue', 'done');
            setStage('stageInfer', 'active');
            updateStatusBadge('传输+推理中', 'status-processing');
        } else if (data.status === 'completed') {
            setStage('stageQueue', 'done');
            setStage('stageInfer', 'done');
            setStage('stageReturn', 'active');
            updateStatusBadge('已完成', 'status-completed');
            showDownload(data);
            setStage('stageReturn', 'done');
        } else if (data.status === 'failed') {
            stopPolling();
            showError(data.error || '推理失败');
            updateStatusBadge('失败', 'status-failed');
            $('#btnSubmit').style.display = 'none';
        }

        $('#detailPosition').textContent = data.position > 0 ? '第 ' + data.position + ' 位' : '-';
    } catch (e) { console.error('轮询失败:', e); }
}

function updateStatusBadge(text, cls) {
    const b = $('#statusBadge');
    b.textContent = text;
    b.className = 'status-badge ' + cls;
}

function showDownload(data) {
    $('#downloadSection').style.display = 'block';
    $('#btnDownload').href = `${API_BASE}/api/download/${appState.currentTaskId}`;
    $('#btnSubmit').style.display = 'none';
    $$('.model-card').forEach(c => c.style.pointerEvents = 'none');
}

function hideDownloadSection() {
    $('#downloadSection').style.display = 'none';
    $('#btnSubmit').style.display = 'block';
    ['stageUpload','stageQueue','stageInfer','stageReturn'].forEach(id => setStage(id, ''));
}

function showError(msg) {
    const el = $('#errorMsg');
    el.textContent = msg;
    el.style.display = 'block';
}
function hideError() { $('#errorMsg').style.display = 'none'; }

function resetAll() {
    stopPolling();
    appState.currentTaskId = null;
    hideError(); hideDownloadSection();
    $('#statusSection').style.display = 'none';
    $('#uploadArea').style.display = 'block';
    $('#btnSubmit').style.display = 'block';
    resetSubmitBtn();
    removeFile();
    $$('.model-card').forEach(c => { c.classList.remove('selected'); c.style.pointerEvents = 'auto'; });
    appState.selectedModel = null;
    ['stageUpload','stageQueue','stageInfer','stageReturn'].forEach(id => setStage(id, ''));
    window.scrollTo({ top: 0, behavior: 'smooth' });
}

function showToast(msg, type) {
    const c = $('#toastContainer');
    const t = document.createElement('div');
    t.className = `toast ${type}`;
    t.textContent = msg;
    c.appendChild(t);
    setTimeout(() => { t.style.animation = 'toastOut 0.3s forwards'; setTimeout(() => t.remove(), 300); }, 3000);
}

function formatSize(b) {
    if (b<1024) return b+' B';
    if (b<1048576) return (b/1024).toFixed(1)+' KB';
    return (b/1048576).toFixed(1)+' MB';
}
function escapeHtml(s) { const d=document.createElement('div'); d.textContent=s; return d.innerHTML; }
