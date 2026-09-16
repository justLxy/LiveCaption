# LumaCaption 0.3.1

双击 `LumaCaption.app` 即可使用，Apple Silicon / macOS 14+。模型与 Metal 运行库已内置，无需联网推理。

## 0.3 断句优化

- 删除 14 词硬切规则；partial 保持即时显示，不因长度直接提交翻译。
- ASR final 作为音频识别分段，不能直接视为完整句子；未完成的尾句跨 final 续接。
- 拦截 `has a`、`lead to`、`in the`、`so many` 等悬空尾部，以及未完成的条件句。
- 句末 partial 稳定 650 ms 后才可提交；完整 final 中的句子立即提交。
- 未闭合片段保持在英文预览中。没有新 partial 时，普通尾句等待 2.2 秒、明显不完整尾句等待 4 秒后提交；点击停止强制提交剩余内容。连续长句可能使中文更新比此前慢，优先避免断义。
- 这是保守的标点与语法规则，不是完整语义解析器，不能修正 ASR 已经识错的单词，也不能保证翻译模型不误译。

验证：`Tests/segmentation-replay.txt` 是用户所示会话原始 ASR final 的顺序回放（不是音频重跑，也不代表实时 partial 完整回放）；`Tests/segmentation-smoke-report.json` 是更新后的短时真实模型链路测试。三小时测试仍然停用。

## 本次更新

- **窗口移动**：按住顶部左侧的三横线、LUMA 标识或状态文字拖动。字幕正文保留滚动和选择文字功能，窗口边缘可缩放。点击穿透开启时需要先在菜单栏关闭穿透。
- **英文识别模型**：已改为 NVIDIA 官方 `nemotron-speech-streaming-en-0.6b`（NeMo 简称 `nemotron-en`），Q8_0 GGUF；仍然使用真正 cache-aware streaming C API、持续 20 ms PCM 帧和 Metal。
- **显示模式**：设置 → 显示模式，可选“单句字幕”或“长段转录与翻译”。默认长段模式，英中逐段配对，中文就绪后更新对应段落，不替换此前记录。
- **回看记录**：向上滚动暂停跟随，点击“回到最新”恢复。窗口保留 50、100、300 或 1000 段可选，默认 300。窗口达到上限时移除最早的可视记录；完整文件记录不受限制。开始新会话会清空当前窗口记录，上次内容仍保存在文件中。
- **已取消三小时测试**：后台测试已停止，自动跟进已暂停；短时功能验证继续保留。

## 使用

菜单栏气泡图标 → 设置与术语表。选择麦克风或 Mac 系统音频，再点击“开始字幕”。系统音频通过 ScreenCaptureKit 捕获。开始时会弹出 macOS 原生共享选择器，请选择屏幕并确认本次共享；不再预先枚举屏幕或依赖旧的永久屏幕录制授权。仅接收音频回调，不保存画面。⌥⌘S 可显示/隐藏字幕窗。

背景不透明度 0–100%、字体、英中显示、置顶和点击穿透均可调。设置页面可编辑术语，每行 `English = 中文`。字幕全文使用 UTF-8 JSONL 和 TXT 持续保存，点击“打开双语记录”即可定位。

模型：Nemotron English 0.6B Q8_0 + Hy-MT2-1.8B Q4_K_M。翻译只接收稳定/最终片段。单句模式保持最后一组完整双语字幕，另显示即时英文 partial。

## 构建与验证

已在本机编译并做 ad-hoc 签名。运行 `./build.sh` 重建（先退出 App），需 Apple Command Line Tools。`Tests/run-tests.sh` 验证断句、修订、记录写入与历史段落按 ID 更新。`Tests/english-smoke-report.json` 是英文模型的短时实际推理测试。

本机签名不是 Developer ID 公证签名，跨机器分发尚未公证。短时合成语音测试不代表任意课程准确率或持续三小时硬件捕获验收。系统音频实现已编译，交互式系统音频验收尚未完成。

## 官方来源

- [Nemotron English 模型与 GGUF](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b)
- [NeMo-Speech.cpp 官方 SDK](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/sdk.md)
- [Hy-MT2 官方 GGUF](https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF)
- [llama.cpp b10991](https://github.com/ggml-org/llama.cpp/releases/tag/b10991)

固定版本、模型校验值见 `Dependencies/versions.json`。

## 0.3.1 系统音频权限修复

旧版本使用 ad-hoc 签名，其 designated requirement 是会随构建变化的 cdhash；设置开关开启仍可能被 TCC 拒绝。日志确认之前的失败发生在屏幕枚举阶段。新版取消 `SCShareableContent` 预枚举，使用官方 `SCContentSharingPicker` 返回的用户授权过滤器创建音频流。无需重置其他 App 的权限。

取消选择、点击停止和关闭应用会清理选择器观察者及等待中的请求。系统音频来源选择会保存。编译与现有回归检查通过；实际捕获仍需用户在系统选择器中确认后验证。

官方说明：https://developer.apple.com/videos/play/wwdc2023/10053/
