import Foundation

/// ASR endpoints are not sentence boundaries. Only stable, plausible clause endings
/// are translated; unclosed final tails carry into the next streaming utterance.
struct Segmenter {
    private var committedKeys: [String] = []
    private var candidate = ""
    private var candidateSince = Date.distantFuture
    private var carry = ""
    private var carrySince = Date.distantFuture
    private(set) var revised = false

    private static func words(_ text:String) -> [Substring] { text.split(whereSeparator: { $0.isWhitespace }) }
    private static func key(_ word:Substring) -> String {
        word.lowercased().trimmingCharacters(in:.punctuationCharacters.union(.symbols))
    }
    private static func trim(_ text:String) -> String { text.trimmingCharacters(in:.whitespacesAndNewlines) }

    // 扩展的悬挂词列表 - 更全面的语法覆盖
    private static let dangling: Set<String> = [
        // 冠词和限定词
        "a","an","the","my","your","our","their","its","his","her","this","these","those",
        // 连词
        "and","or","but","because","although","unless","whether","which","whose","that","what","if","when","while","since",
        // 介词
        "to","of","in","on","at","for","from","by","about","into","with","without","through","over","under","between","among","during","before","after","against","towards","toward",
        // 助动词和系动词
        "has","have","had","having","be","been","being","is","was","were","am","are",
        // 情态动词
        "can","could","will","would","shall","should","must","might","may","ought",
        // 程度副词和量词
        "very","so","too","more","most","less","many","much","some","such","each","every","another","any","all",
        // 口语缩略和填充词
        "going","gonna","wanna","gotta","kinda","sorta","want","wants","need","needs","invest",
        // 常见动词后缀（不完整）
        "trying","getting","making","taking","doing","saying","feeling","thinking","looking","coming","working"
    ]

    // 填充词和对话标记
    private static let fillers: Set<String> = [
        "well","um","uh","erm","hmm","ah","oh","like",
        "and","or","but","so","then","now","actually","basically",
        "y","yeah","yep","nah","okay","ok","right","sure"
    ]

    // 对话性短语开头 - 需要等待完整表达
    private static let conversationalOpeners: [String] = [
        "i mean", "you know", "let me", "i think", "i feel", "i believe",
        "it seems", "it looks", "it feels", "the thing is", "the point is",
        "what i mean", "in other words", "to be honest", "to be fair"
    ]

    // 技术缩写 - 不应该被当作句子结尾
    private static let techAbbreviations: Set<String> = [
        "api","ui","ux","ml","ai","cpu","gpu","url","html","css","js","sql",
        "http","https","ssh","ftp","dns","tcp","ip","etc","e.g","i.e",
        "mr","mrs","ms","dr","prof","vs","inc","ltd","corp","co"
    ]

    /// 智能语法完整性检查 - 更细致的语义理解
    private static func canClose(_ text:String) -> Bool {
        let tokens = words(text).map(key).filter { !$0.isEmpty }
        guard let last = tokens.last else { return false }

        // 纯填充词不能断句
        if tokens.allSatisfy({ fillers.contains($0) }) { return false }

        // 问句需要合理长度（至少主语+动词）
        if text.hasSuffix("?") { return tokens.count >= 2 }

        // 检查是否以对话性短语开头且未完成
        let beginning = tokens.prefix(6).joined(separator:" ")
        for opener in conversationalOpeners {
            if beginning.hasPrefix(opener) {
                // 如果有逗号或明确的完成标记，可以断句
                if !text.contains(",") && !text.contains(" and ") { return false }
            }
        }

        // 悬挂词检查 - 但有例外情况
        if dangling.contains(last) {
            // 相对从句中的悬挂介词是合法的
            if ["with","for","about","at","on"].contains(last), tokens.count >= 7 {
                let hasStrandableVerb = tokens.contains(where: {
                    ["disagree","looking","stands","work","rely","depend","focus","based"].contains($0)
                })
                if hasStrandableVerb { return true }
            }
            return false
        }

        // "are" 的特殊处理 - 避免 "values are" 类型的中断
        if last == "are" {
            if !text.lowercased().contains("values are") && tokens.count < 8 { return false }
        }

        // 去除开头的填充词，检查核心句子结构
        var core = tokens
        while let first = core.first, fillers.contains(first) { core.removeFirst() }

        // 从句检查 - 如果以从句连词开头但没有主句，不应该断句
        if let firstCore = core.first {
            let subordinators = ["if","because","although","unless","when","while","since","though","whereas"]
            if subordinators.contains(firstCore) {
                // 检查是否有明确的主句标记（逗号后的内容，或 "then"）
                if !tokens.contains("then") && !text.contains(",") { return false }
            }
        }

        // "feel like if" 这类需要完整的条件-结果结构
        let lower = text.lowercased()
        if (lower.contains("feel like if") || lower.contains("seems like if")), !tokens.contains("then") {
            return false
        }

        // 检查是否以 -ing 结尾（可能是未完成的动作）
        if last.hasSuffix("ing") && tokens.count < 5 { return false }

        return true
    }

