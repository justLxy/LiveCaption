import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var stream: SCStream?
    private var picker: SystemAudioPicker?
    private var tapped = false
    private let audioQueue = DispatchQueue(label: "caption.system-audio", qos: .userInitiated)
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    var onPCM: ((Data) -> Void)?
    var onError: ((String) -> Void)?
    func startMicrophone() async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw NSError(domain:"麦克风权限未开启，请在系统设置 → 隐私与安全性 → 麦克风中允许 LumaCaption。",code:1) }
        let node = engine.inputNode, format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NSError(domain:"没有可用的麦克风",code:2) }
        node.installTap(onBus: 0, bufferSize: 960, format: format) { [weak self] b,_ in self?.convert(b) }
        tapped = true; engine.prepare(); try engine.start()
    }
    @MainActor func startSystem() async throws {
        let selection = SystemAudioPicker(); picker = selection
        let filter = try await selection.choose()
        try Task.checkCancellation()
        let config = SCStreamConfiguration()
        config.capturesAudio = true; config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000; config.channelCount = 2
        config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3; config.showsCursor = false
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        stream = capture; try await capture.startCapture()
    }
    func stop() async {
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        engine.stop()
        if let s = stream { try? await s.stopCapture() }; stream = nil
        await MainActor.run { self.picker?.cancel(); self.picker = nil }
        lock.withLock { converter = nil; inputFormat = nil }
    }
    private func convert(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if inputFormat != buffer.format { inputFormat = buffer.format; converter = AVAudioConverter(from: buffer.format, to: output) }
        guard let converter else { return }
        let count = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 32)
        guard let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: count) else { return }
        var supplied = false; var error: NSError?
        converter.convert(to: target, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        if let error { onError?(error.localizedDescription); return }
        if let pointer = target.floatChannelData?[0], target.frameLength > 0 {
            onPCM?(Data(bytes: pointer, count: Int(target.frameLength) * 4))
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)) else { return }
        buffer.frameLength = buffer.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(sampleBuffer.numSamples), into: buffer.mutableAudioBufferList)
        if status == noErr { convert(buffer) } else { onError?("系统音频格式转换失败：\(status)") }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error.localizedDescription) }
}
