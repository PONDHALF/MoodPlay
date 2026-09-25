<div align="center">

<img src="MoodPlay/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png" width="128" alt="MoodPlay icon">

# MoodPlay

**Your Spotify music, right on the Mac Lock Screen.**

When you step away from your desk, MoodPlay locks your Mac and shows the song you're playing on the Lock Screen: an album-colored glow, the cover or a spinning vinyl, and time-synced lyrics. Unlock with Touch ID as usual, and it gets out of the way.

![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0A84FF)
![Spotify](https://img.shields.io/badge/works%20with-Spotify%20desktop-1DB954?logo=spotify&logoColor=white)
[![Release](https://img.shields.io/github/v/release/PONDHALF/MoodPlay?label=download&color=8E5CFF)](https://github.com/PONDHALF/MoodPlay/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

</div>

---

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [First launch & permissions](#first-launch--permissions)
- [Usage](#usage)
- [Menu reference](#menu-reference)
- [Recommended macOS settings](#recommended-macos-settings)
- [How it works](#how-it-works)
- [Performance & battery](#performance--battery)
- [Privacy](#privacy)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Project structure](#project-structure)
- [Contributing](#contributing)
- [Credits](#credits)
- [License](#license)

---

## Features

| | |
|---|---|
| 🔒 **Lives on the Lock Screen** | Your music shows up on the real macOS Lock Screen. The clock, password field, and Touch ID stay exactly where macOS puts them. |
| 🎨 **Album-driven glow** | Colors from the album cover glow softly from the edges of the screen and crossfade when the track changes. |
| 💿 **Two themes** | **Album cover**: the cover with the track details. **Vinyl**: a spinning record with the cover as its label and a tonearm that lifts when you pause. |
| 🎤 **Synced lyrics** | Time-synced lyrics from [LRCLIB](https://lrclib.net). The current line is highlighted and centered, and nearby lines softly blur. Instrumental breaks show animated dots. |
| ⏱️ **Locks when you're away** | Locks your Mac on its own after 30 s, 1, 2, or 5 minutes of inactivity, but only while music is playing. |
| ⌨️ **Instant hotkey** | Press **⌘⇧M** to lock right away when you get up. Locking with **⌃⌘Q** shows your music too. |
| 🖥️ **Every display** | Shows on all connected screens and adapts when displays are added or removed. |
| 🪶 **Lightweight** | Menu bar only (no Dock icon). It does no work while you're using your Mac, and animations run on Core Animation. |
| 🔑 **No login required** | No Spotify account connection and no API keys. It talks to the Spotify desktop app locally. |

---

## Requirements

- **macOS 14 Sonoma** or later
- **Spotify desktop app** (the web player isn't supported)
- **Xcode 26** or later, only if you build from source (Swift 6.2)

---

## Installation

### Option 1: Download the installer (recommended)

1. Go to the [**latest release**](https://github.com/PONDHALF/MoodPlay/releases/latest) and download **`MoodPlay-x.y.z.dmg`**.
2. Open the DMG and drag **MoodPlay** into **Applications**.
3. Open MoodPlay from **Applications**. A waveform icon appears in the menu bar.
4. In the MoodPlay menu, turn on **Launch at login** if you want it to start with your Mac.

The app is a universal build, so it runs natively on both Apple Silicon and Intel Macs.

#### "Apple could not verify MoodPlay…" on first open

MoodPlay is open source and isn't signed with a paid Apple Developer ID, so macOS shows this warning the first time you open it. To open it anyway:

1. Try to open MoodPlay once, then click **Done** in the warning.
2. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the MoodPlay message.
3. Confirm with **Open Anyway** and your password or Touch ID.

You only need to do this once. If you prefer Terminal, this command does the same thing:

```bash
xattr -dr com.apple.quarantine /Applications/MoodPlay.app
```

> 🔐 Want to check the download? Every release includes a `.sha256` file:
> ```bash
> shasum -a 256 -c MoodPlay-x.y.z.dmg.sha256
> ```

#### Updating

Quit MoodPlay from its menu, download the new DMG, and replace the app in **Applications**. Because each build has its own ad-hoc signature, macOS may ask for the Spotify permission again after an update. Click **OK**.

### Option 2: Build from source

```bash
git clone https://github.com/PONDHALF/MoodPlay.git
cd MoodPlay
open MoodPlay.xcodeproj
```

1. In Xcode, select the **MoodPlay** target → **Signing & Capabilities** → choose your **Team**.
   A free Apple ID works for personal use.
2. Press **⌘R** to build and run.

### Building the installer yourself

To produce the same universal DMG that's published on the Releases page:

```bash
./scripts/build-release.sh
# → build/MoodPlay-<version>.dmg and build/MoodPlay-<version>.dmg.sha256
```

The build is ad-hoc signed by default. If you have a Developer ID certificate, pass it to create a build you can notarize:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-release.sh
```

---

## First launch & permissions

MoodPlay asks for **one** permission:

| Permission | Why | When |
|---|---|---|
| **Automation → Spotify** | Reads the current track, playback position, and artwork URL from the Spotify app. | The first time Spotify is running while MoodPlay is open. |

Click **OK** when macOS asks. MoodPlay **never launches Spotify by itself**. It only talks to Spotify when Spotify is already running.

> **Denied by accident?** The menu shows a warning with a shortcut to the right settings page.
> You can also go to **System Settings → Privacy & Security → Automation → MoodPlay** and enable **Spotify**.

No Accessibility or Screen Recording permission is needed. The ⌘⇧M hotkey uses the system hotkey API.

---

## Usage

1. Play something in Spotify.
2. Walk away. After the idle time you set, MoodPlay **locks your Mac** and your music fades in on the Lock Screen.
   You can also press **⌘⇧M** (or choose **Lock & show now** in the menu), or lock the usual way with **⌃⌘Q**.
3. Come back and unlock with **Touch ID** or your password. The music screen disappears.

While music is playing, the display stays on so you can enjoy it. Pause the music and the display turns off according to your macOS settings.

**Don't want your Mac to lock while you're just reading?** Turn off **Lock automatically when idle**. MoodPlay will then only lock when you press ⌘⇧M, and it still shows your music whenever you lock the Mac yourself.

---

## Menu reference

Click the **waveform** icon in the menu bar:

| Item | Description |
|---|---|
| *Now playing* | The current track and whether it's playing or paused. |
| **Theme** | **Album cover** or **Vinyl**. |
| **Show lyrics** | On: artwork on the left, lyrics on the right. Off: artwork only. |
| **Lock automatically when idle** | Lock the Mac and show your music when it has been idle while music plays. |
| **Idle time before locking** | 30 seconds, 1, 2, or 5 minutes. |
| **Lock & show now ⌘⇧M** | Lock the Mac immediately and show your music. |
| **Launch at login** | Start MoodPlay when you log in. |
| **Quit MoodPlay** | ⌘Q |

> The app's interface is currently in Thai. The items above are shown in English for readability.

---

## Recommended macOS settings

MoodPlay keeps the display awake **only while it's on the Lock Screen and music is playing**. Everywhere else, your normal macOS settings apply.

For MoodPlay to lock and show your music before your Mac dims or starts the screen saver, open **System Settings → Lock Screen** and set:

- **Start Screen Saver when inactive** to longer than MoodPlay's idle time (or **Never**)
- **Turn display off when inactive** to longer than MoodPlay's idle time

Example: MoodPlay at **2 minutes**, display off at **10 minutes**.

---

## How it works

```mermaid
flowchart LR
    S[Spotify app] -- PlaybackStateChanged<br/>notification --> M[SpotifyMonitor]
    M -- AppleScript<br/>(only while visible) --> S
    M -- track change --> L[LyricsStore]
    L -- HTTPS --> R[(LRCLIB)]
    A[AppModel<br/>idle scheduler] -- lock & show / hide --> O[OverlayController]
    O -- SkyLight space<br/>above Lock Screen --> V[MoodView<br/>on every screen]
    M --> V
    L --> V
```

- **Track info** comes from the distributed notification that Spotify broadcasts on every play, pause, or skip. AppleScript is used only for the first read at launch, for the artwork URL, and to re-sync the position every 3 s while your music is on screen, in case you seek.
- **Lyrics** are fetched from LRCLIB's `/api/get`, with `/api/search` as a fallback. They're parsed from the LRC format and cached for the 40 most recent tracks.
- **Idle detection** doesn't poll. MoodPlay works out when the idle threshold will be reached and sets a single timer for that moment.
- **Locking** uses the same mechanism as the system's Lock Screen command, so you unlock with Touch ID or your password as usual.
- **Showing on the Lock Screen** uses a private SkyLight (WindowServer) API to create a space above the Lock Screen and place MoodPlay's windows in it. The windows ignore the mouse and keyboard, so authentication is always handled by macOS. If the API isn't available, MoodPlay still locks, just without the music screen.

---

## Performance & battery

MoodPlay is built to be close to free when you're not looking at it.

**While you're using your Mac**
- No repeating timers and no AppleScript calls. It only listens for Spotify's notifications.
- Artwork isn't downloaded, and the music screen's windows and views are destroyed so their memory is freed.
- Nothing runs while the display is asleep, the screen saver is active, or another user is logged in.

**While on the Lock Screen**
- Lyrics and the progress bar don't redraw on a fixed timer. Lyrics update only when a new line starts, and the progress bar once per second.
- The background is a pre-blurred 32 px image scaled up, so there's no full-screen live blur. It drifts using Core Animation, which runs outside the app process.
- The vinyl record is drawn once per cover and rotated by Core Animation.
- Only the lyric lines on screen are created.

**Reliability**
- Every AppleScript call has a 2 s timeout, so a frozen Spotify can't freeze MoodPlay.
- Scripts are compiled once and reused.

---

## Privacy

- **No accounts, no analytics, no tracking.**
- Network requests go only to:
  - `lrclib.net`: the track title, artist, album, and duration, to look up lyrics
  - Spotify's image CDN: to download the current album cover
- Lyrics and artwork are kept in memory only. They're never written to disk or cached by the network layer. The only thing saved is your menu settings (UserDefaults).

---

## Troubleshooting

<details>
<summary><b>The menu says nothing is playing, but Spotify is playing</b></summary>

- Check for a permission warning in the menu and click **Open permission settings…**.
- Make sure you're using the Spotify **desktop app**, not the web player.
- Reset the permission and try again:
  ```bash
  tccutil reset AppleEvents me.pondhalf.moodplay.MoodPlay
  ```
  Then relaunch MoodPlay and play a track. macOS will ask again.
</details>

<details>
<summary><b>macOS says MoodPlay "can't be opened" or "could not be verified"</b></summary>

This is expected for apps without a paid Developer ID. See [first open instructions](#apple-could-not-verify-moodplay-on-first-open).
</details>

<details>
<summary><b>My Mac never locks on its own</b></summary>

- **Lock automatically when idle** must be on, and music must be **playing** (not paused).
- Your screen saver or display-off time must be **longer** than MoodPlay's idle time. See [Recommended macOS settings](#recommended-macos-settings).
- Try **⌘⇧M** to confirm locking works.
</details>

<details>
<summary><b>The Mac locks, but no music shows on the Lock Screen</b></summary>

- Make sure Spotify has a track loaded. MoodPlay only shows up when there's something to show.
- A macOS update may have changed the private API MoodPlay uses for the Lock Screen. Please [open an issue](https://github.com/PONDHALF/MoodPlay/issues) with your macOS version.
</details>

<details>
<summary><b>⌘⇧M does nothing</b></summary>

Another app may already use ⌘⇧M. Quit apps with global shortcuts one at a time to find the conflict.
</details>

<details>
<summary><b>"Lyrics not found for this song"</b></summary>

LRCLIB is a free, community-maintained database, and some tracks aren't in it yet. You can contribute lyrics at [lrclib.net](https://lrclib.net).
</details>

<details>
<summary><b>Two waveform icons in the menu bar</b></summary>

Two copies are running, for example one from Xcode and one from Applications. Quit one of them.
</details>

<details>
<summary><b>The new app icon doesn't show in Finder or System Settings</b></summary>

macOS caches icons. Run:
```bash
killall iconservicesagent Dock
```
Then reopen System Settings.
</details>

---

## Limitations

- **Lock Screen display relies on a private macOS API** (SkyLight). It works on macOS 14 through 27, but a future macOS update could break it. If that happens, MoodPlay still locks your Mac, just without the music screen.
- **Spotify desktop only.** Apple Music and other players aren't supported yet.
- **Not on the Mac App Store.** MoodPlay needs App Sandbox off to talk to Spotify, and it uses private macOS functions to lock the screen and to show on the Lock Screen.
- **Lyrics quality** depends on LRCLIB's community data.

---

## Project structure

```
MoodPlay/
├── MoodPlayApp.swift        # App entry, menu bar menu, AppModel (settings, idle scheduling,
│                            # lock/sleep handling), themes, global hotkey
├── SpotifyMonitor.swift     # Spotify notifications + AppleScript, playback anchor, artwork loading
├── LyricsStore.swift        # LRCLIB client, LRC parser, lyrics cache, shared HTTP session
├── OverlayController.swift  # Lock Screen space (SkyLight), windows per screen, screen lock, power assertion
├── MoodView.swift           # Lock Screen UI: album glow, cover / vinyl, progress, lyrics
├── MoodPlay.entitlements    # Apple Events automation entitlement
└── plan.md                  # Original design plan (Thai)
scripts/
└── build-release.sh         # Universal build + DMG installer
```

---

## Contributing

Issues and pull requests are welcome. Before opening a PR:

1. Build with **Swift 6 language mode**. The project should compile with no concurrency warnings.
2. Keep the performance principles above: no work while hidden, and no per-frame SwiftUI updates for things Core Animation can do.
3. Describe how you tested it (Spotify playing or paused, single or multiple displays, macOS version).

Ideas on the roadmap: Apple Music support, more themes (e.g. a visualizer), and text colors picked from the album art.

---

## Credits

- Lyrics by **[LRCLIB](https://lrclib.net)**, a free and open synced-lyrics database.
- The Lock Screen technique is based on **[SkyLightWindow](https://github.com/Lakr233/SkyLightWindow)** by Lakr Aream (MIT).
- Built with SwiftUI, AppKit, and Core Animation.

> MoodPlay isn't affiliated with, endorsed by, or connected to Spotify AB.
> "Spotify" is a trademark of Spotify AB.

---

## License

MoodPlay is released under the [MIT License](LICENSE). You're free to use, modify, and share it, as long as you keep the copyright notice.

<div align="center">
<sub>Made by <a href="https://github.com/PONDHALF">PONDHALF</a></sub>
</div>
