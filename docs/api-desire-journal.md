# API desire 日志出口（2026-10-03）

API 身体现在通过 `moments_read` / `moments_post` 使用现有 `/app/posts` 后端。
写入固定 `author=ai`，`kind=moment` 发短动态，`kind=journal` 写长日志。
API 仍沿用原来的 desire 调度和冷却，不增加新的定时器。

`intent="memory"` 的规则与桌面一致：先翻 ombre 记忆，看看最近写过什么；
有几天的事想沉淀就写日志，只有一句感慨就选动态或聊天，不强制每次发帖。
日志写第一人称、具体、细腻、有留白，基于真实记忆和感受。
成功发帖后可只输出 `[[silent]]`，不再给聊天发送正文或发帖汇报。

只有 relay 已落库且 metadata 标注为 hidden desire/moments 的回合才缓冲正文、
thinking 和动作条，最终选择是否发聊天。工具执行、记忆便签仍照常工作。
普通聊天继续流式输出；用户手打的事件标签不会开启这个后台模式。
同一回合重复调用完全相同的发帖参数会复用已确认结果；POST 不自动重试。
预览/dry 回合禁用发帖。空白最终正文只有在发帖已确认成功时才视为安静结束。

评论也通过 `moments_comment(post_id, text, reply_to="human")` 接入：收到评论事件后，
先读帖子及完整评论，再在原帖下回复。固定以 AI 身份发布，默认显示回复她；
直接评论帖子时传 `reply_to=""`。同一回合相同参数只写一次，预览禁止写入，
成功后可以安静结束，不额外发聊天消息。

未接点赞、删帖；API 保活心跳仍只发文字，
也没有打开 explore/peek 的联网搜索能力。

验证：`backend/.venv/Scripts/python.exe -X utf8 -m unittest discover -s examples -p 'test_*.py'`。
测试使用假 HTTP relay 和假模型，覆盖 desire → 记忆 → 读最近日志 → 发帖 → 安静结束，
两种模型协议、普通聊天、中文正文、失败结果和预览禁写，不会往真实朋友圈发测试帖。
