import Foundation
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError(message) }
}
func segments(_ changes: [SegmentChange]) -> [CaptionSegment] {
    changes.compactMap { if case .upsert(let s) = $0 { return s }; return nil }
}
func texts(_ changes: [SegmentChange]) -> [String] { segments(changes).map(\.english) }
func feed(_ s: inout Segmenter, _ text: String, _ time: Double, final: Bool = false, u: Int = 0) -> [SegmentChange] {
    s.ingest(text, final: final, audio: time, utterance:u, now:time)
}
var s = Segmenter()
expect(texts(feed(&s,"The value is fifteen. Next",0)).isEmpty,"first partial must wait")
expect(s.tick(now:10).isEmpty,"timer must never confirm cached partial")
expect(feed(&s,"The value is fifteen. Next",0).isEmpty,"duplicate audio is not evidence")
let original = segments(feed(&s,"The value is fifteen. Next",0.6))
expect(original.map(\.english) == ["The value is fifteen."],"real repeated ASR update confirms prefix")
let correction = segments(feed(&s,"The value is fifty. Next example.",1,final:true))
expect(correction.count == 1 && correction[0].id == original[0].id && correction[0].revision == 1,"final correction retains ID")
expect(correction[0].english == "The value is fifty. Next example.","correction replaces suffix without duplicates")
expect(feed(&s,"The value is fifty. Next example.",1,final:true).isEmpty,"duplicate final ignored")

s = Segmenter()
expect(texts(feed(&s,"Well, I feel like if you're going to invest",0,final:true)).isEmpty,"unpunctuated endpoint held")
expect(texts(feed(&s,"So much in building AI",0.5,final:true,u:1)).isEmpty,"merge across endpoint")
let merged = texts(feed(&s,"then people should understand your values.",1,final:true,u:2))
expect(merged == ["Well, I feel like if you're going to invest So much in building AI then people should understand your values."],"carry must be lossless")
for input in ["Yes.","No!","Why?","The result is correct. We can proceed.","The signal drops. We should stop.","The value is 3. Next example.","The value is 3.14. Next example."] {
    var t = Segmenter()
    let result = texts(feed(&t,input,0,final:true))
    expect(result.joined(separator:" ") == input,"no loss for \(input)")
    expect(result.count == (input.contains("Next") || input.contains("We ") ? 2 : 1),"natural boundaries: \(input) -> \(result)")
}
s = Segmenter()
_ = feed(&s,"Well",0,final:true)
expect(texts(feed(&s,"well, this works.",1,final:true,u:1)) == ["Well well, this works."],"do not delete real repeated words")
s = Segmenter()
_ = feed(&s,"A phrase without punctuation",0,final:true)
expect(s.tick(now:1).isEmpty,"endpoint waits for continuation")
expect(texts(s.tick(now:2.1)) == ["A phrase without punctuation"],"endpoint bounded flush")
expect(s.tick(now:5).isEmpty,"flush once")
s = Segmenter()
_ = feed(&s,"An unfinished hypothesis",0)
expect(texts(s.tick(now:1,force:true)) == ["An unfinished hypothesis"],"stop saves last partial")
expect(s.tick(now:2,force:true).isEmpty,"stop idempotent")
s = Segmenter()
_ = feed(&s,"First sentence. Second sentence. Third",0)
let first = segments(feed(&s,"First sentence. Second sentence. Third",0.6))
let second = segments(feed(&s,"First sentence. Second sentence. Third",1.2))
expect(first.count == 1 && second.count == 1,"multiple stable sentences")
let changes = feed(&s,"Replacement.",1.4,final:true)
expect(segments(changes).first?.id == first.first?.id,"cross-boundary correction keeps earliest ID")
expect(changes.contains { if case .remove(let id) = $0 { return id == second.first?.id }; return false },"obsolete suffix removed")

