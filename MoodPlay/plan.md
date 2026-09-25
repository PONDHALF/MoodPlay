# MoodPlayer — Plan

แอป macOS บน menu bar ที่จะเฟดขึ้นเต็มจอเมื่อไม่ได้ใช้เครื่องนานตามที่ตั้งไว้ หน้าจอนี้แสดงเพลงที่เปิดอยู่ใน Spotify แบบมูด ๆ และเลือกได้ว่าจะแสดงเนื้อเพลงที่ sync ตามเวลาด้วยหรือไม่

## เป้าหมาย
- เมื่อเครื่องว่างครบ N นาที และ Spotify กำลังเล่นอยู่ ให้แสดง overlay เต็มจอทุกจอ
- ขยับเมาส์ คลิก เลื่อน หรือกดคีย์ แล้ว overlay ต้องปิด
- ตั้งค่าได้จากเมนูบาร์ ได้แก่ แสดงเนื้อเพลง (on/off), เปิดเองอัตโนมัติ (on/off), เวลาว่างก่อนเปิด (30 วิ / 1 / 2 / 5 นาที) และปุ่ม "แสดงตอนนี้"
- ไม่ใช้ Spotify Web API และไม่ต้องล็อกอิน

## สิ่งที่ไม่ทำ / ข้อจำกัด
- วาดบน Lock Screen จริงไม่ได้ เพราะ macOS ไม่อนุญาต จึงใช้วิธีขึ้นตอนเครื่องว่างแทน
- เมื่อพับจอหรือกดล็อกเครื่อง overlay จะไม่แสดง
- ไม่ใช้เนื้อเพลงจาก Spotify/Musixmatch เพราะไม่มี API ทางการ

## Tech stack
- Swift + SwiftUI, deployment target **macOS 14**
- `MenuBarExtra` สำหรับเมนู, `NSWindow` แบบ borderless สำหรับ overlay
- ข้อมูลเพลงได้จาก `DistributedNotificationCenter` ร่วมกับ `NSAppleScript`
- เนื้อเพลงดึงจาก LRCLIB (`https://lrclib.net/api`) ซึ่งฟรีและไม่ต้องใช้ key
- ตรวจเวลาว่างด้วย `CGEventSource.secondsSinceLastEventType`
- กันจอดับด้วย IOKit `IOPMAssertion`

## ตั้งค่าโปรเจกต์
- สร้างเป็น Xcode project แบบ macOS App (SwiftUI) หรือ Swift Package ที่ build เป็น `.app` ได้
- **ปิด App Sandbox** เพราะ AppleScript ไปยัง Spotify และ userInfo ของ distributed notification ถูกบล็อกใน sandbox
- เปิด Hardened Runtime และ entitlement `com.apple.security.automation.apple-events`
- ตั้งค่า Info.plist ดังนี้
  - `LSUIElement = YES` เพื่อไม่ให้มีไอคอนใน Dock
  - `NSAppleEventsUsageDescription = "ใช้อ่านเพลงที่เล่นใน Spotify"`

## โครงสร้างไฟล์
```
MoodPlayer/
├── MoodPlayerApp.swift      // @main, MenuBarExtra, AppModel (idle watcher)
├── SpotifyMonitor.swift     // สถานะเพลง, position, artwork
├── LyricsStore.swift        // ดึง + parse LRC, cache
├── OverlayController.swift  // สร้าง/ปิดหน้าต่างเต็มจอ, event monitor, power assertion
└── MoodView.swift           // UI เต็มจอ + LyricsPanel + SyncedLyrics
```

## Architecture
```
Spotify ──notification──▶ SpotifyMonitor ──onTrackChange──▶ LyricsStore ──▶ LRCLIB
            AppleScript ◀─┘   │ @Published track/isPlaying/position/artwork
                              ▼
AppModel (timer 2s: เช็ก idle) ──▶ OverlayController.show() ──▶ MoodView
```
ทุก class ใส่ `@MainActor` และ state ทั้งหมดอยู่บน main thread

## รายละเอียดแต่ละส่วน

