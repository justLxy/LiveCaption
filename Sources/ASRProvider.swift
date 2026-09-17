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
           let raw = ProcessInfo.processInfo.environment["XUESCRIBE_TEST_PROVIDER"], let kind = Self(rawValue:raw) { return kind }
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
    private var readOffset = 0
    static let packetBytes = 1600 // 800 samples = 50 ms, raw little-endian PCM16.
    mutating func append(_ floats: Data) -> [Data] {
        let sampleCount = floats.count / MemoryLayout<Float>.size
        guard sampleCount > 0 else { return [] }
        var converted = Data(count: sampleCount * MemoryLayout<Int16>.size)
        converted.withUnsafeMutableBytes { destination in
            floats.withUnsafeBytes { source in
                for index in 0..<sampleCount {
                    let offset = index * MemoryLayout<Float>.size
                    let outputOffset = index * MemoryLayout<Int16>.size
                    let value = source.loadUnaligned(fromByteOffset:offset,as:Float.self)
                    let clipped = value.isFinite ? min(1,max(-1,value)) : 0
                    let sample = Int16(max(-32768,min(32767,Int((clipped * 32768).rounded())))).littleEndian
                    destination.storeBytes(of:sample,toByteOffset:outputOffset,as:Int16.self)
                }
            }
        }
        buffer.append(converted)
        var packets: [Data] = []
        while buffer.count - readOffset >= Self.packetBytes {
            let end = readOffset + Self.packetBytes
            packets.append(buffer.subdata(in:readOffset..<end))
            readOffset = end
        }
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity:true)
            readOffset = 0
        } else if readOffset >= Self.packetBytes * 8 {
            buffer.removeSubrange(0..<readOffset)
            readOffset = 0
        }
        return packets
    }
    mutating func finish() -> Data? {
        guard readOffset < buffer.count else { return nil }
        defer { buffer.removeAll(keepingCapacity:true); readOffset = 0 }
        // At most 49 ms silence; do not lose the final real samples.
        var tail = buffer.subdata(in:readOffset..<buffer.count)
        tail.append(Data(count:Self.packetBytes-tail.count))
        return tail
    }
}
