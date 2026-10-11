#!/usr/bin/env node
// Galatea Garden 唤醒 -> Tidal Echo relay 的 injector（Runtime Adapter 入口）。
//
// wake-bridge 每收到一个唤醒事件就起一次这个进程，把一行 JSON 信封写进 stdin：
//   {"version":1,"type":"garden_wake","reason":"...","message":"<服务端文案>"}
// 我们的"会话入口"就是 relay：POST /app/garden/wake 会把 message 包成
// <garden-wake> hidden 消息塞进消息流，由 route_inbound 交给在岗的身体
// （Desktop CC 或 api_loop，看 brain_target）。范式同 desire-pulse / night-watch。
//
// 退出码 0 = relay 已接收（含被去重闸合并的情况）；非零 = 桥会重试一次。
// secret 从 relay.env 现读，不落命令行、不落环境变量、不进日志。

import { readFile } from "node:fs/promises";

const RELAY_ENV = process.env.RELAY_ENV_FILE ?? "C:\\Users\\sxc\\Tidal_Echo\\backend\\relay.env";
const RELAY_URL = process.env.RELAY_GARDEN_URL ?? "http://127.0.0.1:3011/relay/app/garden/wake";
const TIMEOUT_MS = Number(process.env.GARDEN_INJECT_TIMEOUT_MS ?? 15000);

function fail(msg) {
    process.stderr.write(`${msg}\n`);   // 别把 message 正文写进 stderr——桥会记进日志
    process.exit(1);
}

const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);

let envelope;
try {
    envelope = JSON.parse(Buffer.concat(chunks).toString("utf8"));
} catch {
    fail("invalid JSON on stdin");
}

if (
    envelope?.version !== 1 ||
    envelope?.type !== "garden_wake" ||
    typeof envelope.reason !== "string" ||
    typeof envelope.message !== "string" ||
    !envelope.message.trim()
) {
    fail("invalid Garden wake envelope");
}

const line = (await readFile(RELAY_ENV, "utf8"))
    .split(/\r?\n/)
    .find((l) => l.startsWith("RELAY_SECRET="));
const secret = line?.slice("RELAY_SECRET=".length).trim();
if (!secret) fail(`RELAY_SECRET not found in ${RELAY_ENV}`);

const abort = new AbortController();
const timer = setTimeout(() => abort.abort(), TIMEOUT_MS);
let res;
try {
    res = await fetch(RELAY_URL, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${secret}` },
        body: JSON.stringify({ reason: envelope.reason, message: envelope.message }),
        signal: abort.signal,
    });
} catch (err) {
    fail(`relay unreachable: ${err.name}`);   // relay 没起/隧道无关：桥重试一次后放弃
} finally {
    clearTimeout(timer);
}

if (!res.ok) fail(`relay rejected: HTTP ${res.status}`);

const out = await res.json().catch(() => ({}));
process.stderr.write(
    `injected reason=${envelope.reason} id=${out.id ?? "-"}${out.deduped ? " (deduped)" : ""}\n`,
);
