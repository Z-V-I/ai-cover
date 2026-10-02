/**
 * 前端本地配置模板
 *
 *   cp frontend/js/config.example.js frontend/js/config.js
 *
 * config.js 已在 .gitignore 中，不会提交到仓库。
 * apiToken 必须与决策层环境变量 API_TOKEN 完全一致，否则 /api/* 全部返回 401。
 *
 * 生成随机串：python3 -c "import secrets; print(secrets.token_urlsafe(32))"
 */
window.APP_CONFIG = {
    apiToken: 'CHANGE_ME',
};
