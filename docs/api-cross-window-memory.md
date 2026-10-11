# API 跨窗记忆

本窗滚动摘要仍由本窗原始聊天和实际查阅记录生成。桌面、其他 API 窗的交接单独保存；交接资料不进入摘要器的新增输入，也不作为另一个窗的交接来源。

## 行为

- 首次实际聊天：选最近活跃的 API 窗（默认最多 3 个），加桌面摘要、交接便签和最近原文。每来源最多 12 条原文，摘要覆盖过的 API 消息不再重复带入。
- 返回已有窗：只追加其他来源在上次同步之后的原始消息。桌面摘要文件变更标记为替代快照，不宣称其全部内容是新事件。
- 默认延续最近活跃来源。`fresh` 共享近况但另开话题；`isolated` 不接收交接，也不再成为新交接的来源。
- 本窗历史翻页、设置变化或增量资料超过预算时，重建一份有界交接快照；正常轮次只在尾部追加，不改写开头。更换快照、摘要或达到查阅预算仍会改变部分缓存前缀。
- 每次成功的 `breath`、`breath_search`、`breath_advanced`、`dream`、`trace`、`letter_read` 立即存原文。模型后续失败不影响已保存的结果，同一轮相同结果重试去重。
- 查阅随原始轮次进入后续上下文；超出预算明确标记节选。`memory_read()` 查目录，`memory_read(id=..., offset=...)` 分页读完整原文。工具错误不作为成功查阅保存。
- 查阅退出本窗上下文后，摘要器可保留相关事实及原文 id；查阅日期与记忆所述事件日期不同。旧版开窗便签继续可读，不覆盖或重复迁移。
- 预览和缓存心跳不会更新交接游标或写入查阅资料。功能不额外调用摘要模型或 OB。

## 设置

网页设置 → 模型 → **API 跨窗记忆**。原生 iOS 聊天同样使用后端默认行为；本次未给原生设置页增加控件。

`POST /loop/config`（通过已鉴权的 relay `/app/loop_config`）支持：

```json
{
  "memory": {
    "enabled": true,
    "default_mode": "continue",
    "source_windows": 3,
    "recent_messages": 12,
    "handoff_chars": 12000,
    "read_chars": 16000
  }
}
```

`POST /loop/sessions`、`PATCH /loop/sessions/{id}` 可传 `handoff_mode`（continue/fresh/isolated）、`handoff_from`（auto/desktop/另一个 API 窗 id）。网页当前提供新窗默认方式；指定接续来源用接口。设置预算不删除原始聊天和查阅记录。

## 存储与限制

- 独立 SQLite：默认和 `LOOP_CONFIG` 同目录、同名，后缀 `.memory.sqlite3`。可用 `LOOP_MEMORY_DB` 指定。包含私人记忆，已加入 gitignore；备份应覆盖此文件。
- 桌面文件目录默认 `backend/forge`，可用 `LOOP_FORGE_DIR` 指定；最近原文来自 relay，不包含绕过 relay 的其他桌面会话。
- 桌面旧摘要只有文件更新时间，没有精确的消息覆盖游标，因此同时携带近期原文并注明可能重叠、旧状态不能当作此刻。
- 为避免无限增长，交接是有预算的近期快照，不保证把所有旧窗的全部历史装入上下文。长久重要记忆仍应放入 OB。
- 删除一个窗会删除它自己的查阅、交接和旧摘要状态。已进入其他窗的历史交接快照不会被追溯抹除；后续重建快照不再从已删除窗取材。
- API 的普通 `breath()` 现支持独立的钉选/高分/近期配额，见 [API 呼吸配比](api-breath-profile.md)。这里的查阅字数预算也约束呼吸结果的长度。

## 验证

`backend/.venv/Scripts/python.exe -X utf8 -m unittest discover -s examples -p "test_*.py"`

新测试使用临时 SQLite、虚构聊天、AST 加载函数，不读取实际 persona 或 key、不调用模型、不发送消息。覆盖跨窗增量、桌面近况、缓存前缀、本窗摘要隔离、跨窗读权限、持久化、重试、预算及删除。
