import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case channel, hotkey, audio, permission

    var id: String { rawValue }

    func contentHeight(doubao: Bool = false) -> CGFloat {
        switch self {
        case .channel: doubao ? 430 : 330
        case .hotkey: 280
        case .audio: 390
        case .permission: 250
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var tab = SettingsTab.channel
}

@MainActor
final class SettingsWindow: NSWindow {
    let navigation = SettingsNavigation()

    init(defaults: UserDefaults = .standard) {
        MicrophoneMode.migrate(in: defaults)
        Channel.migrateLegacySelection(in: defaults)
        Hotkey.removeRetiredSettings(in: defaults)
        let channel = Channel.current(in: defaults)
        let height = SettingsTab.channel.contentHeight(doubao: channel == .doubao)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 700, height: height),
                   styleMask: [.titled, .closable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "OpenVoice 设置"
        isReleasedWhenClosed = false
        let settings = SettingsView(navigation: navigation, defaults: defaults) { [weak self] height in
            self?.resizeContent(to: height)
        }
        contentView = NSHostingView(rootView: AnyView(settings.defaultAppStorage(defaults)))
        center()
        setFrameAutosaveName("OpenVoiceSettings")
    }

    override func close() {
        contentView = nil
        super.close()
    }

    private func resizeContent(to height: CGFloat) {
        let top = frame.maxY
        setContentSize(NSSize(width: 700, height: height))
        setFrameOrigin(NSPoint(x: frame.minX, y: top - frame.height))
    }
}
