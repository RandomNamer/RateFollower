import AppKit
import ServiceManagement

/// Menu-bar item: title shows the output device's current format; the menu
/// shows which device that is. Works only from cached snapshots, so opening
/// the menu never touches CoreAudio on the main thread.
final class StatusController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var device: DeviceState?
    private var track: TrackFormat?
    private var song: String?

    /// Hi-Res gold, one per menu-bar appearance. The bar turns light or dark with the
    /// wallpaper and template icons flip black/white; a fixed color can't work on both.
    /// Dark bar: brightest stop of the official logo's highlight band (owner's pick).
    private static let goldOnDark = NSColor(srgbRed: 0xF8 / 255, green: 0xBD / 255, blue: 0x5D / 255, alpha: 1)
    /// Light bar: a deeper gold from the logo's face gradient (74% stop; owner's pick).
    private static let goldOnLight = NSColor(srgbRed: 0xDF / 255, green: 0x94 / 255, blue: 0x30 / 255, alpha: 1)
    private static let titleFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    private static let noteSymbol: NSImage? = {
        let cfg = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular)
        return NSImage(systemSymbolName: "music.note", accessibilityDescription: "RateFollower")?
            .withSymbolConfiguration(cfg)
    }()
    private static let plainIcon: NSImage? = {
        let img = noteSymbol?.copy() as? NSImage
        img?.isTemplate = true  // follows menu-bar light/dark like the title
        return img
    }()
    private static func goldIcon(_ color: NSColor) -> NSImage? {
        let img = noteSymbol?.withSymbolConfiguration(.init(paletteColors: [color]))
        img?.isTemplate = false
        return img
    }
    private static let goldIconOnDark = goldIcon(goldOnDark)
    private static let goldIconOnLight = goldIcon(goldOnLight)

    private var appearanceObservation: NSKeyValueObservation?

    override init() {
        super.init()
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        item.button?.title = "–"
        item.button?.image = Self.plainIcon
        item.button?.imagePosition = .imageLeading
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu

        // The menu bar's appearance changes with the wallpaper; repaint the gold when it does.
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.render() }
        }

        // Music broadcasts this on every play/pause/track change: push-only, no polling.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playerInfo(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"), object: nil)
    }

    func update(device: DeviceState?, track: TrackFormat?) {
        self.device = device
        self.track = track
        render()
    }

    private func render() {
        guard let button = item.button else { return }
        // Kept short on purpose: on notched MacBooks a wide status item gets hidden behind the notch.
        let text = device.map { Fmt.compact(rate: $0.rate, bits: $0.bits) } ?? "–"
        let hiRes = device.map(Self.isHiRes) == true
        let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let gold = dark ? Self.goldOnDark : Self.goldOnLight
        button.attributedTitle = NSAttributedString(string: text, attributes: hiRes
            ? [.font: Self.titleFont, .foregroundColor: gold]
            : [.font: Self.titleFont])
        button.image = hiRes ? (dark ? Self.goldIconOnDark : Self.goldIconOnLight) : Self.plainIcon
        button.toolTip = device.map { "\($0.name): " + Fmt.describe(rate: $0.rate, bits: $0.bits) }
    }

    /// Apple Music's "Hi-Res Lossless" line: above 48 kHz at 24-bit.
    /// Judged on what the device is actually outputting, not on the track.
    private static func isHiRes(_ d: DeviceState) -> Bool {
        d.rate > 48_000 && (d.bits.map { $0 >= 24 } ?? true)
    }

    @objc private func playerInfo(_ note: Notification) {
        let info = note.userInfo ?? [:]
        if info["Player State"] as? String == "Stopped" { song = nil; return }
        song = (info["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(info(device?.name ?? "No output device", bold: true))
        if let d = device { menu.addItem(info("Output: " + Fmt.describe(rate: d.rate, bits: d.bits))) }
        if let s = song {
            // Menus grow to fit their widest item, so cap long titles; the tooltip keeps the full name.
            let max = 40
            let mi = info(s.count > max ? s.prefix(max - 1).trimmingCharacters(in: .whitespaces) + "…" : s)
            mi.toolTip = s
            menu.addItem(mi)
        }
        menu.addItem(info("Track: " + (track.map { Fmt.describe(rate: $0.rate, bits: $0.bits) } ?? "nothing detected yet")))

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit RateFollower", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func info(_ text: String, bold: Bool = false) -> NSMenuItem {
        let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        if bold {
            mi.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold),
                .foregroundColor: NSColor.labelColor,
            ])
        }
        return mi
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.say("login item change failed: \(error)")
        }
    }
}

private extension NSFont {
    func withWeight(_ w: NSFont.Weight) -> NSFont {
        let d = fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: w]])
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}
