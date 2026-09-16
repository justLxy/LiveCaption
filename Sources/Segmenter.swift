import Foundation

/// Real-time caption segmentation using ASR signal prioritization.
///
/// Key insight from V1 analysis:
/// - Partials are cumulative (ASR refines the same utterance)
/// - Finals are new segments (committedKeys is reset)
/// - Use remainder() to extract only new content beyond what's committed
///
/// Simplified architecture:
/// - Explicit state machine (empty/accumulating/stable)
/// - Minimal semantic checks (~15 words vs 150+)
/// - Trust ASR final events as natural boundaries
struct Segmenter {

    // MARK: - State

    private enum State {
        case empty
        case accumulating(buffer: String)
        case stable(text: String, since: Date)
    }

    private var state = State.empty

    /// Tracks committed words to detect revisions and extract new content
    private var committedKeys: [String] = []

    /// Carry-over buffer for incomplete phrases across finals
    private var carry = ""
    private var carrySince = Date.distantFuture

    /// Current stable candidate (for partials)
    private var candidate = ""
    private var candidateSince = Date.distantFuture

    // MARK: - Configuration

    private let stabilityWindow: TimeInterval = 0.6
    private let finalFlushDelay: TimeInterval = 1.8

    // MARK: - Public API

    mutating func ingest(_ text: String, final: Bool, now: Date = Date()) -> [String] {
        // Check for ASR revision during partials
        if !final && !committedKeys.isEmpty {
            let keys = tokenize(text)
            guard keys.count >= committedKeys.count,
                  Array(keys.prefix(committedKeys.count)) == committedKeys else {
                // Revision detected - reset and treat as new
                return []
            }
        }

        // Extract new content beyond what we've committed
        let rest = remainder(text)

        if final {
            return handleFinal(rest, now: now)
        } else {
            return handlePartial(rest, now: now)
        }
    }

    mutating func tick(now: Date = Date(), force: Bool = false) -> [String] {
        guard !carry.isEmpty else { return [] }

        let wait = canClose(carry) ? 2.2 : 4.0
        guard force || now.timeIntervalSince(carrySince) >= wait else { return [] }

        defer { carry = "" }
        return [carry]
    }

    func preview(_ current: String) -> String {
        guard !current.isEmpty else { return carry }
        let snapshot = self
        return join(carry, snapshot.remainder(current))
    }

    // MARK: - Private Handlers

    private mutating func handlePartial(_ rest: String, now: Date) -> [String] {
        guard !rest.isEmpty else { return [] }

        // Find first closable boundary
        guard let boundary = findBoundaries(in: rest).first(where: {
            canClose(join(carry, String(rest[...$0])))
        }) else {
            candidate = ""
            return []
        }

        let prefix = String(rest[...boundary])
        let combined = join(carry, prefix)

        // Check if candidate is stable
        if candidate != combined {
            candidate = combined
            candidateSince = now
            return []
        }

        // Check if stable long enough
        let requiredWait = adjustedWaitTime(for: combined)
        guard now.timeIntervalSince(candidateSince) >= requiredWait else { return [] }

        // Commit this segment
        let prefixTokens = prefix.split(whereSeparator: { $0.isWhitespace })
        committedKeys += prefixTokens.map { normalize($0) }

        carry = ""
        candidate = ""
        return [combined]
    }

    private mutating func handleFinal(_ rest: String, now: Date) -> [String] {
        // Reset committed tracking at final boundary
        committedKeys = []
        candidate = ""

        guard !rest.isEmpty else { return [] }

        let combined = join(carry, rest)
        carry = ""
        var output: [String] = []
        var start = combined.startIndex
        let boundaries = findBoundaries(in: combined)

        // Split at boundaries and extract complete phrases
        for boundary in boundaries {
            let after = combined.index(after: boundary)
            let phrase = String(combined[start..<after]).trimmingCharacters(in: .whitespacesAndNewlines)

            if canClose(phrase) {
                output.append(phrase)
                start = after
            }
        }

        // Handle remainder
        let remainder = String(combined[start...]).trimmingCharacters(in: .whitespacesAndNewlines)

        // If no boundaries found but text is complete, output it
        // Or if boundaries were found but remainder is also complete, output remainder
        if !remainder.isEmpty && canClose(remainder) {
            output.append(remainder)
        } else if !remainder.isEmpty {
            // Save incomplete remainder as carry
            carry = remainder
        }

        carrySince = now

        return output
    }

