// 微信 iLink(ClawBot 官方个人号 Bot 协议)最小客户端。
// 照 @tencent-weixin/openclaw-weixin 2.4.9 的 dist 源码对齐:请求头、base_info、
// CDN 的 AES-128-ECB 加解密。只留我们用得到的:扫码、长轮询、发文字/图/文件、typing。
import crypto from "node:crypto";

export const ILINK_BASE = "https://ilinkai.weixin.qq.com";
export const CDN_BASE = "https://novac2c.cdn.weixin.qq.com/c2c";
const CHANNEL_VERSION = "2.4.9";
const APP_ID = "bot";
const CLIENT_VERSION = String((2 << 16) | (4 << 8) | 9);   // 0x00MMNNPP
const BOT_AGENT = "TidalEcho/1.0";

export const ItemType = { TEXT: 1, IMAGE: 2, VOICE: 3, FILE: 4, VIDEO: 5 };
const UploadType = { IMAGE: 1, VIDEO: 2, FILE: 3 };

const baseInfo = () => ({ channel_version: CHANNEL_VERSION, bot_agent: BOT_AGENT });

function randomUin() {
  const n = crypto.randomBytes(4).readUInt32BE(0);
  return Buffer.from(String(n), "utf-8").toString("base64");
}

function commonHeaders() {
  return { "iLink-App-Id": APP_ID, "iLink-App-ClientVersion": CLIENT_VERSION };
}

function withSlash(u) { return u.endsWith("/") ? u : u + "/"; }

// message_id 之类是 uint64,JSON.parse 会丢精度。我们不拿它做事,只是别让它毁掉解析。
function parseJson(text) { return text ? JSON.parse(text) : {}; }

