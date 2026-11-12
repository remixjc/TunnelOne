const assert = require("node:assert/strict");
const http = require("node:http");
const path = require("node:path");
const fs = require("node:fs/promises");
const { chromium } = require("playwright");

(async () => {
  const root = path.resolve(__dirname, "../website");
  const output = path.resolve(__dirname, "../build/site-qa");
  await fs.mkdir(output, { recursive: true });
  const mime = { ".html": "text/html", ".css": "text/css", ".js": "text/javascript",
    ".svg": "image/svg+xml", ".png": "image/png" };
  const server = http.createServer(async (request, response) => {
    try {
      const pathname = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
      const file = path.resolve(root, "." + (pathname === "/" ? "/index.html" : pathname));
      if (!file.startsWith(root + path.sep)) throw new Error("Invalid path");
      response.setHeader("Content-Type", mime[path.extname(file)] || "application/octet-stream");
      response.end(await fs.readFile(file));
    } catch { response.statusCode = 404; response.end("Not found"); }
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  let browser;
  try {
    browser = await chromium.launch({
      headless: true,
      ...(process.env.PLAYWRIGHT_EXECUTABLE_PATH
        ? { executablePath: process.env.PLAYWRIGHT_EXECUTABLE_PATH } : {})
    });
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, colorScheme: "dark" });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    page.on("response", response => {
      if (response.url().startsWith(base) && response.status() >= 400) errors.push(response.url());
    });
    await page.goto(base);
    await page.locator("h1").waitFor();
    await page.screenshot({ path: path.join(output, "desktop.png"), fullPage: true });
    await page.locator("#connect-button").click();
    await page.locator("#demo-title").filter({ hasText: "隧道与代理已就绪" }).waitFor();
    await page.locator("#proxy-toggle").click();
    assert.equal(await page.locator("#proxy-toggle").getAttribute("aria-checked"), "false");
    assert.match(await page.locator("#proxy-description").innerText(), /下次连接生效/);
    await page.locator("#connect-button").click();
    await page.locator("#connect-button").click();
    await page.locator("#demo-title").filter({ hasText: "WireGuard 已就绪" }).waitFor();
    assert.match(await page.locator(".route-diagram").getAttribute("class"), /hidden-proxy/);
    await page.locator("#connect-button").click();
    await page.locator("details").first().locator("summary").click();
    assert.equal(await page.locator("details").first().getAttribute("open"), "");
    for (const width of [390, 320]) {
      await page.setViewportSize({ width, height: 900 });
      const sizes = await page.evaluate(() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth }));
      assert.ok(sizes.scroll <= sizes.viewport, `Horizontal overflow at ${width}: ${sizes.scroll}`);
    }
    await page.screenshot({ path: path.join(output, "mobile.png"), fullPage: true });
    await page.goto(base + "/prototype.html");
    await page.locator("#to-main").waitFor();
    assert.equal(await page.locator("#tunnel-one-prototype").count(), 1);
    await page.setViewportSize({ width: 1280, height: 1050 });
    await page.locator("#to-main svg").first().waitFor();
    // Give the resized macOS compositor a frame before taking the QA image.
    await page.waitForTimeout(250);
    await page.screenshot({ path: path.join(output, "prototype.png"), fullPage: true });
    await page.locator('[data-action="connect"]').click();
    await page.locator(".to-status-title").filter({ hasText: "隧道与代理已连接" }).waitFor();
    assert.deepEqual(errors, []);
    console.log("Website passed: connect/disconnect, proxy preferences, FAQ, 390/320px layout, prototype, no JS/resource errors.");
  } finally {
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
