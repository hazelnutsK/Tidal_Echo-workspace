# examples/ — 接入示例

给**不用 Claude Code**、或需要无人值守跑的人。完整部署 SOP 见仓库根的 [`AGENTS.md`](../AGENTS.md)。

| 文件 | 干什么 | 平台 |
|---|---|---|
| [`bridge_any_llm.py`](bridge_any_llm.py) | 把任意 OpenAI 兼容模型(GPT/DeepSeek/Gemini/GLM/Kimi/通义/本地…)接成 AI 侧 | 任意 |
| [`codex_app_server_bridge.py`](codex_app_server_bridge.py) | 把本机 Codex app-server 接成独立、可切换的 Codex 身体 | Windows/macOS/Linux |
| [`api_loop.py`](api_loop.py) | 服务器常驻 API 身体；配合 PWA 的 Desktop/API 开关、多窗口和流式输出 | Linux/VPS |
| [`companion-api-loop.service`](companion-api-loop.service) | `api_loop.py` 的 systemd 模板 | Linux/VPS |
| [`.env.example`](.env.example) | `bridge_any_llm.py` / `api_loop.py` 共用配置模板 | — |

## Codex app-server 身体

先完成本机 `codex login`，在 `.env` 填好 `RELAY_URL / RELAY_SECRET`，然后运行：

```powershell
python codex_app_server_bridge.py --check-app-server
python codex_app_server_bridge.py
```

bridge 会通过 Codex app-server 的 `account/rateLimits/read` 每分钟读取一次真实账号限额，并只把额度窗口快照上报 relay；登录令牌始终留在本机。可用 `CODEX_QUOTA_INTERVAL` 调整刷新秒数（最小 30 秒）。

bridge 使用 `/channel/codex/in` 独立接收消息，每个 Codex 窗口保留自己的 thread，并把正文、thinking、
工具活动映射回 Tidal。窗口菜单可分别新建 Codex / API 对话；倒计时、选择卡、
语音和收藏标记继续由 relay 的现有 `/channel/out` 协议解析。
| [`confirm_dev_channel_win.py`](confirm_dev_channel_win.py) | Windows 上自动确认 Claude Code 的 DevChannelsDialog 弹框 | Windows |

---

## 用任意 LLM 当大脑(bridge_any_llm.py)

它替代 `channel/` 插件,不依赖 Claude Code。原理是个三步薄循环:SSE 收
`/channel/in` → 拉历史拼 messages + 调你的模型 → POST `/channel/out`。零第三方依赖。

```bash
cd examples
cp .env.example .env
#  编辑 .env:填 RELAY_URL、RELAY_SECRET(和后端一致),以及你的模型三件套
#  LLM_API_BASE / LLM_API_KEY / LLM_MODEL(各家取值见 .env.example 里的注释表)
python3 bridge_any_llm.py
```

跑起来后,在手机 PWA 发一条 → 终端打印 `[in] #.. ` → 模型生成 → 手机收到回复。

- **换模型**只改 `.env` 的三件套,代码不动。Gemini 用它的 OpenAI 兼容端点即可。
- **兜底链**:填 `LLM_*_2` / `LLM_*_3`,主模型 401/403/429/5xx 时自动顺次切。
- **失忆?** 调大 `HISTORY_N`(默认喂最近 12 条)。
- **看图**:默认把附件降级成文字提示;要真看图,在 `handle_human_message` 里下载
  `/uploads/{name}?token=` 再按多模态格式喂(代码里有注释标位置)。

---

## 服务器 API 身体(api_loop.py)

它不是长连消费 `/channel/in`，而是一个本机 HTTP 服务：relay 的 `/app/brain` 切到
`loop` 后，`/app/send` 会把新消息 POST 到 `/loop/ingest`。它支持：

- OpenAI-compatible 模型链和 fallback。
- 读取 relay.db 里的同窗口近期上文。
- PWA 多窗口 `api_session`。
- `reply_delta` 流式草稿，完成后落正式 `reply`。

```bash
cd examples
cp .env.example .env
# 填 RELAY_URL / RELAY_SECRET / RELAY_DB / LLM_API_BASE / LLM_API_KEY / LLM_MODEL
python3 api_loop.py
```

把 relay 切到它：

```bash
curl -s -X POST http://127.0.0.1:3011/app/brain \
  -H "Authorization: Bearer $RELAY_SECRET" \
  -H "Content-Type: application/json" \
  -d '{"target":"loop"}'
```

要常驻就参考 [`companion-api-loop.service`](companion-api-loop.service)。

### API 身体的主动心跳

在 `examples/.env` 设置 `CACHE_TTL=1h`、`KEEPALIVE_AFTER_MIN=50`、
`KEEPALIVE_MAX_IDLE_H=10` 和 `KEEPALIVE_PROACTIVE=1`，重启 API loop 后，
现有缓存心跳会同时生成一条简短的主动消息，写入当前 API 会话并沿用 relay 的通知通道。
检查周期是 5 分钟，通常在空闲 50～55 分钟时触发。正常聊天会推迟下一针；
成功投递、主动选择安静或避免重复时，会续上 10 小时活动窗口，可以持续运行。
`KEEPALIVE_PROACTIVE=0` 恢复仅保活；现有 `keepalive_enabled` 开关仍控制整个心跳。

触发纸条不落库，缓存断点停在共用历史末尾。人格、工具、thinking、effort、
供应商设置沿用聊天路径。若生成期间有新消息、切换窗口/身体/模型，结果会丢弃；
空回复、截断、工具请求和动作标记不会投递。投递失败不立即重试，避免不确定的响应造成重复消息。

`GET /loop/keepalive` 可查看 `proactive`、`after_min`、`max_idle_h` 和事件里的
`delivery` / `message_id`。已投递消息的费用记入正常聊天统计，不再叠加到纯保活费用里。
`POST /loop/keepalive/run` 会真实触发一次（主动模式会发消息），不是预览。

离线回归：`python -m unittest discover -s examples -p 'test_*.py'`。

---

## Claude Code 的确认框自动过(无人值守)

只有走 Claude Code 这条路才有这个框。**Linux/macOS 用 tmux 最干净:**

```bash
tmux new-session -d -s cc 'claude --dangerously-load-development-channels server:companion'
sleep 3 && tmux send-keys -t cc Enter        # 替你确认 DevChannelsDialog
```

**Windows(无 tmux)** 用 [`confirm_dev_channel_win.py`](confirm_dev_channel_win.py):

```bash
python confirm_dev_channel_win.py -- claude --dangerously-load-development-channels server:companion
```

细节(为什么躲不掉、覆盖范围)见 [`AGENTS.md` §4](../AGENTS.md)。

---

## ⚠️ 单身体原则

relay 是单用户单通道。**同一时刻只跑一个 AI 侧** —— 别同时开着 Claude Code channel
和 `bridge_any_llm.py`。`api_loop.py` 由 relay 的 Desktop/API 开关控流，切到 `loop`
时 Desktop channel 不会收到新消息；切回 `desktop` 时 API loop 仍可运行但不会接新入站。
