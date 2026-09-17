# 雪笺 XueScribe

> Turn speech into text, quietly.

实时英文语音字幕与中文翻译工具。默认使用本地 Nemotron，也可选 AssemblyAI 云端实时识别；中文翻译始终使用本地 Hy-MT2。

## 核心功能

捕获英文语音（麦克风或 Mac 系统音频）→ 实时识别为英文字幕 → 智能断句 → 翻译为中文字幕

- 识别 Provider：默认使用 Nemotron 本地 Metal 推理；也可由用户填写自己的 AssemblyAI API Key 使用云端实时识别，仅选择 Cloud 时上传音频
- 实时字幕：边听边显示，悬浮窗支持置顶、穿透、透明度调节
- 稳定断句：结合真实更新中的稳定前缀、模型标点和 endpoint，避免按时间硬切
- 双语记录：自动保存完整的英中双语记录（JSONL + TXT）

## 使用的模型

| 组件 | 模型 | 量化 | 作用 |
|------|------|------|------|
| **ASR（语音识别）** | NVIDIA Nemotron English 0.6B | Q8_0 GGUF | 实时英文语音转文字，使用 NeMo-Speech.cpp cache-aware streaming API |
| **ASR（可选云端）** | AssemblyAI Universal-3.5 Pro | — | v3 WebSocket，`speech_model=universal-3-5-pro` |
| **翻译** | 腾讯 Hy-MT2-1.8B | Q4_K_M GGUF | 英译中，通过 llama.cpp 加载 |

本地模型文件已内置在 App 中，无需单独下载。云端识别需要网络和有效的 AssemblyAI 账户。

## 系统要求

- Apple Silicon Mac（M 系列芯片）
- macOS 14+
- 系统音频捕获通过 ScreenCaptureKit 实现（需用户授权）

## 使用方法

1. 双击 `XueScribe.app` 启动
2. 点击菜单栏图标 → 设置，选择 ASR Provider 与音频源（麦克风或系统音频）
3. 点击"开始字幕"
4. 使用快捷键 ⌥⌘S 显示/隐藏字幕窗口

### 显示模式

- **单句字幕**：保持最后一组完整双语字幕，适合类似传统字幕的体验
- **长段转录与翻译**（默认）：保留最近 50/100/300/1000 段历史记录，可向上滚动回看

### 自定义术语表

设置页面可编辑术语表，格式为每行 `English = 中文`，用于专业词汇的翻译偏好。

## 技术细节

- **断句策略**：ASR 的 final 事件是音频分段边界，不等同于完整句子。使用真实 ASR 更新中的稳定前缀、模型标点和 endpoint 组合判断；无句末标点的 final 可跨段续接，并由统一等待预算兜底。不使用课程关键词或句型特例
- **流式处理**：ASR 使用真正的 cache-aware streaming API，持续接收 20ms PCM 帧；翻译仅处理稳定片段
- **Metal 加速**：本地 ASR 和翻译模型使用 Metal GPU 加速

## 构建

```bash
./build.sh
```

需要 Apple Command Line Tools。脚本会重新编译 Swift 代码并打包 App（需先退出运行中的 App）。

## 测试

```bash
Tests/run-tests.sh
```

验证断句逻辑、历史记录管理和 ID 更新机制。

## 官方来源