### 1. SpotifyMonitor
- `Track { id, name, artist, album, duration(sec) }`
- ฟัง notification `com.spotify.client.PlaybackStateChanged` โดย key ใน userInfo คือ `Player State` (Playing/Paused/Stopped), `Track ID`, `Name`, `Artist`, `Album`, `Duration` (ms) และ `Playback Position` (sec)
- ตอนเปิดแอป notification ยังไม่มา ให้ดึงสถานะครั้งแรกด้วย AppleScript ตัวเดียว คั่นแต่ละค่าด้วย `|~|`
- **ห้ามรัน AppleScript ถ้า Spotify ไม่ได้เปิดอยู่** (เช็กด้วย `NSRunningApplication` และ bundle id `com.spotify.client`) ไม่อย่างนั้น Spotify จะถูกเปิดขึ้นมาเองหรือเด้ง dialog ถามหาแอป
- การคำนวณ position:
  - เก็บค่าเวลาอ้างอิง (anchor) กับเวลาที่บันทึกไว้ แล้วนับเวลาเดินเองด้วย timer ทุก 0.2 วิ
  - sync กับ `player position` ทุก 3 วิ เพื่อรองรับการกรอเพลง
  - แปลง `,` เป็น `.` ก่อน parse Double เพราะเครื่องที่ใช้ locale บางแบบจะคืนทศนิยมเป็นจุลภาค
- artwork: ดึง `artwork url of current track` ผ่าน AppleScript แล้วโหลดด้วย URLSession ก่อนตั้งค่าให้เช็กว่ายังเป็นเพลงเดิมอยู่
- ถ้า Spotify ปิดไป ให้ `isPlaying = false` และ `track = nil`
- ส่งต่อการเปลี่ยนเพลงผ่าน callback `onTrackChange: (@MainActor (Track?) -> Void)?` แทนการใช้ Combine เพื่อเลี่ยงปัญหา isolation ของ Swift 6

### 2. LyricsStore
- `LyricsState`: idle, loading, notFound, instrumental, synced([LyricLine]) และ plain([String])
- ขั้นตอนดึงเนื้อเพลง:
  1. เรียก `GET /api/get?artist_name=&track_name=&album_name=&duration=`
  2. ถ้าไม่ได้ 200 ให้ใช้ `GET /api/search?track_name=&artist_name=` แทน โดยเลือกผลแรกที่มี `syncedLyrics` ก่อน
- ใส่ header `User-Agent: MoodPlayer/1.0 (...)` ตามที่ LRCLIB ขอ
- parse LRC รูปแบบ `[mm:ss.xx] text` และข้าม tag metadata อย่าง `[ar:...]`
- cache ผลตาม track id และทิ้งผลที่ได้มาช้าถ้าเปลี่ยนเพลงไปแล้ว

### 3. OverlayController
- สร้างหน้าต่างหนึ่งบานต่อทุก `NSScreen` โดยใช้ subclass `NSWindow` ที่ override `canBecomeKey` ให้เป็น `true`
- ตั้ง level เป็น `.screenSaver` และ collectionBehavior เป็น `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`
- ตั้ง background เป็น clear ให้ SwiftUI ทำหน้าที่เฟดเอง ไม่ใช้ `NSAnimationContext` เพราะมีปัญหา concurrency
- ตอน show ให้เรียก `NSApp.activate()` และ `NSCursor.hide()`
- event monitor ใช้ทั้ง **local** (คืน `nil` เพื่อกลืน event) และ **global** (เผื่อแอปไม่ได้ active) สำหรับ keyDown, mouseMoved, คลิก และ scroll
- มีช่วงผ่อนผัน 2 วิหลังเปิด กันเมาส์สั่นตอนเพิ่งกดเปิดจากเมนู
- ระหว่างแสดงให้ถือ `kIOPMAssertionTypePreventUserIdleDisplaySleep` ไว้ และ release ตอน hide

### 4. AppModel / idle
- `UserDefaults.register` ค่าเริ่มต้นเป็น showLyrics=true, autoShow=true, idleMinutes=2
- timer ทุก 2 วิ: ถ้า autoShow เปิด, overlay ยังไม่แสดง, `isPlaying` เป็นจริง และเวลาว่าง ≥ idleMinutes×60 ให้เรียก show
- เวลาว่างหาจาก `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)`

