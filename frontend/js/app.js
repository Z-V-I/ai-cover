/**
 * AI 翻唱 - 前端逻辑
 */

const API_BASE = window.API_BASE || '';
// ⚠ 后端 nginx 对每个 IP 有 1 请求/秒 的限流（另外可突发 5 次）。
// 前端轮询必须明显低于这个速率：一旦被打成 429，不只是轮询失败，
// 之后所有请求（健康检查、语音列表、下载）都会连带失败，页面表现为"离线"。
const POLL_INTERVAL = 3000;        // 常态轮询间隔（原 2000 偏密）
const POLL_INTERVAL_MAX = 30000;   // 被限流后指数退避的上限
const HEALTH_INTERVAL = 30000;     // 健康检查间隔（原 10000）
// API Token 不写死在源码里：由 js/config.js 注入（该文件已在 .gitignore 中）。
// 照着 js/config.example.js 建一个 config.js，填上与决策层 API_TOKEN 相同的值。
const API_TOKEN = (window.APP_CONFIG && window.APP_CONFIG.apiToken) || '';

function apiFetch(url, options = {}) {
    options.headers = options.headers || {};
    options.headers['X-API-Token'] = API_TOKEN;
    return fetch(API_BASE + url, options);
}

/**
 * 安全解析 JSON。
 * nginx 限流(429) 返回的是 text/html 错误页，直接 res.json() 会抛
 * "SyntaxError: Unexpected token '<'" —— 这正是控制台里刷屏的那条报错。
 */
async function readJson(res) {
    const ct = (res.headers.get('content-type') || '').toLowerCase();
    if (!ct.includes('application/json')) {
        const text = await res.text().catch(() => '');
        const err = new Error(
            res.status === 429 ? '服务器繁忙（请求过于频繁），请稍后重试'
                               : `服务返回异常（HTTP ${res.status}）`
        );
        err.status = res.status;
        err.body = (text || '').slice(0, 200);
        throw err;
    }
    const data = await res.json();
    if (!res.ok) {
        const err = new Error(data.error || `HTTP ${res.status}`);
        err.status = res.status;
        err.data = data;
        throw err;
    }
    return data;
}

let appState = { selectedModel: null, selectedFile: null, fileDuration: null, currentTaskId: null, pollTimer: null, pollDelay: 0, pollCount: 0, models: [] };

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => document.querySelectorAll(sel);

document.addEventListener('DOMContentLoaded', () => {
    initUpload();
    loadModels();
    checkServerHealth();
    setInterval(checkServerHealth, HEALTH_INTERVAL);
});

async function checkServerHealth() {
    try {
        const data = await readJson(await apiFetch('/api/health'));
        updateServerStatus('online', data);
        updateQueueBar(data);
    } catch (e) {
        // 429 是"被限流"而不是"掉线"：服务其实活着，别误报离线吓人
        updateServerStatus(e.status === 429 ? 'busy' : 'offline');
    }
}

