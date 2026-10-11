# set_tgterm_menu.ps1 — 把 TG 聊天框左下角的 menu button 指向终端页(mini app)。
#
#   .\set_tgterm_menu.ps1          设成「终端」按钮
#   .\set_tgterm_menu.ps1 -Undo    改回默认(命令列表)
#
# 为什么要人来跑:这一步会把带 token 的 URL 发到 Telegram 服务器上,形状等同
# 凭据外泄,自动化安全闸拦下了。所以由你亲手执行。那个 token 不是 RELAY_SECRET,
# 是 backend\.tgterm_token —— 只能开终端页那一扇门(screentime / thinking_stream
# / calendar 都会 401),泄漏了也读不到你们的聊天。
param([switch]$Undo)

$ErrorActionPreference = 'Stop'
$CHAT     = 8674631234
$envFile  = 'C:\Users\sxc\.claude\channels\telegram\.env'
$tokFile  = 'C:\Users\sxc\Tidal_Echo\backend\.tgterm_token'
$proxy    = 'http://127.0.0.1:8890'
$pageBase = 'https://lyra.myaltair.uk/chat/tgterm.html'

$token = $null
foreach ($l in (Get-Content -LiteralPath $envFile)) {
  if ($l -match '^\s*TELEGRAM_BOT_TOKEN\s*=\s*(.+?)\s*$') { $token = $matches[1] }
}
if (-not $token) { throw "读不到 TELEGRAM_BOT_TOKEN($envFile)" }

function Call-TG([string]$method, $payload) {
  $json  = $payload | ConvertTo-Json -Compress -Depth 5
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/$method" -Method Post `
    -Body $bytes -ContentType 'application/json; charset=utf-8' -Proxy $proxy -TimeoutSec 30
}

if ($Undo) {
  $null = Call-TG 'setChatMenuButton' @{ chat_id = $CHAT; menu_button = @{ type = 'default' } }
  Write-Host "已改回默认按钮。" -ForegroundColor Yellow
} else {
  if (-not (Test-Path -LiteralPath $tokFile)) { throw "找不到 $tokFile" }
  $tt  = (Get-Content -LiteralPath $tokFile -Raw).Trim()
  if (-not $tt) { throw "$tokFile 是空的" }
  $url = "$pageBase`?token=$tt"

  $null = Call-TG 'setChatMenuButton' @{
    chat_id     = $CHAT
    menu_button = @{ type = 'web_app'; text = 'Terminal'; web_app = @{ url = $url } }
  }
  Write-Host "已设好。TG 聊天框左下角会多一个「Terminal」按钮。" -ForegroundColor Green
}

# --- 回读确认(不打印 token) ---
$cur = Call-TG 'getChatMenuButton' @{ chat_id = $CHAT }
$shown = if ($cur.result.web_app.url) { $cur.result.web_app.url -replace '\?token=.*', '?token=***' } else { '(无)' }
Write-Host ("现在是: type={0} text={1}" -f $cur.result.type, $cur.result.text)
Write-Host ("URL:    {0}" -f $shown)
