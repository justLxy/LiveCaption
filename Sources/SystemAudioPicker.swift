import AppKit
import ScreenCaptureKit

/// User-selected, session-scoped capture authorization. Never enumerates content first.
@MainActor
final class SystemAudioPicker: NSObject, SCContentSharingPickerObserver {
    private var continuation: CheckedContinuation<SCContentFilter,Error>?
    private var observing = false
    func choose() async throws -> SCContentFilter {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing:CancellationError()); return }
                self.continuation = continuation
                let picker = SCContentSharingPicker.shared
                var configuration = SCContentSharingPickerConfiguration()
                configuration.allowedPickerModes = [.singleDisplay]
                configuration.allowsChangingSelectedContent = false
                picker.defaultConfiguration = configuration
                picker.add(self); observing = true
                picker.isActive = true
                NSApp.activate(ignoringOtherApps:true)
                picker.present(using:.display)
            }
        }, onCancel: { Task { @MainActor in self.cancel() } })
    }
    func cancel() {
        let pending = continuation; continuation = nil
        if observing { SCContentSharingPicker.shared.remove(self); observing = false }
        SCContentSharingPicker.shared.isActive = false
        pending?.resume(throwing:CancellationError())
    }
    private func resolve(_ result:Result<SCContentFilter,Error>) {
        let pending = continuation; continuation = nil
        pending?.resume(with:result)
    }
    nonisolated func contentSharingPicker(_ picker:SCContentSharingPicker, didCancelFor stream:SCStream?) {
        Task { @MainActor in self.resolve(.failure(NSError(domain:"LumaCaption",code:1,userInfo:[NSLocalizedDescriptionKey:"已取消系统音频共享。点击开始可重新选择屏幕。"]))) }
    }
    nonisolated func contentSharingPicker(_ picker:SCContentSharingPicker, didUpdateWith filter:SCContentFilter, for stream:SCStream?) {
        Task { @MainActor in self.resolve(.success(filter)) }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error:Error) {
        Task { @MainActor in self.resolve(.failure(error)) }
    }
}
