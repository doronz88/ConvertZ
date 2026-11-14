import Foundation

/// Runs one ffmpeg process, reporting progress and the final outcome on the main queue.
public final class ConversionRunner {
    public struct Outcome {
        public let exitCode: Int32
        public let cancelled: Bool
        public let log: String
        public var succeeded: Bool { exitCode == 0 && !cancelled }
    }

    private let process = Process()
    private let lock = NSLock()
    private var log = Data()
    private var parser = ProgressParser()
    private var cancelled = false
    private static let maxLog = 400_000

    public init(ffmpeg: URL, arguments: [String]) {
        process.executableURL = ffmpeg
        process.arguments = arguments
    }

    /// `onProgress` receives the encoded position in seconds.
    public func start(onProgress: @escaping (Double) -> Void, completion: @escaping (Outcome) -> Void) {
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            let changed = self.parser.feed(data)
            let seconds = self.parser.seconds
            self.lock.unlock()
            if changed { DispatchQueue.main.async { onProgress(seconds) } }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.appendLog(data)
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            if let rest = try? err.fileHandleForReading.readToEnd() { self.appendLog(rest) }
            self.lock.lock()
            let outcome = Outcome(exitCode: process.terminationStatus, cancelled: self.cancelled,
                                  log: String(decoding: self.log, as: UTF8.self))
            self.lock.unlock()
            DispatchQueue.main.async { completion(outcome) }
        }
        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let outcome = Outcome(exitCode: -1, cancelled: false, log: "Could not start ffmpeg: \(error.localizedDescription)")
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    private func appendLog(_ data: Data) {
        lock.lock()
        log.append(data)
        if log.count > Self.maxLog { log.removeFirst(log.count - Self.maxLog) }
        lock.unlock()
    }

    /// Asks ffmpeg to stop, and kills it if it has not exited shortly after.
    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        guard process.isRunning else { return }
        process.terminate()
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Stops ffmpeg and waits for it to exit. For use while the app is quitting.
    public func cancelAndWait() {
        cancel()
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