function updateServerStatus(state, data) {
    const dot = $('.status-dot');
    const text = $('.status-text');
    if (state === 'online') {
        dot.className = 'status-dot online';
        text.textContent = data ? '在线 | 排队 ' + (data.queue_length||0) + '/' + (data.max_queue||20) : '在线';
    } else if (state === 'busy') {
        dot.className = 'status-dot online';
        text.textContent = '服务器繁忙，稍后自动恢复';
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
        const data = await readJson(await apiFetch('/api/models'));
        appState.models = data.models || [];
        renderModels(data.models || []);
    } catch (e) {
        // 限流时别把卡片永远卡在"加载中"，给个明确提示
        showToast(e.status === 429 ? '服务器繁忙，请稍后刷新重试' : '无法加载语音模型列表', 'error');
        renderModels([]);
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
    $('#btnDownload').addEventListener('click', (e) => { e.preventDefault(); downloadResult(); });
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

    // 选完立刻读 1KB 探一下：安卓从系统文件选择器拿到的往往只是一个临时
    // 授权引用，授权失效时文件内容根本读不出来。早发现就能早提示，
    // 不至于让用户选好音色、调好音高、点了提交才弹"网络错误"。
    file.slice(0, 1024).arrayBuffer().catch(() => {
        showToast('这个文件读不出来，请重新选择（建议先把文件另存到手机"下载"目录）', 'error');
        removeFile();
    });
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

/**
 * 用 XHR 而不是 fetch 上传。
 * 两个理由：
 *  1. 只有 XHR 能拿到上传进度 —— 手机上"到底传没传出去"一目了然；
 *  2. fetch 失败时只给一句 TypeError: Failed to fetch，服务端又没有任何
 *     日志，根本分不清是"文件读不出来"还是"网络断了"。XHR 能把这两种
 *     情况区分开（status 0 + error 事件 vs onload 拿到真实状态码）。
 */
function uploadWithProgress(fd, onProgress) {
    return new Promise((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        xhr.open('POST', API_BASE + '/api/upload', true);
        xhr.setRequestHeader('X-API-Token', API_TOKEN);
        xhr.upload.onprogress = (e) => {
            if (e.lengthComputable) onProgress(Math.round((e.loaded / e.total) * 100));
        };
        xhr.onload = () => resolve(xhr);
        xhr.onerror = () => { const e = new Error('上传连接被中断或无法建立'); e.name = 'NetworkError'; reject(e); };
        xhr.ontimeout = () => { const e = new Error('上传超时'); e.name = 'TimeoutError'; reject(e); };
        xhr.onabort = () => { const e = new Error('上传被取消'); e.name = 'AbortError'; reject(e); };
        xhr.send(fd);
    });
}

function parseXhrResponse(xhr) {
    const ct = (xhr.getResponseHeader('content-type') || '').toLowerCase();
    let data = null;
    if (ct.includes('application/json')) {
        try { data = JSON.parse(xhr.responseText); } catch (e) { data = null; }
    }
    if (xhr.status === 429) {
        const e = new Error('排队人数已满或请求过于频繁，请稍后再试。');
        e.status = 429; throw e;
    }
    if (xhr.status === 413) {
        const e = new Error((data && data.error) || '文件超过服务器允许的大小，请换更短的音频。');
        e.status = 413; throw e;
    }
    if (xhr.status >= 200 && xhr.status < 300) {
        if (data) return data;
        const e = new Error(`服务返回异常（HTTP ${xhr.status}）`);
        e.status = xhr.status; throw e;
    }
    const e = new Error((data && data.error) || `服务返回异常（HTTP ${xhr.status}）`);
    e.status = xhr.status; throw e;
}

async function submitTask() {
    if (!appState.selectedFile || !appState.selectedModel) return;
    hideError(); hideDownloadSection();

    const btn = $('#btnSubmit');
    btn.disabled = true;
    btn.textContent = '准备中...';

    setStage('stageUpload', 'active');

    try {
        // ⚠ 先把文件读进内存，再上传。
        // 手机（尤其安卓）从系统文件选择器拿到的 File 往往只是一个
        // content:// 临时授权引用：如果这个引用在选完之后失效（切了下 App、
        // 文件在云盘/微信目录里、系统回收过授权），浏览器读不到内容，
        // 请求会在发出前就失败 —— 服务端一条日志都没有，前端只弹"网络错误"。
        // 先 arrayBuffer() 读成内存 Blob，既能在读取阶段就给出准确原因，
        // 也让实际上传不再依赖那个临时授权。
        btn.textContent = '读取文件...';
        const buf = await appState.selectedFile.arrayBuffer();
        const blob = new Blob([buf], { type: appState.selectedFile.type || 'application/octet-stream' });

        const fd = new FormData();
        fd.append('audio', blob, appState.selectedFile.name);
        fd.append('voice_model', appState.selectedModel);
        fd.append('pitch_shift', $('#pitchSlider').value);

        btn.textContent = '上传中 0%';
        const xhr = await uploadWithProgress(fd, (pct) => {
            btn.textContent = pct < 100 ? `上传中 ${pct}%` : '排队中...';
        });
        const data = parseXhrResponse(xhr);

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
        // readJson / parseXhrResponse 抛出的是后端返回的 error 文本；纯网络层错误没有 status
        if (e.status === 413) { showError(e.message); removeFile(); resetSubmitBtn(); setStage('stageUpload', ''); return; }
        if (e.name === 'NotReadableError' || /could not be read|读取/i.test(e.message || '')) {
            showError('无法读取这个音频文件：手机给网页的临时授权已失效。请重新点"选择音频文件"再选一次；若仍不行，先把文件另存到手机"下载"或"音乐"目录后再选。');
        } else {
            // 把真实原因带出来，别再让用户只看到一句笼统的"网络错误"
            showError(`网络错误：${e.message || e.name || '未知原因'}。请确认手机网络正常后重试。`);
        }
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
    stopPolling();
    appState.pollDelay = POLL_INTERVAL;
    appState.pollCount = 0;
    scheduleNextPoll(0);   // 立即先跑一次，之后按当前延迟递归
}

function stopPolling() {
    if (appState.pollTimer) { clearTimeout(appState.pollTimer); appState.pollTimer = null; }
}

// 用 setTimeout 递归而不是 setInterval —— 只有这样才能在被打成 429 时
// 动态拉长间隔做退避，setInterval 的周期是写死的，做不到。
function scheduleNextPoll(delay) {
    if (!appState.currentTaskId) return;
    appState.pollTimer = setTimeout(async () => {
        if (!appState.currentTaskId) return;
        await pollTaskStatus();
        scheduleNextPoll(appState.pollDelay);
    }, delay === undefined ? appState.pollDelay : delay);
}

async function pollTaskStatus() {
    if (!appState.currentTaskId) return;

    // 队列条每 3 轮才刷新一次。原来每轮都额外打一次 /api/health，
    // 让前端请求量直接翻倍（1.1 请求/秒），正好顶到 nginx 的 1 请求/秒 限流线上。
    if (appState.pollCount % 3 === 0) {
        try { updateQueueBar(await readJson(await apiFetch('/api/health'))); } catch (e) {}
    }
    appState.pollCount++;

    let data;
    try {
        data = await readJson(await apiFetch('/api/status/' + appState.currentTaskId));
    } catch (e) {
        if (e.status === 429) {
            // 被限流了：指数退避。继续硬刚只会让限流舱一直满着，越拖越久。
            appState.pollDelay = Math.min(appState.pollDelay * 2, POLL_INTERVAL_MAX);
            console.warn(`轮询被限流，${appState.pollDelay}ms 后重试`);
        } else {
            console.error('轮询失败:', e.message || e);
        }
        return;
    }

    // 拿到正常响应 → 立刻恢复正常节奏
    appState.pollDelay = POLL_INTERVAL;

    // 按顺序点亮阶段，不跳过
    if (data.status === 'pending') {
        // 仍在排队
    } else if (data.status === 'processing') {
        setStage('stageQueue', 'done');
        setStage('stageInfer', 'active');
        updateStatusBadge('传输+推理中', 'status-processing');
    } else if (data.status === 'completed') {
        // 关键：一旦完成必须停掉轮询。原来这里没有 stopPolling，
        // 任务结束后仍每 2 秒打一次接口，把 IP 一直顶在 429 上，
        // 于是"跑完一次之后就一直提示离线、加载不了语音列表"。
        stopPolling();
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
}

function updateStatusBadge(text, cls) {
    const b = $('#statusBadge');
    b.textContent = text;
    b.className = 'status-badge ' + cls;
}

function showDownload(data) {
    $('#downloadSection').style.display = 'block';
    // ⚠ 不能把 <a href> 直接指到 /api/download/xxx：
    // 浏览器导航式下载不会带上 X-API-Token 头，后端必然返回 401，
    // 浏览器就报"无法从该网站上提取文件，请先尝试登录网站"。
    // 必须走 downloadResult()，用 fetch 带头取回 blob 再本地触发保存。
    $('#btnSubmit').style.display = 'none';
    $$('.model-card').forEach(c => c.style.pointerEvents = 'none');
}

async function downloadResult() {
    const taskId = appState.currentTaskId;
    if (!taskId) return;
    const btn = $('#btnDownload');
    const oldText = btn.textContent;
    btn.textContent = '下载中...';
    btn.style.pointerEvents = 'none';
    try {
        const res = await apiFetch('/api/download/' + taskId);
        if (!res.ok) {
            throw new Error(
                res.status === 401 ? '下载凭证失效，请刷新页面后重试'
              : res.status === 429 ? '服务器繁忙，请稍后重试'
              : `下载失败（HTTP ${res.status}）`
            );
        }
        const blob = await res.blob();
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = 'ai-cover-' + String(taskId).slice(0, 8) + '.wav';
        document.body.appendChild(a);
        a.click();
        a.remove();
        setTimeout(() => URL.revokeObjectURL(url), 10000);
        showToast('下载完成', 'success');
    } catch (e) {
        showToast(e.message || '下载失败', 'error');
    } finally {
        btn.textContent = oldText;
        btn.style.pointerEvents = '';
    }
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
