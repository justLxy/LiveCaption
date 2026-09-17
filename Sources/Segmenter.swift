import Foundation
import NaturalLanguage

struct CaptionSegment: Identifiable, Equatable {
    let id: UUID
    let english: String
    let created: Date
    let revision: Int
    let bufferedSeconds: Double
    init(id: UUID = UUID(), english: String, created: Date = Date(), revision: Int = 0, bufferedSeconds: Double = 0) {
        self.id = id; self.english = english; self.created = created; self.revision = revision; self.bufferedSeconds = bufferedSeconds
    }
}

enum SegmentChange {
    case upsert(CaptionSegment)
    case remove(UUID)
}

/// Acoustic utterances and translation segments deliberately have separate lifetimes.
/// Only real decoder events establish stability. The timer may flush an endpoint,
/// but can never confirm a partial. All clocks used for decisions are monotonic.
struct Segmenter {
    struct Configuration {
        var confirmation: Double = 0.45
        var maxWait: Double = 2.0
    }
    var configuration = Configuration()
    private var carry = ""
    private var carrySince: Double?
    private var lead = ""
    private var leadSince: Double?
    private var active = ""
    private var committed: [CaptionSegment] = []
    private var previousWords: [String] = []
    private var wordSince: [Double] = []
    private var pendingSince: Double?
    private var lastAudio: Double = -.infinity
    private var currentUtterance: Int?

    var preview: String {
        let full = words(join(lead, active))
        let used = committed.flatMap { words($0.english) }
        // Never show the whole corrected hypothesis a second time below committed text.
        if !used.isEmpty && !full.starts(with: used) { return "" }
        return join(carry, full.dropFirst(used.count).joined(separator: " "))
    }

    mutating func ingest(_ text: String, final: Bool, audio: Double, utterance: Int,
                         now: Double = ProcessInfo.processInfo.systemUptime) -> [SegmentChange] {
        if let currentUtterance, utterance < currentUtterance { return [] }
        var changes: [SegmentChange] = []
        if currentUtterance != utterance {
            // A missing final must not silently discard the previous hypothesis.
            if !active.isEmpty { changes += finish(now: now) }
            currentUtterance = utterance
            lastAudio = -.infinity
        }
        let advanced = audio > lastAudio
        if !final && !advanced && canonical(text) == active { return changes }
        if active.isEmpty && committed.isEmpty && !text.isEmpty {
            lead = carry; leadSince = carrySince; carry = ""
            pendingSince = carrySince ?? now; carrySince = nil
        }
        active = canonical(text)
        let full = words(join(lead, active))
        var common = 0
        while common < min(full.count, previousWords.count), full[common] == previousWords[common] { common += 1 }
        wordSince = Array(wordSince.prefix(common)) + Array(repeating: now, count: full.count - common)
        previousWords = full
        lastAudio = max(lastAudio, audio)
        if final {
            changes += finish(now: now)
            // Bridge advances utterance after every final; reject late/duplicate events.
            currentUtterance = utterance + 1
            lastAudio = -.infinity
            return changes
        }
        // A revised cloud partial can retain the same word-end timestamp. Display
        // it immediately, but do not treat it as new progress for early submission.
        guard advanced else { return changes }
        let used = committed.flatMap { words($0.english) }
        guard full.starts(with: used) else { return changes } // Reconcile authoritatively at final.
        let remaining = Array(full.dropFirst(used.count))
        guard !remaining.isEmpty else { return changes }
        let stableCount = wordSince.dropFirst(used.count).prefix { now - $0 >= configuration.confirmation }.count
        let boundaries = sentenceLengths(remaining.joined(separator: " "))
        // Require a subsequent word: the end of a live hypothesis is especially revisable.
        var count = boundaries.first { $0 <= stableCount && $0 < remaining.count }
        if count == nil, now - (pendingSince ?? now) >= configuration.maxWait {
            // Prefer a stable clause boundary after the budget, never an arbitrary
            // word count/time slice. A long unpunctuated utterance waits for endpoint.
            let available = min(stableCount, remaining.count - 1)
            count = remaining.prefix(available).enumerated().first(where: { _, token in
                guard let last = token.last else { return false }
                return ",;:".contains(last)
            }).map { $0.offset + 1 }
        }
        if let count {
            let segment = CaptionSegment(english: remaining.prefix(count).joined(separator: " "), bufferedSeconds: max(0, now - (pendingSince ?? now)))
            committed.append(segment); changes.append(.upsert(segment)); pendingSince = now
        }
        return changes
    }

    mutating func tick(now: Double = ProcessInfo.processInfo.systemUptime, force: Bool = false) -> [SegmentChange] {
        if force {
            var result = finish(now: now)
            result += flushCarry(now:now)
            return result
        }
        // Carry moves into the active hypothesis on the next utterance. Never flush
        // it independently while the decoder is refining that joined hypothesis.
        guard let since = carrySince, now - since >= configuration.maxWait else { return [] }
        return flushCarry(now:now)
    }

