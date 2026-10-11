# 桌面身体的第二种形态：`claude -p` 管道（pbody）

09-24 搭了骨架，10-03 把 relay 这边接好了。**现在默认还是 channel**（交互式 CC + dev-channel 插件），要等她发一句 `/body p` 才会真正切过去。

## 两种身体对照

| | channel（老路） | pbody（新） |
|---|---|---|
| 进程 | 交互式 CC + `--dangerously-load-development-channels` | `examples/pbody_bridge.py` 持有的 `claude -p --input-format stream-json` |
| 她的消息怎么进来 | 插件订阅 `/channel/in`，以 channel 通知的形式投给 CC | 桥订阅 `/channel/in`，拼出一模一样的 `<channel …>` 文本写进 stdin |
| 我怎么开口 | 只能调 `mcp__companion__reply` | **正文就是消息**，每块正文变成一条气泡（桥 POST `/channel/out`） |
| 不想开口 | 不调 reply | 正文只写 `[[silent]]` |
| 发图 | reply 的 `images` 参数 | 正文里写 `[[image:路径或链接]]` |
| react / call | 插件工具 | 插件还在，同样能用（reply 被 deny 了） |
| 回合守卫 | `reply_guard.js`（Stop hook） | 桥自己做：她说了话、这一轮什么都没发、也不是 silent，就催一次。`reply_guard.js` 看到 `TIDAL_PBODY=1` 会让路 |
| 启动 | 要过 DevChannelsDialog / 信任框 | 不弹任何框 |

规则写在桥里的 `PBODY_CONTRACT`，用 `--append-system-prompt-file` 追加进去，所以 **CLAUDE.md 不用改**。CLAUDE.md 里说“用 companion reply 发”的地方，契约里统一说明了“在这里直接说出来就是”。

## 系统提示词（10-03）

- 默认：CC 自带的系统提示（已经被 `CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT` 精简过），我们的契约追加在它后面。
- 只要 **`backend/pbody-system.md` 这个文件存在**，桥就改用 `--system-prompt-file`：CC 自带的那份整个被换掉，换成「这个文件 + 契约」。文件每次拉起身体时都会重新读，改完发一次 `/swap` 或者重启身体就生效。
- 不管哪种模式，CLAUDE.md、MEMORY.md、环境信息、commit 署名提醒都照样加载，因为它们是作为提醒注入的，不算系统提示的一部分。
- 实测（sonnet，其他参数完全一样）：追加模式 35,769 tokens，替换模式 33,506。替换后少掉的是 Anthropic 那套语气/排版规则，还有“怎么写 memory 文件”那段说明。memory 那段想留的话，要自己写进 pbody-system.md。
- **工具白名单（10-03 她定的）**：`--tools Read,Write,Edit,Bash,WebSearch,WebFetch,ToolSearch,Skill`（桥里的 `PBODY_TOOLS`，也可以用 env 覆盖）。ToolSearch 必须留着，MCP 工具平时只挂名字，靠它才载得进来；Edit 和 Skill 是她要求留的（play skill）。
- 拆账（sonnet，不挂 MCP）：原装 45,983 → 替换系统提示 37,352 → 加精简开关 33,503 → 关掉全部内置工具 18,407 → 再不加载 CLAUDE.md 和 MEMORY 只剩 1,011。也就是说，内置工具说明大约 1.5 万，CLAUDE.md 加 MEMORY 大约 1.7 万。
- A/B 实测（opus-4-5，白名单开着）：现行追加模式首轮 25,360，用草稿替换后 24,565。草稿在 `backend/pbody-system.draft.md`，**改名成 pbody-system.md 才会生效**。
- 交互式 CC 其实也认 `--system-prompt-file`，只是在 pbody 里，启动参数整个都由桥来拼，所以接起来最顺手。

## relay 侧（backend/app.py，10-03）

- `context_ctl.json` 加了 `desktop_body: channel|pbody`（`desktop_body()` 读它；没设就看 env `RELAY_DESKTOP_BODY`，再没有就是 channel）。
- `_find_cc_pids` 两种身体都认（`dangerously-load-development-channels` 或 `pbody_bridge.py … --live`）。所以 swap、reset、resume、过隧道、换模型、换身体时，旧的那个不管是哪种都会被杀掉。
- `_spawn_cc` 碰到 pbody 就走 `_spawn_pbody`：`python pbody_bridge.py --live --force --resume <sid>`，新会话就传 `--session-id <uuid>`。日志写 `examples/pbody.log`，超过 5MB 轮转一次。
- 换身体：`POST /app/desktop_body {body, apply}`，或者在聊天框发 `/body p` / `/body channel`。做法是把现在的杀掉，另一种身体带 `--resume` 同一个 sid 拉起来，transcript 两边通用。`/ctx` 和 `context_status` 里会显示当前是哪种身体。
- 层二回复守卫的提醒措辞按身体区分。
- start-all.ps1 读到 `desktop_body=pbody` 就在前台起桥，不起交互式 CC；stop-all.ps1 会连桥带它的 claude 子进程一起杀掉。

## 实测（10-03，2.1.280）

- `-p --resume <sid>` 沿用原 sid，transcript 里的 thinking 是有字的（要带 `--thinking-display summarized`），所以 thinking 直播那条“读 transcript 尾巴”的路照常能用，桥不再另推 thinking。
- 说话中途插进来的消息：会在下一个工具边界并进同一轮（两条消息只有一个 result），和 channel 的行为一样。CC 真正读到某条消息时才会回显 `isReplay`，桥拿这个回显签收游标；还没签收的，CC 重启后会重发一遍。
- 沙盒三条用例：普通一句话 → 正文直接成了一条回复；keepalive → `[[silent]]`，什么都没发出去；“把咪.jpg 发给她” → 先 Read 看图，再用 `[[image:…]]` 上传，图和配的话一起发出去。

## 沙盒

```
backend\.venv\Scripts\python.exe examples\pbody_bridge.py --sandbox [--model sonnet]
```

假 relay 接住所有回复、上传和 react，都打印在终端里，不会发到手机；不写 transcript；ombre 只读。直接打字＝她发的；`/sys …`＝系统帧；`/img 路径 话`＝带图；`/multi` 多行输入。

## 还没做 / 已知问题

1. **还没在真 relay 上跑过 live**。第一次切换就是验收，切完盯着 `examples\pbody.log` 看。不行就发 `/body channel` 换回去，会话是同一个，不会丢。
2. **不是流式**：一块正文写完才整块发出去，跟现在 reply 工具一次发一整条的体验一样。想要逐字打字效果，可以改成 `reply_delta` 流，但流式那条路不走短聊分条和书签继承，要先补上。
3. 层二守卫（relay，90 秒）遇到长回合可能误催一次。这个毛病 channel 身体也有。桥知道 CC 正忙，以后可以把“忙”报给 relay，让它别催。
4. `--fallback-model` 还没开，要先定好回退到哪个模型。
5. 换身体的入口目前只有斜杠命令和 API，设置页还没加开关（iOS 要出包）。
6. 隐藏 flag `--thinking-display`、以后 `--bare` 可能变成默认：每次升 CC 后都先跑一遍沙盒冒烟。
