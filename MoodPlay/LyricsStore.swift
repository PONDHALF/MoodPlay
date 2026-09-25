//
//  LyricsStore.swift
//  MoodPlay
//

import Combine
import Foundation

nonisolated struct LyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    /// วินาที
    let time: Double
    let text: String
}

nonisolated enum LyricsState: Equatable, Sendable {
    case idle
    case loading
    case notFound
    case instrumental
    case synced([LyricLine])
    case plain([String])
}

@MainActor
final class LyricsStore: ObservableObject {
    @Published private(set) var state: LyricsState = .idle
    @Published private(set) var trackID: String?

    private var cache: [String: LyricsState] = [:]
    private var cacheOrder: [String] = []
    private var task: Task<Void, Never>?

    /// เก็บเนื้อเพลงไว้แค่ไม่กี่สิบเพลงล่าสุด กันแรมโตไปเรื่อย ๆ
    private static let cacheLimit = 40

    func load(for track: Track?) {
        task?.cancel()
        trackID = track?.id
        guard let track else {
            state = .idle
            return
        }
        if let cached = cache[track.id] {
            state = cached
            return
        }
        state = .loading
        task = Task { [weak self] in
            let result = await LRCLib.fetch(track)
            // ทิ้งผลที่มาช้าถ้าเปลี่ยนเพลงไปแล้ว
            guard let self, !Task.isCancelled, self.trackID == track.id else { return }
            if let result {
                self.store(result, for: track.id)
                self.state = result
            } else {
                // network error: ไม่ cache เพื่อให้ลองใหม่ได้ในรอบถัดไป
                self.state = .notFound
            }
        }
    }

    private func store(_ state: LyricsState, for id: String) {
        if cache.updateValue(state, forKey: id) == nil {
            cacheOrder.append(id)
        }
        while cacheOrder.count > Self.cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}

// MARK: - HTTP

/// session เดียวใช้ทั้งแอป: ไม่มี URLCache (ไม่กินแรม/ดิสก์) และไม่รอเน็ตค้างไว้
nonisolated enum HTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()
}

// MARK: - LRCLIB

nonisolated enum LRCLib {
    private static let baseURL = URL(string: "https://lrclib.net/api")!
    private static let userAgent = "MoodPlay/1.0 (macOS menu bar app)"

    private struct Record: Decodable, Sendable {
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    /// คืน `nil` เมื่อเกิด network error (ไม่ควร cache)
    static func fetch(_ track: Track) async -> LyricsState? {
        do {
            if let record = try await get(track) {
                return state(from: record)
            }
            let results = try await search(track)
            let best = results.first { !($0.syncedLyrics ?? "").isEmpty }
                ?? results.first { !($0.plainLyrics ?? "").isEmpty }
                ?? results.first { $0.instrumental == true }
            return best.map(state(from:)) ?? .notFound
        } catch {
            return nil
        }
    }

    private static func get(_ track: Track) async throws -> Record? {
        var items = [
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "track_name", value: track.name),
            URLQueryItem(name: "album_name", value: track.album),
        ]
        if track.duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))))
        }
        guard let (data, status) = try await request(path: "get", query: items), status == 200 else {
            return nil
        }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func search(_ track: Track) async throws -> [Record] {
        let items = [
            URLQueryItem(name: "track_name", value: track.name),
            URLQueryItem(name: "artist_name", value: track.artist),
        ]
        guard let (data, status) = try await request(path: "search", query: items), status == 200 else {
            return []
        }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private static func request(path: String, query: [URLQueryItem]) async throws -> (Data, Int)? {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = query
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await HTTP.session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func state(from record: Record) -> LyricsState {
        if let synced = record.syncedLyrics, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = record.plainLyrics, !plain.isEmpty {
            return .plain(plain.components(separatedBy: .newlines))
        }
        if record.instrumental == true {
            return .instrumental
        }
        return .notFound
    }

    /// parse รูปแบบ `[mm:ss.xx] text` (หนึ่งบรรทัดอาจมีหลาย timestamp) และข้าม tag อย่าง `[ar:...]`
    static func parseLRC(_ text: String) -> [LyricLine] {
        let timestamp = /\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]/
        var entries: [(time: Double, text: String)] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var times: [Double] = []
            while let match = rest.prefixMatch(of: timestamp) {
                let minutes = Double(match.1) ?? 0
                let seconds = Double(match.2.replacingOccurrences(of: ":", with: ".")) ?? 0
                times.append(minutes * 60 + seconds)
                rest = rest[match.range.upperBound...]
            }
            guard !times.isEmpty else { continue }
            let lyric = rest.trimmingCharacters(in: .whitespaces)
            for time in times {
                entries.append((time, lyric))
            }
        }

        return entries
            .sorted { $0.time < $1.time }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
    }
}
