//
//  SpotifyMonitor.swift
//  MoodPlay
//

import AppKit
import Combine
import Foundation
import ImageIO

nonisolated struct Track: Equatable, Sendable {
    let id: String
    let name: String
    let artist: String
    let album: String
    /// วินาที
    let duration: Double
}

/// จุดอ้างอิงเวลาเพลง: view คำนวณตำแหน่งเองจากค่านี้ จึงไม่ต้องมี timer คอยอัปเดตตำแหน่ง
nonisolated struct PlaybackAnchor: Equatable, Sendable {
    var position: Double = 0
    var date: Date = .distantPast
    var isPlaying = false
    var duration: Double = 0

    func position(at now: Date) -> Double {
        guard isPlaying else { return position }
        let value = position + now.timeIntervalSince(date)
        return duration > 0 ? min(value, duration) : value
    }

    /// เวลาจริงที่เพลงจะเล่นถึงตำแหน่ง `target`
    func date(reaching target: Double) -> Date {
        date.addingTimeInterval(target - position)
    }
}

/// ปกที่ย่อขนาดแล้ว + พื้นหลังจิ๋วที่เบลอไว้ล่วงหน้า
nonisolated struct Artwork: @unchecked Sendable {
    let trackID: String
    let cover: CGImage
    let ambient: CGImage
}

