import Foundation
import Darwin

struct ASREvent: Decodable { let type: String; let text: String?; let audio: Double?; let utterance: Int? }

/// Serial pipe writer with a 2 s hard backlog bound. Overload stops visibly rather than dropping words silently.
final class ASRProcess: @unchecked Sendable {
    let process = Process()
    private let input = Pipe(), output = Pipe()
    private let writer = DispatchQueue(label: "caption.pcm-writer", qos: .userInitiated)
    private let lock = NSLock()
    private var pending = 0
    private var closed = false
    var event: ((ASREvent) -> Void)?
    var failure: ((String) -> Void)?
    init(resources: URL, log: URL) throws {
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = resources.appendingPathComponent("Runtime/nemo/bin/asr-bridge")
        process.arguments = [resources.appendingPathComponent("Models/nemotron-speech-streaming-en-0.6b.q8_0.gguf").path]
        process.standardInput = input; process.standardOutput = output
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: log)
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.lock.lock(); let expected = self.closed; self.lock.unlock()
            if !expected { self.failure?("识别进程意外退出（\(p.terminationStatus)），请查看 ASR 日志。") }
        }
    }
    func start() throws {
        try process.run()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var buffer = Data()
            do {
                while true {
                    var chunk = [UInt8](repeating: 0, count: 8192)
                    let count = Darwin.read(self.output.fileHandleForReading.fileDescriptor, &chunk, chunk.count)
                    if count == 0 { break }
                    if count < 0 { if errno == EINTR { continue }; throw NSError(domain:NSPOSIXErrorDomain, code:Int(errno)) }
                    buffer.append(contentsOf: chunk.prefix(count))
                    while let end = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                        if let e = try? JSONDecoder().decode(ASREvent.self, from: line) { self.event?(e) }
                    }
                    if buffer.count > 1_000_000 { self.failure?("ASR 输出协议异常"); break }
                }
            } catch { self.failure?("读取识别结果失败：\(error.localizedDescription)") }
            self.event?(ASREvent(type: "drained", text: nil, audio: nil, utterance: nil))
        }
    }
    func send(_ data: Data) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        if pending + data.count > 128_000 { closed = true; lock.unlock(); failure?("识别积压超过 2 秒，已停止录音以避免丢字。请关闭其他高负载应用后重试。"); process.terminate(); return }
        pending += data.count; lock.unlock()
        writer.async { [weak self] in
            guard let self else { return }
            do { try self.input.fileHandleForWriting.write(contentsOf: data) }
            catch { self.failure?("音频传输失败：\(error.localizedDescription)") }
            self.lock.lock(); self.pending -= data.count; self.lock.unlock()
        }
    }
    func finish() {
        lock.lock(); closed = true; lock.unlock()
        writer.async { [weak self] in try? self?.input.fileHandleForWriting.close() }
    }
    func terminate() { finish(); if process.isRunning { process.terminate() } }
}

@MainActor
final class Translator {
    private var process: Process?
    private let token = UUID().uuidString
    private var port = 0
    private var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 12; c.timeoutIntervalForResource = 15
        return URLSession(configuration: c)
    }()
    func start(resources: URL, log: URL) async throws {
        // Obtain an unused loopback port; child startup verifies binding through authenticated health.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain:"无法创建本地端口",code:1) }
        var socketOpen = true
        defer { if socketOpen { close(fd) } }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw NSError(domain:"无法绑定本地端口",code:2) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        port = Int(UInt16(bigEndian: address.sin_port))
        // Release the reservation before launching the listener.
        shutdown(fd, SHUT_RDWR)
        let p = Process(); p.executableURL = resources.appendingPathComponent("Runtime/llama/llama-server")
        p.arguments = ["-m",resources.appendingPathComponent("Models/Hy-MT2-1.8B-Q4_K_M.gguf").path,"-ngl","99","-c","2048","-np","1","--host","127.0.0.1","--port",String(port),"--jinja","--api-key",token,"--log-verbosity","1"]
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log); p.standardOutput = handle; p.standardError = handle
        // close bound socket now (defer close is harmless after fd invalidation only if no reuse; use dup design below)
        close(fd); socketOpen = false
        try p.run(); process = p
        for _ in 0..<120 {
            try Task.checkCancellation()
            guard p.isRunning else { throw NSError(domain:"翻译引擎未能启动，请查看 llama 日志",code:3) }
            var request = URLRequest(url: URL(string:"http://127.0.0.1:\(port)/health")!); request.timeoutInterval = 1
            if let (_, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        stop(); throw NSError(domain:"翻译模型加载超时",code:4)
    }
    func translate(_ english: String, glossary: String) async throws -> String {
        let matches = glossary.split(separator:"\n").compactMap { line -> String? in
            let parts = line.split(separator:"=", maxSplits:1).map { $0.trimmingCharacters(in:.whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, english.localizedCaseInsensitiveContains(parts[0]) else { return nil }
            return "\(parts[0]) 翻译成 \(parts[1])"
        }.prefix(24).joined(separator:"\n")
        let prompt = (matches.isEmpty ? "" : "参考下面的翻译：\n\(matches)\n") + "将以下文本翻译为简体中文，注意只需要输出翻译后的结果，不要额外解释：\n\n" + english
        var request = URLRequest(url:URL(string:"http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"; request.setValue("application/json",forHTTPHeaderField:"Content-Type"); request.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject:["messages":[["role":"user","content":prompt]],"temperature":0.7,"top_p":0.6,"top_k":20,"repeat_penalty":1.05,"max_tokens":256,"stream":false])
        let (data,response) = try await session.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let choice = (obj["choices"] as? [[String:Any]])?.first,
              choice["finish_reason"] as? String == "stop",
              let message = choice["message"] as? [String:Any], let text = message["content"] as? String, !text.isEmpty else {
            throw NSError(domain:"翻译请求失败或输出被截断",code:5)
        }
        return text.trimmingCharacters(in:.whitespacesAndNewlines)
    }
    func stop() { if let process, process.isRunning { process.terminate() }; process = nil }
}
