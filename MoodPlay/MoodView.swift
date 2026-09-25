//
//  MoodView.swift
//  MoodPlay
//

import AppKit
import QuartzCore
import SwiftUI

// หลักการด้าน performance ของไฟล์นี้
// - view หลักไม่ observe เวลาเพลง: มีแค่ view ปลายทาง (แถบเวลา/เนื้อเพลง) ที่คำนวณเวลาเอง
// - เนื้อเพลงและแถบเวลาใช้ TimelineView ที่ปลุกเฉพาะตอนที่ต้องเปลี่ยนจริง ไม่ tick ถี่ ๆ
// - อะไรที่ขยับตลอด (พื้นหลังลอย, แผ่นหมุน) ใช้ Core Animation ซึ่งวิ่งใน render server ไม่กิน CPU แอป

struct MoodView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var spotify: SpotifyMonitor
    let clock: PlaybackClock
    let lyrics: LyricsStore

    /// ปกตรงกับเพลงปัจจุบันหรือยัง (ระหว่างโหลดปกใหม่ พื้นหลังยังใช้ปกเก่าได้ แต่ปกด้านหน้าไม่ควร)
    private var currentCover: CGImage? {
        guard let track = spotify.track, let artwork = spotify.artwork, artwork.trackID == track.id else { return nil }
        return artwork.cover
    }

    private var coverKey: String { currentCover == nil ? "none" : (spotify.artwork?.trackID ?? "none") }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // สีจากปกเรืองที่ขอบซ้าย/ขวา กลางจอโปร่งให้เห็นนาฬิกาและช่องปลดล็อกของระบบ
                AmbientBackground(image: spotify.artwork?.ambient)

                // เงาเข้มที่ขอบให้อ่านตัวหนังสือออกบนทุก wallpaper
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.55), location: 0),
                        .init(color: .clear, location: 0.4),
                        .init(color: .clear, location: 0.6),
                        .init(color: .black.opacity(0.55), location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                if let track = spotify.track {
                    layout(track: track, size: geo.size)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.6), value: model.showLyrics)
            .animation(.easeInOut(duration: 0.6), value: model.theme)
            .animation(.easeInOut(duration: 0.6), value: spotify.track == nil)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }

    /// ปกอยู่ซ้าย เนื้อเพลงอยู่ขวา กลางจอว่างไว้ให้ระบบ
    private func layout(track: Track, size: CGSize) -> some View {
        let cover = min(size.height * 0.3, 320)
        let side = size.width * 0.3
        return HStack(alignment: .center, spacing: 0) {
            NowPlayingColumn(
                track: track,
                theme: model.theme,
                cover: currentCover,
                coverKey: coverKey,
                coverSize: cover,
                isPlaying: spotify.isPlaying,
                clock: clock
            )
            .frame(width: side, alignment: .leading)

            Spacer(minLength: 0)

            if model.showLyrics {
                LyricsPanel(lyrics: lyrics, clock: clock)
                    .frame(width: side)
                    .frame(maxHeight: size.height * 0.6)
            }
        }
        .padding(.horizontal, size.width * 0.05)
    }
}

// MARK: - Background

/// พื้นหลังจากปกเบลอ: ภาพจิ๋ว 32px ที่เบลอไว้แล้ว ขยายเต็มจอ + ลอยช้า ๆ ด้วย Core Animation
private struct AmbientBackground: NSViewRepresentable {
    let image: CGImage?

    func makeNSView(context: Context) -> AmbientLayerView { AmbientLayerView() }

    func updateNSView(_ view: AmbientLayerView, context: Context) {
        view.setImage(image)
    }
}

final class AmbientLayerView: NSView {
    private let imageLayer = CALayer()
    private let edgeMask = CAGradientLayer()
    private var currentImage: CGImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.masksToBounds = true
        layer = root
        wantsLayer = true

        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.magnificationFilter = .linear
        imageLayer.opacity = 0.65
        imageLayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        root.addSublayer(imageLayer)

