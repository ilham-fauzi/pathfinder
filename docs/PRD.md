# Pathfinder — Product Requirements Document (PRD)

**Version:** 0.2 (redesign) · **Platform:** macOS 14+ · **Status:** Draft, aligned to the "Media Downloader" design (dark + light, 9 screens)

## 1. Overview
Pathfinder is a macOS app that downloads video or audio from a link, powered by `yt-dlp` and `ffmpeg`. v0.2 shifts the primary experience from a power-user yt-dlp GUI to a **simple, guided flow**: paste a link, pick a quality, download. Advanced options remain available but are secondary.

## 2. Goals / Non-goals
**Goals**
- A non-technical user can go from link to saved file in ≤3 clicks.
- Clear status at every step: analyzing, downloading, merging, done, failed.
- Friendly, plain-language errors with a way to recover.
- Dark and light appearance that match the design.

**Non-goals (v0.2)**
- Playlist/batch selection UI (open question, see §9).
- Built-in media player or editing.
- Windows/Linux builds.

## 3. Target users
- **Casual user:** wants one file, in a sensible quality, no jargon.
- **Power user:** wants formats, subtitles, post-processing, network options and the CLI command (kept under Advanced).

## 4. User flow
Home → (paste/clipboard suggestion) → Analyze → Results (Video | Audio only) → Download → Downloads panel (Downloading → Merging → Completed | Failed) → Open File / Open Folder.

## 5. Functional requirements

| ID | Requirement | Priority |
|---|---|---|
| F1 | Home screen: hero, URL field, Analyze button | P0 |
| F2 | URL validation with two error states: empty link; link that isn't a video | P0 |
| F3 | Clipboard suggestion banner ("Use the link from your clipboard?") with Use / Dismiss; honors the clipboard-monitoring setting | P1 |
| F4 | Analyzing state with skeleton placeholders for thumbnail and quality rows | P0 |
| F5 | Results screen: video box (thumbnail, title, channel, duration) and Video / Audio-only tabs with item counts | P0 |
| F6 | Simplified quality list: up to 6 video rows (2160p→360p) and 4 audio rows (320/256/192/128 kbps), each with quality chip, friendly label, format tag, estimated size (`~`), per-row Download button | P0 |
| F7 | "Recommended" badge on the best sensible option (1080p video / 320 kbps audio), falling back to the best available | P0 |
| F8 | Downloads panel with per-item name, meta (size, speed, ETA), status, progress bar and percentage; summary line ("1 downloading · 1 queued") | P0 |
| F9 | Merging phase shown as indeterminate progress ("Merging files…"), Cancel disabled | P0 |
| F10 | Actions: Cancel (active/queued), Open File / Open Folder (completed), Try Again / Remove (failed), Open downloads folder | P0 |
| F11 | Completion toast with Open file and dismiss; optional macOS notification | P1 |
| F12 | Failed state with plain-language reason (e.g. connection lost) | P0 |
| F13 | Settings: download folder, appearance (Dark / Light, plus System), simultaneous downloads (1–5) | P0 |
| **F14** | **Show/hide video thumbnail** in the video box. Toggle in Settings → General ("Show Video Thumbnail"). Default: on. Persists across launches. When off, the video box shows text details only (title, channel, duration, views) and no thumbnail is loaded from the network. | **P1** |
| F15 | Missing-tools state: detect missing `yt-dlp` / `ffmpeg` and guide install (Setup Assistant) | P0 |
| F16 | Advanced mode (format, post-processing, subtitles, network, filesystem, advanced tabs), CLI preview, presets | P2 (retained, de-emphasized) |
| F17 | Queue persistence across launches | P2 |

### F14 detail — thumbnail visibility
- **Why:** privacy (no image requests to the video host), bandwidth savings, a denser layout, and avoiding spoiler or unwanted imagery.
- **Behavior:** applies everywhere the video box is shown (Results, and the info card on the main window). Turning it off takes effect immediately without re-analyzing. The duration badge overlaid on the thumbnail moves into the metadata line when no thumbnail is shown.
- **Acceptance criteria:**
  1. With the toggle on, the thumbnail shows when the video has one.
  2. With the toggle off, no thumbnail image is requested or rendered; title, channel and duration still show.
  3. The value survives app restart.
  4. Changing it in Settings updates an open video box live.

## 6. Non-functional requirements
- Responsive: UI never blocks during analysis or download.
- Accessibility: labeled controls, ≥4.5:1 text contrast in both themes, full keyboard navigation, VoiceOver labels on icon-only buttons.
- Minimum window 900×650; layout must flex in larger windows.
- No data leaves the device except requests made by `yt-dlp` to the media host.

## 7. Success metrics
- Time from launch to first completed download (target < 60 s for a new user with tools installed).
- Share of downloads that complete without a retry.
- Share of failures that show an actionable message (target 100%).

## 8. Risks
- Site changes break extraction → keep `yt-dlp` updatable from Settings.
- `ffmpeg` missing → merge/audio conversion fails (F15 mitigates).
- Size estimates are approximate for some sources.

## 9. Status
F1–F15 and F17 are implemented. F16 (Advanced mode) is retained unchanged. Not implemented: cookies / sign-in support for restricted videos, playlist selection, ffmpeg auto-install.

## 10. Open questions
1. Keep Advanced mode, CLI preview and presets visible, or behind a disclosure?
2. Support playlists in v0.2?
3. Add a "System" appearance option (design only shows Dark/Light)?