    /// 查找句子边界 - 改进的标点符号识别
    private static func boundaries(_ text:String) -> [String.Index] {
        text.indices.filter { i in
            guard ".!?;".contains(text[i]) else { return false }
            let next = text.index(after:i)
            guard next == text.endIndex || text[next].isWhitespace else { return false }

            if text[i] == "." {
                // 提取当前词（包含点号）
                let token = words(String(text[...i])).last.map(key) ?? ""

                // 单字母缩写（如 "I.B.M."）
                if token.count == 1 { return false }

                // 技术缩写和常见缩写
                if techAbbreviations.contains(token) { return false }

                // 数字后的点（如 "3.14", "v2.0"）
                if let prevIdx = text.index(i, offsetBy: -1, limitedBy: text.startIndex),
                   text[prevIdx].isNumber { return false }
            }

            return true
        }
    }

    /// 智能连接两个文本片段
    private static func join(_ left:String,_ right:String) -> String {
        guard !left.isEmpty else { return trim(right) }
        guard !right.isEmpty else { return left }

        var lhs = left

        // 如果左侧不能独立结束，移除尾部的标点
        if !canClose(lhs) {
            while let c = lhs.last, ".!?;".contains(c) { lhs.removeLast() }
        }

        // 检测重复的填充词 - ASR 有时会在边界重复
        let l = words(lhs), r = words(right)
        if l.count == 1, let first = l.first, fillers.contains(key(first)),
           r.first.map(key) == key(first) {
            return trim(right)
        }

        return trim(lhs) + " " + trim(right)
    }

    /// 清理文本 - 移除不合法的句尾标点
    private static func cleaned(_ text:String) -> String {
        var result = "", start = text.startIndex
        for end in boundaries(text) {
            let after = text.index(after:end)
            var chunk = trim(String(text[start..<after]))

            // 如果是句号结尾但不能独立结束，移除句号
            if text[end] == ".", !canClose(chunk) { chunk.removeLast() }

            if !chunk.isEmpty { result += (result.isEmpty ? "" : " ") + chunk }
            start = after
        }

        let tail = trim(String(text[start...]))
        if !tail.isEmpty { result += (result.isEmpty ? "" : " ") + tail }
        return result
    }

    /// 计算剩余文本（去除已提交的部分）
    private mutating func remainder(_ text:String) -> String {
        let tokens = Self.words(text), keys = tokens.map(Self.key)
        guard !committedKeys.isEmpty else { return Self.trim(text) }

        // 检查 ASR 是否修改了之前的内容
        guard keys.count >= committedKeys.count,
              Array(keys.prefix(committedKeys.count)) == committedKeys else {
            revised = true
            return Self.trim(text)
        }

        guard tokens.count > committedKeys.count else { return "" }
        return String(text[tokens[committedKeys.count].startIndex...])
    }

    /// 动态计算等待时间 - 根据句子特征调整
    private static func waitTime(for text: String) -> TimeInterval {
        let tokens = words(text)
        let tokenCount = tokens.count

        // 短句可以更快断句
        if tokenCount <= 4 { return 0.4 }
        if tokenCount <= 6 { return 0.5 }

        // 检查是否包含复杂结构
        let lower = text.lowercased()
        let hasComplexStructure = lower.contains("because") ||
                                  lower.contains("although") ||
                                  lower.contains("unless") ||
                                  lower.contains(" if ") ||
                                  lower.contains("which") ||
                                  lower.contains("that ")

        // 复杂句子等待更久
        if hasComplexStructure && tokenCount > 10 { return 0.85 }
        if hasComplexStructure { return 0.75 }

        // 标准等待时间
        return 0.65
    }