- [NVIDIA Nemotron English 模型](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b)
- [NeMo-Speech.cpp SDK](https://github.com/NVIDIA/NeMo-Speech.cpp)
- [腾讯 Hy-MT2 GGUF](https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF)
- [llama.cpp b10991](https://github.com/ggml-org/llama.cpp/releases/tag/b10991)

详细版本和校验值见 [Dependencies/versions.json](Dependencies/versions.json)。

## 注意事项

- 本机 ad-hoc 签名，非 Developer ID 公证签名
- 模型标点不保证语义完整；endpoint 后达到等待预算时可能输出短语；连续无标点发言可能等待更久。最终修订会更新原字幕段并重新翻译，不会作为重复的新句追加。不能保证 ASR 或翻译模型完全准确
- 双语记录保存在 `~/Library/Application Support/XueScribe/Transcripts/`；首次启动新版时会复制旧 `LumaCaption` 目录中的记录

## 0.5 断句与修订

- Bridge 保留相同文本的真实 ASR 更新，提供 utterance ID；定时器不再重放缓存文本。只有同一 utterance 中 audio 游标推进的结果参与稳定性确认。
- 两个通用参数位于 `Segmenter.Configuration`：`confirmation = 0.45s`、`maxWait = 2.0s`。前者确认真实更新中的共同前缀，后者限制 endpoint 后等待续接的时间，并允许使用已稳定的逗号、分号或冒号边界。模型 endpoint 仍使用 SDK 的 800ms token-silence。
- partial 中优先提交已经稳定且后面出现新词的句末边界；超过预算时可提交稳定的分句标点边界；没有标点时不会按时间或词数硬切。没有新 ASR 结果时不强行确认 partial。
- final 中完整标点句及时提交（包括 Yes./No.）；没有句末标点的尾部暂存，等待下一 utterance。跨段保留重复词，不做文本去重猜测。句子范围由系统 NaturalLanguage tokenizer 识别。
- ASR 修订已提交前缀时，保留未受影响的段，替换受影响的后缀并删除旧的后续段。段 ID 保持稳定，revision 递增；过期翻译结果不会显示或写入当前文本记录。
- `transcript.jsonl` 保留事件历史（含 revision 和 segment_removed），`transcript.txt` 保留已完成翻译的当前版本。重建文本只在修订时发生。
- 日志中的 `latency_seconds` 是提交后等待及翻译耗时；`segmentation_wait_seconds` 是应用缓冲等待；`buffer_and_translation_seconds` 是两者之和，**不是精确的最后发声到中文字幕延迟**。800ms endpoint、ASR 推理与采集延迟仍需单独考虑，1～2.5 秒是目标而非保证。
- 当前 SDK 的 stability/confidence 不是可靠的连续置信评分，不用于决策。没有引入语法模型，错误的模型句号仍可能导致语义上不完整的句子。

回归测试包含真实更新/缓存区分、修订插入删除、跨 endpoint 续接、缩写/数字/短回答、停止冲刷、历史 ID、过期译文和 transcript 修订。

## 0.5.1 透明窗口

背景 0% 时保留 7pt 的近乎透明边缘缩放区域，四边与角落均可拖动。字幕采用浅色字及深色描边，以兼容白色页面。鼠标悬停时临时显示深色底板和控制栏，移开后恢复设定透明度。开启点击穿透时，窗口不会接收拖动；需先在菜单栏关闭点击穿透。

## 0.5.2 文字配色

移除字幕描边、文字阴影和窗口阴影。顶部半黑半白圆形按钮可切换深灰／浅灰文字，设置中的“文字颜色”也可选择，偏好自动保存。悬停不再改变整窗背景透明度，仅音频来源和按钮组显示局部底板。背景 0% 时仍保留边缘缩放区域。

## 0.6.0 可选云端 ASR

顶部电脑／云图标菜单，或设置中的 **ASR Provider**，可选择：

- Nemotron 3 English — Local（默认）
- AssemblyAI Universal-3.5 Pro — Cloud

切换时先停止采集，等待旧 ASR 尾段及翻译保存，再开启新 Provider；悬浮窗历史保留。网络错误不会自动切换服务或重复发送旧音频。

两个实现遵循 `ASRProvider` 接口，统一接收 16kHz mono Float32 PCM，输出相同 `ASREvent`。AssemblyAI 实现将连续 PCM 转为 PCM16，以 50ms 二进制帧通过 WebSocket 发送；没有 WAV 文件切片、录音上传或 batch 接口。发送积压上限 2 秒；网络或认证失败会显示错误并停止捕获。

### 官方协议核对（2026-09-16）

- 模型：`universal-3-5-pro`
- 地址：`wss://streaming.assemblyai.com/v3/ws`
- 认证：`Authorization` 请求头直接放 API key，不加 Bearer，不放 URL。
- `Begin.configuration.model` 必须确认请求的模型，随后才开始捕获。
- `Turn.transcript` 是当前 turn 的完整假设；`turn_order` 映射为 utterance ID；final 使用 `end_of_turn && turn_is_formatted`。
- word end 时间戳用于识别进度；Heartbeat 不作为文本稳定证据。同一时间戳上的文本修订会更新预览，但不会被当成进度确认。
- 使用 `mode=balanced`、`include_partial_turns=true`、`continuous_partials=true`；partials 的具体发送时机仍由服务端控制，不保证每个词都返回一条结果。
- 停止时发送 `Terminate`，继续读取尾部 Turn，直到 `Termination`，之后才关闭连接。服务器会话最长约 3 小时；服务器结束或网络中断后需手动重新开始。
- 翻译只调用本机 llama.cpp/Hy-MT2；glossary 仍用于本地翻译，不发送给 AssemblyAI。

AssemblyAI API Key 由用户在设置中填写，并保存到 macOS 钥匙串；不写入偏好设置、字幕记录或日志。`Sources/LocalSecrets.swift` 不再参与构建。

官方来源：
- https://www.assemblyai.com/docs/streaming/select-the-speech-model
- https://www.assemblyai.com/docs/streaming/api-spec/streaming-websocket
- https://www.assemblyai.com/docs/streaming/message-sequence
- https://www.assemblyai.com/docs/streaming/common-session-errors-and-closures

测试模式可运行 `XUESCRIBE_TEST_PROVIDER=assemblyAI ./XueScribe.app/Contents/MacOS/XueScribe --headless --sample-seconds 12`，仅发送 App 内置样例，不录麦克风，不改变保存的 Provider 偏好；将环境变量改成 `local` 可验证本地路径。
