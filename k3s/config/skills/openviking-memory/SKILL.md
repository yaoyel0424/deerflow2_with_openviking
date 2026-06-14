---
name: openviking-memory
description: 使用 OpenViking MCP 进行分层记忆检索与上下文加载
---

# OpenViking 记忆检索

DeerFlow 已接入 **OpenViking** 作为外置上下文数据库。内置 Memory 已关闭，请通过 MCP 工具管理长期记忆。

## 何时使用

在以下场景**优先**调用 OpenViking MCP（`search` / `find` / `read`）：

- 用户提到「之前说过」「继续上次」「我的偏好」等跨会话信息
- 复杂任务开始前，检索相关历史记忆或资源
- 需要引用已导入文档、技能或项目上下文

## 推荐流程

1. **检索**：`find` 或 `search`，查询与用户问题相关的记忆/资源
2. **精读**：对高相关 URI 使用 `read` 加载 L2 详情
3. **回答**：结合检索结果生成回复，必要时引用来源 URI

## 注意事项

- 会话结束后 Middleware 会自动将对话同步到 OpenViking 并 `commit` 提取记忆
- 不要与 DeerFlow 内置 memory API 混用（已禁用）
- 若 MCP 不可用，如实告知用户并基于当前线程上下文回答
