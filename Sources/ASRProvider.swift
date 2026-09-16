import Foundation

/// Every provider consumes continuous mono Float32 PCM at 16 kHz and emits the
/// same cumulative hypothesis/final events. UI, segmenter and translation stay shared.
protocol ASRProvider: AnyObject {
    var event: ((ASREvent) -> Void)? { get set }
    var failure: ((String) -> Void)? { get set }
    func start() throws
    func send(_ data: Data)
    func finish()
    func terminate()
}

enum ASRProviderKind: String, CaseIterable, Identifiable {
    case local, assemblyAI
    var id: String { rawValue }
    static var initialSelection: Self {
        if CommandLine.arguments.contains("--headless"),
           let raw = ProcessInfo.processInfo.environment["LUMACAPTION_TEST_PROVIDER"], let kind = Self(rawValue:raw) { return kind }
        return Self(rawValue:UserDefaults.standard.string(forKey:"asrProvider") ?? "local") ?? .local
    }
    var title: String {
        switch self {
        case .local: return "Nemotron 3 English — Local"
        case .assemblyAI: return "AssemblyAI Universal-3.5 Pro — Cloud"
        }
    }
    var shortTitle: String { self == .local ? "Local" : "Cloud" }
}

/// Pure wire adaptation, also exercised without credentials by regression tests.
struct AssemblyAIMessage: Decodable {
    struct Configuration: Decodable { let model: String? }
    struct Word: Decodable { let end: Double? }
    let type: String
    let configuration: Configuration?
    let turn_order: Int?
    let end_of_turn: Bool?
    let turn_is_formatted: Bool?
    let transcript: String?
    let words: [Word]?
    let audio_duration_seconds: Double?
    let error_code: Int?

    var turn: ASREvent? {
        guard type == "Turn", let order = turn_order, let final = end_of_turn,
              let transcript else { return nil }
        // Word end is recognition evidence, not the amount of client audio sent.
        // Do not manufacture a progress update from a network heartbeat.
        let end = words?.compactMap(\.end).max().map { $0 / 1000 }
        return ASREvent(type:final && turn_is_formatted == true ? "final" : "partial",text:transcript,audio:end,utterance:order)
    }
}

struct PCM16Packetizer {
    private var buffer = Data()
    static let packetBytes = 1600 // 800 samples = 50 ms, raw little-endian PCM16.
    mutating func append(_ floats: Data) -> [Data] {
        floats.withUnsafeBytes { bytes in
            for offset in stride(from:0,to:floats.count - floats.count % 4,by:4) {
                let f = bytes.loadUnaligned(fromByteOffset:offset,as:Float.self)
                let value = f.isFinite ? min(1,max(-1,f)) : 0
                var sample = Int16(max(-32768,min(32767,Int((value * 32768).rounded())))).littleEndian
                withUnsafeBytes(of:&sample) { buffer.append(contentsOf:$0) }
            }
        }
        var packets: [Data] = []
        while buffer.count >= Self.packetBytes {
            packets.append(Data(buffer.prefix(Self.packetBytes)))
            buffer.removeFirst(Self.packetBytes)
        }
        return packets
    }
    mutating func finish() -> Data? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        // At most 49 ms silence; do not lose the final real samples.
        var tail = buffer
        tail.append(Data(count:Self.packetBytes-tail.count))
        return tail
    }
}
