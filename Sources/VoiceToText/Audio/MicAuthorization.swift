import AVFoundation

/// The TCC lookup behind `AVCaptureDevice.authorizationStatus` is an XPC round
/// trip (~25-40ms, more under load). Asked at the top of `run()` it overlaps the
/// CoreAudio first touch that device resolution pays anyway, instead of adding
/// to it.
enum MicAuthorization {
    private static let done = DispatchSemaphore(value: 0)
    private static var fetched: AVAuthorizationStatus?

    static func prefetch() {
        DispatchQueue.global(qos: .userInteractive).async {
            fetched = AVCaptureDevice.authorizationStatus(for: .audio)
            done.signal()
        }
    }

    /// Blocks until the prefetch lands. Call `prefetch()` first.
    static var status: AVAuthorizationStatus {
        done.wait()
        defer { done.signal() }
        guard let status = fetched else {
            fatalError("MicAuthorization.status read before prefetch() completed")
        }
        return status
    }
}
