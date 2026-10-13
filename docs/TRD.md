# Pathfinder — Technical Requirements Document (TRD)

**Version:** 0.2 · **Stack:** Swift 6, SwiftUI, Observation (`@Observable`), macOS 14+, SwiftPM / XcodeGen (`project.yml`)

## 1. Architecture

```
Views (SwiftUI)  ──reads/writes──▶  Stores / State (@Observable)
      │                                   │
      └──────── actions ──────▶  Services (YTDLPService actor, QueueManager, ClipboardMonitor,
                                          DependencyChecker, CommandBuilder, PresetManager)
                                          │
                                   ProcessRunner ──▶ yt-dlp / ffmpeg (child processes)
```

| Layer | Files |
|---|---|
| App | `App/PathfinderApp.swift`, `App/AppState.swift` |
| Models | `VideoInfo`, `FormatInfo`, `DownloadItem`, `DownloadOptions`, `ProgressUpdate`, … |
| Stores | `SettingsStore` (persisted via UserDefaults), `LogStore` |
| Services | `YTDLPService`, `QueueManager`, `ProcessRunner`, `DependencyChecker`, `ClipboardMonitor` |
| Views | `MainWindow`, `Queue`, `Settings`, `Sheets`, `MenuBar`, `Tabs`, `Components` |

## 2. Required engine fixes (blockers for the new design)

| # | Issue (current code) | Required change |
|---|---|---|
| E1 | Analyze never invoked from UI; `currentVideoInfo`, `isAnalyzing`, `error` never set | Add `AppState.analyze()` that calls `YTDLPService.analyze`, sets loading/error/result; bind to Analyze button and menu command |
| E2 | Progress parsing commented out; template emits `%(progress)s` | Use `--progress-template "download:%(progress._percent_str)s\|\|\|%(progress._speed_str)s\|\|\|%(progress._eta_str)s\|\|\|%(progress.downloaded_bytes)s\|\|\|%(progress.total_bytes_estimate)s"`; parse via `ProgressUpdate.parse`; yield `.progress` |
| E3 | `.completed(outputPath: nil)` always | Add `--print after_move:filepath`; capture path for Open File / Open Folder / toast |
| E4 | Completion emitted regardless of exit code | Await `process.terminationStatus`; emit `.error` with mapped message on non-zero; keep stderr tail |
| E5 | Cancel only cancels the Swift `Task` | Keep the `Process` per item; `terminate()` on cancel/pause; kill the process group so `ffmpeg` children stop |
| E6 | `processNext()` starts one item per call; `maxConcurrent` ignored from settings | Loop while `activeCount < maxConcurrent`; sync `maxConcurrent` from `SettingsStore` (clamp 1–5) |
| E7 | `listFormats` re-runs analysis; `listSubtitles` returns `[:]` | Reuse the cached `VideoInfo`; decode subtitles from it |
| E8 | Settings Detect / Update buttons empty; Setup Assistant not driven by `DependencyChecker` | Implement detection + `updateBinary`; show Setup Assistant when `!DependencyStatus.isReady` |
| E9 | `SettingsStore` computed properties backed by UserDefaults are **not observed** by `@Observable` | Convert to stored properties with `didSet` persistence (pattern used by `showThumbnail`), or use `@AppStorage` in views |

**Status (phase 1):** E1–E9 implemented. E8 covers Detect/Update, Homebrew install and manual path; the "auto-install binary" option is not built. Progress template verified against yt-dlp 2026.08.19.

**Status (phases 2–3):** `Theme.swift` (light/dark tokens, appearance System/Dark/Light), `HomeView`, `ResultsView` (video box honors F14, skeletons, Video/Audio tabs), `QualityOption` builder with per-row Download, and a basic `DownloadsPanel` are implemented in `Views/Simple/`. Simple mode uses the new flow; Advanced mode keeps the previous layout. Also done (phases 4–6): completion toast, macOS notifications (only inside a bundled `.app`), in-window Settings modal, yt-dlp auto-install, queue persistence (`QueueStore`, interrupted downloads restore as Paused), and 14 tests in `Tests/` (`swift test`; `LIVE=1 swift test` also runs a real analyze and download against archive.org).

**Known gaps / decisions:** Advanced mode, CLI preview and presets are kept as-is behind the Simple/Advanced switch. Sites that need sign-in or bot checks (e.g. YouTube from some networks) fail with a friendly message; a cookies option is not built. ffmpeg has no auto-install (Homebrew or manual path only).

## 3. New components