/// สถานะของ Spotify ณ ขณะหนึ่ง อ่านได้ทั้งจาก distributed notification และ AppleScript
nonisolated struct SpotifySnapshot: Sendable {
    static let separator = "|~|"

    let state: String
    let track: Track?
    let position: Double?

    var isPlaying: Bool { state.lowercased() == "playing" }
    var isStopped: Bool { state.lowercased() == "stopped" }

    init(userInfo: [AnyHashable: Any]) {
        state = userInfo["Player State"] as? String ?? "Stopped"
        position = (userInfo["Playback Position"] as? NSNumber)?.doubleValue
        if let id = userInfo["Track ID"] as? String, !id.isEmpty {
            track = Track(
                id: id,
                name: userInfo["Name"] as? String ?? "",
                artist: userInfo["Artist"] as? String ?? "",
                album: userInfo["Album"] as? String ?? "",
                duration: ((userInfo["Duration"] as? NSNumber)?.doubleValue ?? 0) / 1000
            )
        } else {
            track = nil
        }
    }

    init(appleScriptOutput output: String) {
        let parts = output.components(separatedBy: Self.separator)
        state = parts.first ?? "stopped"
        guard parts.count == 7 else {
            track = nil
            position = nil
            return
        }
        track = Track(
            id: parts[1],
            name: parts[2],
            artist: parts[3],
            album: parts[4],
            duration: (Self.parseNumber(parts[5]) ?? 0) / 1000
        )
        position = Self.parseNumber(parts[6])
    }

    /// บาง locale คืนทศนิยมเป็นจุลภาค เช่น "12,5"
    static func parseNumber(_ string: String) -> Double? {
        Double(string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }
}

/// แยกเวลาเพลงออกมา เพื่อให้เมนูไม่ต้อง render ใหม่ทุกครั้งที่ sync ตำแหน่ง
@MainActor
final class PlaybackClock: ObservableObject {
    @Published fileprivate(set) var anchor = PlaybackAnchor()
}

@MainActor
final class SpotifyMonitor: ObservableObject {
    nonisolated static let bundleID = "com.spotify.client"

    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: Artwork?
    /// ผู้ใช้กดปฏิเสธสิทธิ์ Automation (MoodPlay → Spotify) ไว้
    @Published private(set) var automationDenied = false

    let clock = PlaybackClock()

    var onTrackChange: (@MainActor (Track?) -> Void)?
    var onPlayStateChange: (@MainActor (Bool) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var syncTimer: Timer?
    private var artworkTask: Task<Void, Never>?
    /// true เฉพาะตอน overlay แสดงอยู่: ค่อย sync ตำแหน่งและโหลดปก
    private var isLive = false

    /// ถ้าตำแหน่งจริงต่างจากที่คำนวณไว้ไม่ถึงค่านี้ จะไม่อัปเดต (กัน view render ใหม่โดยไม่จำเป็น)
    private static let driftTolerance = 0.35

    // ทุก script มี timeout 2 วิ กันแอปค้างถ้า Spotify ไม่ตอบ
    private static let stateScript = """
        tell application id "com.spotify.client"
            with timeout of 2 seconds
                set s to player state as string
                if s is "stopped" then return s
                set t to current track
                set sep to "\(SpotifySnapshot.separator)"
                return s & sep & (id of t) & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & ((duration of t) as string) & sep & ((player position) as string)
            end timeout
        end tell
        """

    /// ใช้ตอน sync เป็นระยะ: ขอแค่ 2 ค่า (Apple Event 2 ครั้ง แทนที่จะเป็น 8)
    private static let syncScript = """
        tell application id "com.spotify.client"
            with timeout of 2 seconds
                return (player state as string) & "\(SpotifySnapshot.separator)" & ((player position) as string)
            end timeout
        end tell
        """

    private static let artworkScript = """
        tell application id "com.spotify.client"
            with timeout of 2 seconds
                return artwork url of current track
            end timeout
        end tell
        """

    private static var compiledScripts: [String: NSAppleScript] = [:]

    var isSpotifyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    func start() {
        guard observers.isEmpty else { return }

        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let snapshot = SpotifySnapshot(userInfo: note.userInfo ?? [:])
            MainActor.assumeIsolated { self?.apply(snapshot) }
        })

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == SpotifyMonitor.bundleID else { return }
            MainActor.assumeIsolated { self?.reset() }
        })

        // ตอนเปิดแอป notification ยังไม่มา ต้องถามสถานะเองครั้งแรก
        refresh()
    }

    /// เปิด/ปิดโหมดแสดงผล: ตอน overlay ปิด ไม่มี timer หรือ AppleScript วิ่งเลย พึ่ง notification อย่างเดียว
    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        syncTimer?.invalidate()
        syncTimer = nil
        guard live else {
            artworkTask?.cancel()
            return
        }

        syncPosition()
        loadArtworkIfNeeded()

        // sync เผื่อมีการกรอเพลง
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPosition() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }

    /// ดึงสถานะทั้งหมดผ่าน AppleScript (เฉพาะเมื่อ Spotify เปิดอยู่เท่านั้น)
    func refresh() {
        guard isSpotifyRunning else {
            if track != nil || isPlaying { reset() }
            return
        }
        guard let output = runAppleScript(Self.stateScript) else { return }
        apply(SpotifySnapshot(appleScriptOutput: output))
    }

    // MARK: - State

    private func syncPosition() {
        guard track != nil, isSpotifyRunning,
              let output = runAppleScript(Self.syncScript)
        else { return }
        let parts = output.components(separatedBy: SpotifySnapshot.separator)
        guard parts.count == 2, let position = SpotifySnapshot.parseNumber(parts[1]) else { return }
        if (parts[0].lowercased() == "playing") != isPlaying {
            // notification หลุดไป ดึงใหม่ทั้งชุด
            refresh()
            return
        }
        updateAnchor(position)
    }

    private func updateAnchor(_ position: Double) {
        let now = Date()
        let next = PlaybackAnchor(
            position: max(0, position),
            date: now,
            isPlaying: isPlaying,
            duration: track?.duration ?? 0
        )
        let current = clock.anchor
        if current.isPlaying == next.isPlaying,
           current.duration == next.duration,
           abs(current.position(at: now) - next.position) < Self.driftTolerance {
            return
        }
        clock.anchor = next
    }

    private func apply(_ snapshot: SpotifySnapshot) {
        let newTrack = snapshot.isStopped ? nil : snapshot.track
        let changed = newTrack?.id != track?.id
        let previousPosition = clock.anchor.position(at: Date())

        if track != newTrack { track = newTrack }
        let playing = newTrack != nil && snapshot.isPlaying
        let playStateChanged = playing != isPlaying
        if playStateChanged { isPlaying = playing }
        updateAnchor(snapshot.position ?? (changed ? 0 : previousPosition))

        if changed {
            onTrackChange?(newTrack)
            if isLive { loadArtworkIfNeeded() }
        }
        if playStateChanged {
            onPlayStateChange?(playing)
        }
    }

    private func reset() {
        let hadTrack = track != nil
        let wasPlaying = isPlaying
        track = nil
        isPlaying = false
        artworkTask?.cancel()
        artwork = nil
        clock.anchor = PlaybackAnchor()
        if hadTrack { onTrackChange?(nil) }
        if wasPlaying { onPlayStateChange?(false) }
    }

    /// โหลดปกเฉพาะตอนต้องแสดงจริง และเก็บปกเก่าไว้จนกว่าปกใหม่จะพร้อม เพื่อให้ crossfade ต่อเนื่อง
    private func loadArtworkIfNeeded() {
        guard let track, artwork?.trackID != track.id, isSpotifyRunning else { return }
        artworkTask?.cancel()
        guard let output = runAppleScript(Self.artworkScript),
              let url = URL(string: output.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.hasPrefix("http") == true
        else {
            artwork = nil
            return
        }
        let trackID = track.id
        artworkTask = Task { [weak self] in
            let loaded = await ArtworkLoader.load(url, trackID: trackID)
            guard let self, !Task.isCancelled, self.track?.id == trackID, let loaded else { return }
            self.artwork = loaded
        }
    }

    // MARK: - AppleScript

    /// -1743 = ผู้ใช้ปฏิเสธสิทธิ์, -1744 = ยังไม่เคยถาม แต่ห้ามถามในบริบทนี้
    private static let permissionErrors: Set<Int> = [-1743, -1744]

    private func runAppleScript(_ source: String) -> String? {
        let (output, errorCode) = Self.executeAppleScript(source)
        let denied = errorCode.map(Self.permissionErrors.contains) ?? false
        if denied != automationDenied, output != nil || denied {
            automationDenied = denied
        }
        return output
    }

    /// compile ครั้งเดียวแล้วเก็บไว้ใช้ซ้ำ
    private static func executeAppleScript(_ source: String) -> (output: String?, errorCode: Int?) {
        let script: NSAppleScript
        if let cached = compiledScripts[source] {
            script = cached
        } else {
            guard let created = NSAppleScript(source: source) else { return (nil, nil) }
            var compileError: NSDictionary?
            guard created.compileAndReturnError(&compileError) else {
                return (nil, compileError?[NSAppleScript.errorNumber] as? Int)
            }
            compiledScripts[source] = created
            script = created
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            #if DEBUG
            print("[SpotifyMonitor] AppleScript error:", error)
            #endif
            return (nil, error[NSAppleScript.errorNumber] as? Int)
        }
        return (result.stringValue, nil)
    }
}