    // MARK: - Helper Functions

    /// Extract new content beyond what's been committed (mirrors V1's remainder())
    private func remainder(_ text: String) -> String {
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        let keys = tokens.map { normalize($0) }

        guard !committedKeys.isEmpty else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Check if ASR revised previous content
        guard keys.count >= committedKeys.count,
              Array(keys.prefix(committedKeys.count)) == committedKeys else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard tokens.count > committedKeys.count else { return "" }

        return String(text[tokens[committedKeys.count].startIndex...])
    }

    /// Find sentence boundaries
    private func findBoundaries(in text: String) -> [String.Index] {
        text.indices.filter { i in
            guard ".!?;".contains(text[i]) else { return false }
            let next = text.index(after: i)
            guard next == text.endIndex || text[next].isWhitespace else { return false }

            if text[i] == "." {
                // Skip decimals
                if let prev = text.index(i, offsetBy: -1, limitedBy: text.startIndex),
                   text[prev].isNumber {
                    return false
                }

                // Skip common abbreviations
                let token = String(text[...i]).split(whereSeparator: { $0.isWhitespace }).last.map(String.init)?.lowercased() ?? ""
                let abbrevs = ["dr", "mr", "mrs", "ms", "prof", "inc", "ltd", "corp", "co", "e.g", "i.e", "etc"]
                if abbrevs.contains(where: { token.contains($0) }) {
                    return false
                }
            }

            return true
        }
    }

    /// Check if phrase can be closed (minimal semantic check)
    private func canClose(_ text: String) -> Bool {
        let words = tokenize(text)
        guard !words.isEmpty else { return false }

        // Trust ASR punctuation as sentence boundaries
        if text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") {
            return words.count >= 2
        }

        // No punctuation: check if last word is obviously incomplete
        let lastWord = words.last!
        let incomplete: Set<String> = ["a", "an", "the", "to", "of", "in", "on", "at", "and", "or", "but"]

        return !incomplete.contains(lastWord)
    }

    /// Adaptive wait time based on content
    private func adjustedWaitTime(for text: String) -> TimeInterval {
        let words = tokenize(text)
        let tokenCount = words.count

        // Short phrases commit faster
        if tokenCount <= 4 { return 0.4 }
        if tokenCount <= 6 { return 0.5 }

        // Check for complex structures
        let lower = text.lowercased()
        let hasComplexStructure = lower.contains("because") ||
                                  lower.contains("although") ||
                                  lower.contains("unless") ||
                                  lower.contains(" if ") ||
                                  lower.contains("which") ||
                                  lower.contains("that ")

        if hasComplexStructure && tokenCount > 10 { return 0.85 }
        if hasComplexStructure { return 0.75 }

        return 0.65
    }

    /// Join two text segments
    private func join(_ left: String, _ right: String) -> String {
        guard !left.isEmpty else { return right.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !right.isEmpty else { return left }

        var lhs = left

        // Remove trailing punctuation if left side can't close
        if !canClose(lhs) {
            while let c = lhs.last, ".!?;".contains(c) {
                lhs.removeLast()
            }
        }

        let leftTrimmed = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightTrimmed = right.trimmingCharacters(in: .whitespacesAndNewlines)

        // Detect and prevent duplication at boundaries (e.g., "Well" appearing in both)
        let leftWords = leftTrimmed.split(whereSeparator: { $0.isWhitespace })
        let rightWords = rightTrimmed.split(whereSeparator: { $0.isWhitespace })

        if let lastLeft = leftWords.last, let firstRight = rightWords.first,
           normalize(lastLeft) == normalize(firstRight), leftWords.count == 1 {
            // Left is just one word that duplicates first word of right - use right only
            return rightTrimmed
        }

        return leftTrimmed + " " + rightTrimmed
    }

    /// Tokenize and normalize words
    private func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { normalize($0) }
            .filter { !$0.isEmpty }
    }

    /// Normalize word (lowercase, remove punctuation)
    private func normalize(_ word: Substring) -> String {
        String(word).lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }
}

// MARK: - Supporting Types

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
