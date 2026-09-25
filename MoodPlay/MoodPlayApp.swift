//
//  MoodPlayApp.swift
//  MoodPlay
//
//  Created by Thanyaphat Kanokpiyasawad on 25/9/2569 BE.
//

import Combine
import SwiftUI
import ServiceManagement

@main
struct MoodPlayApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("MoodPlay", systemImage: "waveform") {
            MenuContent(model: model, spotify: model.spotify)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var spotify: SpotifyMonitor

    var body: some View {
        if let track = spotify.track {
            Text(verbatim: "\(spotify.isPlaying ? "▶︎" : "❚❚")  \(track.name) — \(track.artist)")
        } else {
            Text("Nothing Playing in Spotify")
        }
        if spotify.automationDenied {
            Divider()
            Text("⚠︎ MoodPlay Can’t Access Spotify")
            Button("Open Permission Settings…") { model.openAutomationSettings() }
            Button("Try Again") { spotify.refresh() }
        }
        Divider()
        Picker("Theme", selection: $model.theme) {
            ForEach(OverlayTheme.allCases) { theme in
                Text(theme.title).tag(theme)
            }
        }
        Toggle("Show Lyrics", isOn: $model.showLyrics)
        Divider()
        Toggle("Open at Startup", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))
        Divider()
        Button("Quit MoodPlay") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - AppModel

@MainActor
final class AppModel: ObservableObject {
    private enum Keys {
        static let showLyrics = "showLyrics"
        static let theme = "theme"
    }

    let spotify = SpotifyMonitor()
    let lyrics = LyricsStore()
    let overlay = OverlayController()

    @Published var showLyrics: Bool {
        didSet { UserDefaults.standard.set(showLyrics, forKey: Keys.showLyrics) }
    }
    @Published var theme: OverlayTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme) }
    }

    /// อ่านจากระบบทุกครั้ง เพราะผู้ใช้ปิดได้เองจาก System Settings → Login Items
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var systemObservers: [NSObjectProtocol] = []
    /// หน้าจอล็อกอยู่ / สลับผู้ใช้ไปแล้ว: ห้ามขึ้น overlay ไปแอบกินแบตอยู่หลังหน้าล็อก
    private var isScreenLocked = false

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.showLyrics: true,
            Keys.theme: OverlayTheme.cover.rawValue,
        ])
        showLyrics = defaults.bool(forKey: Keys.showLyrics)
        theme = OverlayTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .cover

        overlay.content = { [unowned self] in
            AnyView(MoodView(model: self, spotify: spotify, clock: spotify.clock, lyrics: lyrics))
        }
        overlay.onShow = { [weak self] in
            guard let self else { return }
            spotify.setLive(true)
            overlay.setKeepsDisplayAwake(spotify.isPlaying)
        }
        overlay.onHide = { [weak self] in
            self?.spotify.setLive(false)
        }
        spotify.onTrackChange = { [weak self] track in
            self?.lyrics.load(for: track)
        }
        spotify.onPlayStateChange = { [weak self] playing in
            self?.overlay.setKeepsDisplayAwake(playing)
        }
        spotify.start()

        observeSystem()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            #if DEBUG
            print("[AppModel] launch at login:", error)
            #endif
        }
        // ถ้าระบบต้องให้ผู้ใช้อนุมัติก่อน พาไปหน้า Login Items เลย
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        launchAtLogin = service.status == .enabled
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - System

    private func observeSystem() {
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screenIsLocked") { $0.setScreenLocked(true) }
        observe(distributed, "com.apple.screenIsUnlocked") { $0.setScreenLocked(false) }
        observe(distributed, "com.apple.screensaver.didstart") { $0.overlay.hide() }

        let workspace = NSWorkspace.shared.notificationCenter
        // จอดับ = ไม่มีใครเห็น ปิดทิ้งเพื่อหยุด animation ทั้งหมด
        observe(workspace, NSWorkspace.screensDidSleepNotification.rawValue) { $0.overlay.hide() }
        observe(workspace, NSWorkspace.willSleepNotification.rawValue) { $0.overlay.hide() }
        // จอติดกลับมาขณะยังล็อกอยู่ (เช่นกดคีย์เพื่อจะปลดล็อก) → ขึ้นหน้าจอเพลงบนหน้าล็อกอีกครั้ง
        observe(workspace, NSWorkspace.screensDidWakeNotification.rawValue) { model in
            if model.isScreenLocked { model.updateLockScreenOverlay() }
        }
        // สลับผู้ใช้: session เราไม่ได้อยู่หน้าจอแล้ว ไม่ต้องแสดงอะไร
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification.rawValue) { $0.setScreenLocked(true, showMood: false) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification.rawValue) { $0.setScreenLocked(false) }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: String,
        _ action: @escaping @MainActor @Sendable (AppModel) -> Void
    ) {
        systemObservers.append(center.addObserver(
            forName: Notification.Name(name),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        })
    }

    private func setScreenLocked(_ locked: Bool, showMood: Bool = true) {
        isScreenLocked = locked
        if locked, showMood {
            updateLockScreenOverlay()
        } else {
            overlay.hide()
        }
    }

    /// บนหน้าล็อก: แสดงหน้าจอเพลงเฉพาะเมื่อมีเพลงอยู่
    private func updateLockScreenOverlay() {
        if spotify.track != nil {
            overlay.show()
        } else {
            overlay.hide()
        }
    }
}

// MARK: - Theme

enum OverlayTheme: String, CaseIterable, Identifiable {
    case cover
    case vinyl

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .cover: "Album Cover"
        case .vinyl: "Vinyl"
        }
    }

    /// ความกว้างของส่วนภาพเทียบกับขนาดปก (แผ่นเสียงมีแขนเข็มยื่นออกไปทางขวา)
    var artWidthRatio: CGFloat {
        switch self {
        case .cover: 1
        case .vinyl: 1.18
        }
    }
}