### 5. MoodView (UI)
แนวทางคือให้ปกอัลบั้มเป็นตัวกำหนดสีทั้งจอ ส่วนอื่นทำให้เรียบและนิ่ง
- **พื้นหลัง:** ปกขยายเต็มจอ `blur(100)`, saturation 1.35, opacity 0.65 ค่อย ๆ scale และหมุน ±6° แบบ repeatForever รอบละ 18 วิ เมื่อเปลี่ยนเพลงให้ crossfade ด้วย `.id(track.id)` + `.transition(.opacity)`
- **vignette:** ใช้ RadialGradient ไล่จากใสไปดำ 0.92
- **ฝั่งซ้าย:** ปก (มุมโค้ง 6, เงาลึก), ชื่อเพลงตัว serif 46, ศิลปินตัว serif italic (มีไอคอน pause เมื่อหยุด) และแถบเวลาบาง 2pt พร้อมตัวเลข monospacedDigit
- **ฝั่งขวา (เมื่อเปิดเนื้อเพลง):** ใช้ `SyncedLyrics`
  - บรรทัดปัจจุบันขาวเต็ม bold 38
  - บรรทัดที่ผ่านไปแล้ว opacity 0.2 ส่วนบรรทัดที่ยังไม่ถึง opacity 0.38
  - เบลอเพิ่มตามระยะห่างจากบรรทัดปัจจุบัน (สูงสุด 3.5)
  - `ScrollViewReader` เลื่อนบรรทัดปัจจุบันไว้กลางแบบ spring และปิดการ scroll ด้วยมือ
  - บนล่างเฟดด้วย mask gradient
  - เลื่อนเวลาเร็วขึ้น +0.25 วิ ให้บรรทัดขึ้นทันเสียง
- **เมื่อปิดเนื้อเพลง:** ปกขนาดใหญ่อยู่กลางจอ
- **มุมขวาบน:** นาฬิกา ultraLight 72 และวันที่ serif italic
- **ข้อความสถานะ:** "กำลังหาเนื้อเพลง…", "เพลงนี้ไม่มีเนื้อร้อง", "ไม่พบเนื้อเพลงของเพลงนี้" และ "เปิดเพลงใน Spotify แล้วจะขึ้นตรงนี้"
- ไม่ใช้ label ตัวพิมพ์ใหญ่ทั้งหมดอย่าง "NOW PLAYING" และไม่ใส่การ์ดหรือ gradient ประดับ

## ลำดับงาน (milestones)
1. [ ] ตั้งโปรเจกต์ + entitlement + Info.plist แล้วให้ MenuBarExtra ขึ้นได้
2. [ ] SpotifyMonitor แสดงชื่อเพลงในเมนูได้ถูกต้องเมื่อเปลี่ยนเพลงหรือกด pause (ใช้ debug)
3. [ ] OverlayController + MoodView แบบยังไม่มีเนื้อเพลง เปิดได้จากปุ่ม "แสดงตอนนี้" และปิดด้วยเมาส์หรือคีย์
4. [ ] ระบบตรวจเวลาว่าง + power assertion
5. [ ] LyricsStore + SyncedLyrics + toggle เนื้อเพลง
6. [ ] ปรับรายละเอียด เช่น crossfade ตอนเปลี่ยนเพลง, รองรับหลายจอ, กรณีปิด Spotify ระหว่างแสดง

## Acceptance checklist
- [ ] ไม่มีไอคอนใน Dock และมีเฉพาะไอคอน waveform ใน menu bar
- [ ] ครั้งแรกขอสิทธิ์ Automation แค่ครั้งเดียว และถ้าไม่ได้เปิด Spotify อยู่ แอปต้องไม่เปิด Spotify ขึ้นมาเอง
- [ ] เปลี่ยนเพลงแล้วชื่อ ปก และสีพื้นหลังเปลี่ยนภายในประมาณ 1 วิ
- [ ] เนื้อเพลงคลาดจากเสียงไม่เกินประมาณ 0.5 วิ รวมถึงหลังกรอเพลง
- [ ] toggle เนื้อเพลงระหว่างที่ overlay เปิดอยู่แล้ว layout เปลี่ยนทันที
- [ ] แสดงครบทุกจอ และจอไม่ดับระหว่างแสดง
- [ ] ปิดได้ทันทีเมื่อขยับเมาส์หรือกดคีย์ และเคอร์เซอร์กลับมาแสดง
- [ ] build ผ่านใน Swift 6 language mode โดยไม่มี concurrency error

## หมายเหตุสำหรับผู้ใช้
- ตั้ง Screen Saver และเวลาปิดจอใน System Settings ให้นานกว่าค่า idleMinutes ของแอป
- ถ้าเผลอกดปฏิเสธสิทธิ์ ให้ไปเปิดใหม่ที่ System Settings → Privacy & Security → Automation → MoodPlayer → Spotify

## ไอเดียต่อยอด (ทำทีหลัง)
- global hotkey (เช่น ⌘⇧M) สำหรับเปิดเอง
- ธีมอื่น เช่น vinyl หมุน หรือ visualizer
- ดึงสีเด่นจากปกมาใช้เป็นสีตัวอักษร
- รองรับ Apple Music ผ่าน `com.apple.Music.playerInf
o`