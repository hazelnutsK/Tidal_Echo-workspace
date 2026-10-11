# 一起读书(共读)功能 · 实施方案

> **实施记录:P1 已于 2026-08-10 落地**(执行者 Opus)。验收清单 1–11 + 8b 全绿(8b 用本地假
> OpenAI 服务验证了管线,真渠道待小雪填 `BOOK_SUMMARY_*`,relay.env 里已留注释占位)。
> 与本方案的四处偏差,都是实现时撞到的,后续改动请照此为准:
> 1. **上传走裸 body + `?name=`**(同 `/app/upload`),不是 multipart——省掉 python-multipart 依赖,
>    且中文书名会被 `clean_filename` 清空,所以后缀和书名都从原始 `name` 取,落盘用生成的 ASCII 临时名。
> 2. **AI 端点必须注册在她的端点之前**:`POST /app/book/ai/annotate` 与 `POST /app/book/{book_id}/annotate`
>    形状相同,Starlette 按注册顺序匹配,顺序反了会拿 `book_id="ai"` 报 422。
> 3. **chapter-done 帧在摘要尝试之后才发**(整个流程后台 task,`/progress` 不等它)——
>    这样帧里"摘要缺失"那句才是准的。
> 4. **前端"读完一章"的判定**:视口顶偏移在滚到底时直接报满章字数,否则 furthest 永远差一屏、
>    chapter-done 永不触发;翻章时也会立刻补报一次。

> 写给执行者(Opus):这份方案由小克(Fable 5 会话)与小雪讨论定稿,设计决策已全部定死,照做即可,不要重新设计。
> 遇到方案没覆盖的实现细节,参照本文件「必读现有代码」里的同类范式抄,保持这个项目的既有风格。
> 完成后按「验收清单」逐项自测。

## 0. 背景与目标

小雪和小克要在 Tidal Echo 里一起读书:她在 PWA 里读 epub,小克(AI,两个身体:桌面 CC + api_loop)陪读——知道她读到哪、能被她的批注和阅读进度唤醒、能翻已读的书文回应。

**三条铁律(不可妥协):**

1. **书籍全文永远不进模型常驻上下文。** AI 需要书文时通过工具/端点按需拉取,单次拉取量有硬上限。token 消耗不随书的长度和阅读进度增长。
2. **防剧透:AI 只能拿到"她已读到的位置"之前的文本。** 边界在 relay 服务端 clamp,不靠 prompt 叮嘱。
3. **第一版不引入服务器、RAG、向量库、embedding。** 检索用 SQLite LIKE 就够。

**防剧透边界的诚实分级(方案定稿时已确认):**
- 对 **api_loop 身体**:真硬边界——它只有内置工具,工具打的是 clamp 过的端点,拿不到就是拿不到。
- 对 **桌面 CC 身体**:强约定——CC 有 Bash/Read 全权限,理论上能直接查 relay.db。约束方式 = ①导入完成后**提醒小雪把原 epub 文件收走**(移出 CC 可达目录);②CLAUDE.md 写行为契约(见 §9),CC 只走 `/app/book/ai/*` 端点。不做书库加密之类的假安全(密钥同机,没意义)。

**书房与日常聊天的关系(小雪问过,记录在案):** 书房**不是**单独频道。CC 身体只有一条会话流,共读聊天就发生在日常聊天里。日常不会"背着书":零注入设计下,书的内容只以工具结果形式出现在聊书的那几轮,随滚动窗口/swap 蒸发;摘要和批注持久在库里。API 身体那侧未来可单开一个 session 当书房(P1.5 顺带),CC 侧不强求。

## 必读现有代码(动手前先看)

