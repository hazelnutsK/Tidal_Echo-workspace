// 扫码把微信接上。跑一次就行,token 存在 state/account.json,之后 bridge.mjs 直接用。
// 要在一个真的控制台窗口里跑(登录中途微信可能让她输一个数字),所以配了 登录微信.cmd。
import { writeFileSync, mkdirSync } from "node:fs";
import { exec } from "node:child_process";
import { createInterface } from "node:readline/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import QRCode from "qrcode";
import { ILINK_BASE, fetchQrCode, pollQrStatus } from "./ilink.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const STATE = path.join(HERE, "state");
mkdirSync(STATE, { recursive: true });
const rl = createInterface({ input: process.stdin, output: process.stdout });

async function showQr() {
  const qr = await fetchQrCode();
  if (!qr.qrcode_img_content) throw new Error("没拿到二维码: " + JSON.stringify(qr));
  const png = path.join(STATE, "login-qr.png");
  await QRCode.toFile(png, qr.qrcode_img_content, { width: 360, margin: 2 });
  console.log(await QRCode.toString(qr.qrcode_img_content, { type: "terminal", small: true }));
  console.log("用手机微信扫上面的码(扫不了的话,弹出来的那张图也是同一个码)");
  exec(`start "" "${png}"`);
  return qr.qrcode;
}

let qrcode = await showQr();
let base = ILINK_BASE;
let verify;
let refreshes = 0;
for (;;) {
  const st = await pollQrStatus(base, qrcode, verify);
  switch (st.status) {
    case "scaned":
      verify = undefined;
      process.stdout.write("\r已扫码,在手机上点确认…        ");
      break;
    case "need_verifycode":
      verify = (await rl.question(verify ? "数字不对,再输一次:" : "输入手机微信上显示的数字:")).trim();
      continue;
    case "scaned_but_redirect":
      if (st.redirect_host) base = `https://${st.redirect_host}`;
      break;
    case "expired":
    case "verify_code_blocked":
      if (++refreshes > 3) { console.log("\n二维码失效太多次了,过会儿再试"); process.exit(1); }
      console.log("\n二维码过期了,换一张");
      verify = undefined;
      qrcode = await showQr();
      break;
    case "binded_redirect":
      console.log("\n这个微信已经连过了。要重连就先删掉 state/account.json 再跑。");
      process.exit(0);
    case "confirmed": {
      const account = {
        bot_token: st.bot_token,
        baseurl: st.baseurl || ILINK_BASE,
        bot_id: st.ilink_bot_id || "",
        user_id: st.ilink_user_id || "",     // 扫码的人=她。bridge 只认这一个人的消息
        login_time: new Date().toISOString(),
      };
      writeFileSync(path.join(STATE, "account.json"), JSON.stringify(account, null, 2));
      console.log("\n接上了。关掉这个窗口就行,剩下的小克来。");
      process.exit(0);
    }
  }
  await new Promise((r) => setTimeout(r, 1000));
}