s = Segmenter()
_ = feed(&s,"The derivative tells us how quickly",0)
expect(feed(&s,"The derivative tells us how quickly a function",2.1).isEmpty,"never cut unpunctuated speech on a timer budget")
expect(texts(feed(&s,"The derivative tells us how quickly a function changes.",3,final:true)) == ["The derivative tells us how quickly a function changes."],"complete context reaches translator")
s = Segmenter()
_ = feed(&s,"We can proceed, and this",0)
expect(texts(feed(&s,"We can proceed, and this works",2.1)) == ["We can proceed,"],"stable clause boundary is a latency fallback")
for input in ["Dr. Smith is here.", "The value is 3.14.", "She said \"Yes.\" Next example."] {
    var t = Segmenter()
    expect(texts(feed(&t,input,0,final:true)).joined(separator:" ") == input,"abbreviations/quotes preserved")
}
// Deterministic edit cases after two committed sentences: replay the public
// changes exactly as the UI would, then compare against the authoritative final.
for final in ["", "First sentence.", "First sentence. Revised tail.",
              "Inserted first sentence. Second sentence. Third.",
              "First changed sentence. Third.",
              "First sentence. Second sentence. Third sentence."] {
    var t = Segmenter()
    var visible: [CaptionSegment] = []
    func apply(_ updates: [SegmentChange]) {
        for update in updates {
            switch update {
            case .upsert(let segment):
                if let index = visible.firstIndex(where: { $0.id == segment.id }) { visible[index] = segment }
                else { visible.append(segment) }
            case .remove(let id): visible.removeAll { $0.id == id }
            }
        }
    }
    apply(feed(&t,"First sentence. Second sentence. Third",0))
    apply(feed(&t,"First sentence. Second sentence. Third",0.6))
    apply(feed(&t,"First sentence. Second sentence. Third",1.2))
    apply(feed(&t,final,1.8,final:true))
    apply(t.tick(now:4,force:true))
    expect(visible.map(\.english).joined(separator:" ") == final,"authoritative edit must be lossless: \(final)")
}
s = Segmenter()
_ = feed(&s,"First unfinished phrase",0,final:true)
_ = feed(&s,"and its continuation",1,u:1)
expect(s.tick(now:3).isEmpty,"timer cannot flush carry separately from active continuation")
expect(texts(s.tick(now:3,force:true)) == ["First unfinished phrase and its continuation"],"stop retains cross-utterance carry")
expect(feed(&s,"late event",4,u:0).isEmpty,"old utterance cannot reappear")