async function post(baseUrl, endpoint, payload, token, timeoutMs = 15_000) {
  const body = JSON.stringify(payload);
  const headers = {
    "Content-Type": "application/json",
    AuthorizationType: "ilink_bot_token",
    "X-WECHAT-UIN": randomUin(),
    ...commonHeaders(),
  };
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(new URL(endpoint, withSlash(baseUrl)), {
    method: "POST", headers, body, signal: AbortSignal.timeout(timeoutMs),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${endpoint} HTTP ${res.status}: ${text.slice(0, 300)}`);
  return parseJson(text);
}

async function get(baseUrl, endpoint, timeoutMs = 35_000) {
  const res = await fetch(new URL(endpoint, withSlash(baseUrl)), {
    headers: commonHeaders(), signal: AbortSignal.timeout(timeoutMs),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${endpoint} HTTP ${res.status}: ${text.slice(0, 300)}`);
  return parseJson(text);
}

// ---- 扫码登录 ----------------------------------------------------------------

export async function fetchQrCode() {
  return post(ILINK_BASE, "ilink/bot/get_bot_qrcode?bot_type=3", { local_token_list: [] });
}

export async function pollQrStatus(baseUrl, qrcode, verifyCode) {
  let ep = `ilink/bot/get_qrcode_status?qrcode=${encodeURIComponent(qrcode)}`;
  if (verifyCode) ep += `&verify_code=${encodeURIComponent(verifyCode)}`;
  try {
    return await get(baseUrl, ep);
  } catch (err) {
    if (err.name === "TimeoutError" || err.name === "AbortError") return { status: "wait" };
    return { status: "wait", error: String(err) };   // 网关抖一下照官方做法当 wait
  }
}

// ---- 收 ----------------------------------------------------------------------

/** 长轮询。服务端最多 hold 35s;客户端超时当空结果,调用方直接再来。 */
export async function getUpdates(account, buf) {
  try {
    return await post(account.baseurl, "ilink/bot/getupdates",
      { get_updates_buf: buf || "", base_info: baseInfo() }, account.bot_token, 40_000);
  } catch (err) {
    if (err.name === "TimeoutError" || err.name === "AbortError") return { ret: 0, msgs: [], get_updates_buf: buf };
    throw err;
  }
}

function parseAesKey(b64) {
  const raw = Buffer.from(b64, "base64");
  if (raw.length === 16) return raw;
  if (raw.length === 32 && /^[0-9a-fA-F]{32}$/.test(raw.toString("ascii"))) {
    return Buffer.from(raw.toString("ascii"), "hex");   // 文件/语音/视频:base64(hex)
  }
  throw new Error(`aes_key 长度不对: ${raw.length}`);
}

function aesDecrypt(buf, key) {
  const d = crypto.createDecipheriv("aes-128-ecb", key, null);
  return Buffer.concat([d.update(buf), d.final()]);
}

function aesEncrypt(buf, key) {
  const c = crypto.createCipheriv("aes-128-ecb", key, null);
  return Buffer.concat([c.update(buf), c.final()]);
}

/** 把一条 item 里的媒体下回来解密成明文。图片的 key 可能在 image_item.aeskey(hex)。 */
export async function downloadMedia(item) {
  const box = item.image_item || item.file_item || item.video_item || item.voice_item;
  const media = box?.media;
  if (!media?.encrypt_query_param && !media?.full_url) return null;
  const url = media.full_url
    || `${CDN_BASE}/download?encrypted_query_param=${encodeURIComponent(media.encrypt_query_param)}`;
  const res = await fetch(url, { signal: AbortSignal.timeout(60_000) });
  if (!res.ok) throw new Error(`CDN download ${res.status}`);
  const enc = Buffer.from(await res.arrayBuffer());
  const keyB64 = item.image_item?.aeskey
    ? Buffer.from(item.image_item.aeskey, "hex").toString("base64")
    : media.aes_key;
  return keyB64 ? aesDecrypt(enc, parseAesKey(keyB64)) : enc;   // 个别图片是明文
}

// ---- 发 ----------------------------------------------------------------------

function clientId() { return `tidal-${crypto.randomUUID()}`; }

async function sendItem(account, to, contextToken, item) {
  const resp = await post(account.baseurl, "ilink/bot/sendmessage", {
    msg: {
      from_user_id: "", to_user_id: to, client_id: clientId(),
      message_type: 2, message_state: 2,           // BOT / FINISH
      item_list: [item],
      context_token: contextToken || undefined,
    },
    base_info: baseInfo(),
  }, account.bot_token);
  if (resp.ret && resp.ret !== 0) throw new Error(`sendmessage ret=${resp.ret} ${resp.errmsg || ""}`);
  return resp;
}

export function sendText(account, to, contextToken, text) {
  return sendItem(account, to, contextToken, { type: ItemType.TEXT, text_item: { text } });
}

async function uploadToCdn(account, to, plain, mediaType) {
  const aeskey = crypto.randomBytes(16);
  const filekey = crypto.randomBytes(16).toString("hex");
  const filesize = Math.ceil((plain.length + 1) / 16) * 16;
  const up = await post(account.baseurl, "ilink/bot/getuploadurl", {
    filekey, media_type: mediaType, to_user_id: to,
    rawsize: plain.length,
    rawfilemd5: crypto.createHash("md5").update(plain).digest("hex"),
    filesize, no_need_thumb: true, aeskey: aeskey.toString("hex"),
    base_info: baseInfo(),
  }, account.bot_token);
  const target = up.upload_full_url?.trim()
    || (up.upload_param && `${CDN_BASE}/upload?encrypted_query_param=${encodeURIComponent(up.upload_param)}&filekey=${encodeURIComponent(filekey)}`);
  if (!target) throw new Error(`getuploadurl 没给上传地址: ${JSON.stringify(up).slice(0, 200)}`);
  let lastErr;
  for (let i = 0; i < 3; i++) {
    try {
      const res = await fetch(target, {
        method: "POST", headers: { "Content-Type": "application/octet-stream" },
        body: new Uint8Array(aesEncrypt(plain, aeskey)), signal: AbortSignal.timeout(60_000),
      });
      if (res.status !== 200) throw new Error(`CDN upload ${res.status} ${res.headers.get("x-error-message") || ""}`);
      const param = res.headers.get("x-encrypted-param");
      if (!param) throw new Error("CDN upload 没回 x-encrypted-param");
      return {
        media: { encrypt_query_param: param, aes_key: Buffer.from(aeskey.toString("hex")).toString("base64"), encrypt_type: 1 },
        cipherSize: filesize,
      };
    } catch (err) {
      lastErr = err;
      if (/ 4\d\d /.test(String(err.message))) break;
    }
  }
  throw lastErr;
}

export async function sendImage(account, to, contextToken, plain) {
  const up = await uploadToCdn(account, to, plain, UploadType.IMAGE);
  return sendItem(account, to, contextToken, {
    type: ItemType.IMAGE, image_item: { media: up.media, mid_size: up.cipherSize },
  });
}

export async function sendFile(account, to, contextToken, plain, fileName) {
  const up = await uploadToCdn(account, to, plain, UploadType.FILE);
  return sendItem(account, to, contextToken, {
    type: ItemType.FILE, file_item: { media: up.media, file_name: fileName, len: String(plain.length) },
  });
}

export async function sendTyping(account, to, contextToken, typing = true) {
  const cfg = await post(account.baseurl, "ilink/bot/getconfig",
    { ilink_user_id: to, context_token: contextToken, base_info: baseInfo() }, account.bot_token, 10_000);
  if (!cfg.typing_ticket) return;
  await post(account.baseurl, "ilink/bot/sendtyping",
    { ilink_user_id: to, typing_ticket: cfg.typing_ticket, status: typing ? 1 : 2, base_info: baseInfo() },
    account.bot_token, 10_000);
}