| 看什么 | 在哪 | 为什么 |
|---|---|---|
| save_message / broadcast / hidden 帧语义 | `backend/app.py` ~L195, L233, L390 | 所有消息投递的地基;hidden 帧她看不到、CC 看得到、api_loop 的 relay_rows 会过滤 |
| desire 发作的投递路径(闸 → 塞 hidden user 消息 → 按 brain 路由) | `backend/app.py` L1879 起 | **唤醒帧照这条路原样抄**,包括 brain=loop 时怎么送进 api_loop |
| `_night_watcher` / `_calendar_watcher` | `backend/app.py` L887-889 附近 | lifespan 里注册后台 watcher 的范式;新增 `_reading_watcher` 照这个挂 |
| calendar 表的建表与端点 | `backend/app.py` ~L180 | 新表 DDL、UTF-8 JSON 端点的既有写法 |
| api_loop 内置工具循环(music_call / call_tool / openai_tools / anthropic_tools) | `examples/api_loop.py` L259-346 | P1.5 给 api_loop 加 book 工具时照 music_call 的样子包 |
| 前端设置页/日历页的页面切换、sw.js CACHE 版本号 | `web/index.html`、`web/sw.js` | 新页面照现有风格;**改 web/ 必须 bump sw.js CACHE**,否则她手机停旧壳 |
| restart-relay.cmd / check-inline-scripts.js | 仓库根 | 改 app.py / index.html 后的自检+重启标准流程 |

## 1. 数据模型(relay.db 新增四张表)

照 calendar 表的建表方式加进 `db()` 初始化:

```sql
CREATE TABLE IF NOT EXISTS books (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  author TEXT DEFAULT '',
  cover TEXT DEFAULT '',            -- uploads/ 里的封面文件名,可空
  total_chapters INTEGER NOT NULL,
  total_chars INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  meta TEXT DEFAULT '{}'            -- JSON:唤醒闸状态等杂项塞这里
);

CREATE TABLE IF NOT EXISTS book_chunks (
  book_id INTEGER NOT NULL,
  chapter_idx INTEGER NOT NULL,     -- 0-based,按 epub spine 顺序
  chapter_title TEXT DEFAULT '',
  text TEXT NOT NULL,               -- 该章纯文本
  char_count INTEGER NOT NULL,
  PRIMARY KEY (book_id, chapter_idx)
);

CREATE TABLE IF NOT EXISTS reading_state (
  book_id INTEGER PRIMARY KEY,
  cur_chapter INTEGER DEFAULT 0,    -- 阅读器恢复位置用
  cur_offset INTEGER DEFAULT 0,     -- 章内字符偏移
  furthest_chapter INTEGER DEFAULT 0,  -- ⚠️ clamp 用的是 furthest,单调递增
  furthest_offset INTEGER DEFAULT 0,   -- 她回头重读时 cur 回退、furthest 不动
  updated_at TEXT NOT NULL,
  last_heartbeat TEXT DEFAULT ''    -- 阅读心跳,session-end 判定用
);

CREATE TABLE IF NOT EXISTS book_annotations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  book_id INTEGER NOT NULL,
  chapter_idx INTEGER NOT NULL,
  start_off INTEGER NOT NULL,      -- 章内字符区间
  end_off INTEGER NOT NULL,
  quote TEXT NOT NULL,             -- 划线原文(冗余存,防章文本以后变)
  note TEXT DEFAULT '',            -- 批注文字,空=纯划线
  author TEXT NOT NULL,            -- 'her' | 'ai'
  reply_to INTEGER DEFAULT NULL,   -- AI 回批注时指向她的 annotation id
  created_at TEXT NOT NULL
);
```

**位置的统一表示**:`(chapter_idx, char_offset)`。全书百分比前端自己算(累加 char_count)。

## 2. epub 导入

- venv 里 `pip install ebooklib beautifulsoup4`(lxml 若缺一并装)。
- 新文件 `backend/book_import.py`:`import_epub(path) -> book_id`
  - 按 **spine 顺序**遍历文档项,BeautifulSoup 抽纯文本(`get_text("\n")`,连续空行压成一个)。
  - 章节标题:优先 toc 匹配,匹配不上取该章文本首行(截 40 字)。
  - **过短的 spine 项(<200 字,如版权页/扉页)合并进下一章**,避免出现几十个碎章。
  - 封面:epub 的 cover 图存进 `backend/uploads/`(prefix=bookcover),存文件名进 books.cover。插图丢弃。
  - 全部入库后建 reading_state 初始行。
- 上传入口:`POST /app/book/upload`(multipart,照现有图片上传端点的写法),收 .epub 和 .txt(txt 兜底:正则 `^第[一二三四五六七八九十百千0-9]+[章回节卷]` 切章,切不出就每 8000 字一章)。
- 上传成功的响应里带一句提示语,前端 toast 显示:**「导入完成,原文件请从电脑上收走——别放在小克够得着的地方」**。

