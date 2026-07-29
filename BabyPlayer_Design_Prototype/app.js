const screens = [
  ["welcome", "01 · 欢迎与家长设置"],
  ["server", "02 · 输入 Jellyfin 地址"],
  ["pairing", "03 · Quick Connect 配对"],
  ["success", "04 · 配对成功"],
  ["home", "05 · 儿童首页 / 默认 Focus"],
  ["home-gear", "06 · 儿童首页 / 家长入口 Focus"],
  ["empty", "07 · 空状态"],
  ["offline", "08 · 媒体源不可用"],
  ["player-day", "09 · 白天模式播放"],
  ["player-sleep", "10 · 哄睡模式播放"],
  ["player-loading", "11 · 播放加载中"],
  ["player-error", "12 · 播放失败"],
  ["settings", "13 · 家长设置 / 平铺列表"],
  ["tags", "14 · 内容标签分配"]
];

const params = new URLSearchParams(location.search);
let current = params.get("screen") || "home";
const capture = params.get("capture") === "1";
if (capture) document.body.classList.add("capture");
let homeFocus = current === "home-gear" ? { zone: "gear", index: 4 } : { zone: "day", index: 0 };
let settingsFocus = 0;
let tagsFocus = 0;
let soundEnabled = true;
let audioContext;

const stage = document.querySelector("#stage");
const links = document.querySelector("#screen-links");

const media = [
  ["小星星", "cover-a"], ["颜色小火车", "cover-b"], ["海洋朋友", "cover-c"],
  ["ABC 歌", "cover-d"], ["动物律动", "cover-e"], ["月亮晚安", "cover-f"]
];

function caption(name) {
  return `<div class="screen-caption">${name}</div>`;
}

function logo() {
  return `<div class="logo"><span class="logo-mark"></span><span>BabyPlayer</span></div>`;
}

function card([title, art], focused = false) {
  return `<div class="media-card${focused ? " focused" : ""}" tabindex="0" data-focusable>
    <div class="cover ${art}"></div><div class="media-title">${title}</div>
  </div>`;
}

function welcome() {
  return `<section class="screen"><div class="safe setup-grid">
    <div><div class="eyebrow">家长设置</div><h1 class="display-title">一次连接，之后只看见喜欢的内容。</h1>
      <p class="lead">连接家里的 Jellyfin。完成后，孩子打开 App 就能直接选择熟悉的视频。</p>
      <div class="button-row"><button class="tv-button focused" data-focusable>开始设置</button></div>
    </div>
    <div class="setup-steps">
      <div class="setup-step active"><span class="step-no">1</span><span class="step-copy"><strong>输入服务器地址</strong><small>例如 192.168.1.8:8096</small></span></div>
      <div class="setup-step"><span class="step-no">2</span><span class="step-copy"><strong>在 Mac 上批准</strong><small>使用 6 位 Quick Connect 码</small></span></div>
      <div class="setup-step"><span class="step-no">3</span><span class="step-copy"><strong>进入儿童首页</strong><small>之后打开即可使用</small></span></div>
    </div>
  </div>${caption("WELCOME · PARENT SETUP")}</section>`;
}

function server() {
  const keys = "1234567890qwertyuiopasdfghjkl-:zxcvbnm./".split("");
  return `<section class="screen"><div class="safe">
    <div class="eyebrow">第 1 步，共 2 步</div><h1 class="display-title" style="font-size:60px">输入 Jellyfin 服务器地址</h1>
    <p class="lead" style="margin-top:16px">请确保 Apple TV 和 Mac 连接到同一个家庭网络。</p>
    <div style="margin-top:42px"><span class="field-label">服务器地址</span><div class="address-field">192.168.1.8:8096</div></div>
    <div class="keyboard">${keys.map((k,i)=>`<div class="key${i===11?" focused":""}">${k}</div>`).join("")}<div class="key wide">空格</div><div class="key wide">清除</div><div class="key wide">连接</div></div>
  </div>${caption("SYSTEM KEYBOARD REPRESENTATION")}</section>`;
}

