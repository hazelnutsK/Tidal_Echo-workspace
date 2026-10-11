import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";
import test from "node:test";

// Run the real bridge handlers with all network, account, disk and timer access
// replaced. Tests cannot poll WeChat, call a model, or send a real message.
const bridgeUrl = new URL("./bridge.mjs", import.meta.url);
const source = readFileSync(bridgeUrl, "utf8")
  .replace(/^import .*;\r?\n/gm, "")
  .replaceAll("import.meta.url", JSON.stringify(bridgeUrl.href))
  .replace(/log\(`微信桥起来了[^]*$/, "")
  + "\nglobalThis.bridge = { state, handleInbound, onPayload, catchUp, flush: () => sendChain };";

function fixture({ target = "loop", active = "api-a", saved = null, offline = false } = {}) {
  const requests = [], sent = [];
  const config = { active_session: active, sessions: active ? [{ id: active }] : [] };
  const server = { on() { return this; }, listen() { return this; } };
  const sandbox = {
    path, fileURLToPath, Buffer, AbortSignal, TextDecoder,
    process: { env: { RELAY_SECRET: "test-only" }, exit() { throw new Error("unexpected exit"); } },
    console: { log() {}, error() {} },
    setTimeout() { return 1; }, clearTimeout() {},
    mkdirSync() {}, writeFileSync() {}, renameSync() {},
    existsSync(p) { return p.endsWith("account.json") || (p.endsWith("bridge.json") && saved !== null); },
    readFileSync(p) {
      if (p.endsWith("account.json")) return JSON.stringify({ user_id: "owner" });
      if (p.endsWith("bridge.json")) return JSON.stringify(saved);
      throw new Error("unexpected file read");
    },
    http: { createServer() { return server; } },
    ilink: {
      ItemType: { TEXT: 1, IMAGE: 2, VOICE: 3, FILE: 4, VIDEO: 5 },
      async sendText(...args) { sent.push(args[3]); },
      async sendTyping() {},
    },
    async fetch(url, options) {
      const endpoint = new URL(url).pathname.replace(/^\/relay/, "");
      const json = options.body ? JSON.parse(options.body) : undefined;
      requests.push({ endpoint, json });
      let result;
      if (endpoint === "/app/brain") result = { target };
      else if (endpoint === "/app/loop_config") {
        if (offline) throw new Error("API offline");
        result = config;
      } else if (endpoint === "/app/send") result = { id: 100 };
      else if (endpoint.startsWith("/app/history")) result = { messages: sandbox.history || [] };
      else if (endpoint.startsWith("/app/ask/")) result = { ok: true };
      else throw new Error(`unexpected request: ${endpoint}`);
      return { ok: true, text: async () => JSON.stringify(result) };
    },
  };
  vm.runInNewContext(source, sandbox, { filename: "bridge.mjs" });
  return { ...sandbox.bridge, requests, sent, config, sandbox };
}

const incoming = (text = "hello") => ({
  from_user_id: "owner", context_token: "test-context",
  item_list: [{ type: 1, text_item: { text } }],
});
const reply = (id, session = "api-a", text = "answer") => ({
  id, from: "ai", kind: "reply", text, ts: new Date().toISOString(), meta: { api_session: session },
});
const appMessage = (id) => ({
  id, from: "human", kind: "user", ts: new Date(Date.now() + 1).toISOString(),
  meta: { user: "human", api_session: "api-a" },
});

test("API input and reply share a session; other windows and desktop are excluded", async () => {
  const f = fixture();
  await f.handleInbound(incoming());
  assert.equal(f.requests.at(-1).json.api_session, "api-a");
  assert.equal(f.requests.at(-1).json.via, "wechat");
  f.onPayload(reply(101));
  f.onPayload(reply(101)); // duplicate SSE delivery
  f.onPayload(reply(102, "api-b", "wrong window"));
  f.onPayload(reply(103, "", "desktop"));
  await f.flush();
  assert.deepEqual(f.sent, ["answer"]);
});

test("each new inbound uses the selected API window and clears old cards", async () => {
  const f = fixture();
  await f.handleInbound(incoming());
  f.state.openAsk = { id: 1, n: 2, at: Date.now() };
  f.state.openTimer = { id: 2, at: Date.now() };
  f.config.active_session = "api-b";
  f.config.sessions.push({ id: "api-b" });
  await f.handleInbound(incoming("A"));
  assert.equal(f.requests.at(-1).endpoint, "/app/send");
  assert.equal(f.requests.at(-1).json.api_session, "api-b");
  assert.equal(f.state.openAsk, null);
  assert.equal(f.state.openTimer, null);
  f.onPayload(reply(101, "api-a", "old window"));
  f.onPayload(reply(102, "api-b", "new window"));
  await f.flush();
  assert.deepEqual(f.sent, ["new window"]);
});

test("card answers still use the card endpoint in the same session", async () => {
  const f = fixture();
  await f.handleInbound(incoming());
  f.state.openAsk = { id: 55, n: 2, at: Date.now() };
  await f.handleInbound(incoming("B"));
  assert.equal(f.requests.at(-1).endpoint, "/app/ask/55/answer");
  assert.equal(f.requests.at(-1).json.index, 1);
});

test("App input stops both pending and later WeChat deliveries", async () => {
  const f = fixture();
  await f.handleInbound(incoming());
  f.onPayload(reply(101));
  f.onPayload(appMessage(102));
  await f.flush();
  f.onPayload(reply(103));
  await f.flush();
  assert.deepEqual(f.sent, []);
});

test("30-minute expiry and non-reply events never deliver", async () => {
  const f = fixture();
  await f.handleInbound(incoming());
  f.onPayload({ ...reply(101), kind: "thinking" });
  f.onPayload({ type: "reply_delta", text: "partial", api_session: "api-a" });
  f.state.route.at = Date.now() - 31 * 60_000;
  f.onPayload(reply(102));
  await f.flush();
  assert.deepEqual(f.sent, []);
});

test("desktop and API without named windows retain legacy routing", async () => {
  for (const settings of [{ target: "desktop" }, { active: "" }]) {
    const f = fixture(settings);
    await f.handleInbound(incoming());
    assert.equal(f.requests.at(-1).json.api_session, undefined);
    f.onPayload(reply(101, "", "legacy reply"));
    f.onPayload(reply(102, "api-a", "unrelated"));
    await f.flush();
    assert.deepEqual(f.sent, ["legacy reply"]);
  }
});

test("API session lookup failure does not silently send to the wrong window", async () => {
  const f = fixture({ offline: true });
  await assert.rejects(f.handleInbound(incoming()), /API offline/);
  assert.equal(f.requests.some((r) => r.endpoint === "/app/send"), false);
});

test("restart catches up only the persisted WeChat session", async () => {
  const f = fixture({ saved: {
    route: { source: "wechat", at: Date.now() - 1000, api_session: "api-a" },
    lastSeenId: 100, ctx: { user: "owner", token: "test-context" },
  } });
  f.sandbox.history = [reply(101, "api-b", "unrelated"), reply(102, "api-a", "catchup")];
  await f.catchUp();
  await f.flush();
  assert.deepEqual(f.sent, ["catchup"]);
});

test("old saved bridge state without api_session still supports desktop replies", async () => {
  const f = fixture({ saved: { route: { source: "wechat", at: Date.now() - 1000 } } });
  f.onPayload(reply(101, "", "old state"));
  await f.flush();
  assert.deepEqual(f.sent, ["old state"]);
});
