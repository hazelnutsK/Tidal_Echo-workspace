// 微信 ⇄ relay 的桥(2026-09-26)。
//
// 不是另一个身体:微信只是 relay 的又一个入口。她在微信说的话走 /app/send
// (带 via:"wechat"),和 App 里说的落进同一个库、投给同一个我;我的回复照常先进 App,
// 这里从 /app/stream 听到之后,按"她最后在哪说话"决定要不要抄一份回微信:
//   - 她最后一句是从微信来的,且不到 WINDOW_MIN 分钟 → 抄送微信
//   - 否则只留在 App(她在家用 App 时微信不会响)
// 我主动找她的消息走同一条规则,所以上班时间找得到她,下班自动回到 App。
// API 身体:每条微信消息绑定当时激活的 API 窗口,只抄送该窗口的回复。
//
// 微信渲染不了的卡片换成字:倒计时/选择题/peek。选择题她回一个字母、倒计时她回
// "搞定",会直接替她按卡片上的按钮(和在 App 里点一样,不另起一条气泡)。
import { readFileSync, writeFileSync, existsSync, mkdirSync, renameSync } from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import * as ilink from "./ilink.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const STATE_DIR = path.join(HERE, "state");
const ACCOUNT_FILE = path.join(STATE_DIR, "account.json");
const STATE_FILE = path.join(STATE_DIR, "bridge.json");
mkdirSync(STATE_DIR, { recursive: true });

function readEnv(file) {
  const out = {};
  if (!existsSync(file)) return out;
  for (const line of readFileSync(file, "utf-8").replace(/^﻿/, "").split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
  return out;
}

const env = { ...readEnv(path.join(HERE, "..", "backend", "relay.env")), ...process.env };
const SECRET = env.RELAY_SECRET;
const RELAY_ORIGIN = `http://127.0.0.1:${env.RELAY_PORT || 3011}`;
const RELAY = RELAY_ORIGIN + (env.RELAY_PUBLIC_PREFIX || "/relay").replace(/\/$/, "");
const WINDOW_MIN = Number(env.WECHAT_WINDOW_MIN || 30);
const CATCHUP_MAX_AGE_MIN = 15;     // 桥断过再连上,只补这么久以内的回复,别一口气倒一堆旧话
const STATUS_PORT = Number(env.WECHAT_BRIDGE_PORT || 3031);
if (!SECRET) { console.error("relay.env 里没有 RELAY_SECRET"); process.exit(1); }

const log = (...a) => console.log(new Date().toISOString().slice(0, 19), ...a);

// ---- 状态 --------------------------------------------------------------------

const state = {
  buf: "",                 // getupdates 游标
  ctx: null,               // { user, token } 她最近一条消息带的 context_token
  route: { source: "app", at: 0, api_session: "" },
  lastSeenId: 0,
  forwarded: [],           // 抄送过的回复 id(去重)
  openAsk: null,           // { id, n } 最近抄过去、还没答的选择题
  openTimer: null,         // { id } 最近抄过去、还在跑的倒计时
  ...(existsSync(STATE_FILE) ? JSON.parse(readFileSync(STATE_FILE, "utf-8")) : {}),
};
const status = { started: new Date().toISOString(), poll: "", sse: "", lastIn: "", lastOut: "", lastError: "" };
let saveTimer;
function save() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    state.forwarded = state.forwarded.slice(-300);
    writeFileSync(STATE_FILE + ".tmp", JSON.stringify(state, null, 2));
    renameSync(STATE_FILE + ".tmp", STATE_FILE);
  }, 200);
}
function fail(where, err) {
  // undici 的 "fetch failed" 本身不说为什么,真正的原因(ECONNRESET/超时/DNS)在 cause 里
  const cause = err?.cause ? ` (${err.cause.code || err.cause.message || err.cause})` : "";
  status.lastError = `${new Date().toISOString().slice(0, 19)} ${where}: ${err?.message || err}${cause}`;
  log(`[${where}]`, (err?.message || err) + cause);
}

if (!existsSync(ACCOUNT_FILE)) { console.error("还没扫码:先跑 登录微信.cmd"); process.exit(1); }
const account = JSON.parse(readFileSync(ACCOUNT_FILE, "utf-8"));

// 单实例:两个桥同时跑会抢游标、回复抄两遍。状态端口顺便给排障用。
http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify({ ...status, route: state.route, window_min: WINDOW_MIN,
                           has_context: !!state.ctx, lastSeenId: state.lastSeenId }, null, 2));
}).on("error", (e) => {
  if (e.code === "EADDRINUSE") { console.error(`:${STATUS_PORT} 被占了,桥已经在跑`); process.exit(1); }
  throw e;
}).listen(STATUS_PORT, "127.0.0.1");

