---
name: vision-image-delegation
description: 主模型为纯文本时，通过 task 委派 vision-analyst 子 Agent 分析图片
---

# 图片任务：委派视觉子 Agent

主对话模型（如 DeepSeek）**不能**直接看图。用户上传图片或问题涉及图像时，必须用 **`task` 工具**委派 **`vision-analyst`** 子 Agent，由豆包视觉模型分析后返回**纯文字**，你再基于文字继续回答。

## 何时委派

- 用户上传了图片（`additional_kwargs.files` 或 `<uploaded_files>` 中出现图片路径）
- 用户问「这张图」「上传的图片」「截图里写了什么」等
- 需要 OCR、图表解读、界面截图分析

## 标准流程

1. 从上传信息或用户说明中确认图片**虚拟路径**（如 `/mnt/user-data/uploads/photo.png`）。
2. 调用 `task`：
   - `description`: 简短说明，如「分析上传图片」
   - `subagent_type`: **`vision-analyst`**
   - `prompt`: 写明图片路径、用户问题、需要关注的细节
3. 收到子 Agent 返回的**文字总结**后，用主模型继续推理、写代码或给建议。
4. **禁止**：为看图而建议用户切换主模型；**禁止**在主对话中直接调用 `view_image`（主模型无此工具）。

## 示例 prompt（委派给 vision-analyst）

```
请用 view_image 查看 /mnt/user-data/uploads/demo.png，
描述画面内容并提取图中所有可见文字，按 SKILL 规定的格式返回纯文字总结。
用户问题：这份截图里的报错是什么意思？
```

## 前置条件

- 会话需开启 **Ultra** 模式（前端才会启用 `subagent_enabled` 与 `task` 工具）。
- 主模型保持 **DeepSeek**；视觉由子 Agent 内的 `doubao-seed-2-0-mini` 完成。

## 同一线程切换模型

不要在同一线程里先选豆包看图再切回 DeepSeek（历史中的 `image_url` 会导致 400）。始终用本 Skill 的委派流程。
