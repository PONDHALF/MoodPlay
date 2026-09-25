//
//  OverlayController.swift
//  MoodPlay
//

import AppKit
import QuartzCore
import SwiftUI
import IOKit.pwr_mgt
import Darwin

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// สำรองอีกชั้น: ถ้าเคอร์เซอร์โผล่ขึ้นมาบนหน้าต่างนี้ ให้เป็นภาพโปร่งใส
final class BlankCursorHostingView: NSHostingView<AnyView> {
    private static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.blankCursor)
    }
}

@MainActor
final class OverlayController {
    var content: (() -> AnyView)?
    /// ใช้เปิด/ปิดงานที่ต้องทำเฉพาะตอนแสดง (sync เพลง, โหลดปก)
    var onShow: (@MainActor () -> Void)?
    var onHide: (@MainActor () -> Void)?

    private(set) var isShowing = false

    private var windows: [OverlayWindow] = []
    private var eventMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false
    private var shownAt = Date.distantPast
    private var generation = 0

    private static let gracePeriod: TimeInterval = 2
    private static let fadeInDuration = 1.2
    private static let fadeOutDuration = 0.3

    func show() {
        guard !isShowing, content != nil else { return }
        isShowing = true
        generation += 1
        shownAt = Date()

        closeWindows() // เผื่อยังเฟดออกจากรอบก่อนไม่เสร็จ
        onShow?()
        buildWindows(alpha: 0)

        NSApp.activate()
        windows.first?.makeKeyAndOrderFront(nil)
        Self.setCursorHidden(true)
        installEventMonitors()
        preventDisplaySleep()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildWindows() }
        }

        animateAlpha(to: 1, duration: Self.fadeInDuration)
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false

        removeEventMonitors()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        Self.setCursorHidden(false)
        allowDisplaySleep()

        windows.forEach { $0.ignoresMouseEvents = true }
        animateAlpha(to: 0, duration: Self.fadeOutDuration)
        onHide?()

        let current = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.fadeOutDuration + 0.05))
            guard let self, self.generation == current, !self.isShowing else { return }
            self.closeWindows()
        }
    }

    // MARK: - Windows

    private func buildWindows(alpha: CGFloat) {
        guard let content else { return }
        for screen in NSScreen.screens {
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            window.alphaValue = alpha

            let hosting = BlankCursorHostingView(rootView: content())
            hosting.sizingOptions = []
            window.contentView = hosting
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    /// ทำลายหน้าต่างและ view ทั้งหมดทิ้ง ไม่เก็บไว้ในแรมระหว่างที่ไม่ได้แสดง
    private func closeWindows() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
    }

    private func rebuildWindows() {
        guard isShowing else { return }
        closeWindows()
        buildWindows(alpha: 1)
        windows.first?.makeKeyAndOrderFront(nil)
    }

    /// ให้ WindowServer เฟดทั้งหน้าต่างเอง ไม่ต้อง render SwiftUI ใหม่ทุกเฟรม
    private func animateAlpha(to value: CGFloat, duration: TimeInterval) {
        let targets = windows
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for window in targets {
                window.animator().alphaValue = value
            }
        }
    }

    // MARK: - Events

    private func installEventMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .mouseMoved, .scrollWheel,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged,
        ]
        // local: กลืน event ไม่ให้ทะลุไปถึง view
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.userDidInteract() }
            return nil
        }) {
            eventMonitors.append(local)
        }
        // global: เผื่อแอปไม่ได้ active
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.userDidInteract() }
        }) {
            eventMonitors.append(global)
        }
    }

    private func removeEventMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
    }

    private func userDidInteract() {
        // ช่วงผ่อนผันกันเมาส์สั่นตอนเพิ่งกดเปิดจากเมนู
        guard isShowing, Date().timeIntervalSince(shownAt) >= Self.gracePeriod else { return }
        // ล็อกก่อนแล้วค่อยปิด overlay จะได้ไม่เห็น desktop โผล่ก่อนหน้า login
        Self.lockScreen()
        hide()
    }

    /// พาไปหน้า login ของ macOS (ปลดล็อกด้วย Touch ID หรือรหัสผ่านตามปกติ)
    private static func lockScreen() {
        typealias LockFunction = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            _ = unsafeBitCast(symbol, to: LockFunction.self)()
            return
        }
        // สำรอง: ปิดจอ ซึ่งจะล็อกเครื่องถ้าตั้ง "ต้องใส่รหัสผ่านทันที" ไว้ใน System Settings
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    // MARK: - Cursor

    /// NSCursor.hide() ใช้ได้เฉพาะตอนแอป active ซึ่งแอป menu bar มักไม่ได้ active
    /// จึงเปิด "SetsCursorInBackground" ก่อน แล้วซ่อนด้วย CGDisplayHideCursor ที่มีผลทั้งระบบ
    private static func setCursorHidden(_ hidden: Bool) {
        if hidden {
            allowCursorChangesInBackground()
            CGDisplayHideCursor(CGMainDisplayID())
        } else {
            CGDisplayShowCursor(CGMainDisplayID())
        }
    }

    private static func allowCursorChangesInBackground() {
        typealias ConnectionFunction = @convention(c) () -> Int32
        typealias SetPropertyFunction = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connectionSymbol = dlsym(defaultHandle, "_CGSDefaultConnection"),
              let setPropertySymbol = dlsym(defaultHandle, "CGSSetConnectionProperty")
        else { return }
        let connection = unsafeBitCast(connectionSymbol, to: ConnectionFunction.self)()
        let setProperty = unsafeBitCast(setPropertySymbol, to: SetPropertyFunction.self)
        _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    // MARK: - Power

    private func preventDisplaySleep() {
        guard !hasAssertion else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MoodPlay is showing the now-playing screen" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            hasAssertion = true
        }
    }

    private func allowDisplaySleep() {
        guard hasAssertion else { return }
        IOPMAssertionRelease(assertionID)
        hasAssertion = false
    }
}
