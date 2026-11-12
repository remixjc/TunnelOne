/* SPDX-License-Identifier: GPL-3.0-or-later */
(() => {
  const root = document.querySelector('#tunnel-one-prototype');
  const main = document.querySelector('#to-main');
  const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const icon = name => `<i data-lucide="${name}" aria-hidden="true"></i>`;
  const button = (text, action, style = '', disabled = false) => `<button class="to-button ${style}" data-action="${action}" ${disabled ? 'disabled' : ''}>${text}</button>`;
  let snapshot = {tunnels: [], logs: [], message: '', version: ''};
  let selected = null, page = 'tunnel', tab = 'overview', signature = '';
  const current = () => snapshot.tunnels.find(t => t.id === selected);
  const busy = t => !['inactive', 'active'].includes(t.status);
  const send = (action, value) => {
    const bridge = window.webkit?.messageHandlers?.tunnelOne;
    if (!bridge) {
      snapshot.message = '此页面需要在 TunnelOne 应用中运行，尚未执行任何连接操作。';
      render();
      return;
    }
    const payload = {action, id: selected};
    if (value !== undefined) payload.value = value;
    bridge.postMessage(payload);
  };
  const fields = items => `<dl class="to-details">${items.map(([label, value]) => `<div><dt>${esc(label)}</dt><dd class="to-mono">${esc(value || '—')}</dd></div>`).join('')}</dl>`;
  const section = (title, description, content, trailing = '') => `<section class="to-section"><div class="to-section-heading"><div><h3>${title}</h3>${description ? `<p class="to-subtitle">${description}</p>` : ''}</div>${trailing}</div><div class="to-section-content">${content}</div></section>`;
  const header = (title, subtitle, actions = '') => `<div class="to-page-top"><div><h1>${esc(title)}</h1><p class="to-subtitle">${esc(subtitle)}</p></div><div class="to-row">${actions}</div></div>`;
  function overview(t) {
    const report = t.report;
    const verified = t.status === 'active' && t.proxyEnabled && t.safetyMode && report?.result === 'connected-and-checked';
    const failed = ['failed', 'preflight-failed', 'rollback-failed'].includes(report?.result);
    let title = '隧道未连接', detail = '准备就绪，点击开启后自动处理网络与代理。', stateClass = '', glyph = 'shield';
    if (busy(t)) {
      title = t.status === 'deactivating' ? '正在断开' : '正在连接';
      detail = report?.result === 'checking' || report?.result === 'rolling-back' ? report.stage : '正在等待系统建立隧道…';
      glyph = 'loader-circle';
    } else if (t.status === 'active') {
      const checking = t.safetyMode && ['checking', 'rolling-back'].includes(report?.result);
      title = checking ? (report.result === 'rolling-back' ? '正在自动断开' : '正在验证连接') : verified ? '隧道与代理已连接' : 'WireGuard 已连接';
      detail = checking ? report.stage : verified ? '国内直连与国外代理检查均通过。' : t.proxyEnabled ? '隧道已建立；本次安全启动检查尚未通过或未执行。' : '当前按 WireGuard 配置访问网络。';
      stateClass = verified || !t.proxyEnabled ? 'good' : 'warn'; glyph = verified ? 'shield-check' : 'shield';
    } else if (failed) {
      title = '安全启动未完成'; detail = report.reason || '检查未通过。'; stateClass = 'warn'; glyph = 'shield-alert';
    }
    let html = `<div class="to-status-panel" aria-live="polite"><div class="to-status-icon ${stateClass}">${icon(glyph)}</div><div><div class="to-status-title">${title}</div><div class="to-status-detail">${esc(detail)}</div></div><div class="to-status-trailing"><span class="to-pill ${verified ? 'good' : ''}">${verified ? '连通检查通过' : esc(t.statusLabel)}</span></div></div>`;
    if (failed) html += `<div class="to-notice error" role="alert">${icon('circle-alert')}<div><strong>${esc(report.reason)}</strong><p>${esc(report.stage)}</p></div></div>`;
    const locked = t.status !== 'inactive' || t.onDemandEnabled || snapshot.saving;
    const toggle = `<label class="to-switch"><input type="checkbox" role="switch" data-action="proxy-toggle" aria-label="连接时带入代理" ${t.proxyEnabled ? 'checked' : ''} ${locked ? 'disabled' : ''}><span aria-hidden="true"></span></label>`;
    html += section(icon('shuffle') + '连接时带入代理', '为这个隧道单独设置，连接时自动生效。',
      t.proxyEnabled && !t.safetyMode
        ? `<div class="to-proxy-off">当前保留已有的内置 Mihomo 设置。关闭后重新打开此开关，将改用现有 Clash Party 的安全启动流程。</div>`
        : t.proxyEnabled
        ? `<div class="to-profile-line"><div class="to-field"><span>使用代理配置</span><strong>${esc(t.proxySource)}</strong></div><button class="to-text-button" data-action="open-clash">打开 Clash Party</button></div>
           <div class="to-connection-flow"><span class="to-flow-item">${icon('laptop')}应用</span>${icon('chevron-right')}<span class="to-flow-item on">${icon('shield')}WireGuard</span>${icon('chevron-right')}<span class="to-flow-item on">${icon('shuffle')}Clash 规则代理</span>${icon('chevron-right')}<span class="to-flow-item">${icon('globe')}互联网</span></div>
           <div class="to-footnote">${icon('undo-2')}<span>按安全启动流程检查 Clash、同步隧道代理并验证国内外访问；失败自动断开本次隧道，保留原有 Clash 代理。</span></div>`
        : `<div class="to-proxy-off">仅连接 WireGuard。打开此开关后，使用现有 Clash Party 执行安全启动流程。</div>`,
      toggle);
    if (locked) html += `<p class="to-footnote">请断开隧道并关闭按需连接后更改代理开关。</p>`;
    html += fields([['本地地址', t.address], ['服务器', t.endpoint], ['DNS 服务器', t.dns], ['路由范围', t.allowedIPs]]);
    if (t.status === 'active') html += `<dl class="to-metrics"><div><dt>已接收</dt><dd>${esc(t.rx || '—')}</dd></div><div><dt>已发送</dt><dd>${esc(t.tx || '—')}</dd></div><div><dt>上次握手</dt><dd>${esc(t.handshake || '尚未确认')}</dd></div></dl>`;
    if (report?.checks?.length) html += section('连通性检查', '本次启动时的实际检查结果，不代表持续监控。', report.checks.map(check => `<div class="to-setting-row"><span>${esc(check.name)}</span><span class="to-pill ${check.ok ? 'good' : ''}">${check.ok ? '通过' : '失败'} · HTTP ${esc(check.http || '无响应')}</span></div>${!check.ok && check.detail ? `<p class="to-footnote">${esc(check.detail)}${check.exitCode != null ? ` · curl ${esc(check.exitCode)}` : ''}</p>` : ''}`).join(''));
    return html;
  }
  function configuration(t) {
    return `<div class="to-row">${button(icon('pencil') + '编辑配置', 'edit')}</div>` +
      section('接口', '私钥保存在钥匙串，编辑和导出时由系统验证访问权限。',
        fields([['公钥', t.publicKey], ['IP 地址', t.address], ['DNS', t.dns], ['MTU', t.mtu], ['监听端口', t.listenPort]])) +
      t.peers.map((peer, i) => section(`对端 ${i + 1}`, '', fields([['公钥', peer.publicKey], ['端点', peer.endpoint], ['AllowedIPs', peer.allowedIPs], ['持续保活', peer.keepalive]]))).join('');
  }
  function tunnelPage(t) {
    if (!t) return header('隧道', '导入已有的 WireGuard 配置后，即可连接。', button(icon('download') + '导入隧道', 'import', 'primary')) + `<div class="to-empty">${icon('shield')}<p>还没有隧道</p></div>`;
    const active = t.status === 'active';
    const connectLabel = active ? '断开连接' : busy(t) ? (t.status === 'deactivating' ? '正在断开…' : '取消连接') : '开启';
    let html = header(t.name, '日常上网 · WireGuard',
      button(icon(active ? 'square' : 'power') + connectLabel, 'connect', active ? 'to-main-connect' : 'primary to-main-connect', t.status === 'deactivating') +
      `<button class="to-icon-button" data-action="tunnel-menu" aria-label="隧道操作">${icon('ellipsis')}</button>`);
    html += `<div class="to-tabs" role="tablist" aria-label="隧道详情">${[['overview','概览'], ['configuration','隧道配置'], ['ondemand','按需连接']].map(([key,label]) => `<button class="to-tab ${tab === key ? 'active' : ''}" role="tab" aria-selected="${tab === key}" data-tab="${key}">${label}</button>`).join('')}</div>`;
    if (tab === 'configuration') return html + configuration(t);
    if (tab === 'ondemand') return html + section('按需连接', '沿用该隧道的系统设置，连接同样经过安全启动检查。',
      fields([['当前状态', t.onDemandEnabled ? '已启用' : '未启用'], ['网络条件', t.onDemandDescription]]) +
      `<div class="to-row">${button('编辑按需连接', 'edit')}</div>`);
    return html + overview(t);
  }
  function proxyPage() {
    return header('代理配置', '使用现有 Clash Party，连接时自动执行安全启动流程。', button('打开 Clash Party', 'open-clash')) +
      section(icon('plug') + '本机代理 · Clash Party', '127.0.0.1:7890 · HTTP / HTTPS / SOCKS', `<ol class="to-step-list">
        <li>确认系统代理开启、TUN 关闭、规则模式、混合端口 7890。</li>
        <li>读取物理网络上的代理源，等待 Clash 端口就绪，再建立 WireGuard 隧道。</li>
        <li>等待系统确认已连接并稳定 1 秒，再确认 IPv4 主路由、同步临时网络服务代理。</li>
        <li>检查百度直连和 Google 代理访问，失败自动停止本次隧道。</li>
      </ol><p class="to-footnote">在隧道概览中打开“连接时带入代理”，下次开启时自动执行。</p>`);
  }
  function logsPage() {
    return header('连接日志', '显示实际连接状态与本次安全启动结果。', button('查看系统日志', 'system-logs')) +
      `<table class="to-table"><thead><tr><th>时间</th><th>事件</th></tr></thead><tbody>${snapshot.logs.length ? snapshot.logs.map(log => `<tr><td>${esc(log.time)}</td><td>${esc(log.message)}</td></tr>`).join('') : '<tr><td colspan="2">尚无运行记录。</td></tr>'}</tbody></table>`;
  }
  function settingsPage() {
    return header('设置', 'macOS 系统扩展与应用信息。') +
      section('系统扩展', '系统扩展负责连接、代理同步和失败回滚。',
        `<div class="to-row">${button('安装 / 允许网络扩展', 'install-extension')}${button('移除网络扩展', 'remove-extension')}</div>`) +
      section('关于隧行', `当前版本 ${esc(snapshot.version)}`, button('关于 TunnelOne', 'about'));
  }
  function render() {
    const t = current();
    document.querySelector('#to-tunnels').innerHTML = snapshot.tunnels.map(item => `<button class="to-tunnel ${selected === item.id && page === 'tunnel' ? 'selected' : ''}" data-tunnel="${esc(item.id)}">${icon('shield')}<span><span class="to-tunnel-name">${esc(item.name)}</span><span class="to-tunnel-meta"><span class="to-dot ${item.status === 'active' ? 'good' : ''}"></span>${esc(item.statusLabel)}</span></span></button>`).join('');
    document.querySelector('#to-title-status').textContent = snapshot.tunnels.find(item => item.status === 'active') ? '隧道已连接' : snapshot.tunnels.some(busy) ? '正在处理连接' : '尚未连接';
    document.querySelector('#to-version').textContent = snapshot.version;
    root.querySelectorAll('[data-page]').forEach(el => el.classList.toggle('active', el.dataset.page === page));
    const notice = snapshot.message ? `<div class="to-notice to-message" role="alert">${icon('info')}<span>${esc(snapshot.message)}</span></div>` : '';
    main.innerHTML = notice + (page === 'proxy' ? proxyPage() : page === 'logs' ? logsPage() : page === 'settings' ? settingsPage() : tunnelPage(t));
    window.lucide?.createIcons();
  }
  window.TunnelOne = {
    update(data) {
      const nextSignature = JSON.stringify(data);
      if (signature === nextSignature) return;
      signature = nextSignature;
      snapshot = data;
      if (!snapshot.tunnels.some(t => t.id === selected)) selected = snapshot.tunnels.find(t => t.status === 'active')?.id || snapshot.tunnels[0]?.id || null;
      render();
    }
  };
  root.addEventListener('click', event => {
    const el = event.target.closest('button');
    if (!el || el.disabled) return;
    if (el.dataset.tunnel) { selected = el.dataset.tunnel; page = 'tunnel'; tab = 'overview'; render(); send('select'); }
    else if (el.dataset.page) { page = el.dataset.page; render(); }
    else if (el.dataset.tab) { tab = el.dataset.tab; render(); }
    else if (el.dataset.action) send(el.dataset.action);
  });
  root.addEventListener('change', event => {
    if (event.target.dataset.action === 'proxy-toggle') send('proxy-toggle', event.target.checked);
  });
  render();
  send('ready');
})();