        // ทึบที่ขอบ โปร่งกลางจอ
        let opaque = NSColor.black.cgColor
        let clear = NSColor.clear.cgColor
        edgeMask.colors = [opaque, clear, clear, opaque]
        edgeMask.locations = [0, 0.38, 0.62, 1]
        edgeMask.startPoint = CGPoint(x: 0, y: 0.5)
        edgeMask.endPoint = CGPoint(x: 1, y: 0.5)
        edgeMask.actions = ["bounds": NSNull(), "position": NSNull()]
        root.mask = edgeMask

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.2
        scale.toValue = 1.4
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = -6 * Double.pi / 180
        rotation.toValue = 6 * Double.pi / 180
        let drift = CAAnimationGroup()
        drift.animations = [scale, rotation]
        drift.duration = 9
        drift.autoreverses = true
        drift.repeatCount = .infinity
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        drift.isRemovedOnCompletion = false
        imageLayer.add(drift, forKey: "drift")
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        imageLayer.bounds = bounds
        imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        edgeMask.frame = bounds
    }

    func setImage(_ image: CGImage?) {
        guard image !== currentImage else { return }
        currentImage = image
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 1.2
        imageLayer.add(fade, forKey: "crossfade")
        imageLayer.contents = image
    }
}

// MARK: - Now playing

private struct NowPlayingColumn: View {
    let track: Track
    let theme: OverlayTheme
    let cover: CGImage?
    let coverKey: String
    let coverSize: CGFloat
    let isPlaying: Bool
    let clock: PlaybackClock

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch theme {
                case .cover:
                    CoverArt(image: cover, key: coverKey, size: coverSize)
                case .vinyl:
                    VinylPlayer(cover: cover, size: coverSize, isPlaying: isPlaying)
                }
            }
            .padding(.bottom, 40)

            Text(track.name)
                .font(.system(size: 40, weight: .bold))
                .tracking(-0.8)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.bottom, 8)

            HStack(spacing: 10) {
                if !isPlaying {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 13, weight: .bold))
                }
                Text(track.artist)
                    .font(.system(size: 20, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.6))
            .padding(.bottom, 32)

            ProgressLine(clock: clock)
                .frame(width: coverSize)
        }
    }
}

private struct CoverArt: View {
    let image: CGImage?
    let key: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.06))
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .id(key)
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.2, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.6), radius: 50, y: 30)
        .animation(.easeInOut(duration: 0.8), value: key)
    }
}

