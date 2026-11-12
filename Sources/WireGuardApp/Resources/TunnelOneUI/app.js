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
    const withoutProxy = t.status === 'active' && report?.result === 'connected-without-proxy';
    const failed = ['failed', 'preflight-failed', 'rollback-failed'].includes(report?.result);
    let title = '隧道未连接', detail = '准备就绪，点击开启后自动处理网络与代理。', stateClass = '', glyph = 'shield';
    if (busy(t)) {
      title = t.status === 'deactivating' ? '正在断开' : '正在连接';
      detail = report?.result === 'checking' || report?.result === 'rolling-back' ? report.stage : '正在等待系统建立隧道…';
      glyph = 'loader-circle';
    } else if (t.status === 'active') {
      const checking = t.safetyMode && ['checking', 'rolling-back'].includes(report?.result);
      title = checking ? (report.result === 'rolling-back' ? '正在自动断开' : '正在验证连接') : verified ? '隧道与代理已连接' : 'WireGuard 已连接';
      detail = checking ? report.stage : verified ? '已沿用系统代理，访问检查通过。' : withoutProxy ? '未启用系统代理，本次仅连接 WireGuard。' : t.proxyEnabled ? '隧道已建立；本次代理继承尚未验证。' : '当前按 WireGuard 配置访问网络。';
      stateClass = verified || withoutProxy || !t.proxyEnabled ? 'good' : 'warn'; glyph = verified ? 'shield-check' : 'shield';
    } else if (failed) {
      title = '安全启动未完成'; detail = report.reason || '检查未通过。'; stateClass = 'warn'; glyph = 'shield-alert';
    }
    let html = `<div class="to-status-panel" aria-live="polite"><div class="to-status-icon ${stateClass}">${icon(glyph)}</div><div><div class="to-status-title">${title}</div><div class="to-status-detail">${esc(detail)}</div></div><div class="to-status-trailing"><span class="to-pill ${verified ? 'good' : ''}">${verified ? '连通检查通过' : esc(t.statusLabel)}</span></div></div>`;
    if (failed) html += `<div class="to-notice error" role="alert">${icon('circle-alert')}<div><strong>${esc(report.reason)}</strong><p>${esc(report.stage)}</p></div></div>`;
    const locked = t.status !== 'inactive' || t.onDemandEnabled || snapshot.saving;
    const toggle = `<label class="to-switch"><input type="checkbox" role="switch" data-action="proxy-toggle" aria-label="连接时沿用系统代理" ${t.proxyEnabled ? 'checked' : ''} ${locked ? 'disabled' : ''}><span aria-hidden="true"></span></label>`;
    html += section(icon('shuffle') + '连接时沿用系统代理', '自动读取已启用的系统代理；没有代理时仅连接 WireGuard。',
      t.proxyEnabled && !t.safetyMode
        ? `<div class="to-proxy-off">当前保留已有的内置 Mihomo 设置。关闭后重新打开此开关，将改为自动沿用系统代理。</div>`
        : t.proxyEnabled
        ? `<div class="to-profile-line"><div class="to-field"><span>${t.status === 'active' ? '本次代理' : '当前系统代理'}</span><strong>${esc(report?.proxySummary || snapshot.systemProxySummary || '连接时自动检测')}</strong></div></div>
           <div class="to-footnote">${icon('shuffle')}<span>沿用当前代理客户端和规则，不启动指定软件。连接期间同步系统代理变化，失败时回滚本次隧道。</span></div>`
        : `<div class="to-proxy-off">仅连接 WireGuard，不主动带入或同步系统代理。</div>`,
      toggle);
    if (locked) html += `<p class="to-footnote">请断开隧道并关闭按需连接后更改代理开关。</p>`;
    html += fields([['本地地址', t.address], ['服务器', t.endpoint], ['DNS 服务器', t.dns], ['路由范围', t.allowedIPs]]);
    if (t.status === 'active') html += `<dl class="to-metrics"><div><dt>已接收</dt><dd>${esc(t.rx || '—')}</dd></div><div><dt>已发送</dt><dd>${esc(t.tx || '—')}</dd></div><div><dt>上次握手</dt><dd>${esc(t.handshake || '尚未确认')}</dd></div></dl>`;
    if (report?.checks?.length) html += section('连通性检查', '最近一次连接或代理变更的实际检查结果，不代表持续监控。', report.checks.map(check => `<div class="to-setting-row"><span>${esc(check.name)}</span><span class="to-pill ${check.ok ? 'good' : ''}">${check.ok ? '通过' : '失败'} · HTTP ${esc(check.http || '无响应')}</span></div>${!check.ok && check.detail ? `<p class="to-footnote">${esc(check.detail)}${check.exitCode != null ? ` · curl ${esc(check.exitCode)}` : ''}</p>` : ''}`).join(''));
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
    return header('代理配置', '自动沿用当前系统代理，兼容使用标准系统代理设置的客户端。') +
      section(icon('plug') + '当前系统代理', '', `<p>${esc(snapshot.systemProxySummary || '连接时自动检测')}</p><ol class="to-step-list">
        <li>连接前读取 HTTP、HTTPS、SOCKS、PAC 和绕过规则，验证现有代理可用。</li>
        <li>建立 WireGuard 并将代理设置应用到本次隧道，再验证系统实际生效的访问路径。</li>
        <li>没有系统代理时只连接 WireGuard；已配置但不可用时明确报错。</li>
        <li>连接期间跟随网络服务的代理变化，不修改永久网络偏好或启动代理客户端。</li>
      </ol><p class="to-footnote">系统代理仅影响遵循它的应用。仅 TUN / 其他 VPN 接管网络、WPAD 自动发现及需要额外认证的代理不保证自动兼容。</p>`);
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