function pairing() {
  return `<section class="screen"><div class="safe">${logo()}<div class="pair-panel">
    <div class="eyebrow">第 2 步，共 2 步</div><h1 class="display-title" style="max-width:none;font-size:62px">在 Mac 上批准这台 Apple TV</h1>
    <div class="code-row">${"427159".split("").map(n=>`<span class="code-digit">${n}</span>`).join("")}</div>
    <p class="lead" style="margin:0 auto;max-width:980px">打开 Jellyfin 网页，进入 Quick Connect，输入上面的 6 位数字码。</p>
    <div class="pulse-line"></div><p class="fine" style="margin-top:18px">等待批准… 代码将在 4 分 36 秒后失效</p>
  </div></div>${caption("JELLYFIN QUICK CONNECT")}</section>`;
}

function success() {
  return `<section class="screen"><div class="state-center"><div style="display:grid;place-items:center;text-align:center">
    <div class="success-mark">✓</div><div class="eyebrow">连接成功</div><h1 class="display-title" style="max-width:1100px">内容准备好了</h1>
    <p class="lead" style="margin-left:auto;margin-right:auto">以后打开 BabyPlayer，会直接进入儿童首页。</p>
    <div class="button-row"><button class="tv-button focused" data-focusable>进入首页</button></div>
  </div></div>${caption("QUICK CONNECT · SUCCESS")}</section>`;
}

function home(forceGearFocus = false) {
  const focus = forceGearFocus ? { zone: "gear", index: 4 } : homeFocus;
  const mood = focus.zone === "sleep" ? "sleep" : focus.zone === "day" ? "day" : "neutral";
  const day = media.map((m,i)=>card(m, focus.zone === "day" && focus.index === i)).join("");
  const sleepMedia = [media[5], media[0], media[2], media[3], media[1]];
  const sleep = sleepMedia.map((m,i)=>card(m, focus.zone === "sleep" && focus.index === i)).join("");
  return `<section class="screen home mood-${mood}"><div class="home-ambient" aria-hidden="true"><span></span><span></span><span></span></div><div class="safe">
    <header class="home-header"><div class="tabs">${["儿歌","动画","全部"].map((label,i)=>`<div class="tab${i===0?" active":""}${focus.zone==="tabs"&&focus.index===i?" focused":""}" data-focusable>${label}</div>`).join("")}</div><div class="home-wordmark">BabyPlayer</div></header>
    <section class="shelf"><h2 class="shelf-heading"><span class="mode-dot"></span>白天模式</h2><div class="cards">${day}</div></section>
    <section class="shelf sleep-shelf"><h2 class="shelf-heading"><span class="mode-dot"></span>哄睡模式</h2><div class="cards">${sleep}</div></section>
    <div class="gear${focus.zone==="gear"?" focused":""}" data-focusable><span class="gear-icon"></span>${focus.zone==="gear"?"家长设置":""}</div>
  </div>${caption(forceGearFocus ? "HOME · SETTINGS FOCUS" : "HOME · INTERACTIVE FOCUS")}</section>`;
}

function state(type) {
  const offline = type === "offline";
  return `<section class="screen home"><div class="safe"><header class="home-header"><div class="tabs"><div class="tab active">儿歌</div><div class="tab">动画</div><div class="tab">全部</div></div><div class="home-wordmark">BabyPlayer</div></header></div>
    <div class="state-center"><div class="state-panel"><div class="state-art${offline?" offline":""}"></div>
      <h1 class="state-title">${offline?"暂时看不到内容":"还没有内容"}</h1>
      <p class="state-copy">${offline?"请稍后再试；如果一直无法连接，请让家长检查 Mac 和家庭网络。":"请家长先在 Jellyfin 中添加视频，BabyPlayer 会自动显示在这里。"}</p>
      ${offline?'<div class="button-row" style="justify-content:center"><button class="tv-button focused" data-focusable>重试</button></div>':""}
    </div></div>${caption(offline?"HOME · SOURCE OFFLINE":"HOME · EMPTY")}</section>`;
}

function player(mode) {
  const sleep = mode === "sleep";
  return `<section class="screen"><div class="video-scene${sleep?" sleep-video":""}"></div><div class="player-vignette"></div>${caption(sleep?"PLAYER · SLEEP MODE · NO TIMER UI":"PLAYER · DAYTIME MODE · NO OVERLAY")}</section>`;
}

function playerLoading() {
  return `<section class="screen"><div class="video-scene" style="filter:brightness(.28)"></div><div class="state-center"><div><div class="spinner"></div><p class="fine" style="margin-top:24px">正在准备视频…</p></div></div>${caption("PLAYER · LOADING")}</section>`;
}

