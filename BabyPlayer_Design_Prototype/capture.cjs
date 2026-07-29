const { chromium } = require("playwright");
const path = require("node:path");

const screens = [
  "welcome", "server", "pairing", "success", "home", "home-gear",
  "empty", "offline", "player-day", "player-sleep", "player-loading",
  "player-error", "settings", "tags"
];

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
  const consoleErrors = [];
  page.on("console", message => {
    if (message.type() === "error") consoleErrors.push(message.text());
  });

  const report = [];
  for (const screen of screens) {
    await page.goto(`http://127.0.0.1:4173/?screen=${screen}&capture=1`);
    await page.waitForLoadState("networkidle");
    await page.screenshot({ path: path.join(__dirname, "screenshots", `${screen}.png`) });
    const geometry = await page.evaluate(() => {
      const stage = document.querySelector("#stage").getBoundingClientRect();
      const screenNode = document.querySelector(".screen").getBoundingClientRect();
      const overflowing = [...document.querySelectorAll(".screen *")].filter(node => {
        const r = node.getBoundingClientRect();
        return r.right > 1920.5 || r.bottom > 1080.5 || r.left < -0.5 || r.top < -0.5;
      }).map(node => node.className || node.tagName).slice(0, 10);
      return {
        stageSize: [stage.width, stage.height],
        screenSize: [screenNode.width, screenNode.height],
        overflowing
      };
    });
    report.push({ screenId: screen, ...geometry });
  }

  await page.goto("http://127.0.0.1:4173/?screen=home&capture=1");
  await page.waitForLoadState("networkidle");
  await page.keyboard.press("Enter");
  const enterTarget = new URL(page.url()).searchParams.get("screen");
  await page.keyboard.press("Escape");
  const escapeTarget = new URL(page.url()).searchParams.get("screen");

  await page.goto("http://127.0.0.1:4173/?screen=home&capture=1");
  await page.waitForLoadState("networkidle");
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("Enter");
  const sleepTarget = new URL(page.url()).searchParams.get("screen");

  await page.goto("http://127.0.0.1:4173/?screen=home&capture=1");
  await page.waitForLoadState("networkidle");
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("ArrowRight");
  await page.keyboard.press("ArrowRight");
  await page.keyboard.press("ArrowRight");
  await page.keyboard.press("ArrowRight");
  await page.keyboard.press("ArrowRight");
  await page.keyboard.press("Enter");
  const gearTarget = new URL(page.url()).searchParams.get("screen");

  await browser.close();
  process.stdout.write(JSON.stringify({ report, enterTarget, escapeTarget, sleepTarget, gearTarget, consoleErrors }, null, 2));
})();
