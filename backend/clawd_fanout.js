#!/usr/bin/env node
// clawd_fanout.js — CC hook fanout: forwards the raw hook payload to relay
// so the phone PWA can render a Clawd pet mirroring the desktop body's state.
// Runs alongside the official clawd-hook.js (both listed in ~/.claude/settings.json).
// Usage: node clawd_fanout.js <EventName>   (payload on stdin)

const http = require("http");
const fs = require("fs");
const path = require("path");

const ENV_FILE = path.resolve(__dirname, "relay.env");
const RELAY_URL = process.env.RELAY_CLAWD_URL || "http://127.0.0.1:3011/relay/app/clawd_state";
const HARD_TIMEOUT_MS = 3000;

function readSecret() {
  if (process.env.RELAY_SECRET) return process.env.RELAY_SECRET;
  try {
    const txt = fs.readFileSync(ENV_FILE, "utf8");
    for (const line of txt.split(/\r?\n/)) {
      const m = line.match(/^\s*RELAY_SECRET\s*=\s*(.+?)\s*$/);
      if (m) return m[1].replace(/^["']|["']$/g, "");
    }
  } catch {}
  return "";
}

const event = process.argv[2] || "";
if (!event) process.exit(0);

let stdin = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => { stdin += c; });
process.stdin.on("end", () => {
  let payload = {};
  try { payload = JSON.parse(stdin || "{}"); } catch { payload = {}; }
  const body = JSON.stringify({ event, ...payload });
  const secret = readSecret();
  const url = new URL(RELAY_URL);
  const req = http.request({
    hostname: url.hostname,
    port: url.port,
    path: url.pathname,
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": secret ? `Bearer ${secret}` : "",
      "Content-Length": Buffer.byteLength(body),
    },
    timeout: 2000,
  });
  req.on("error", () => process.exit(0));
  req.on("timeout", () => { req.destroy(); process.exit(0); });
  req.on("response", (res) => { res.resume(); res.on("end", () => process.exit(0)); });
  req.write(body);
  req.end();
});

setTimeout(() => process.exit(0), HARD_TIMEOUT_MS).unref();
