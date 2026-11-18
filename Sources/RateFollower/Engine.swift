import CoreAudio
import Foundation

/// Owns all switching state. Every CoreAudio call happens on `queue`; the UI only
/// ever receives finished snapshots on the main thread.
final class Engine {
    /// Delivered on the main thread.
    var onUpdate: ((_ device: DeviceState?, _ track: TrackFormat?) -> Void)?

    private let queue = DispatchQueue(label: "RateFollower.engine", qos: .userInitiated)
    private let monitor = FormatMonitor()
    private var lastTrack: TrackFormat?
    private var pending: DispatchWorkItem?

    private var device: AudioObjectID?
    private var stream: AudioStreamID?
    private lazy var refreshBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.publish() }

    func start() {
        monitor.onFormat = { [weak self] f, authoritative in self?.received(f, authoritative: authoritative) }
        monitor.start()

        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue) { [weak self] _, _ in
            self?.defaultDeviceChanged()
        }
        queue.async { self.defaultDeviceChanged() }
    }

    func stop() { monitor.stop() }

    // MARK: - On `queue`

    private func received(_ f: TrackFormat, authoritative: Bool) {
        queue.async { [self] in
            pending?.cancel()
            if authoritative {
                lastTrack = f
                applyAndPublish()
            } else {
                // The AudioQueue line only carries the rate. Wait briefly for the
                // FigLog report (rate + bit depth) so the DAC switches only once.
                let item = DispatchWorkItem { [self] in
                    let bits = lastTrack.flatMap { abs($0.rate - f.rate) < 1 ? $0.bits : nil }
                    lastTrack = TrackFormat(rate: f.rate, bits: bits)
                    applyAndPublish()
                }
                pending = item
                queue.asyncAfter(deadline: .now() + 0.6, execute: item)
            }
        }
    }

    private func applyAndPublish() {
        if let dev = device, let want = lastTrack { CA.apply(want, to: dev) }
        publish()
    }

    private func defaultDeviceChanged() {
        // Move the "format changed" listeners to the new device so the menu bar
        // also reflects changes made elsewhere (e.g. Audio MIDI Setup).
        var rateAddr = CA.address(kAudioDevicePropertyNominalSampleRate)
        var fmtAddr = CA.address(kAudioStreamPropertyPhysicalFormat)
        if let old = device { AudioObjectRemovePropertyListenerBlock(old, &rateAddr, queue, refreshBlock) }
        if let old = stream { AudioObjectRemovePropertyListenerBlock(old, &fmtAddr, queue, refreshBlock) }

        device = CA.defaultOutput()
        stream = device.flatMap(CA.firstOutputStream)
        if let dev = device { AudioObjectAddPropertyListenerBlock(dev, &rateAddr, queue, refreshBlock) }
        if let s = stream { AudioObjectAddPropertyListenerBlock(s, &fmtAddr, queue, refreshBlock) }

        if let dev = device { Log.say("output device: \(CA.name(dev))") }
        applyAndPublish()
    }

    private func publish() {
        let state = device.map(CA.state)
        let track = lastTrack
        DispatchQueue.main.async { self.onUpdate?(state, track) }
    }
}