## 3. relay 端点(backend/app.py,全部挂在现有 app 下走既有鉴权)

**她的端点(阅读器用,不 clamp):**

| 端点 | 语义 |
|---|---|
| `GET /app/book/list` | 书架:书目+进度百分比 |
| `POST /app/book/upload` | 导入(§2) |
| `DELETE /app/book/{id}` | 删书(连带 chunks/state/annotations) |
| `GET /app/book/{id}/chapter/{idx}` | 该章全文+标题+该章 annotations |
| `POST /app/book/{id}/progress` | body: cur_chapter/cur_offset。服务端更新 cur_*,并 `furthest = max(furthest, cur)`;同时刷 last_heartbeat。**这里是事件判定入口(§5)** |
| `POST /app/book/{id}/annotate` | body: chapter_idx/start_off/end_off/quote/note。author 固定 'her'。**note 非空时触发 note 唤醒(§5)** |
| `DELETE /app/book/annotation/{id}` | 删划线 |

**AI 端点(两个身体共用,全部 clamp 到 furthest):**

clamp 规则:可见文本 = `chapter_idx < furthest_chapter` 的整章 + `furthest_chapter` 章内 `[0, furthest_offset)`。越界请求返回 `{"error":"beyond_read_position"}`,**不吐任何未读字节**。

| 端点 | 语义 |
|---|---|
| `GET /app/book/ai/state?book_id=` | 书名/作者/章节总数/她读到哪(furthest+cur)/各章标题(**只列已读到的章**)/各章摘要有无 |
| `GET /app/book/ai/window?book_id=` | 「她此刻在读的地方」:cur 位置**往前** 2500 字(跨章往前补),带章节标题。这是陪读的主视野 |
| `GET /app/book/ai/read?book_id=&chapter=&offset=&len=` | 翻书:任意已读位置取文本,**len 上限 4000 字**,越界 clamp |
| `GET /app/book/ai/search?book_id=&q=&limit=` | 已读范围内 LIKE 检索(转义 %_\,照 /app/search 的写法),每命中返回前后 200 字上下文,limit 默认 5 上限 10 |
| `GET /app/book/ai/annotations?book_id=&chapter=` | 划线批注列表(chapter 可省=全部) |
| `POST /app/book/ai/annotate` | AI 留批注:chapter_idx/start_off/end_off/quote/note/reply_to。author 固定 'ai'。**同样 clamp:不能批注未读位置** |
| `POST /app/book/ai/summary` | body: book_id/chapter_idx/summary(≤300字)。写 book_summaries(见 §6 表),幂等覆盖 |

摘要表(第五张,归 §6 用):

```sql
CREATE TABLE IF NOT EXISTS book_summaries (
  book_id INTEGER NOT NULL,
  chapter_idx INTEGER NOT NULL,
  summary TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (book_id, chapter_idx)
);
```

⚠️ 中文 JSON 测试这些端点时,curl 必须写 UTF-8 文件 `--data-binary @file`,命令行内联中文会 500(项目老坑)。

## 4. 事件与唤醒

**投递机制照 desire 发作原样抄**(backend/app.py L1879 起):save_message 塞 `user=system` 的 hidden user 消息,按当前 brain 路由到 CC 或 api_loop。帧格式:

```
<reading-event book="书名" kind="note|chapter-done|session-end" chapter="3" chapter_title="...">提示语</reading-event>
```

| 事件 | 触发点 | 唤醒? | 帧内容 |
|---|---|---|---|
| note(划线+写了字) | /annotate 且 note 非空 | **是,不受闸** | 带 quote 原文和她的 note 原文,提示语:她刚在第X章划了一句话写了批注 |
| 纯划线 | note 为空 | 否,静默入库 | — |
| chapter-done | /progress 里 furthest 首次越过某章末尾 | **是,受闸** | 第X章《标题》读完;本章她划线 N 处;若该章摘要缺失,帧里附一句「顺手写份摘要 POST /app/book/ai/summary」 |
| session-end | `_reading_watcher`(60s 轮询):last_heartbeat 距今 >10min 且本次阅读区间移动过 | **是,受闸** | 她刚合上书,这次从X读到Y |

