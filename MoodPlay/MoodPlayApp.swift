//
//  MoodPlayApp.swift
//  MoodPlay
//
//  Created by Thanyaphat Kanokpiyasawad on 25/9/2569 BE.
//

import Combine
import SwiftUI
import CoreGraphics
import Carbon.HIToolbox
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
            Text("ไม่มีเพลงที่เล่นอยู่ใน Spotify")
        }
        if spotify.automationDenied {
            Divider()
            Text("⚠︎ MoodPlay ยังไม่ได้รับสิทธิ์ควบคุม Spotify")
            Button("เปิดการตั้งค่าสิทธิ์…") { model.openAutomationSettings() }
            Button("ลองอีกครั้ง") { spotify.refresh() }
        }
        Divider()
        Picker("ธีม", selection: $model.theme) {
            ForEach(OverlayTheme.allCases) { theme in
                Text(theme.title).tag(theme)
            }
        }
        Toggle("แสดงเนื้อเพลง", isOn: $model.showLyrics)
        Toggle("เปิดเองอัตโนมัติ", isOn: $model.autoShow)
        Picker("เวลาว่างก่อนเปิด", selection: $model.idleMinutes) {
            Text("30 วินาที").tag(0.5)
            Text("1 นาที").tag(1.0)
            Text("2 นาที").tag(2.0)
            Text("5 นาที").tag(5.0)
        }
        Divider()
        Button("แสดงตอนนี้  ⌘⇧M") { model.showNow() }
        Divider()
        Toggle("เปิดพร้อมเครื่อง", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))
        Divider()
        Button("ออกจาก MoodPlay") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - AppModel

@MainActor
final class AppModel: ObservableObject {
    private enum Keys {
        static let showLyrics = "showLyrics"
        static let autoShow = "autoShow"
        static let idleMinutes = "idleMinutes"
        static let theme = "theme"
    }

    let spotify = SpotifyMonitor()
    let lyrics = LyricsStore()
    let overlay = OverlayController()

    @Published var showLyrics: Bool {
        didSet { UserDefaults.standard.set(showLyrics, forKey: Keys.showLyrics) }
    }
    @Published var autoShow: Bool {
        didSet {
            UserDefaults.standard.set(autoShow, forKey: Keys.autoShow)
            scheduleIdleCheck()
        }
    }
    @Published var idleMinutes: Double {
        didSet {
            UserDefaults.standard.set(idleMinutes, forKey: Keys.idleMinutes)
            scheduleIdleCheck()
        }
    }
    @Published var theme: OverlayTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme) }
    }

    /// อ่านจากระบบทุกครั้ง เพราะผู้ใช้ปิดได้เองจาก System Settings → Login Items
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var idleTimer: Timer?
    private var hotKey: GlobalHotKey?
    private var systemObservers: [NSObjectProtocol] = []
    /// หน้าจอล็อกอยู่ / สลับผู้ใช้ไปแล้ว: ห้ามขึ้น overlay ไปแอบกินแบตอยู่หลังหน้าล็อก
    private var isScreenLocked = false

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.showLyrics: true,
            Keys.autoShow: true,
            Keys.idleMinutes: 2.0,
            Keys.theme: OverlayTheme.cover.rawValue,
        ])
        showLyrics = defaults.bool(forKey: Keys.showLyrics)
        autoShow = defaults.bool(forKey: Keys.autoShow)
        idleMinutes = defaults.double(forKey: Keys.idleMinutes)
        theme = OverlayTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .cover

        overlay.content = { [unowned self] in
            AnyView(MoodView(model: self, spotify: spotify, clock: spotify.clock, lyrics: lyrics))
        }
        overlay.onShow = { [weak self] in
            self?.idleTimer?.invalidate()
            self?.spotify.setLive(true)
        }
        overlay.onHide = { [weak self] in
            self?.spotify.setLive(false)
            self?.scheduleIdleCheck()
        }
        spotify.onTrackChange = { [weak self] track in
            self?.lyrics.load(for: track)
        }
        spotify.onPlayStateChange = { [weak self] _ in
            self?.scheduleIdleCheck()
        }
        spotify.start()

        observeSystem()
        scheduleIdleCheck()

        // ⌘⇧M: เปิดทันทีตอนลุกจากโต๊ะ ไม่ต้องรอเครื่องว่าง
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.showNow()
        }
    }

    func showNow() {
        guard !isScreenLocked else { return }
        // ให้เมนูปิดให้เรียบร้อยก่อนค่อยขึ้น overlay
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.overlay.show()
        }
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

    // MARK: - Idle

    /// ไม่ poll ทุกกี่วิ: คำนวณว่าอีกนานแค่ไหนจะว่างครบ แล้วตั้ง timer ปลุกครั้งเดียวตรงนั้น
    /// ถ้าผู้ใช้ขยับเมาส์ระหว่างนั้น ตอนตื่นมาจะเห็นว่ายังไม่ครบ ก็ตั้งใหม่ตามเวลาที่เหลือ
    private func scheduleIdleCheck() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard autoShow, spotify.isPlaying, !overlay.isShowing, !isScreenLocked else { return }

        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~0)!
        )
        let remaining = idleMinutes * 60 - idle
        if remaining <= 0 {
            overlay.show()
            return
        }

        let timer = Timer(timeInterval: max(remaining, 1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleIdleCheck() }
        }
        // ยอมให้ระบบรวบ wake-up กับงานอื่นได้ ช้าไปไม่กี่วิไม่มีใครสังเกต
        timer.tolerance = min(max(remaining * 0.1, 0.5), 5)
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
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
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification.rawValue) { $0.setScreenLocked(true) }
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

    private func setScreenLocked(_ locked: Bool) {
        isScreenLocked = locked
        if locked { overlay.hide() }
        scheduleIdleCheck()
    }
}

// MARK: - Theme

enum OverlayTheme: String, CaseIterable, Identifiable {
    case cover
    case vinyl

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .cover: "ปกอัลบั้ม"
        case .vinyl: "แผ่นเสียง"
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

// MARK: - Global hotkey

/// ใช้ Carbon hotkey เพราะไม่ต้องขอสิทธิ์ Accessibility
@MainActor
final class GlobalHotKey {
    private static var action: (@MainActor () -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        Self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { GlobalHotKey.action?() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x4D4F4F44), id: 1) // 'MOOD'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