function playerError() {
  return `<section class="screen"><div class="state-center"><div class="state-panel"><div class="state-art offline"></div>
    <h1 class="state-title">这个视频暂时播不了</h1><p class="state-copy">请返回选择其他内容；家长可以稍后检查媒体文件。</p>
    <div class="button-row" style="justify-content:center"><button class="tv-button focused" data-focusable>返回首页</button></div>
  </div></div>${caption("PLAYER · ERROR")}</section>`;
}

function settings() {
  const rows = [
    ["Jellyfin 连接", "已连接 · 192.168.1.8"], ["分类映射", "儿歌 / 动画"], ["内容适用性标签", "设置"],
    ["白天模式循环次数", "3 次"], ["哄睡模式总时长", "30 分钟"], ["遥控器声音", soundEnabled ? "开启" : "关闭"], ["关于 BabyPlayer", "版本 1.0"]
  ];
  return `<section class="screen settings"><div class="safe"><header class="settings-header"><div><div class="eyebrow">仅供家长</div><h1 class="settings-title">家长设置</h1></div>${logo()}</header>
    <div class="settings-list">${rows.map((r,i)=>`<div class="settings-row${i===settingsFocus?" focused":""}" data-focusable><span>${r[0]}</span><span class="value">${r[1]}</span><span class="chevron">›</span></div>`).join("")}</div>
  </div>${caption("SETTINGS · FLAT LIST")}</section>`;
}

function tags() {
  return `<section class="screen settings"><div class="safe"><header class="settings-header"><div><div class="eyebrow">家长设置</div><h1 class="settings-title">内容适用性标签</h1><p class="fine" style="margin:12px 0 0">默认“两者都适合”；同一个视频可以同时出现在两行。</p></div></header>
    <div class="tag-list">${media.slice(0,5).map((m,i)=>`<div class="tag-row${i===tagsFocus?" focused":""}" data-focusable><div class="tag-thumb ${m[1]}"></div><div class="tag-name">${m[0]}</div><div class="segmented"><span class="segment${i===1?" active":""}">适合白天</span><span class="segment${i===4?" active":""}">适合哄睡</span><span class="segment${![1,4].includes(i)?" active":""}">两者都适合</span></div></div>`).join("")}</div>
  </div>${caption("SETTINGS · DAYTIME / SLEEP / BOTH")}</section>`;
}

const renderers = {
  welcome, server, pairing, success,
  home: () => home(false), "home-gear": () => home(true),
  empty: () => state("empty"), offline: () => state("offline"),
  "player-day": () => player("day"), "player-sleep": () => player("sleep"),
  "player-loading": playerLoading, "player-error": playerError,
  settings, tags
};

function render() {
  if (!renderers[current]) current = "home";
  stage.innerHTML = renderers[current]();
  links.innerHTML = screens.map(([id,label])=>`<a class="screen-link${id===current?" active":""}" href="?screen=${id}">${label}</a>`).join("");
  document.title = `BabyPlayer · ${screens.find(([id])=>id===current)?.[1] || current}`;
  requestAnimationFrame(syncFocusedCard);
}

function syncFocusedCard() {
  const focusedCard = stage.querySelector(".media-card.focused");
  const shelf = focusedCard?.closest(".cards");
  if (!focusedCard || !shelf) return;
  const targetLeft = focusedCard.offsetLeft - (shelf.clientWidth - focusedCard.clientWidth) / 2;
  shelf.scrollTo({ left: Math.max(0, targetLeft), behavior: "smooth" });
}

function playFeedback(type) {
  if (!soundEnabled) return;
  audioContext ||= new (window.AudioContext || window.webkitAudioContext)();
  if (audioContext.state === "suspended") audioContext.resume();

  const notes = type === "confirm"
    ? [[523.25, 0, .065], [659.25, .075, .08]]
    : type === "error"
      ? [[246.94, 0, .11]]
      : [[587.33, 0, .045]];

  notes.forEach(([frequency, delay, duration]) => {
    const oscillator = audioContext.createOscillator();
    const gain = audioContext.createGain();
    const start = audioContext.currentTime + delay;
    oscillator.type = "sine";
    oscillator.frequency.setValueAtTime(frequency, start);
    gain.gain.setValueAtTime(0.0001, start);
    gain.gain.exponentialRampToValueAtTime(type === "move" ? 0.018 : 0.028, start + .012);
    gain.gain.exponentialRampToValueAtTime(0.0001, start + duration);
    oscillator.connect(gain).connect(audioContext.destination);
    oscillator.start(start);
    oscillator.stop(start + duration + .02);
  });
}

