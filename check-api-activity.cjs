// Isolated browser regression: uses the real PWA card/CSS/renderers, no live API.
const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert/strict');
const { chromium } = require('playwright');
const html = fs.readFileSync(path.join(__dirname, 'web/index.html'), 'utf8');
const title = html.indexOf('>心跳与摘要记录</div>');
const card = html.slice(html.lastIndexOf('<section', title), html.indexOf('</section>', title) + 10);
const styles = [...html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map(m => m[1]).join('\n');
const code = html.slice(html.indexOf('const apiStatsList ='), html.indexOf('let apiDetailOpen ='));
const escape = html.slice(html.indexOf('function escapeHtml(s)'), html.indexOf('function renderText(t)'));
const activity = {heartbeat:{skip_reason:'retry_wait', next_retry_at:1791122430, retry_count:2}, events:[
  {kind:'heartbeat', at:'2026-10-04T22:00:00+08:00', status:'error', error:'ReadError: private details', retry_attempt:1, retry_in_s:60, session_title:'晚上的窗口'},
  {kind:'summary', at:'2026-10-04T21:59:00+08:00', reason:'compact', chars:2300, covers_to:24624, session_title:'晚上的窗口'},
  {kind:'heartbeat', at:'2026-10-04T21:58:00+08:00', status:'hit', delivery:'silent', read:39768, written:120, cost:.05, session_title:'晚上的窗口'},
  {kind:'heartbeat', at:'2026-10-04T21:57:00+08:00', status:'hit', delivery:'sent', read:39768, written:120, cost:.05, session_title:'晚上的窗口'}
]};
(async () => {
  const browser = await chromium.launch({channel:'msedge', headless:true});
  try {
    const page = await browser.newPage({viewport:{width:390, height:844}, timezoneId:'Asia/Shanghai'});
    const errors = [];
    page.on('pageerror', e => errors.push(String(e)));
    await page.route('**/*', route => route.abort());
    await page.setContent(`<html data-theme="paper"><head><meta charset="utf-8"><style>${styles}</style><style>body{position:static;display:block;overflow:auto;padding:18px 12px;background:#f4f1ea}main{max-width:500px;margin:auto}.settings-card{display:block!important}</style></head><body><main>${card}</main><script>const $=s=>document.querySelector(s);${escape}${code}\nwindow.refreshes=0;async function loadApiStats(){window.refreshes++;renderApiActivity();}apiActivityData=${JSON.stringify(activity)};renderApiActivity();</script></body></html>`);
    assert.equal(await page.locator('.api-activity-row').count(), 4);
    assert.match(await page.locator('#apiActivityStatus').innerText(), /第 2 次重试/);
    await page.getByRole('button', {name:'摘要', exact:true}).click();
    assert.equal(await page.locator('.api-activity-row').count(), 1);
    assert.match(await page.locator('#apiActivityList').innerText(), /摘要已写入/);
    await page.getByRole('button', {name:'心跳', exact:true}).click();
    assert.equal(await page.locator('.api-activity-row').count(), 3);
    await page.getByRole('button', {name:'刷新', exact:true}).click();
    assert.equal(await page.evaluate(() => window.refreshes), 1);
    await page.getByRole('button', {name:'全部', exact:true}).click();
    await page.evaluate(() => {
      Object.assign(apiActivityData.events[0], {http_status:400, error_type:'HTTPStatusError',
        error_detail:'Provider returned error · temporary validation failure <img src=x onerror="window.injected=1">'});
      renderApiActivity();
    });
    assert.match(await page.locator('#apiActivityList').innerText(), /HTTP 400/);
    assert.match(await page.locator('#apiActivityList').innerText(), /temporary validation failure/);
    assert.equal(await page.locator('#apiActivityList img').count(), 0);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    const screenshot = path.join(os.tmpdir(), 'tidal-api-activity-mobile.png');
    await page.screenshot({path:screenshot, fullPage:true});
    await page.evaluate(() => {
      delete apiActivityData.events[0].http_status;
      delete apiActivityData.events[0].error_detail;
      apiActivityData.events[0].error = "HTTPStatusError: Client error '400 Bad Request' for url 'https://example.test/messages'";
      renderApiActivity();
    });
    assert.match(await page.locator('#apiActivityList').innerText(), /HTTP 400/);
    assert.match(await page.locator('#apiActivityList').innerText(), /具体原因未保存/);
    await page.evaluate(() => { apiActivityData.events[0].session_title = '<img src=x onerror="window.injected=1">'; renderApiActivity(); });
    assert.equal(await page.locator('#apiActivityList img').count(), 0);
    await page.evaluate(() => { apiActivityData.events = []; renderApiActivity(); });
    assert.match(await page.locator('#apiActivityList').innerText(), /暂无这类记录/);
    await page.evaluate(() => { apiActivityData = null; renderApiActivity(); });
    assert.match(await page.locator('#apiActivityStatus').innerText(), /重启 API/);
    assert.equal(errors.length, 0, errors.join('\n'));
    console.log('PASS: mobile layout, filters, refresh, empty/legacy state, escaped metadata. Screenshot: ' + screenshot);
  } finally { await browser.close(); }
})().catch(e => {console.error(e); process.exitCode=1;});