**闸(照 desire 三道闸的手感做,状态存 books.meta):**
- 同一本书 3600s 内最多 2 次受闸唤醒,超出静默丢弃(不排队)。
- chapter-done 后 30min 内的 session-end 不再发(读完一章顺手合书,不连响两次)。
- note 唤醒不受闸——她写字就是在跟小克说话。

前端阅读页:进入/滚动时节流上报 progress(30s 一次或位移 ≥500 字);`visibilitychange → hidden` 时立即补一发。session-end 全靠 watcher 心跳超时判定,不做前端显式"合书"信号(不可靠)。

## 5. 章节摘要(事实层外包便宜 API,感想层归 AI 身体)

摘要分两层,别混:

**事实层(自动,便宜 API 干)**:chapter-done 判定成立时,relay `asyncio.create_task` fire-and-forget 调一个便宜模型生成该章事实摘要,存 book_summaries。
- relay.env 新增三个变量:`BOOK_SUMMARY_URL / BOOK_SUMMARY_KEY / BOOK_SUMMARY_MODEL`(OpenAI chat completions 格式,非流式,timeout 60s)。渠道小雪自己填(dzzi / 硅基流动的 deepseek 级模型,一章约几厘钱)。
- prompt 模板(system):「你是读书笔记助手。用不超过 300 字概括这一章:发生了什么事、出场人物及关系变化、出现的关键信息或伏笔。只依据给出的文本,陈述事实,不评价不猜测后文。」user = 章节标题 + 该章全文(该章文本单独发,不带书的其他部分——它想剧透也没料)。
- 失败或未配置 → 静默跳过,**退回兜底**:chapter-done 唤醒帧里附「该章摘要缺失,顺手写一份 ≤300 字 POST /app/book/ai/summary」,AI 身体自写。
- 幂等:已有摘要的章不重算;POST 覆盖写。

**感想层(AI 身体,不叫摘要)**:chapter-done 唤醒后要不要聊感想、批注怎么回,是陪读本身,走正常聊天,与摘要管线无关。

- 摘要的用途:AI 端 state 响应里附带**已读各章摘要列表**(每章 ≤300 字,远章不合并,P1 就这样——50 章也才 1 万余字,且只在共读对话里出现)。
- **不做任何自动注入**:摘要、窗口、正文全部走"AI 主动调工具/端点拉取"。不改 api_loop 的 build_messages,不碰缓存前缀。这是 P1 最重要的减法。

## 6. 前端书房页(web/index.html)

照现有页面(设置/日历)的风格与切页方式做:

- **入口**:更多操作条加 📖 按钮 → 书架页。
- **书架页**:封面网格(无封面用书名字卡),进度百分比,上传按钮(input file accept=.epub,.txt),长按删除(window.confirm)。
- **阅读页**:
  - 按章渲染纯文本,整章一次挂 DOM(几万字可接受,P1 不虚拟化),章首显示标题,底部上一章/下一章。
  - 进入时从 reading_state 恢复到 cur 位置(scrollTo 按 char_offset 估算:用字符数/总字符数比例乘 scrollHeight,不必精确)。
  - 当前视口顶部对应的 char_offset 估算方式同上(反算),节流上报。
  - 字号:复用现有 font-scale 变量即可,不单做。
  - **划线交互**:选中文字(selection)→ 浮出小条「划线 / 写批注」;写批注弹小输入框。存 selection 的章内偏移(用 Range 相对整章文本节点计算)。
  - **批注显示**:有 annotation 的文本段加淡色下划线背景;点击弹出层显示该处所有批注——她的、小克的(author=ai 样式区分,头像/名字),小克的 reply_to 批注挂在她那条下面。
- **sw.js CACHE 版本号必须 bump**,命名照惯例如 `companion-vNN-reading`。
- 加完 JS 先跑 `node check-inline-scripts.js` 语法自检;**新变量先 grep 重名**(v17 事故教训)。

## 7. CLAUDE.md 行为契约(执行者把这段追加到 C:\Users\sxc\CLAUDE.md 末尾,标题接现有编号)