// MARK: - Artwork

nonisolated enum ArtworkLoader {
    private static let coverPixels = 640
    private static let ambientPixels = 32

    /// โหลด + ย่อขนาด + ทำพื้นหลัง บน background thread
    @concurrent
    static func load(_ url: URL, trackID: String) async -> Artwork? {
        guard let (data, _) = try? await HTTP.session.data(from: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: coverPixels,
        ]
        guard let cover = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let ambient = makeAmbient(from: cover)
        else { return nil }
        return Artwork(trackID: trackID, cover: cover, ambient: ambient)
    }

    /// ย่อปกเหลือ 32px แล้วเบลอ + เพิ่มความสด ครั้งเดียว
    /// พอขยายเต็มจอแบบ bilinear จะได้ภาพนุ่มเหมือนเบลอหนัก ๆ โดยไม่ต้องเบลอสดทุกเฟรม
    private static func makeAmbient(from image: CGImage) -> CGImage? {
        let n = ambientPixels
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let raw = context.data
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))

        let pixels = raw.bindMemory(to: UInt8.self, capacity: n * n * 4)
        let saturation = 1.35
        for i in 0..<(n * n) {
            let o = i * 4
            let r = Double(pixels[o]), g = Double(pixels[o + 1]), b = Double(pixels[o + 2])
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            pixels[o] = UInt8(clamping: Int((luma + (r - luma) * saturation).rounded()))
            pixels[o + 1] = UInt8(clamping: Int((luma + (g - luma) * saturation).rounded()))
            pixels[o + 2] = UInt8(clamping: Int((luma + (b - luma) * saturation).rounded()))
        }
        for _ in 0..<3 { boxBlur(pixels, size: n) }
        return context.makeImage()
    }

    private static func boxBlur(_ pixels: UnsafeMutablePointer<UInt8>, size n: Int) {
        let copy = [UInt8](UnsafeBufferPointer(start: pixels, count: n * n * 4))
        for y in 0..<n {
            for x in 0..<n {
                var r = 0, g = 0, b = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let sx = min(max(x + dx, 0), n - 1)
                        let sy = min(max(y + dy, 0), n - 1)
                        let o = (sy * n + sx) * 4
                        r += Int(copy[o]); g += Int(copy[o + 1]); b += Int(copy[o + 2])
                    }
                }
                let o = (y * n + x) * 4
                pixels[o] = UInt8(r / 9)
                pixels[o + 1] = UInt8(g / 9)
                pixels[o + 2] = UInt8(b / 9)
            }
        }
    }
}
