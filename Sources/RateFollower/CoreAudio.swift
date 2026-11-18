import CoreAudio
import Foundation

/// Thin CoreAudio helpers. All of these may block on coreaudiod; call them off the main thread.
enum CA {
    static func address(_ sel: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T? {
        var addr = address(sel, scope)
        var v = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func array<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope, _ zero: T) -> [T] {
        var addr = address(sel, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var arr = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &arr) == noErr else { return [] }
        return arr
    }

    static func defaultOutput() -> AudioObjectID? {
        get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal, AudioObjectID(0)).flatMap { $0 == 0 ? nil : $0 }
    }

    static func name(_ dev: AudioObjectID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name) == noErr, let n = name else { return "Device \(dev)" }
        return n.takeRetainedValue() as String
    }

    static func firstOutputStream(_ dev: AudioObjectID) -> AudioStreamID? {
        array(dev, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, AudioStreamID(0)).first
    }

    static func physicalFormat(_ stream: AudioStreamID) -> AudioStreamBasicDescription? {
        get(stream, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription())
    }

    static func nominalRate(_ dev: AudioObjectID) -> Double? {
        get(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0))
    }
}

/// What the current output device is actually running at.
struct DeviceState: Equatable {
    var name: String
    var rate: Double
    var bits: UInt32?
}

extension CA {
    static func state(_ dev: AudioObjectID) -> DeviceState {
        let fmt = firstOutputStream(dev).flatMap(physicalFormat)
        return DeviceState(name: name(dev),
                           rate: fmt?.mSampleRate ?? nominalRate(dev) ?? 0,
                           bits: fmt.map(\.mBitsPerChannel).flatMap { $0 > 0 ? $0 : nil })
    }

    /// Switch `dev` to the track's format. Prefers setting the stream's physical
    /// format (rate + bit depth together); falls back to nominal rate only.
    static func apply(_ want: TrackFormat, to dev: AudioObjectID) {
        let devName = name(dev)
        let label = Fmt.describe(rate: want.rate, bits: want.bits)

        if let stream = firstOutputStream(dev) {
            let current = physicalFormat(stream)
            let avail = array(stream, kAudioStreamPropertyAvailablePhysicalFormats,
                              kAudioObjectPropertyScopeGlobal, AudioStreamRangedDescription())
                .map(\.mFormat)
                .filter { $0.mFormatID == kAudioFormatLinearPCM && abs($0.mSampleRate - want.rate) < 1 }
            let curCh = current?.mChannelsPerFrame ?? 2
            let sameCh = avail.filter { $0.mChannelsPerFrame == curCh }
            let pool = sameCh.isEmpty ? avail : sameCh
            let pick: AudioStreamBasicDescription? = {
                if let b = want.bits, let exact = pool.first(where: { $0.mBitsPerChannel == b }) { return exact }
                if want.bits == nil, let cur = current,
                   let same = pool.first(where: { $0.mBitsPerChannel == cur.mBitsPerChannel }) { return same }
                return pool.max(by: { $0.mBitsPerChannel < $1.mBitsPerChannel })  // never truncate below source
            }()
            if let target = pick {
                if let cur = current, abs(cur.mSampleRate - target.mSampleRate) < 1,
                   cur.mBitsPerChannel == target.mBitsPerChannel {
                    Log.say("\(devName): already matches track \(label)")
                    return
                }
                var addr = address(kAudioStreamPropertyPhysicalFormat)
                var fmt = target
                let err = AudioObjectSetPropertyData(stream, &addr, 0, nil,
                                                     UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &fmt)
                if err == noErr {
                    Log.say("\(devName): -> \(Fmt.describe(rate: target.mSampleRate, bits: target.mBitsPerChannel)) (track \(label))")
                    return
                }
                Log.say("\(devName): physical format set failed (\(err)), trying nominal rate")
            }
        }

        let ranges = array(dev, kAudioDevicePropertyAvailableNominalSampleRates,
                           kAudioObjectPropertyScopeGlobal, AudioValueRange())
        guard ranges.contains(where: { want.rate >= $0.mMinimum - 1 && want.rate <= $0.mMaximum + 1 }) else {
            Log.say("\(devName): does not support \(Fmt.rate(want.rate)), leaving as is")
            return
        }
        if let cur = nominalRate(dev), abs(cur - want.rate) < 1 { return }
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(want.rate)
        let err = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &rate)
        Log.say(err == noErr ? "\(devName): -> \(Fmt.rate(want.rate)) (nominal)" : "\(devName): set nominal rate failed (\(err))")
    }
}

enum Fmt {
    static func rate(_ hz: Double) -> String {
        let k = hz / 1000
        return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
    }

    /// Menu-bar form, e.g. "96/24" or "44.1/16".
    static func compact(rate hz: Double, bits: UInt32?) -> String {
        let k = hz / 1000
        let r = k == k.rounded() ? "\(Int(k))" : String(format: "%.1f", k)
        return bits.map { "\(r)/\($0)" } ?? r
    }

    static func describe(rate hz: Double, bits: UInt32?) -> String {
        bits.map { "\(rate(hz)) · \($0)-bit" } ?? rate(hz)
    }
}

enum Log {
    private static let f: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func say(_ s: String) {
        FileHandle.standardError.write(Data("\(f.string(from: Date())) \(s)\n".utf8))
    }
}
