(() => {
  "use strict";
  const connect = document.getElementById("connect-button");
  const toggle = document.getElementById("proxy-toggle");
  const title = document.getElementById("demo-title");
  const status = document.getElementById("demo-status");
  const mark = document.getElementById("connection-mark");
  const tag = document.getElementById("demo-state-tag");
  const dot = document.getElementById("sidebar-dot");
  const route = document.querySelector(".route-diagram");
  const description = document.getElementById("proxy-description");
  let state = "idle", proxy = true, appliedProxy = true, timer;
  function render() {
    const connected = state === "connected", connecting = state === "connecting";
    mark.classList.toggle("connected", connected);
    mark.classList.toggle("connecting", connecting);
    dot.classList.toggle("active", connected);
    toggle.setAttribute("aria-checked", String(proxy));
    toggle.disabled = connecting;
    connect.disabled = connecting;
    const pending = connected && proxy !== appliedProxy;
    description.textContent = pending ? "已保存 · 下次连接生效" :
      proxy ? "内置 Mihomo · 随隧道启停" : "仅连接 WireGuard 隧道";
    route.classList.toggle("hidden-proxy", !(connected ? appliedProxy : proxy));
    if (connected) {
      title.textContent = appliedProxy ? "隧道与代理已就绪" : "WireGuard 已就绪";
      status.textContent = "演示连接成功 · 不修改电脑网络";
      tag.textContent = appliedProxy ? "WireGuard + Mihomo" : "WireGuard";
      connect.innerHTML = '<span aria-hidden="true">⏻</span> 断开连接';
    } else if (connecting) {
      title.textContent = "正在建立连接";
      status.textContent = "演示中：建立隧道 → 准备代理 → 就绪";
      tag.textContent = "正在连接";
      connect.textContent = "连接中…";
    } else {
      title.textContent = "准备好，即可出发";
      status.textContent = "WireGuard 与代理将按你的设置启动";
      tag.textContent = "等待连接";
      connect.innerHTML = '<span aria-hidden="true">⏻</span> 连接隧道';
    }
  }
  toggle.addEventListener("click", () => { proxy = !proxy; render(); });
  connect.addEventListener("click", () => {
    clearTimeout(timer);
    if (state === "connected") { state = "idle"; render(); return; }
    state = "connecting"; appliedProxy = proxy; render();
    timer = setTimeout(() => { state = "connected"; render(); }, 1400);
  });
  render();
})();
