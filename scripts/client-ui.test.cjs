const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const { pathToFileURL } = require('node:url');
const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.CHROME_PATH || (process.platform === 'darwin' &&
      fs.existsSync('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
      ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' : undefined),
    headless: true,
  });
  try {
    const page = await browser.newPage({ viewport: { width: 1024, height: 760 } });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.addInitScript(() => {
      window.nativeMessages = [];
      window.webkit = { messageHandlers: { tunnelOne: { postMessage: message => window.nativeMessages.push(message) } } };
    });
    await page.goto(pathToFileURL(path.resolve('Sources/WireGuardApp/Resources/TunnelOneUI/index.html')).href);
    const tunnel = {
      id: 'home', name: 'macmini152-client', status: 'inactive', statusLabel: '未连接',
      proxyEnabled: true, safetyMode: true, proxySource: '本机代理 · Clash Party',
      address: '10.8.0.2/24', dns: '114.114.114.114, 1.1.1.1',
      endpoint: 'vpn.example.com:51820', allowedIPs: '0.0.0.0/0',
      publicKey: 'UI_TEST_PUBLIC_KEY', mtu: '1420', peers: [],
      onDemandEnabled: false, onDemandDescription: '未配置',
    };
    const data = { tunnels: [tunnel], logs: [], message: '', version: '0.2.5', saving: false };
    const update = () => page.evaluate(value => window.TunnelOne.update(value), data);
    await update();
    assert.equal(await page.locator('.to-sidebar').evaluate(el => el.getBoundingClientRect().width), 208);
    await page.getByRole('button', { name: '开启', exact: true }).click();
    assert.equal((await page.evaluate(() => window.nativeMessages)).at(-1).action, 'connect');
    // Clicking a native action must never simulate a successful connection.
    await page.waitForTimeout(300);
    assert.equal(await page.locator('.to-status-title').innerText(), '隧道未连接');
    assert.equal(await page.locator('.to-metrics').count(), 0);
    await page.getByRole('switch').uncheck();
    assert.deepEqual((await page.evaluate(() => window.nativeMessages)).at(-1), { action: 'proxy-toggle', id: 'home', value: false });

    tunnel.status = 'activating'; tunnel.statusLabel = '正在连接';
    tunnel.report = { time: 'fixture', stage: '同步隧道代理', result: 'checking', checks: [] };
    await update();
    assert.match(await page.locator('.to-status-detail').innerText(), /同步隧道代理/);
    assert.equal(await page.getByRole('switch').isDisabled(), true);
    assert.equal(await page.getByText('国内直连与国外代理检查均通过。').count(), 0);

    tunnel.status = 'active'; tunnel.statusLabel = '已连接';
    tunnel.report.stage = '检查国内直连与国外代理';
    await update();
    assert.equal(await page.locator('.to-status-title').innerText(), '正在验证连接');
    assert.match(await page.locator('.to-status-detail').innerText(), /检查国内直连与国外代理/);
    assert.equal(await page.getByText('国内直连与国外代理检查均通过。').count(), 0);
    tunnel.report = { time: 'fixture', stage: '连通性检查完成', result: 'connected-and-checked', checks: [
      { name: '国内直连', ok: true, http: '200' }, { name: '国外代理', ok: true, http: '204' }
    ] };
    await update();
    assert.equal(await page.locator('.to-status-title').innerText(), '隧道与代理已连接');
    assert.equal(await page.getByText('通过 · HTTP 204').count(), 1);
    assert.equal(await page.locator('.to-metrics dd').first().innerText(), '—');
    fs.mkdirSync('build/ui-qa', { recursive: true });
    await page.screenshot({ path: 'build/ui-qa/client-connected.png' });

    tunnel.proxyEnabled = false;
    await update();
    assert.equal(await page.locator('.to-status-title').innerText(), 'WireGuard 已连接');
    assert.equal(await page.getByText('国内直连与国外代理检查均通过。').count(), 0);
    tunnel.proxyEnabled = true;
    tunnel.status = 'inactive'; tunnel.statusLabel = '未连接';
    tunnel.report = { time: 'fixture', stage: '已自动断开本次 WireGuard，保留原有 Clash 代理',
      result: 'failed', reason: '国外代理连通检查失败', checks: [
        { name: '国外代理', ok: false, http: '000', exitCode: 7, detail: 'curl: (7) Failed to connect' }
      ] };
    await update();
    assert.equal(await page.locator('.to-status-title').innerText(), '安全启动未完成');
    assert.equal(await page.getByText('隧道与代理已连接').count(), 0);
    assert.equal(await page.getByText('失败 · HTTP 000').count(), 1);
    assert.match(await page.locator('.to-footnote').allTextContents().then(values => values.join(' ')), /Failed to connect.*curl 7/);
    await page.getByRole('button', { name: '连接日志', exact: true }).click();
    assert.match(await page.locator('.to-table').innerText(), /尚无运行记录/);
    await page.getByRole('button', { name: '代理配置', exact: true }).click();
    assert.equal(await page.getByText('内置代理', { exact: true }).count(), 0);

    tunnel.name = '<img src=x onerror="window.injected=true">';
    await update();
    assert.equal(await page.evaluate(() => window.injected), undefined);
    assert.deepEqual(errors, []);
    console.log('Client UI: native actions, real progress/results, rollback, missing telemetry and HTML escaping passed.');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
