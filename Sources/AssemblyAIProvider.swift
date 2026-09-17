import Foundation

/// Raw v3 WebSocket; no uploaded recordings, batch endpoint or cloud translation.
final class AssemblyAIProvider: ASRProvider, @unchecked Sendable {
    var event: ((ASREvent) -> Void)?
    var failure: ((String) -> Void)?
    private let queue = DispatchQueue(label:"caption.assemblyai",qos:.userInitiated)
    private let lock = NSLock()
    private let decoder = JSONDecoder()
    private var accepting = false
    private var backlog = 0
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var packetizer = PCM16Packetizer()
    private var packets: [Data] = []
    private var packetIndex = 0
    private var sending = false
    private var finishing = false
    private var terminated = false
    private var ready = false
    private var terminationSent = false
    private var connectTimeout: DispatchWorkItem?
    private var drainTimeout: DispatchWorkItem?
    private let apiKey: String

    init(apiKey: String) { self.apiKey = apiKey }

    static func request(key: String) -> URLRequest {
        var url = URLComponents(string:"wss://streaming.assemblyai.com/v3/ws")!
        url.queryItems = [
            URLQueryItem(name:"speech_model",value:"universal-3-5-pro"),
            URLQueryItem(name:"sample_rate",value:"16000"),
            URLQueryItem(name:"encoding",value:"pcm_s16le"),
            URLQueryItem(name:"language_codes",value:"[\"en\"]"),
            URLQueryItem(name:"mode",value:"balanced"),
            URLQueryItem(name:"include_partial_turns",value:"true"),
            URLQueryItem(name:"continuous_partials",value:"true")
        ]
        var request = URLRequest(url:url.url!); request.timeoutInterval = 20
        request.setValue(key,forHTTPHeaderField:"Authorization")
        return request
    }
    func start() throws {
        queue.async { [self] in
            guard !terminated else { return }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 24 * 60 * 60
            let session = URLSession(configuration:config)
            self.session = session
            let socket = session.webSocketTask(with:Self.request(key:apiKey))
            self.socket = socket
            let timeout = DispatchWorkItem { [weak self] in self?.fail("AssemblyAI 连接超时，请检查网络。") }
            connectTimeout = timeout; queue.asyncAfter(deadline:.now()+20,execute:timeout)
            socket.resume(); receive()
        }
    }
    func send(_ data: Data) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        if backlog + data.count > 128_000 {
            accepting = false; lock.unlock()
            queue.async { [weak self] in self?.fail("AssemblyAI 网络发送积压超过 2 秒，已停止捕获；已有字幕已保存。") }
            return
        }
        backlog += data.count
        queue.async { [self] in
            guard !terminated else { return }
            packets += packetizer.append(data)
            pump()
        }
        lock.unlock()
    }
    func finish() {
        lock.lock(); accepting = false
        queue.async { [self] in
            guard !terminated, !finishing else { return }
            finishing = true
            if let tail = packetizer.finish() { packets.append(tail) }
            let timeout = DispatchWorkItem { [weak self] in self?.fail("AssemblyAI 结束会话超时；已保存收到的字幕。") }
            drainTimeout = timeout; queue.asyncAfter(deadline:.now()+8,execute:timeout)
            pump()
        }
        lock.unlock()
    }
    func terminate() {
        lock.lock(); accepting = false; lock.unlock()
        queue.async { [self] in close() }
    }
    private func pump() {
        guard !terminated, ready, !sending, let socket else { return }
        let message: URLSessionWebSocketTask.Message
        if packetIndex < packets.count {
            message = .data(packets[packetIndex]); packetIndex += 1
            if packetIndex == packets.count { packets.removeAll(keepingCapacity:true); packetIndex = 0 }
        }
        else if finishing && !terminationSent {
            terminationSent = true; message = .string("{\"type\":\"Terminate\"}")
        } else { return }
        sending = true
        socket.send(message) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard !self.terminated else { return }
                self.sending = false
                if let error { self.networkFailed(error); return }
                if case .data(let data) = message {
                    self.lock.lock(); self.backlog = max(0,self.backlog-data.count*2); self.lock.unlock()
                }
                self.pump()
            }
        }
    }
    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.terminated else { return }
                switch result {
                case .failure(let error): self.networkFailed(error)
                case .success(let message):
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: self.fail("AssemblyAI 返回了不支持的消息。"); return
                    }
                    do { self.handle(try self.decoder.decode(AssemblyAIMessage.self,from:data)) }
                    catch { self.fail("AssemblyAI 消息格式不符合当前 v3 协议。"); return }
                    if !self.terminated { self.receive() }
                }
            }
        }
    }
    private func handle(_ message: AssemblyAIMessage) {
        switch message.type {
        case "Begin":
            guard message.configuration?.model == "universal-3-5-pro" else {
                fail("AssemblyAI 未确认 Universal-3.5 Pro 模型，已停止连接。"); return
            }
            connectTimeout?.cancel(); ready = true
            lock.lock(); accepting = !finishing; lock.unlock()
            event?(ASREvent(type:"ready",text:nil,audio:nil,utterance:nil))
            pump()
        case "Turn":
            guard let turn = message.turn else { fail("AssemblyAI Turn 消息缺少必要字段。"); return }
            event?(turn)
        case "Termination":
            if !finishing { failure?("AssemblyAI 会话已由服务器结束，请重新开始字幕。") }
            close()
        case "Error": fail("AssemblyAI 服务返回错误（代码 \(message.error_code.map(String.init) ?? "未知")），请检查 API key、账户额度和网络。")
        default: break // SpeechStarted/Heartbeat are not hypothesis stability evidence.
        }
    }
    private func networkFailed(_ error: Error) {
        // Never log requests, authorization headers, raw server bodies or URL userInfo.
        let status = (socket?.response as? HTTPURLResponse)?.statusCode
        let closeCode = socket?.closeCode.rawValue ?? 0
        let detail = status.map { "HTTP \($0)" } ?? "网络 \((error as NSError).code)，关闭码 \(closeCode)"
        fail("AssemblyAI 连接失败（\(detail)）。请检查 API key、账户额度和网络。")
    }
    private func fail(_ message: String) {
        guard !terminated else { return }
        failure?(message); close()
    }
    private func close() {
        guard !terminated else { return }
        terminated = true
        lock.lock(); accepting = false; backlog = 0; lock.unlock()
        connectTimeout?.cancel(); drainTimeout?.cancel()
        socket?.cancel(with:.normalClosure,reason:nil)
        session?.invalidateAndCancel(); socket = nil; session = nil
        packets.removeAll(keepingCapacity:false); packetIndex = 0
        event?(ASREvent(type:"drained",text:nil,audio:nil,utterance:nil))
    }
}
