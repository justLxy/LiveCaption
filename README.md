# LumaCaption

实时英文语音字幕与中文翻译工具，完全本地运行，无需联网。

## 核心功能

捕获英文语音（麦克风或 Mac 系统音频）→ 实时识别为英文字幕 → 智能断句 → 翻译为中文字幕

- 本地推理：所有模型在 Mac 本机运行（Metal 加速），不发送数据到云端
- 实时字幕：边听边显示，悬浮窗支持置顶、穿透、透明度调节
- 智能断句：基于语法规则的断句引擎，避免在不完整从句、悬空介词或条件句中间断开
- 双语记录：自动保存完整的英中双语记录（JSONL + TXT）

## 使用的模型

| 组件 | 模型 | 量化 | 作用 |
|------|------|------|------|
| **ASR（语音识别）** | NVIDIA Nemotron English 0.6B | Q8_0 GGUF | 实时英文语音转文字，使用 NeMo-Speech.cpp cache-aware streaming API |
| **翻译** | 腾讯 Hy-MT2-1.8B | Q4_K_M GGUF | 英译中，通过 llama.cpp 加载 |

模型文件已内置在 App 中，无需单独下载。

## 系统要求

- Apple Silicon Mac（M 系列芯片）
- macOS 14+
- 系统音频捕获通过 ScreenCaptureKit 实现（需用户授权）

## 使用方法

1. 双击 `LumaCaption.app` 启动
2. 点击菜单栏图标 → 设置，选择音频源（麦克风或系统音频）
3. 点击"开始字幕"
4. 使用快捷键 ⌥⌘S 显示/隐藏字幕窗口

### 显示模式

- **单句字幕**：保持最后一组完整双语字幕，适合类似传统字幕的体验
- **长段转录与翻译**（默认）：保留最近 50/100/300/1000 段历史记录，可向上滚动回看

### 自定义术语表

设置页面可编辑术语表，格式为每行 `English = 中文`，用于专业词汇的翻译偏好。

## 技术细节

- **断句策略**：ASR 的 final 事件是音频分段边界，不等同于完整句子。断句引擎会检测悬空词、未闭合从句、对话性短语，跨 final 续接未完成片段，在语法稳定后才提交翻译
- **流式处理**：ASR 使用真正的 cache-aware streaming API，持续接收 20ms PCM 帧；翻译仅处理稳定片段
- **Metal 加速**：ASR 和翻译模型均使用 Metal GPU 加速

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
- 断句引擎基于保守的标点与语法规则，不能修正 ASR 识错的单词，也不能保证翻译模型完全准确
- 双语记录保存在 `~/Library/Application Support/LumaCaption/Transcripts/`