    private mutating func finish(now: Double) -> [SegmentChange] {
        let full = words(join(lead, active))
        var offset = 0
        var changes: [SegmentChange] = []
        for (index, segment) in committed.enumerated() {
            let tokens = words(segment.english)
            if Array(full.dropFirst(offset)).starts(with: tokens) {
                offset += tokens.count
            } else {
                // Keep unaffected segments and replace the entire affected suffix.
                // This handles insertions/deletions across old boundaries without
                // guessed word offsets, duplicated text, or stale translations.
                let corrected = full.dropFirst(offset).joined(separator: " ")
                if corrected.isEmpty { changes.append(.remove(segment.id)) }
                else { changes.append(.upsert(CaptionSegment(id: segment.id, english: corrected,
                                      created: segment.created, revision: segment.revision + 1, bufferedSeconds: segment.bufferedSeconds))) }
                for obsolete in committed.dropFirst(index + 1) { changes.append(.remove(obsolete.id)) }
                resetActive()
                return changes
            }
        }
        let tail = full.dropFirst(offset).joined(separator: " ")
        var consumed = 0
        let tailWords = words(tail)
        for boundary in sentenceLengths(tail) {
            let sentence = tailWords[consumed..<boundary].joined(separator: " ")
            if !sentence.isEmpty { changes.append(.upsert(CaptionSegment(english: sentence, bufferedSeconds: max(0, now - (pendingSince ?? now))))) }
            consumed = boundary
        }
        let remainder = tailWords.dropFirst(consumed).joined(separator: " ")
        if !remainder.isEmpty {
            carry = remainder
            // Preserve the budget across repeated short, unpunctuated endpoints.
            carrySince = leadSince ?? now
        }
        resetActive()
        return changes
    }

    private mutating func resetActive() {
        active = ""; lead = ""; leadSince = nil; committed = []; previousWords = []; wordSince = []; pendingSince = nil
    }
    private mutating func flushCarry(now: Double) -> [SegmentChange] {
        guard !carry.isEmpty else { return [] }
        defer { carry = ""; carrySince = nil }
        return [.upsert(CaptionSegment(english: carry, bufferedSeconds: max(0, now - (carrySince ?? now))))]
    }
    private func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
    private func canonical(_ text: String) -> String { words(text).joined(separator: " ") }
    private func join(_ left: String, _ right: String) -> String { canonical(left + " " + right) }

    /// Apple's language tokenizer handles sentence boundaries and abbreviations;
    /// no course vocabulary, conjunction lists, or substring abbreviation rules.
    private func sentenceLengths(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(.english); tokenizer.string = text
        var result: [Int] = []
        var wordCount = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            wordCount += words(String(text[range])).count
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]}"))
            if let last = sentence.last, ".!?".contains(last) {
                result.append(wordCount)
            }
            return true
        }
        return result
    }
}

final class TranscriptJournal {
    let directory: URL
    private let json: FileHandle
    private let text: FileHandle
    private let timestampFormatter = ISO8601DateFormatter()
    private var jsonDirty = false
    private var textDirty = false
    private var closed = false

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
        var row = values; row["wall_time"] = timestampFormatter.string(from:Date())
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(10)
        try json.write(contentsOf:data); jsonDirty = true
    }

    private var order: [UUID] = []
    private var segments: [UUID: CaptionSegment] = [:]
    private var translations: [UUID: String] = [:]

    func upsert(_ segment: CaptionSegment) throws {
        let replacing = segments[segment.id] != nil
        if !replacing { order.append(segment.id) }
        segments[segment.id] = segment
        translations.removeValue(forKey: segment.id)
        // Normally append completed pairs. A correction rebuilds the
        // current transcript so an obsolete bilingual pair cannot remain there.
        if replacing { try rebuildText() }
    }
    func remove(_ id: UUID) throws {
        segments.removeValue(forKey:id); translations.removeValue(forKey:id)
        order.removeAll { $0 == id }; try rebuildText()
    }
    private func pair(_ segment: CaptionSegment, _ chinese: String) -> String {
        "[\(timestampFormatter.string(from:segment.created))]\nEnglish: \(segment.english)\n中文: \(chinese)\n\n"
    }
    private func rebuildText() throws {
        let contents = order.compactMap { id -> String? in
            guard let segment = segments[id], let chinese = translations[id] else { return nil }
            return pair(segment, chinese)
        }.joined()
        try text.truncate(atOffset:0); try text.seek(toOffset:0)
        try text.write(contentsOf:Data(contents.utf8)); textDirty = true
    }
    func translated(_ segment: CaptionSegment, chinese: String, latency: Double) throws {
        guard segments[segment.id]?.revision == segment.revision else { return }
        try record(["type":"translation", "id":segment.id.uuidString,"revision":segment.revision,
                    "english":segment.english,"chinese":chinese,"latency_seconds":latency,
                    "segmentation_wait_seconds":segment.bufferedSeconds,
                    "buffer_and_translation_seconds":segment.bufferedSeconds + latency])
        translations[segment.id] = chinese
        if segment.revision > 0 { try rebuildText() }
        else { try text.write(contentsOf:Data(pair(segment,chinese).utf8)); textDirty = true }
    }

    /// FileHandle writes are immediately visible to readers. A durability sync is
    /// needed at the session boundary, not after every small real-time event.
    func finish() throws {
        guard !closed else { return }
        if jsonDirty { try json.synchronize(); jsonDirty = false }
        if textDirty { try text.synchronize(); textDirty = false }
        try json.close(); try text.close(); closed = true
    }

    deinit { try? finish() }
}