let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at:root) }
let journal = try TranscriptJournal(root:root)
let before = CaptionSegment(english:"Wrong.")
try journal.upsert(before); try journal.translated(before,chinese:"错误。",latency:0.1)
let after = CaptionSegment(id:before.id,english:"Right.",revision:1)
try journal.upsert(after)
try journal.translated(before,chinese:"迟到的旧译文",latency:0.2)
try journal.translated(after,chinese:"正确。",latency:0.2)
let saved = try String(contentsOf:journal.directory.appendingPathComponent("transcript.txt"),encoding:.utf8)
expect(saved.contains("Right.") && !saved.contains("Wrong.") && !saved.contains("迟到"),"journal rejects stale revisions")
var history = CaptionHistory()
history.upsert(before,limit:3); history.translate(id:before.id,chinese:"旧译文")
history.upsert(after,limit:3)
expect(history.entries.count == 1 && history.entries[0].chinese == nil && history.entries[0].english == "Right.","history revision invalidates Chinese")
// v3 cloud events use the same segmenter contract as the local bridge.
let cloudPartial = try JSONDecoder().decode(AssemblyAIMessage.self,from:Data(#"{"type":"Turn","turn_order":3,"end_of_turn":false,"transcript":"A new turn","words":[{"end":1200}]}"#.utf8))
expect(cloudPartial.turn?.type == "partial" && cloudPartial.turn?.utterance == 3 && cloudPartial.turn?.audio == 1.2,"cloud partial and word time mapping")
let cloudFinal = try JSONDecoder().decode(AssemblyAIMessage.self,from:Data(#"{"type":"Turn","turn_order":3,"end_of_turn":true,"turn_is_formatted":true,"transcript":"A new turn.","words":[{"end":1500}]}"#.utf8))
expect(cloudFinal.turn?.type == "final","cloud end_of_turn authoritative")
var cloudSegments = Segmenter()
let cp = cloudPartial.turn!, cf = cloudFinal.turn!
_ = cloudSegments.ingest(cp.text!,final:false,audio:cp.audio!,utterance:cp.utterance!,now:0)
expect(texts(cloudSegments.ingest(cf.text!,final:true,audio:cf.audio!,utterance:cf.utterance!,now:1)) == ["A new turn."],"cloud events use existing segmenter")
let heartbeat = try JSONDecoder().decode(AssemblyAIMessage.self,from:Data(#"{"type":"Heartbeat","total_audio_received_ms":3000}"#.utf8))
expect(heartbeat.turn == nil,"heartbeat never confirms partial")
let begin = try JSONDecoder().decode(AssemblyAIMessage.self,from:Data(#"{"type":"Begin","configuration":{"model":"universal-3-5-pro"}}"#.utf8))
expect(begin.configuration?.model == "universal-3-5-pro","model echo decoded")
var packer = PCM16Packetizer()
let floats: [Float] = Array(repeating:0,count:320)
let bytes = floats.withUnsafeBytes { Data($0) }
expect(packer.append(bytes).isEmpty,"20ms buffered, no undersized wire frames")
expect(packer.append(bytes).isEmpty,"40ms buffered")
let packet = packer.append(bytes)
expect(packet.count == 1 && packet[0].count == 1600,"60ms produces one 50ms packet")
expect(packer.finish()?.count == 1600 && packer.finish() == nil,"10ms tail flushed exactly once with zero padding")
let extreme: [Float] = [-2,-1,0,1,2,.nan,.infinity]
var clipping = PCM16Packetizer()
_ = clipping.append(extreme.withUnsafeBytes { Data($0) })
let clipped = clipping.finish()!
let samples = clipped.withUnsafeBytes { raw in (0..<7).map { Int16(littleEndian:raw.loadUnaligned(fromByteOffset:$0*2,as:Int16.self)) } }
expect(samples == [-32768,-32768,0,32767,32767,0,0],"PCM clipping and nonfinite protection")
let request = AssemblyAIProvider.request(key:"test-key-not-real")
expect(request.value(forHTTPHeaderField:"Authorization") == "test-key-not-real","raw header auth, no Bearer")
expect(request.url!.path == "/v3/ws" && !request.url!.absoluteString.contains("test-key"),"v3 endpoint, key never in URL")
expect(request.url!.absoluteString.contains("universal-3-5-pro"),"exact current model ID")
let cloudError = try JSONDecoder().decode(AssemblyAIMessage.self,from:Data(#"{"type":"Error","error_code":3008,"error":"Session expired"}"#.utf8))
expect(cloudError.error_code == 3008,"official error_code field")
var revisedPartial = Segmenter()
_ = revisedPartial.ingest("An old hypothesis",final:false,audio:1,utterance:0,now:0)
expect(revisedPartial.ingest("A revised hypothesis",final:false,audio:1,utterance:0,now:1).isEmpty,"same word timestamp cannot establish stability")
expect(revisedPartial.preview == "A revised hypothesis","latest cloud partial displayed even if word time unchanged")
let glossaryMatcher = GlossaryMatcher("AI = 人工智能\nmachine learning = 机器学习\nin = 错误匹配")
expect(glossaryMatcher.instructions(for:"Machine learning uses AI.").split(separator:"\n").count == 2,"compiled glossary matches case-insensitively with word boundaries")
expect(glossaryMatcher.instructions(for:"A thin model.").isEmpty,"glossary does not match inside a larger word")
let customGlossary = "machine learning = 自定义机器学习\ncourse-specific term = 课程专用译法"
let mergedGlossary = DefaultGlossary.merging(into:customGlossary)
expect(mergedGlossary.contains("course-specific term = 课程专用译法"),"glossary migration preserves custom entries")
expect(mergedGlossary.contains("FlashAttention = 闪速注意力") && mergedGlossary.contains("bounded concurrency = 有界并发"),"course glossary terms are appended")
expect(mergedGlossary.split(separator:"\n").filter { $0.lowercased().hasPrefix("machine learning =") }.count == 1,"glossary migration does not duplicate existing terms")
print("PASS: \(checks) regression checks")
