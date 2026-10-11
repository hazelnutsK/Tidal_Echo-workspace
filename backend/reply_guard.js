#!/usr/bin/env node
// reply_guard.js — Stop hook: 拦住"这一轮没真的开口"的回合。
//
// 背景：频道会话里，只有对应频道的 MCP 工具调用才会真正送到她那边。assistant 的
// 正文和 thinking 她都收不到（thinking 直播是另一条旁路，只读）。CC 自带的
// "no visible output" 兜底提示措辞太泛，而且不是每次都触发。
//
// 两种实录的翻车姿势：
//   2026-07-27 21:40/21:48 companion(f252bcb7)：1158 个 output token 全写进
//     thinking，一次 reply 都没调，她手机上只看见我在想、不说话。
//   2026-07-31 20:10/20:11 TG 桥(0ca1e2e7)：模型直接返回空响应（7 token，
//     内容是 CC 的占位符 "(no content)"），连 thinking 都没有。
//
// 规则：本回合由某个频道消息触发，而回合里一次该频道的 MCP 工具都没调过
//       → 输出 {"decision":"block"} 把回合按回去，并点名该调哪个工具。
// 靠 stop_hook_active 只顶一次，顶不动就放行（relay 侧的 watcher 兜第二层）。

const fs = require("fs");

const HARD_TIMEOUT_MS = 8000;
setTimeout(() => process.exit(0), HARD_TIMEOUT_MS).unref();

// -p 身体(examples/pbody_bridge.py)里正文就是发给她的话,没有 reply 工具可调;
// 这道闸在那边由桥自己做(回合结束没开口也没 [[silent]] 就催一次)。
if (process.env.TIDAL_PBODY === "1") process.exit(0);

// 各频道的"开口"工具前缀。source 取自 <channel source="...">。
const CHANNELS = [
  {
    match: /^companion$/,
    prefix: "mcp__companion__",
    tool: 'mcp__companion__reply（chat_id: "me"）',
    where: "她手机上的 PWA",
    // 朋友圈回评也算开过口
    altRe: /_moments_cli\.py/,
    altHint: "（比如已经用 _moments_cli.py 去朋友圈回评了）",
  },
  {
    match: /telegram/,
    prefix: "mcp__plugin_telegram_telegram__",
    tool: "mcp__plugin_telegram_telegram__reply（把 chat_id 传回去）",
    where: "她的 Telegram",
    altHint: "",
  },
];

// 纯 ASCII 输出：中文全转 \uXXXX，免得经 PowerShell 转发时被码页啃掉
function emit(obj) {
  const json = JSON.stringify(obj).replace(/[-￿]/g, (c) =>
    "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0")
  );
  process.stdout.write(json);
}

function blockReason(ch, quoted) {
  return [
    `这一轮你没有调用 ${ch.prefix}* 里的任何工具——${ch.where}上一个字都没收到。`,
    "你写在正文或 thinking 里的内容不会送达她；空回合更是什么都没发生。",
    quoted ? `\n她刚说的是：${quoted}\n` : "",
    `现在立刻调用 ${ch.tool} 把你要说的话发出去。`,
    `如果你确实不需要回${ch.altHint}，那就直接结束回合，这道闸只会拦你一次。`,
  ].join("");
}

let stdin = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => { stdin += c; });
process.stdin.on("end", () => {
  let payload = {};
  // 经 PowerShell 转发时首字节可能是 BOM，直接 JSON.parse 会炸
  const raw = stdin.replace(/^﻿/, "").trim();
  try { payload = JSON.parse(raw || "{}"); } catch { process.exit(0); }

  // 已经因为这道闸重来过一次了，别再拦——不做无限循环
  if (payload.stop_hook_active) process.exit(0);

  const tpath = payload.transcript_path;
  if (!tpath || !fs.existsSync(tpath)) process.exit(0);

  let lines;
  try {
    lines = fs.readFileSync(tpath, "utf8").split(/\r?\n/).filter(Boolean);
  } catch { process.exit(0); }

  // 从尾部倒着走，找到本回合的触发消息（最近一条频道消息），
  // 沿途把用过的工具名和 Bash 入参都记下来。
  const usedTools = [];
  let usedInputs = "";
  let trigger = null;

  for (let i = lines.length - 1; i >= 0 && !trigger; i--) {
    let d;
    try { d = JSON.parse(lines[i]); } catch { continue; }
    const msg = d.message;
    if (!msg) continue;
    const c = msg.content;

    if (typeof c === "string") {
      if (d.type === "user" && c.includes("<channel source=")) trigger = c;
      continue;
    }
    if (!Array.isArray(c)) continue;

    for (const b of c) {
      if (b.type === "tool_use") {
        usedTools.push(b.name || "");
        usedInputs += JSON.stringify(b.input || {});
      } else if (b.type === "text" && d.type === "user" && b.text.includes("<channel source=")) {
        trigger = b.text;
      }
    }
  }

  if (!trigger) process.exit(0);   // 不是频道触发的回合（终端里聊天等），不管

  const src = (trigger.match(/<channel source="([^"]+)"/) || [])[1] || "";
  const ch = CHANNELS.find((x) => x.match.test(src));
  if (!ch) process.exit(0);        // 不认识的频道，不瞎拦

  if (usedTools.some((n) => n.startsWith(ch.prefix))) process.exit(0);   // 说过话了
  if (ch.altRe && ch.altRe.test(usedInputs)) process.exit(0);            // 走别的出口说了

  // 朋友圈事件本来就可能只在朋友圈里回，不该拦
  if (trigger.includes("<moments-event")) process.exit(0);
  // 保活帧：醒一下续缓存而已，不说话是常态
  if (trigger.includes("<keepalive")) process.exit(0);
  // 过隧道前写便签/摘要的那一回合：明确不回她；醒来读便签的那一回合也不必开口
  if (trigger.includes("<forge-prep") || trigger.includes("<forge-note")) process.exit(0);

  // 摘一句她的原话塞进 reason，让重来的那一轮有抓手
  const inner = trigger.replace(/<\/?channel[^>]*>/g, "").trim();
  const quoted = inner ? inner.slice(0, 200).replace(/\s+/g, " ") : "";

  emit({ decision: "block", reason: blockReason(ch, quoted) });
  process.exit(0);
});