function setFocusTilt(key) {
  const tilt = key === "ArrowLeft" ? -1.4 : key === "ArrowRight" ? 1.4 : key === "ArrowUp" ? -0.5 : key === "ArrowDown" ? 0.5 : 0;
  stage.style.setProperty("--focus-tilt", `${tilt}deg`);
  window.setTimeout(() => stage.style.setProperty("--focus-tilt", "0deg"), 150);
}

function fitStage() {
  if (capture) return;
  const reserved = window.innerWidth <= 1200 ? 250 : 320;
  const scale = Math.min((window.innerWidth - reserved - 48) / 1920, (window.innerHeight - 48) / 1080);
  document.documentElement.style.setProperty("--stage-scale", Math.max(.2, scale));
}

window.addEventListener("resize", fitStage);
window.addEventListener("keydown", (event) => {
  let handled = false;

  if (["welcome", "server", "pairing", "success"].includes(current) && event.key === "Enter") {
    const setupFlow = { welcome: "server", server: "pairing", pairing: "success", success: "home" };
    current = setupFlow[current];
    playFeedback("confirm");
    handled = true;
  } else if (["home", "home-gear"].includes(current)) {
    if (current === "home-gear") { current = "home"; homeFocus = { zone: "gear", index: 4 }; }
    const sleepCount = 5;
    if (event.key === "ArrowUp") {
      if (homeFocus.zone === "sleep") homeFocus = { zone: "day", index: Math.min(homeFocus.index, media.length - 1) };
      else if (homeFocus.zone === "day") homeFocus = { zone: "tabs", index: 0 };
      else if (homeFocus.zone === "gear") homeFocus = { zone: "sleep", index: sleepCount - 1 };
      handled = true;
    } else if (event.key === "ArrowDown") {
      if (homeFocus.zone === "tabs") homeFocus = { zone: "day", index: 0 };
      else if (homeFocus.zone === "day") homeFocus = { zone: "sleep", index: Math.min(homeFocus.index, sleepCount - 1) };
      handled = true;
    } else if (event.key === "ArrowLeft") {
      if (homeFocus.zone === "tabs" || homeFocus.zone === "day" || homeFocus.zone === "sleep") homeFocus.index = Math.max(0, homeFocus.index - 1);
      else if (homeFocus.zone === "gear") homeFocus = { zone: "sleep", index: sleepCount - 1 };
      handled = true;
    } else if (event.key === "ArrowRight") {
      if (homeFocus.zone === "tabs") homeFocus.index = Math.min(2, homeFocus.index + 1);
      else if (homeFocus.zone === "day") homeFocus.index = Math.min(media.length - 1, homeFocus.index + 1);
      else if (homeFocus.zone === "sleep") {
        if (homeFocus.index === sleepCount - 1) homeFocus = { zone: "gear", index: sleepCount - 1 };
        else homeFocus.index += 1;
      }
      handled = true;
    } else if (event.key === "Enter") {
      if (homeFocus.zone === "day") current = "player-day";
      else if (homeFocus.zone === "sleep") current = "player-sleep";
      else if (homeFocus.zone === "gear") current = "settings";
      playFeedback("confirm");
      handled = true;
    }
  } else if (current === "settings") {
    if (event.key === "ArrowUp") { settingsFocus = Math.max(0, settingsFocus - 1); handled = true; }
    else if (event.key === "ArrowDown") { settingsFocus = Math.min(6, settingsFocus + 1); handled = true; }
    else if (event.key === "Enter" && settingsFocus === 2) { current = "tags"; handled = true; }
    else if (event.key === "Enter" && settingsFocus === 5) { soundEnabled = !soundEnabled; playFeedback("confirm"); handled = true; }
  } else if (current === "tags") {
    if (event.key === "ArrowUp") { tagsFocus = Math.max(0, tagsFocus - 1); handled = true; }
    else if (event.key === "ArrowDown") { tagsFocus = Math.min(4, tagsFocus + 1); handled = true; }
  }

  if (event.key === "Escape") {
    current = current === "tags" ? "settings" : "home";
    handled = true;
  }

  if (!handled) return;
  if (event.key.startsWith("Arrow")) {
    setFocusTilt(event.key);
    playFeedback("move");
  }
  const captureQuery = capture ? "&capture=1" : "";
  history.replaceState(null, "", `?screen=${current}${captureQuery}`);
  render();
});

render();
fitStage();