// ---- relay -------------------------------------------------------------------

async function relay(pathname, { method = "GET", json, body, headers = {} } = {}) {
  const res = await fetch(RELAY + pathname, {
    method,
    headers: { Authorization: `Bearer ${SECRET}`, ...(json ? { "Content-Type": "application/json" } : {}), ...headers },
    body: json ? JSON.stringify(json) : body,
    signal: AbortSignal.timeout(30_000),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`relay ${method} ${pathname} ${res.status}: ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : {};
}

function sniffMime(buf, fallback = "application/octet-stream") {
  if (buf[0] === 0xff && buf[1] === 0xd8) return "image/jpeg";
  if (buf[0] === 0x89 && buf[1] === 0x50) return "image/png";
  if (buf[0] === 0x47 && buf[1] === 0x49) return "image/gif";
  if (buf.slice(0, 4).toString() === "RIFF" && buf.slice(8, 12).toString() === "WEBP") return "image/webp";
  return fallback;
}

const EXT_MIME = { pdf: "application/pdf", txt: "text/plain", md: "text/markdown", doc: "application/msword",
  docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  xls: "application/vnd.ms-excel", xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  mp4: "video/mp4", mp3: "audio/mpeg", jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png" };

async function uploadToRelay(buf, name, mime) {
  return relay(`/app/upload?name=${encodeURIComponent(name)}`, {
    method: "POST", body: buf, headers: { "Content-Type": mime },
  });
}

// ---- 微信 → relay ------------------------------------------------------------

async function inboundSession() {
  const { target } = await relay("/app/brain");
  if (target !== "loop") return "";
  // 此端点在 API 身体离线时返回错误,不会把取不到会话误当成主线。
  const config = await relay("/app/loop_config");
  const session = String(config.active_session || "").trim();
  if (!Array.isArray(config.sessions)
      || (config.sessions.length && !config.sessions.some((s) => s.id === session))) {
    throw new Error("API 当前窗口不可用,请在 App 里选择一个 API 窗口");
  }
  return session;
}

function quoteOf(item) {
  const ref = item.ref_msg;
  if (!ref) return "";
  const inner = ref.message_item;
  const body = inner?.text_item?.text || inner?.voice_item?.text
    || (inner ? { 2: "[图片]", 3: "[语音]", 4: "[文件]", 5: "[视频]" }[inner.type] : "") || "";
  return [ref.title?.trim(), body].filter(Boolean).join(" | ");
}

async function handleInbound(msg) {
  if (msg.message_type === 2) return;                         // 自己发出去的
  const from = msg.from_user_id || "";
  if (account.user_id && from !== account.user_id) {         // 只认扫码的她
    log("[in] 忽略陌生人", from.slice(0, 8));
    return;
  }
  if (msg.context_token) { state.ctx = { user: from, token: msg.context_token }; save(); }

  const parts = [];
  const attachments = [];
  let quote = "";
  for (const item of msg.item_list || []) {
    quote ||= quoteOf(item);
    if (item.type === ilink.ItemType.TEXT) parts.push(item.text_item?.text || "");
    else if (item.type === ilink.ItemType.VOICE) {
      parts.push(item.voice_item?.text || "[她发了条语音,微信没转出字]");
    } else if ([ilink.ItemType.IMAGE, ilink.ItemType.FILE, ilink.ItemType.VIDEO].includes(item.type)) {
      try {
        const buf = await ilink.downloadMedia(item);
        if (!buf) continue;
        let name = "wechat", mime;
        if (item.type === ilink.ItemType.IMAGE) mime = sniffMime(buf, "image/jpeg");
        else if (item.type === ilink.ItemType.VIDEO) { mime = "video/mp4"; name = "wechat.mp4"; }
        else {
          name = item.file_item?.file_name || "file.bin";
          mime = EXT_MIME[name.split(".").pop().toLowerCase()] || "application/octet-stream";
        }
        attachments.push(await uploadToRelay(buf, name, mime));
      } catch (err) {
        fail("in-media", err);
        parts.push("[她发了个附件,没下下来]");
      }
    }
  }
  let text = parts.join("\n").trim();
  if (quote) text = `「引用:${quote.slice(0, 120)}」\n${text}`;
  if (!text && !attachments.length) return;

  const session = await inboundSession();
  if (session !== (state.route.api_session || "")) {
    state.openAsk = null;
    state.openTimer = null;
  }
  state.route = { source: "wechat", at: Date.now(), api_session: session };
  save();
  status.lastIn = new Date().toISOString();

  // 回一个字母 = 点选择题;回"搞定" = 按倒计时卡。和她在 App 里点按钮一样,不另起气泡。
  if (!attachments.length && !quote) {
    const STALE = 3 * 3600_000;   // 三小时前的卡就算了,那时候的一个字母多半不是在答它
    if (state.openAsk && Date.now() - (state.openAsk.at || 0) > STALE) state.openAsk = null;
    if (state.openTimer && Date.now() - (state.openTimer.at || 0) > STALE) state.openTimer = null;
    const letter = text.match(/^\s*([A-Fa-f])\s*$/);
    if (letter && state.openAsk) {
      const index = letter[1].toUpperCase().charCodeAt(0) - 65;
      if (index < state.openAsk.n) {
        const id = state.openAsk.id;
        state.openAsk = null; save();
        try { await relay(`/app/ask/${id}/answer`, { method: "POST", json: { index } }); return; }
        catch (err) { fail("ask", err); }
      }
    }
    if (/^\s*搞定了?[!！。~～]*\s*$/.test(text) && state.openTimer) {
      const id = state.openTimer.id;
      state.openTimer = null; save();
      try {
        const r = await relay(`/app/timer/${id}/done`, { method: "POST", json: {} });
        if (r?.timer?.status === "done") return;
      } catch (err) { fail("timer", err); }
    }
  }
  await relay("/app/send", { method: "POST", json: {
    text, attachments, via: "wechat", ...(session ? { api_session: session } : {}),
  } });
  log("[in]", text.slice(0, 40).replace(/\n/g, " "), attachments.length ? `+${attachments.length}附件` : "");
}

async function pollLoop() {
  let failures = 0;
  for (;;) {
    try {
      const data = await ilink.getUpdates(account, state.buf);
      const errcode = data.errcode ?? data.ret;
      if (errcode && errcode !== 0) {
        if (errcode === -14) {
          status.poll = "token 过期,停 60 分钟(要重扫就跑 登录微信.cmd)";
          fail("poll", new Error("session expired (-14)"));
          await sleep(60 * 60_000);
          continue;
        }
        throw new Error(`getupdates ret=${data.ret} errcode=${data.errcode} ${data.errmsg || ""}`);
      }
      failures = 0;
      status.poll = "ok " + new Date().toISOString().slice(11, 19);
      if (data.get_updates_buf) { state.buf = data.get_updates_buf; save(); }
      for (const m of data.msgs || []) {
        try { await handleInbound(m); } catch (err) { fail("in", err); }
      }
    } catch (err) {
      failures++;
      status.poll = `失败 ${failures} 次`;
      fail("poll", err);
      await sleep(Math.min(60_000, 2000 * failures));
    }
  }
}

// ---- relay → 微信 ------------------------------------------------------------

function wechatActive(atMs) {
  return state.route.source === "wechat" && atMs - state.route.at < WINDOW_MIN * 60_000;
}

function matchesWechatSession(session) {
  return (session || "") === (state.route.api_session || "");
}

function renderForWechat(p) {
  const meta = p.meta || {};
  let text = (p.text || "").trim();
  const extra = [];
  if (meta.timer?.status === "running") {
    extra.push(`[倒计时 ${meta.timer.minutes} 分钟:${meta.timer.label}]\n做完回我"搞定"`);
  }
  if (meta.ask && !meta.ask.answer) {
    const opts = meta.ask.options.map((o, i) => `${String.fromCharCode(65 + i)}. ${o}`).join("\n");
    extra.push(`${meta.ask.question}\n${opts}\n(回个字母就行)`);
  }
  if (meta.peek) {
    extra.push(`[想看一眼你的屏幕${meta.peek.note ? ":" + meta.peek.note : ""}。这个得去 App 里点]`);
  }
  if (extra.length) text = [text, ...extra].filter(Boolean).join("\n\n");
  return text;
}

let sendChain = Promise.resolve();
function forward(p) {
  sendChain = sendChain.then(async () => {
    // 排队发送期间她可能已切回 App 或换窗口;发出去前再核对一次。
    if (!wechatActive(Date.now()) || !matchesWechatSession(p.meta?.api_session)) return;
    const to = state.ctx?.user || account.user_id;
    const ctxToken = state.ctx?.token;
    if (!to) return;
    const meta = p.meta || {};
    try {
      const text = renderForWechat(p);
      if (text) await ilink.sendText(account, to, ctxToken, text);
      for (const att of meta.attachments || []) {
        if (!att?.url || att.xhs) continue;
        const res = await fetch(RELAY_ORIGIN + att.url, { headers: { Authorization: `Bearer ${SECRET}` } });
        if (!res.ok) throw new Error(`拿附件 ${att.url} ${res.status}`);
        const buf = Buffer.from(await res.arrayBuffer());
        if (att.kind === "image") await ilink.sendImage(account, to, ctxToken, buf);
        else if (att.kind === "audio") await ilink.sendFile(account, to, ctxToken, buf, "Altair的语音.mp3");
        else await ilink.sendFile(account, to, ctxToken, buf, att.name || "file");
      }
      if (meta.ask && !meta.ask.answer) { state.openAsk = { id: p.id, n: meta.ask.options.length, at: Date.now() }; }
      if (meta.timer?.status === "running") { state.openTimer = { id: p.id, at: Date.now() }; }
      status.lastOut = new Date().toISOString();
      log("[out]", (p.text || "").slice(0, 40).replace(/\n/g, " "));
    } catch (err) {
      fail("out", err);   // 微信没送到就算了,App 里本来就有
    }
    save();
  });
}

let lastTyping = 0;
function onPayload(p, { catchUp = false } = {}) {
  if (p.type === "typing") {
    if (p.active && (!p.api_session || matchesWechatSession(p.api_session))
        && wechatActive(Date.now()) && Date.now() - lastTyping > 20_000 && state.ctx) {
      lastTyping = Date.now();
      ilink.sendTyping(account, state.ctx.user, state.ctx.token).catch(() => {});
    }
    return;
  }
  // 她在 App 里把卡按掉了:微信这边别再把一个字母当成答案吞掉
  if (p.type === "ask" && state.openAsk?.id === p.id && p.ask?.answer) { state.openAsk = null; save(); return; }
  if (p.type === "timer" && state.openTimer?.id === p.id && p.timer?.status !== "running") { state.openTimer = null; save(); return; }
  if (typeof p.id !== "number" || !p.from) return;
  if (p.id > state.lastSeenId) { state.lastSeenId = p.id; save(); }
  const meta = p.meta || {};
  const at = Date.parse(p.ts) || Date.now();
  if (p.from === "human") {
    if (meta.user !== "human" || meta.hidden || meta.command) return;
    if (meta.via === "wechat") {
      if (at >= state.route.at) state.route = { source: "wechat", at, api_session: meta.api_session || "" };
    } else if (at >= state.route.at) {
      state.route = { source: "app", at, api_session: meta.api_session || "" }; // 她回到 App 说话了,微信就不响了
    }
    save();
    return;
  }
  if (p.kind !== "reply" || !matchesWechatSession(meta.api_session)) return;
  if (state.forwarded.includes(p.id)) return;
  state.forwarded.push(p.id);
  save();
  if (catchUp && Date.now() - at > CATCHUP_MAX_AGE_MIN * 60_000) return;
  if (wechatActive(at)) forward(p);
}

async function catchUp() {
  if (!state.lastSeenId) return;   // 第一次跑:从现在开始,不补历史(第一条 SSE 事件就会把它填上)
  const { messages } = await relay(`/app/history?since=${state.lastSeenId}&limit=200`);
  for (const p of messages || []) onPayload(p, { catchUp: true });
}

async function sseLoop() {
  for (;;) {
    const ctrl = new AbortController();
    let watchdog;
    const kick = () => { clearTimeout(watchdog); watchdog = setTimeout(() => ctrl.abort(), 60_000); };
    try {
      await catchUp();
      const res = await fetch(RELAY + "/app/stream", {
        headers: { Authorization: `Bearer ${SECRET}`, Accept: "text/event-stream" }, signal: ctrl.signal,
      });
      if (!res.ok) throw new Error(`stream ${res.status}`);
      status.sse = "connected " + new Date().toISOString().slice(11, 19);
      kick();
      const decoder = new TextDecoder();
      let pending = "";
      for await (const chunk of res.body) {
        kick();
        pending += decoder.decode(chunk, { stream: true }).replace(/\r\n/g, "\n");
        let cut;
        while ((cut = pending.indexOf("\n\n")) >= 0) {
          const block = pending.slice(0, cut);
          pending = pending.slice(cut + 2);
          const data = block.split("\n").filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trimStart()).join("\n");
          if (!data) continue;
          try { onPayload(JSON.parse(data)); } catch (err) { fail("sse-parse", err); }
        }
      }
      throw new Error("stream ended");
    } catch (err) {
      status.sse = "reconnecting";
      if (err.name !== "AbortError") fail("sse", err);
    } finally {
      clearTimeout(watchdog);
    }
    await sleep(3000);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

log(`微信桥起来了 · relay ${RELAY} · 窗口 ${WINDOW_MIN} 分钟 · 状态 http://127.0.0.1:${STATUS_PORT}/`);
pollLoop();
sseLoop();
