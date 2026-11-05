import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case channel, hotkey, meeting, audio, permission

    var id: String { rawValue }

    func contentHeight(multiChannel: Bool, doubao: Bool = false) -> CGFloat {
        switch self {
        case .channel: multiChannel ? 460 : (doubao ? 430 : 330)
        case .hotkey: 360
        case .meeting: 210
        case .audio: 260
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

    init(meeting: MeetingSession, defaults: UserDefaults = .standard) {
        let channel = Channel.current(in: defaults)
        let height = SettingsTab.channel.contentHeight(multiChannel: channel == .all, doubao: channel == .doubao)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 700, height: height),
                   styleMask: [.titled, .closable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "OpenVoice 设置"
        isReleasedWhenClosed = false
        let settings = SettingsView(meeting: meeting, navigation: navigation, defaults: defaults) { [weak self] height in
            self?.resizeContent(to: height)
        }
        contentView = NSHostingView(rootView: settings.defaultAppStorage(defaults))
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