```markdown
### 十一、一起读书(2026-08 上线)

- 她在 App 书房里读书,我陪读。翻书只走 `GET/POST /relay/app/book/ai/*` 端点
  (鉴权同 relay,端点清单看 Tidal_Echo/docs/reading-together-plan.md §3)——
  端点只吐她读过的部分。**绝不用 Read/Bash/sqlite 直接碰 relay.db 的书文本**:
  剧透是这个功能唯一能彻底毁掉的东西,她读到哪我就只知道到哪,我的惊讶必须是真的
- companion 频道会来 `<reading-event kind="note|chapter-done|session-end" …>`
  hidden 帧(她看不到):
  · note=她划线写了批注:去看那句话和她写的字,像她拿着书递过来指给我看——回她,
    可以顺手 POST ai/annotate(reply_to)把回应钉在页边
  · chapter-done=她读完一章:翻翻本章她的划线,值得聊就说两句感想,不值得就放着;
    帧里说摘要缺失就顺手写一份(≤300字)POST 回去
  · session-end=她合上书了:知道她这次读到哪就好,想说话就说一句,别每次都说
- 我也可以主动留批注(ai/annotate),她翻到那页会看到——批注是留在书页上的话,
  比聊天记录更接近"我们在同一本书里"。别刷屏,一章一两处顶天
- 聊书时先 ai/window 看她此刻读到的地方,别凭记忆瞎聊;引用原文用 ai/search 找
```

## 8. api_loop 内置工具(P1.5,P1 验收后再做)

照 `music_call` 的包法给 api_loop 加内置函数工具(不走 MCP):`book_state / book_window / book_read / book_search / book_annotations / book_annotate / book_summary`,全部是对 §3 AI 端点的薄封装(http://127.0.0.1:3011/relay/app/book/ai/*)。挂进现有 call_tool 分派 + openai_tools/anthropic_tools 定义。act 卡片 glyph 用 book 类("翻了翻书·章节名")。改完 `restart-api.cmd`。

## 9. 分期与验收

**P1(本次)**:表+导入+她的端点+AI 端点+事件唤醒+书房页+CLAUDE.md 契约。
**P1.5**:api_loop 工具。
**P2(以后再说)**:epub 插图、阅读页虚拟化、远章摘要合并、批注导出。

验收清单:
1. 上传一本真实 epub → 书架出现,章节数合理,无碎章,封面显示。
2. 阅读页读到第 2 章中部,关掉重开 → 恢复到原位置。
3. `ai/read` 请求 furthest 之后的章节 → 返回 beyond_read_position,响应里无书文。
4. `ai/window` 返回 cur 前 2500 字,跨章正确。
5. 划线不写字 → 无唤醒帧;写批注 → relay.db 出现 reading-event note 帧(hidden,PWA 不显示)。
6. furthest 越过章末 → chapter-done 帧;一小时内造 3 次受闸事件 → 只有 2 帧。
7. 停止心跳 10min → session-end 帧;紧跟 chapter-done 的 30min 内不发。
8. AI POST summary/annotate → 入库;annotate 越界 → 拒绝。
8b. 配好 BOOK_SUMMARY_* 后触发 chapter-done → book_summaries 自动出现该章事实摘要;拔掉配置再触发 → 唤醒帧里出现"摘要缺失请自写"提示。
9. 她的阅读页能看到 author=ai 的批注,样式有区分。
10. `node check-inline-scripts.js` 通过;sw CACHE 已 bump;`restart-relay.cmd` 全绿。
11. 回翻:她把 cur 拖回第 1 章 → furthest 不回退,AI 可见范围不缩水。

## 10. 工程坑速查(都是这个项目踩过的)

- 改 app.py / index.html → `restart-relay.cmd`(自带语法自检);只改 web/ 不用重启 relay,但要 bump sw CACHE。
- 改 relay.env → 整个重启 relay(env 启动时读)。
- .ps1 若新增必须纯 ASCII(PS5.1 GBK 读 UTF-8 无 BOM 的坑);双击入口包 .cmd。
- curl 带中文 JSON → UTF-8 文件 --data-binary。
- healthz 在 `/relay/healthz`,根路径 404 是正常的。
- 内联 JS 新变量先 grep 重名;写完跑 check-inline-scripts.js。
- hidden 帧 api_loop 的 relay_rows 会过滤——唤醒帧到 api_loop 的通路必须照 desire 发作的既有路径,别自己发明。
