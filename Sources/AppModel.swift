import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppModel: ObservableObject {
    @Published var displayMode = UserDefaults.standard.string(forKey:"displayMode") ?? "history" { didSet { save("displayMode",displayMode); windowChange?() } }
    @Published var historyLimit = UserDefaults.standard.object(forKey:"historyLimit") as? Int ?? 300 { didSet { save("historyLimit",historyLimit); history.trim(to:historyLimit) } }
    @Published var followLatest = true
    @Published var history = CaptionHistory()
    @Published var hovering = false
    @Published var status = "就绪 · 全部在本机运行"
    @Published var running = false
    @Published var busy = false
    @Published var partial = ""
    @Published var english = ""
    @Published var chinese = "点击开始，听见英文，看见中文。"
    @Published var latency = ""
    @Published var source = UserDefaults.standard.string(forKey:"source") ?? "microphone" { didSet { save("source",source) } }
    @Published var opacity = UserDefaults.standard.object(forKey:"opacity") as? Double ?? 0.78 { didSet { save("opacity",opacity) } }
    @Published var englishFontSize = UserDefaults.standard.object(forKey:"englishFontSize") as? Double ?? max(8, (UserDefaults.standard.object(forKey:"fontSize") as? Double ?? 28) * 0.68) { didSet { save("englishFontSize",englishFontSize) } }
    @Published var switchingSource = false
    @Published var fontSize = UserDefaults.standard.object(forKey:"fontSize") as? Double ?? 28 { didSet { save("fontSize",fontSize) } }
    @Published var showEnglish = UserDefaults.standard.object(forKey:"showEnglish") as? Bool ?? true { didSet { save("showEnglish",showEnglish) } }
    @Published var showChinese = UserDefaults.standard.object(forKey:"showChinese") as? Bool ?? true { didSet { save("showChinese",showChinese) } }
    @Published var clickThrough = false { didSet { windowChange?() } }
    @Published var onTop = true { didSet { windowChange?() } }
    @Published var glossary = UserDefaults.standard.string(forKey:"glossary") ?? "derivative = 导数\ngradient = 梯度\nlinear algebra = 线性代数\nmachine learning = 机器学习" { didSet { save("glossary",glossary) } }
    var windowChange: (() -> Void)?
    var showSettings: (() -> Void)?
    var hideWindow: (() -> Void)?
    var quitApp: (() -> Void)?
    let support: URL
    let transcripts: URL
    private let resources = Bundle.main.resourceURL!
    private var capture: AudioCapture?
    private var asr: ASRProcess?
    private let translator = Translator()
    private var journal: TranscriptJournal?
    private var segmenter = Segmenter()
    private var liveHypothesis = ""
    private var pending: [CaptionSegment] = []
    private var translationTask: Task<Void,Never>?
    private var startupTask: Task<Void,Never>?
    private var timer: Timer?
    private var sampleTimer: Timer?
    private var keepAwake: NSObjectProtocol?
    private var generation = UUID()
    private var stopping = false
    private var lastAudio = 0.0
    private var captureStarted: Date?
    private var firstPartial = true
    init() {
        support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("LumaCaption")
        transcripts = support.appendingPathComponent("Transcripts")
        try? FileManager.default.createDirectory(at:transcripts,withIntermediateDirectories:true)
    }
    private func save(_ key:String,_ value:Any) { UserDefaults.standard.set(value,forKey:key) }
    func toggle() { guard !switchingSource else { return }; if running || busy { Task { await stop() } } else { start() } }
    func selectSource(_ next:String) {
        guard ["system","microphone"].contains(next), next != source, !busy, !switchingSource, !stopping else { return }
        guard running else { source = next; return }
        switchingSource = true
        Task {
            await stop()
            source = next
            switchingSource = false
            start(preserveHistory:true)
        }
    }
    func start(sampleSeconds: Double? = nil, preserveHistory:Bool = false) {
        guard !busy, !running else { return }
        busy = true; stopping = false; generation = UUID(); let sessionID = generation
        firstPartial = true; lastAudio = 0; captureStarted = nil
        if !preserveHistory { history = CaptionHistory(); followLatest = true; english = ""; chinese = "" }
        partial = ""; latency = ""; pending = []; segmenter = Segmenter(); liveHypothesis = ""
        startupTask = Task { [self] in
            do {
                journal = try TranscriptJournal(root:transcripts)
                try journal?.record(["type":"session_start","source":sampleSeconds == nil ? source : "test_fixture","sample_seconds":sampleSeconds ?? 0])
                status = "正在加载 Hy-MT2 · Metal"
                try await translator.start(resources:resources,log:journal!.directory.appendingPathComponent("llama.log"))
                try Task.checkCancellation()
                guard generation == sessionID else { return }
                status = "正在加载 Nemotron English · Metal"
                let bridge = try ASRProcess(resources:resources,log:journal!.directory.appendingPathComponent("asr.log"))
                bridge.event = { [weak self] event in Task { @MainActor in
                    guard let self, self.generation == sessionID else { return }
                    self.receive(event)
                } }
                bridge.failure = { [weak self] message in Task { @MainActor in
                    guard let self, self.generation == sessionID, !self.stopping else { return }; self.fail(message)
                } }
                asr = bridge; try bridge.start()
                for _ in 0..<180 {
                    if running { break }; try await Task.sleep(nanoseconds:500_000_000); try Task.checkCancellation()
                }
                guard running else { throw NSError(domain:"ASR 模型加载超时",code:1) }
                captureStarted = Date()
                if let duration = sampleSeconds { try startSample(seconds:duration) }
                else {
                    let audio = AudioCapture(); capture = audio
                    audio.onPCM = { [weak bridge] data in bridge?.send(data) }
                    audio.onError = { [weak self] message in Task { @MainActor in
                        guard let self, self.generation == sessionID, !self.stopping else { return }; self.fail(message)
                    } }
                    if source == "system" {
                        status = "请在系统选择器中选择屏幕并确认共享"
                        try await audio.startSystem()
                    } else { try await audio.startMicrophone() }
                    record(["type":"capture_started","source":source])
                }
                try Task.checkCancellation()
                busy = false; status = sampleSeconds == nil ? "正在聆听 · \(source == "system" ? "系统音频" : "麦克风")" : "真实模型测试 · 示例音频"
                keepAwake = ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.idleSystemSleepDisabled],reason:"实时本地字幕")
                timer = Timer.scheduledTimer(withTimeInterval:0.15,repeats:true) { [weak self] _ in Task { @MainActor in self?.checkStable() } }
            } catch is CancellationError { await capture?.stop(); capture = nil; asr?.terminate(); translator.stop() }
            catch { if generation == sessionID { fail(error.localizedDescription) } }
        }
    }
    private func receive(_ e:ASREvent) {
        if e.type == "ready" { running = true; return }
        guard let text = e.text else { return }; lastAudio = e.audio ?? lastAudio
        if e.type == "partial" {
            if firstPartial && !text.isEmpty {
                record(["type":"asr_first_partial","text":text,"audio_seconds":lastAudio,"capture_elapsed":captureStarted.map { Date().timeIntervalSince($0) } ?? 0]); firstPartial = false
            }
            liveHypothesis = text; checkStable()
        }
        if e.type == "final" {
            record(["type":"asr_final","text":text,"audio_seconds":lastAudio,"capture_elapsed":captureStarted.map { Date().timeIntervalSince($0) } ?? 0])
            firstPartial = true
            for text in segmenter.ingest(text,final:true) { enqueue(text) }
            liveHypothesis = ""; partial = segmenter.preview("")
        }
    }
    private func checkStable() {
        if liveHypothesis.isEmpty {
            for text in segmenter.flushCarry() { enqueue(text) }
        } else {
            for text in segmenter.ingest(liveHypothesis,final:false) { enqueue(text) }
        }
        partial = segmenter.preview(liveHypothesis)
    }

    private func enqueue(_ text:String) {
        guard !text.isEmpty else { return }
        let segment = CaptionSegment(english:text)
        record(["type":"english_segment","id":segment.id.uuidString,"text":text,"audio_seconds":lastAudio])
        history.append(id:segment.id,english:text,limit:historyLimit)
        pending.append(segment)
        if pending.count >= 12 { fail("翻译积压过多，已停止捕获；英文已保存在 transcript。请关闭其他高负载应用后重试。"); return }
        if pending.count > 2 { status = "翻译积压 \(pending.count) 段" }
        if translationTask == nil { translateQueue() }
    }
    private func translateQueue() {
        let sessionID = generation
        translationTask = Task {
            while !pending.isEmpty, !Task.isCancelled, generation == sessionID {
                let segment = pending.removeFirst()
                do {
                    let translated = try await translator.translate(segment.english,glossary:glossary)
                    guard generation == sessionID, !Task.isCancelled else { break }
                    let elapsed = Date().timeIntervalSince(segment.created)
                    try journal?.translated(segment,chinese:translated,latency:elapsed)
                    // Publish one complete bilingual pair atomically, never per Chinese token.
                    history.translate(id:segment.id,chinese:translated)
                    english = segment.english; chinese = translated; latency = String(format:"翻译 %.2f s",elapsed)
                } catch {
                    if Task.isCancelled { break }
                    record(["type":"translation_error","id":segment.id.uuidString,"english":segment.english,"error":error.localizedDescription])
                    history.translate(id:segment.id,chinese:"翻译暂不可用 · 英文已保存")
                    english = segment.english; chinese = "翻译暂不可用 · 英文已保存"; status = error.localizedDescription
                }
            }
            if generation == sessionID { translationTask = nil }
        }
    }
    func stop() async {
        guard !stopping else { return }; stopping = true
        startupTask?.cancel(); sampleTimer?.invalidate(); sampleTimer = nil
        timer?.invalidate(); timer = nil
        await capture?.stop(); capture = nil
        asr?.finish()
        // Let EOF flush the true streaming recognizer and drain its final translation.
        for _ in 0..<100 { if asr?.process.isRunning != true { break }; try? await Task.sleep(nanoseconds:100_000_000) }
        asr?.terminate(); asr = nil
        for text in segmenter.flushCarry(force:true) { enqueue(text) }
        liveHypothesis = ""; partial = ""
        for _ in 0..<150 { if translationTask == nil { break }; try? await Task.sleep(nanoseconds:100_000_000) }
        if translationTask != nil {
            record(["type":"translation_drain_timeout","remaining":pending.map(\.english)])
            translationTask?.cancel(); translationTask = nil
        }
        translator.stop(); pending = []
        record(["type":"session_end","audio_seconds":lastAudio])
        if let keepAwake { ProcessInfo.processInfo.endActivity(keepAwake) }; keepAwake = nil
        busy = false; running = false; stopping = false; status = "已停止 · 双语记录已保存"
        if CommandLine.arguments.contains("--headless") { NSApp.terminate(nil) }
    }
    private func record(_ row:[String:Any]) {
        do { try journal?.record(row) } catch { status = "记录保存失败：\(error.localizedDescription)"; if !stopping { Task { await self.stop() } } }
    }
    private func fail(_ message:String) {
        record(["type":"error","message":message]); status = message
        Task { await stop(); status = message }
    }
    func shutdown() { sampleTimer?.invalidate(); timer?.invalidate(); startupTask?.cancel(); translationTask?.cancel(); asr?.terminate(); translator.stop() }
    func openTranscripts() { NSWorkspace.shared.open(transcripts) }
    private func startSample(seconds:Double) throws {
        let data = try Data(contentsOf:resources.appendingPathComponent("sample.f32"))
        guard !data.isEmpty else { throw NSError(domain:"测试音频缺失",code:2) }
        let began = Date(); var cursor = 0; var sent = 0
        sampleTimer = Timer.scheduledTimer(withTimeInterval:0.02,repeats:true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(began)
                if elapsed >= seconds { self.sampleTimer?.invalidate(); self.sampleTimer = nil; Task { await self.stop() }; return }
                let target = Int(elapsed * 16000) / 320
                // Catch up moderate scheduling jitter; backpressure protection remains active.
                for _ in 0..<max(0,min(10,target-sent)) {
                    var frame = Data(); let count = min(1280,data.count-cursor)
                    frame.append(data[cursor..<cursor+count]);cursor += count
                    if cursor == data.count { cursor = 0 }
                    if frame.count < 1280 { frame.append(data[0..<1280-frame.count]);cursor = 1280-count }
                    self.asr?.send(frame); sent += 1
                }
            }
        }
    }
}