/// อัปเดตวินาทีละครั้ง ตรงจังหวะที่ตัวเลขวินาทีเปลี่ยนพอดี และหยุดนิ่งเมื่อ pause
private struct ProgressLine: View {
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        let anchor = clock.anchor
        if anchor.isPlaying {
            TimelineView(.periodic(from: anchor.date(reaching: anchor.position.rounded(.down)), by: 1)) { context in
                bar(position: anchor.position(at: context.date) + 0.01, duration: anchor.duration)
            }
        } else {
            bar(position: anchor.position, duration: anchor.duration)
        }
    }

    private func bar(position: Double, duration: Double) -> some View {
        let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0
        return VStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(.white.opacity(0.85))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 2)

            HStack {
                Text(Self.format(position))
                Spacer()
                Text(Self.format(duration))
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Vinyl

private struct VinylPlayer: View {
    let cover: CGImage?
    let size: CGFloat
    let isPlaying: Bool

    var body: some View {
        let armLength = size * 0.62
        let pivot = CGPoint(x: size * 1.08, y: size * 0.08)
        ZStack(alignment: .topLeading) {
            SpinningDisc(cover: cover, size: size, isPlaying: isPlaying)
                .frame(width: size, height: size)

            ToneArm(length: armLength, scale: size)
                // ตอนเล่นเข็มวางบนแผ่น ตอนหยุดยกออกไปพักข้าง ๆ
                .rotationEffect(.degrees(isPlaying ? 25 : 8), anchor: .top)
                .position(x: pivot.x, y: pivot.y + (armLength + size * 0.05) / 2)
                .animation(.spring(response: 1.1, dampingFraction: 0.8), value: isPlaying)

            Circle()
                .fill(Color(white: 0.16))
                .overlay(Circle().fill(Color(white: 0.72)).padding(size * 0.018))
                .frame(width: size * 0.075, height: size * 0.075)
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                .position(pivot)
        }
        .frame(width: size * OverlayTheme.vinyl.artWidthRatio, height: size, alignment: .topLeading)
    }
}

/// แผ่นเสียงถูกวาดเป็นภาพนิ่งครั้งเดียว (ต่อปก/ขนาด) แล้วให้ Core Animation หมุน
private struct SpinningDisc: NSViewRepresentable {
    let cover: CGImage?
    let size: CGFloat
    let isPlaying: Bool

    func makeNSView(context: Context) -> DiscLayerView { DiscLayerView() }

    func updateNSView(_ view: DiscLayerView, context: Context) {
        view.update(cover: cover, size: size, spinning: isPlaying)
    }
}

final class DiscLayerView: NSView {
    /// วินาทีต่อรอบ (ช้ากว่า 33⅓ rpm จริงนิดหน่อยให้ดูนิ่ง ๆ)
    private static let period: CFTimeInterval = 3.6

    private let discLayer = CALayer()
    private let sheenLayer = CAGradientLayer()
    private var renderedCover: CGImage?
    private var renderedPixels = 0
    private var cover: CGImage?
    private var size: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.masksToBounds = false
        root.shadowColor = NSColor.black.cgColor
        root.shadowOpacity = 0.65
        root.shadowRadius = 50
        root.shadowOffset = CGSize(width: 0, height: -30)
        layer = root
        wantsLayer = true

        let noActions: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "cornerRadius": NSNull()]
        discLayer.actions = noActions
        root.addSublayer(discLayer)

        // แสงสะท้อนอยู่นิ่ง ขณะที่แผ่นหมุนอยู่ข้างใต้
        sheenLayer.type = .conic
        sheenLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        sheenLayer.endPoint = CGPoint(x: 0.5, y: 0)
        let clear = NSColor.white.withAlphaComponent(0).cgColor
        sheenLayer.colors = [clear, NSColor.white.withAlphaComponent(0.13).cgColor, clear, clear,
                             NSColor.white.withAlphaComponent(0.09).cgColor, clear, clear]
        sheenLayer.locations = [0, 0.08, 0.2, 0.5, 0.58, 0.7, 1]
        sheenLayer.transform = CATransform3DMakeRotation(-60 * .pi / 180, 0, 0, 1)
        sheenLayer.masksToBounds = true
        sheenLayer.actions = noActions
        root.addSublayer(sheenLayer)

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi // ทวนเข็มในพิกัด y ขึ้น = ตามเข็มบนจอ
        spin.duration = Self.period
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        discLayer.add(spin, forKey: "spin")
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for sublayer in [discLayer, sheenLayer] {
            sublayer.bounds = bounds
            sublayer.position = center
        }
        sheenLayer.cornerRadius = bounds.width / 2
        layer?.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
        renderIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderIfNeeded()
    }

    func update(cover: CGImage?, size: CGFloat, spinning: Bool) {
        self.cover = cover
        self.size = size
        renderIfNeeded()
        setSpinning(spinning)
    }

    private func renderIfNeeded() {
        let scale = window?.backingScaleFactor ?? 2
        let pixels = Int((size * scale).rounded())
        guard pixels > 0, pixels != renderedPixels || cover !== renderedCover else { return }
        let isNewCover = renderedPixels > 0 && cover !== renderedCover
        renderedPixels = pixels
        renderedCover = cover
        if isNewCover {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.8
            discLayer.add(fade, forKey: "crossfade")
        }
        discLayer.contents = DiscRenderer.render(cover: cover, pixels: pixels)
    }

    /// หยุด/หมุนต่อจากมุมเดิม (เทคนิคมาตรฐานของ Core Animation: speed + timeOffset)
    private func setSpinning(_ spinning: Bool) {
        if spinning, discLayer.speed == 0 {
            let pausedTime = discLayer.timeOffset
            discLayer.speed = 1
            discLayer.timeOffset = 0
            discLayer.beginTime = 0
            discLayer.beginTime = discLayer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        } else if !spinning, discLayer.speed != 0 {
            let pausedTime = discLayer.convertTime(CACurrentMediaTime(), from: nil)
            discLayer.speed = 0
            discLayer.timeOffset = pausedTime
        }
    }
}