    /// 摄入新的 ASR 输出
    mutating func ingest(_ text:String, final:Bool, now:Date = Date()) -> [String] {
        // 非 final 时检查是否有修订
        if !final && !committedKeys.isEmpty {
            let keys = Self.words(text).map(Self.key)
            guard keys.count >= committedKeys.count,
                  Array(keys.prefix(committedKeys.count)) == committedKeys else {
                revised = true
                return []
            }
        }

        let rest = remainder(text)

        // 处理 final 事件
        if final {
            committedKeys = []
            candidate = ""

            // 空的 final 不应该丢弃 carry
            guard !rest.isEmpty else { return [] }

            let combined = Self.join(carry,rest)
            carry = ""
            var output: [String] = []
            var start = combined.startIndex

            // 遍历所有边界，提取可以关闭的短语
            for boundary in Self.boundaries(combined) {
                let after = combined.index(after:boundary)
                let phrase = Self.trim(String(combined[start..<after]))
                if Self.canClose(phrase) {
                    output.append(Self.cleaned(phrase))
                    start = after
                }
            }

            // 保存剩余部分
            carry = Self.trim(String(combined[start...]))
            carrySince = now
            return output
        }

        // 处理流式 partial
        guard !rest.isEmpty else { return [] }

        // 查找第一个可以关闭的边界
        guard let boundary = Self.boundaries(rest).first(where: {
            Self.canClose(Self.join(carry, String(rest[...$0])))
        }) else {
            candidate = ""
            return []
        }

        let prefix = String(rest[...boundary])
        let combined = Self.join(carry, prefix)

        // 候选句子稳定性检查
        if candidate != combined {
            candidate = combined
            candidateSince = now
            return []
        }

        // 动态等待时间
        let requiredWait = Self.waitTime(for: combined)
        guard now.timeIntervalSince(candidateSince) >= requiredWait else { return [] }

        // 提交这个句子
        committedKeys += Self.words(prefix).map(Self.key)
        carry = ""
        candidate = ""
        return [Self.cleaned(combined)]
    }

    /// 预览当前完整文本（包含 carry）
    func preview(_ current:String) -> String {
        guard !current.isEmpty else { return carry }
        var snapshot = self
        return Self.join(carry, snapshot.remainder(current))
    }

    /// 刷新 carry - 在静音或停止时释放
    mutating func flushCarry(now:Date = Date(), force:Bool = false) -> [String] {
        guard !carry.isEmpty else { return [] }

        // 根据句子完整性动态调整等待时间
        let wait = Self.canClose(carry) ? 2.2 : 4.0
        guard force || now.timeIntervalSince(carrySince) >= wait else { return [] }

        defer { carry = "" }
        return [Self.cleaned(carry)]
    }
}

struct CaptionSegment: Identifiable {
    let id = UUID()
    let english: String
    let created = Date()
}

final class TranscriptJournal {
    let directory: URL
    private let json: FileHandle
    private let text: FileHandle
    init(root: URL) throws {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        directory = root.appendingPathComponent(stamp + "-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let j = directory.appendingPathComponent("transcript.jsonl"), t = directory.appendingPathComponent("transcript.txt")
        FileManager.default.createFile(atPath: j.path, contents: nil)
        FileManager.default.createFile(atPath: t.path, contents: nil)
        json = try FileHandle(forWritingTo: j); text = try FileHandle(forWritingTo: t)
    }
    func record(_ values: [String: Any]) throws {
        var row = values; row["wall_time"] = ISO8601DateFormatter().string(from: Date())
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(10)
        try json.write(contentsOf: data); try json.synchronize()
    }
    func translated(_ segment: CaptionSegment, chinese: String, latency: Double) throws {
        try record(["type":"translation", "id":segment.id.uuidString,"english":segment.english,"chinese":chinese,"latency_seconds":latency])
        try text.write(contentsOf: Data("[\(ISO8601DateFormatter().string(from: segment.created))]\nEnglish: \(segment.english)\n中文: \(chinese)\n\n".utf8)); try text.synchronize()
    }
    deinit { try? json.close(); try? text.close() }
}