### 3.1 Quality option model
```swift
struct QualityOption: Identifiable {
    enum Kind { case video, audio }
    let id: String
    let kind: Kind
    let quality: String      // "1080p" / "320 kbps"
    let label: String        // "Full HD"
    let container: String    // "MP4" / "MP3" / "M4A"
    let estimatedBytes: Int64?
    let isRecommended: Bool
    let formatSelector: String   // yt-dlp -f expression
    let audioExtract: (format: String, quality: String)?
}
```
- Builder `QualityOptions.make(from: VideoInfo)`: group `FormatInfo` by height, keep best per height, map to labels, cap at 6; audio rows are fixed presets converted with `-x --audio-format … --audio-quality …`.
- Video selector: `bestvideo[height<=H]+bestaudio/best[height<=H]` with `--merge-output-format mp4`.
- Recommended: highest option ≤1080p; audio: 320 kbps.
- Size estimate: `filesize ?? filesizeApprox`, summing video + best audio.

### 3.2 Theme
`Theme.swift` with light/dark palettes from the design tokens (bg, surface, border, text/text2/text3, accent #2563EB, success, danger, warn). Prefer an asset catalog or dynamic `Color(nsColor:)`. Appearance setting: system / dark / light via `.preferredColorScheme`.

### 3.3 Views
`HomeView` (hero, input, error, clipboard banner), `ResultsView` (video box + tabs + rows), `DownloadsPanel` (replaces `QueueListView`/`QueueItemRow` in the simple flow), `Toast`, `SettingsView` (modal-sized content). Rows use flexible grid columns rather than fixed widths.

### 3.4 State machine
`AppState.phase`: `home | analyzing | results | linkError`. Per-item status maps to `DownloadStatus` (+ a `merging` state derived from `postProcessing`).

## 4. Feature F14 — thumbnail visibility (implemented)

**Setting**
- `SettingsStore.showThumbnail: Bool` — stored property, default `true`, initialized from `UserDefaults["showThumbnail"]`, persisted in `didSet`. Being a stored property, `@Observable` tracks it, so open views update immediately.

**UI**
- `SettingsView` → General: `Toggle("Show Video Thumbnail", isOn: $s.showThumbnail)`.
- `URLInputView` (video info box): the `AsyncImage` is rendered only when `settings.showThumbnail` is true and `VideoInfo.thumbnail` is a valid URL. When false, the image view is not created, so **no network request is made**, and the text block fills the box.
- `ResultsView` (to build): same condition; when hidden, the duration is shown in the metadata line instead of as an overlay badge, and the skeleton in the Analyzing state omits the thumbnail block.

**Tests**
- Default value is `true` on a clean `UserDefaults` suite.
- Setting `false` persists across a new `SettingsStore` instance.
- Snapshot/UI check: with `false`, no `AsyncImage` in the video box.

## 5. Command building
`CommandBuilder` composes `DownloadOptions.toArgs()` + quality selector + `-P <dir>` + the progress/print flags above. Per-row Download builds a `DownloadOptions` copy so Advanced settings still apply.

## 6. Error mapping
Map `yt-dlp` stderr to user messages:

| Pattern | Message |
|---|---|
| `Unsupported URL` | "This link doesn't lead to a video" |
| `HTTP Error 4xx/5xx`, `Unable to download` + network | "Connection lost. Check your internet, then try again." |
| `Private video`, `Sign in` | "This video is private or needs a login" |
| `not available in your country` | "This video isn't available in your region" |
| `ffmpeg not found` | "A required tool is missing" → open Setup Assistant |
| other | "Something went wrong" + "Show details" (log) |

## 7. Persistence
- Settings: UserDefaults.
- Queue (P2): JSON file in `~/Library/Application Support/Pathfinder/queue.json`; restore queued/paused items, mark interrupted as failed.

## 8. Security & privacy
- Pass arguments as an array to `Process` (no shell string) to prevent injection from URLs or titles.
- Only `yt-dlp` makes network requests to media hosts; thumbnail fetching is optional (F14).
- App sandbox/entitlements must allow user-selected folder write and running user-installed binaries; confirm in `Pathfinder.entitlements`.

## 9. Testing
- Unit: `ProgressUpdate.parse`, `QualityOptions.make`, error mapping, `SettingsStore` defaults/persistence.
- Integration: `YTDLPService` against a stub script emitting known output; queue concurrency (N=1..5) and cancel kills the process.
- Manual: both themes, 900×650 and larger windows, missing-tools first run.

## 10. Milestones
1. Engine fixes E1–E9
2. Theme + Home/Analyzing/Results + errors
3. Quality picker + per-row download
4. Downloads panel, toast, notifications
5. Settings modal, clipboard banner, missing-tools state
6. Advanced mode decision, persistence, tests