nonisolated enum DiscRenderer {
    static func render(cover: CGImage?, pixels n: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        let size = CGFloat(n)
        let center = CGPoint(x: size / 2, y: size / 2)
        func circle(_ radius: CGFloat) -> CGRect {
            CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }

        context.setFillColor(CGColor(gray: 0.05, alpha: 1))
        context.fillEllipse(in: circle(size / 2))

        // ร่องแผ่น: จากขอบ label ออกไปจนเกือบถึงขอบแผ่น
        context.setLineWidth(max(size / 700, 0.5))
        var fraction: CGFloat = 0.215
        var index = 0
        while fraction < 0.485 {
            let alpha: CGFloat = index % 5 == 0 ? 0.09 : 0.035
            context.setStrokeColor(CGColor(gray: 1, alpha: alpha))
            context.strokeEllipse(in: circle(size * fraction))
            fraction += 0.0065
            index += 1
        }

        // label กลางแผ่นเป็นปกเพลง
        let label = circle(size * 0.2)
        context.saveGState()
        context.addEllipse(in: label)
        context.clip()
        if let cover {
            context.interpolationQuality = .high
            context.draw(cover, in: label)
        } else {
            context.setFillColor(CGColor(gray: 0.2, alpha: 1))
            context.fill(label)
        }
        context.restoreGState()

        let spindle = circle(size * 0.014)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillEllipse(in: spindle)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.25))
        context.setLineWidth(max(size / 460, 1))
        context.strokeEllipse(in: spindle)

        return context.makeImage()
    }
}

private struct ToneArm: View {
    let length: CGFloat
    let scale: CGFloat

    private var metal: LinearGradient {
        LinearGradient(colors: [Color(white: 0.85), Color(white: 0.55)], startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(metal)
                .frame(width: scale * 0.013, height: length)
            RoundedRectangle(cornerRadius: scale * 0.008, style: .continuous)
                .fill(metal)
                .frame(width: scale * 0.036, height: scale * 0.075)
                .offset(y: length - scale * 0.03)
        }
        .frame(width: scale * 0.05, height: length + scale * 0.05, alignment: .top)
        .shadow(color: .black.opacity(0.5), radius: 10, x: 4, y: 8)
    }
}

// MARK: - Lyrics

private struct LyricsPanel: View {
    @ObservedObject var lyrics: LyricsStore
    @ObservedObject var clock: PlaybackClock

    /// เลื่อนเร็วขึ้นเล็กน้อยให้บรรทัดขึ้นทันเสียง
    private static let syncedLead = 0.25

    var body: some View {
        ZStack {
            switch lyrics.state {
            case .synced(let lines):
                BoundaryTimeline(times: lines.map(\.time), anchor: clock.anchor, lead: Self.syncedLead) { index in
                    SyncedLyrics(lines: lines, current: index)
                        .equatable()
                }
            case .plain(let lines):
                // ไม่มี timestamp จึงเลื่อนตามสัดส่วนเวลาของเพลงแทน
                let step = clock.anchor.duration / Double(max(lines.count, 1))
                BoundaryTimeline(times: lines.indices.map { Double($0) * step }, anchor: clock.anchor, lead: 0) { index in
                    PlainLyrics(lines: lines, anchor: max(index, 0))
                        .equatable()
                }
            case .loading:
                StatusText("กำลังหาเนื้อเพลง…")
            case .instrumental:
                StatusText("เพลงนี้ไม่มีเนื้อร้อง")
            case .notFound:
                StatusText("ไม่พบเนื้อเพลงของเพลงนี้")
            case .idle:
                EmptyView()
            }
        }
        .id(lyrics.trackID)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.5), value: lyrics.trackID)
    }
}

/// ตั้งเวลาปลุก view เฉพาะจังหวะที่ index เปลี่ยน (เช่นขึ้นบรรทัดใหม่) ไม่ tick ระหว่างนั้นเลย
private struct BoundaryTimeline<Content: View>: View {
    let times: [Double]
    let anchor: PlaybackAnchor
    let lead: Double
    @ViewBuilder let content: (Int) -> Content

