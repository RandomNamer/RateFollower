import Foundation

/// The format Apple Music reports for the track it just started.
struct TrackFormat: Equatable {
    var rate: Double
    var bits: UInt32?  // nil when only the sample rate is known
}

/// Push-based detection: one long-lived `log stream` child with a tight predicate.
/// No OSLogStore queries, no polling, no archive reads. The reader thread sits
/// blocked in read() until Music logs a new track format.
final class FormatMonitor {
    /// Called on the monitor's reader thread. `authoritative` is true for the
    /// FigLog report (rate + bit depth); false for the AudioQueue line (rate only).
    var onFormat: ((TrackFormat, _ authoritative: Bool) -> Void)?

    private var child: Process?
    private let lock = NSLock()

    private static let predicate = """
    process == "Music" AND subsystem == "com.apple.coremedia" AND \
    (eventMessage CONTAINS "ReportAudioPlaybackThroughFigLog" OR eventMessage CONTAINS "Creating AudioQueue with format")
    """
    private static let figRe = try! NSRegularExpression(pattern: #"\[SampleRate (\d+)\] \[BitDepth (\d+)\]"#)
    private static let aqRe = try! NSRegularExpression(pattern: #"Creating AudioQueue with format:.*sampleRate:(\d+)"#)

    func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "FormatMonitor"
        t.qualityOfService = .userInitiated
        t.start()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        child?.terminate()
        child = nil
    }

    private func run() {
        while true {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            p.arguments = ["stream", "--style", "compact", "--predicate", Self.predicate]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                Log.say("cannot start log stream: \(error)")
                Thread.sleep(forTimeInterval: 10)
                continue
            }
            lock.lock(); child = p; lock.unlock()
            Log.say("subscribed (log stream pid \(p.processIdentifier))")

            let fh = pipe.fileHandleForReading
            var buf = Data()
            while true {
                let chunk = fh.availableData  // blocks; empty at EOF
                if chunk.isEmpty { break }
                buf.append(chunk)
                while let nl = buf.firstIndex(of: 0x0A) {
                    let line = String(decoding: buf[buf.startIndex..<nl], as: UTF8.self)
                    buf.removeSubrange(buf.startIndex...nl)
                    handle(line)
                }
            }
            p.waitUntilExit()
            Log.say("log stream exited (\(p.terminationStatus)), restarting in 2s")
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func handle(_ line: String) {
        if let g = Self.match(Self.figRe, line), let r = Double(g[0]), let b = UInt32(g[1]), r > 0 {
            onFormat?(TrackFormat(rate: r, bits: b > 0 ? b : nil), true)
        } else if let g = Self.match(Self.aqRe, line), let r = Double(g[0]), r > 0 {
            onFormat?(TrackFormat(rate: r, bits: nil), false)
        }
    }

    private static func match(_ re: NSRegularExpression, _ s: String) -> [String]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
    }
}
