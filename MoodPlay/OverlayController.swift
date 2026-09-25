//
//  OverlayController.swift
//  MoodPlay
//

import AppKit
import QuartzCore
import SwiftUI
import IOKit.pwr_mgt
import Darwin

/// หน้าต่างบนหน้า Lock Screen ต้องไม่แย่งคีย์บอร์ดจากช่องใส่รหัสผ่านของระบบ
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// space พิเศษของ WindowServer ที่อยู่เหนือหน้า Lock Screen (private SkyLight API)
/// หน้าต่างที่ย้ายเข้ามาจะแสดงบนหน้าล็อก ส่วนช่องรหัสผ่าน/Touch ID ยังเป็นของระบบ
/// อ้างอิงเทคนิคจาก github.com/Lakr233/SkyLightWindow (MIT)
@MainActor
final class LockScreenSpace {
    static let shared = LockScreenSpace()

    private typealias MainConnectionFunction = @convention(c) () -> Int32
    private typealias SpaceCreateFunction = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SetLevelFunction = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpacesFunction = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsFunction = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    /// kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock (หน้าล็อกอยู่ที่ 300)
    private static let levelAboveLockScreen: Int32 = 400

    private let connection: Int32
    private let space: Int32
    private let addWindows: AddWindowsFunction

    private init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let mainConnection = dlsym(handle, "SLSMainConnectionID"),
              let spaceCreate = dlsym(handle, "SLSSpaceCreate"),
              let setLevel = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let showSpaces = dlsym(handle, "SLSShowSpaces"),
              let addWindows = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces")
        else { return nil }

        connection = unsafeBitCast(mainConnection, to: MainConnectionFunction.self)()
        space = unsafeBitCast(spaceCreate, to: SpaceCreateFunction.self)(connection, 1, 0)
        guard space != 0 else { return nil }
        self.addWindows = unsafeBitCast(addWindows, to: AddWindowsFunction.self)

        _ = unsafeBitCast(setLevel, to: SetLevelFunction.self)(connection, space, Self.levelAboveLockScreen)
        // macOS 27 คืนค่าสุ่มที่ไม่ใช่ 0 ทั้งที่สำเร็จ จึงไม่เช็กผลลัพธ์
        _ = unsafeBitCast(showSpaces, to: ShowSpacesFunction.self)(connection, [space] as CFArray)
    }

    func add(_ window: NSWindow) {
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
    }
}

/// แสดงหน้าจอเพลงบนหน้า Lock Screen
/// ไม่ดักเมาส์/คีย์และไม่ยุ่งกับเคอร์เซอร์: การปลดล็อกเป็นหน้าที่ของ macOS ทั้งหมด
@MainActor
final class OverlayController {
    var content: (() -> AnyView)?
    /// ใช้เปิด/ปิดงานที่ต้องทำเฉพาะตอนแสดง (sync เพลง, โหลดปก)
    var onShow: (@MainActor () -> Void)?
    var onHide: (@MainActor () -> Void)?

    private(set) var isShowing = false

    private var windows: [OverlayWindow] = []
    private var screenObserver: NSObjectProtocol?
    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false
    private var generation = 0

    private static let fadeInDuration = 1.2
    private static let fadeOutDuration = 0.3

    /// แสดงบนหน้า Lock Screen (เรียกตอนเครื่องล็อกอยู่แล้ว ซ้ำได้ไม่มีผล)
    func show() {
        guard !isShowing, content != nil, LockScreenSpace.shared != nil else { return }
        isShowing = true
        generation += 1

        closeWindows() // เผื่อยังเฟดออกจากรอบก่อนไม่เสร็จ
        onShow?()
        buildWindows(alpha: 0)
        observeScreens()
        animateAlpha(to: 1, duration: Self.fadeInDuration)
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false

        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        setKeepsDisplayAwake(false)
        animateAlpha(to: 0, duration: Self.fadeOutDuration)
        onHide?()

        let current = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.fadeOutDuration + 0.05))
            guard let self, self.generation == current, !self.isShowing else { return }
            self.closeWindows()
        }
    }

    /// ตอนเพลงเล่นอยู่ให้จอติดค้างไว้ ตอนหยุดปล่อยให้จอดับตามการตั้งค่าของระบบ
    func setKeepsDisplayAwake(_ awake: Bool) {
        if awake, isShowing {
            preventDisplaySleep()
        } else {
            allowDisplaySleep()
        }
    }

    // MARK: - Windows

    private func buildWindows(alpha: CGFloat) {
        guard let content, let space = LockScreenSpace.shared else { return }
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
            window.ignoresMouseEvents = true
            window.alphaValue = alpha

            let hosting = NSHostingView(rootView: content())
            hosting.sizingOptions = []
            window.contentView = hosting
            window.orderFrontRegardless()
            space.add(window)
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
    }

    private func observeScreens() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildWindows() }
        }
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