    var body: some View {
        TimelineView(BoundarySchedule(times: times, anchor: anchor, lead: lead)) { context in
            // +0.01 กันกรณีเวลาตรงขอบพอดีแล้วปัดลงไปบรรทัดก่อน
            content(BoundarySchedule.index(in: times, at: anchor.position(at: context.date) + lead + 0.01))
        }
    }
}

nonisolated struct BoundarySchedule: TimelineSchedule, Sendable {
    let times: [Double]
    let anchor: PlaybackAnchor
    let lead: Double

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let times = times
        let anchor = anchor
        let lead = lead
        var emittedStart = false
        var next = anchor.isPlaying ? Self.index(in: times, at: anchor.position(at: startDate) + lead) + 1 : times.count
        return AnyIterator {
            if !emittedStart {
                emittedStart = true
                return startDate
            }
            guard next < times.count else { return nil }
            defer { next += 1 }
            return anchor.date(reaching: times[next] - lead)
        }
    }

    /// index สุดท้ายที่เวลา <= position (binary search), -1 ถ้ายังไม่ถึงตัวแรก
    static func index(in times: [Double], at position: Double) -> Int {
        var low = 0
        var high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] <= position { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }
}

private struct StatusText: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Equatable: SwiftUI จะข้ามการ render ถ้าบรรทัดปัจจุบันยังเป็นบรรทัดเดิม
private struct SyncedLyrics: View, Equatable {
    let lines: [LyricLine]
    /// -1 = ยังไม่ถึงบรรทัดแรก
    let current: Int

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    // Lazy: สร้างเฉพาะบรรทัดที่อยู่ในจอ บรรทัดที่พ้นจอไปไม่ถูก render/เบลอ
                    LazyVStack(alignment: .leading, spacing: 26) {
                        Color.clear.frame(height: geo.size.height / 2)
                        ForEach(lines) { line in
                            lineView(line)
                                .id(line.id)
                        }
                        Color.clear.frame(height: geo.size.height / 2)
                    }
                    .animation(.easeOut(duration: 0.35), value: current)
                }
                .scrollDisabled(true)
                .onAppear {
                    proxy.scrollTo(max(current, 0), anchor: .center)
                }
                .onChange(of: current) { _, newValue in
                    withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) {
                        proxy.scrollTo(max(newValue, 0), anchor: .center)
                    }
                }
            }
        }
        .mask(EdgeFade())
    }

    @ViewBuilder
    private func lineView(_ line: LyricLine) -> some View {
        let distance = abs(line.id - current)
        let isCurrent = line.id == current
        let opacity: Double = isCurrent ? 1 : (line.id < current ? 0.2 : 0.38)
        Group {
            if line.text.isEmpty {
                // ช่วงดนตรีระหว่างท่อน
                BreakDots(active: isCurrent)
            } else {
                Text(verbatim: line.text)
                    .font(.system(size: 36, weight: .bold))
                    .tracking(-0.5)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white.opacity(opacity))
        .blur(radius: isCurrent ? 0 : min(Double(distance) * 0.8, 3.5))
    }
}

/// จุดสามจุดแทนบรรทัดว่าง ค่อย ๆ กระพริบไล่กันเมื่อถึงช่วงนั้น (จำกัด 30fps พอ)
private struct BreakDots: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = active ? (sin(t * 3 - Double(index) * 0.7) + 1) / 2 : 0.5
                    Circle()
                        .frame(width: 12, height: 12)
                        .opacity(0.35 + wave * 0.65)
                        .scaleEffect(0.8 + wave * 0.3)
                }
            }
            .frame(height: 44)
        }
    }
}

private struct PlainLyrics: View, Equatable {
    let lines: [String]
    let anchor: Int

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        Color.clear.frame(height: geo.size.height / 2)
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(verbatim: line)
                                .font(.system(size: 28, weight: .bold))
                                .tracking(-0.3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(.white.opacity(0.5))
                                .id(index)
                        }
                        Color.clear.frame(height: geo.size.height / 2)
                    }
                }
                .scrollDisabled(true)
                .onAppear { proxy.scrollTo(anchor, anchor: .center) }
                .onChange(of: anchor) { _, newValue in
                    withAnimation(.easeInOut(duration: 1.5)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .mask(EdgeFade())
    }
}

private struct EdgeFade: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.22),
                .init(color: .black, location: 0.78),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
