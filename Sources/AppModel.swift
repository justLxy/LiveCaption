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
    @Published var status = "就绪"
    @Published var running = false
    @Published var busy = false
    @Published var partial = ""
    @Published var english = ""
    @Published var chinese = "点击开始，听见英文，看见中文。"
    @Published var latency = ""
    @Published var provider = ASRProviderKind.initialSelection { didSet { save("asrProvider",provider.rawValue) } }
    @Published private(set) var hasAssemblyAIKey = KeychainCredentialStore.hasAssemblyAIKey
    @Published var source = UserDefaults.standard.string(forKey:"source") ?? "microphone" { didSet { save("source",source) } }
    @Published var opacity = UserDefaults.standard.object(forKey:"opacity") as? Double ?? 0.78 { didSet { save("opacity",opacity) } }
    @Published var textTone = UserDefaults.standard.string(forKey:"textTone") ?? ((UserDefaults.standard.object(forKey:"opacity") as? Double ?? 0.78) == 0 ? "dark" : "light") { didSet { save("textTone",textTone) } }
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
    private var asr: (any ASRProvider)?
    private let translator = Translator()
    private var journal: TranscriptJournal?
    private var segmenter = Segmenter()
    private var acceptASREvents = false
    private var asrDrained = false
    private var versions: [UUID: Int] = [:]
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
        let applicationSupport = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        let newSupport = applicationSupport.appendingPathComponent("XueScribe")
        let legacySupport = applicationSupport.appendingPathComponent("LumaCaption")
        if !FileManager.default.fileExists(atPath:newSupport.path),
           FileManager.default.fileExists(atPath:legacySupport.path) {
            try? FileManager.default.copyItem(at:legacySupport,to:newSupport)
        }
        support = newSupport
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
    func selectProvider(_ next: ASRProviderKind) {
        guard next != provider, !busy, !switchingSource, !stopping else { return }
        if next == .assemblyAI, running, !hasAssemblyAIKey {
            status = "请先在设置中保存你的 AssemblyAI API Key"
            return
        }
        guard running else { provider = next; return }
        switchingSource = true
        Task {
            await stop()
            provider = next
            switchingSource = false
            start(preserveHistory:true)
        }
    }
    func start(sampleSeconds: Double? = nil, preserveHistory:Bool = false) {
        guard !busy, !running else { return }
        let assemblyAIKey: String?
        if provider == .assemblyAI {
            assemblyAIKey = KeychainCredentialStore.assemblyAIKey()
            guard assemblyAIKey != nil else {
                hasAssemblyAIKey = false
                status = "请先在设置中保存你的 AssemblyAI API Key"
                return
            }
        } else { assemblyAIKey = nil }
        busy = true; stopping = false; generation = UUID(); let sessionID = generation
        firstPartial = true; lastAudio = 0; captureStarted = nil
        if !preserveHistory { history = CaptionHistory(); followLatest = true; english = ""; chinese = "" }
        partial = ""; latency = ""; pending = []; segmenter = Segmenter(); acceptASREvents = true; asrDrained = false; versions = [:]
        startupTask = Task { [self] in
            do {
                journal = try TranscriptJournal(root:transcripts)
                try journal?.record(["type":"session_start","source":sampleSeconds == nil ? source : "test_fixture","sample_seconds":sampleSeconds ?? 0,"asr_provider":provider.rawValue])
                status = "正在加载 Hy-MT2 · Metal"
                try await translator.start(resources:resources,log:journal!.directory.appendingPathComponent("llama.log"))
                try Task.checkCancellation()
                guard generation == sessionID else { return }
                status = provider == .local ? "正在加载 Nemotron English · Metal" : "正在连接 AssemblyAI · 云端 ASR"
                let bridge: any ASRProvider
                switch provider {
                case .local: bridge = try ASRProcess(resources:resources,log:journal!.directory.appendingPathComponent("asr.log"))
                case .assemblyAI: bridge = AssemblyAIProvider(apiKey:assemblyAIKey!)
                }
                bridge.event = { [weak self] event in DispatchQueue.main.async {
                    guard let self, self.generation == sessionID else { return }
                    self.receive(event)
                } }
                bridge.failure = { [weak self] message in DispatchQueue.main.async {
                    guard let self, self.generation == sessionID else { return }
                    if self.stopping { self.record(["type":"asr_drain_error","message":message]) }
                    else { self.fail(message) }
                } }
                asr = bridge; try bridge.start()
                for _ in 0..<180 {
                    if running { break }; try await Task.sleep(nanoseconds:500_000_000); try Task.checkCancellation()
                }
                guard running else { throw NSError(domain:"ASR 启动超时",code:1) }
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
    func saveAssemblyAIKey(_ key:String) throws {
        try KeychainCredentialStore.saveAssemblyAIKey(key)
        hasAssemblyAIKey = true
        status = "AssemblyAI API Key 已保存到 macOS 钥匙串"
    }
    func deleteAssemblyAIKey() throws {
        try KeychainCredentialStore.deleteAssemblyAIKey()
        hasAssemblyAIKey = false
        if provider == .assemblyAI { status = "AssemblyAI API Key 已删除；本地模式仍可直接使用" }
    }
    private func receive(_ e:ASREvent) {
        if e.type == "drained" { asrDrained = true; return }
        guard acceptASREvents else { return }
        if e.type == "ready" { running = true; return }
        guard let text = e.text else { return }; lastAudio = e.audio ?? lastAudio
        if e.type == "partial" {
            if firstPartial && !text.isEmpty {
                record(["type":"asr_first_partial","text":text,"audio_seconds":lastAudio,"capture_elapsed":captureStarted.map { Date().timeIntervalSince($0) } ?? 0]); firstPartial = false
            }
            apply(segmenter.ingest(text, final:false, audio:lastAudio, utterance:e.utterance ?? 0))
        }
        if e.type == "final" {
            record(["type":"asr_final","text":text,"audio_seconds":lastAudio,"capture_elapsed":captureStarted.map { Date().timeIntervalSince($0) } ?? 0])
            firstPartial = true
            apply(segmenter.ingest(text, final:true, audio:lastAudio, utterance:e.utterance ?? 0))
        }
    }
    private func checkStable() {
        apply(segmenter.tick())
    }

    private func apply(_ changes: [SegmentChange]) {
        for change in changes {
            switch change {
            case .remove(let id):
                versions.removeValue(forKey:id)
                pending.removeAll { $0.id == id }
                history.remove(id)
                if displayedID == id { english = ""; chinese = ""; displayedID = nil }
                record(["type":"segment_removed", "id":id.uuidString])
                do { try journal?.remove(id) } catch { fail(error.localizedDescription) }
            case .upsert(let segment):
                versions[segment.id] = segment.revision
                pending.removeAll { $0.id == segment.id }
                history.upsert(segment, limit:historyLimit)
                if displayedID == segment.id { english = segment.english; chinese = "" }
                record(["type":"english_segment", "id":segment.id.uuidString,
                        "revision":segment.revision, "text":segment.english, "audio_seconds":lastAudio])
                do { try journal?.upsert(segment) } catch { fail(error.localizedDescription) }
                pending.append(segment)
            }
        }
        partial = segmenter.preview
        if pending.count >= 12 { fail("翻译积压过多，已停止捕获；英文已保存在 transcript。请关闭其他高负载应用后重试。"); return }
        if pending.count > 2 { status = "翻译积压 \(pending.count) 段" }
        if translationTask == nil && !pending.isEmpty { translateQueue() }
    }
    private var displayedID: UUID?
    private func translateQueue() {
        let sessionID = generation
        translationTask = Task {
            while !pending.isEmpty, !Task.isCancelled, generation == sessionID {
                let segment = pending.removeFirst()
                do {
                    let translated = try await translator.translate(segment.english,glossary:glossary)
                    guard generation == sessionID, !Task.isCancelled else { break }
                    guard versions[segment.id] == segment.revision else { continue }
                    let elapsed = Date().timeIntervalSince(segment.created)
                    try journal?.translated(segment,chinese:translated,latency:elapsed)
                    // Publish one complete bilingual pair atomically, never per Chinese token.
                    history.translate(id:segment.id,chinese:translated)
                    displayedID = segment.id
                    english = segment.english; chinese = translated; latency = String(format:"翻译 %.2f s",elapsed)
                } catch {
                    if Task.isCancelled { break }
                    guard generation == sessionID, versions[segment.id] == segment.revision else { continue }
                    record(["type":"translation_error","id":segment.id.uuidString,"english":segment.english,"error":error.localizedDescription])
                    history.translate(id:segment.id,chinese:"翻译暂不可用 · 英文已保存")
                    displayedID = segment.id
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
        for _ in 0..<100 { if asr == nil || asrDrained { break }; try? await Task.sleep(nanoseconds:100_000_000) }
        acceptASREvents = false
        asr?.terminate(); asr = nil
        apply(segmenter.tick(force:true))
        partial = ""
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
