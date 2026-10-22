# Yihao's Notch

A personal replacement for Boring Notch on the MacBook Pro's built-in display.

## Build & run

```sh
./scripts/build.sh            # builds build/Yihao's Notch.app
./scripts/build.sh --install  # also installs to ~/Applications and relaunches
```

Launch with `--preview-open` to pin the panel open (useful for screenshots), or
`--preview-cycle` to open and close it every 1.5 s (useful for recording and tuning
the animations, e.g. with `screencapture -v`). `--preview-timer` starts a 25-minute
timer and shows the timer view; `--preview-hud` cycles the volume, brightness and
headphone indicators with sample values (the real volume and brightness are untouched);
`--preview-swap` flips the right column between calendar and timer every 2 s:

```sh
open "build/Yihao's Notch.app" --args --preview-open
```

The app icon is drawn in code (`scripts/icon/render-icon.swift`); after changing it,
run `./scripts/make-icon.sh` to regenerate `Resources/AppIcon.icns`.

Signing uses a local self-signed identity in `.signing/` (not committed) so macOS
keeps Calendar/Camera/Automation permissions across rebuilds.

## Layout

| Path | What |
|---|---|
| `Window/` | Overlay panel, built-in screen + notch detection, hover/click logic |
| `Core/` | Settings, theme, notch shape, view model (state + live-activity priority) |
| `Views/` | Root morphing shape, open panel, compact live activities |
| `Features/NowPlaying` | Music + Spotify via distributed notifications and AppleScript |
| `Features/Calendar` | EventKit events, meeting-link detection (Zoom/Teams/Meet/Webex) |
| `Features/Battery` | IOKit power-source notifications |
| `Features/Camera` | Mirror; the camera runs only while the mirror is visible |
| `Features/System` | Volume/brightness keys (event tap, opt-in), headphone connection |
| `Features/Timer` | Countdown timer, opened from the header clock |
| `Settings/` | Settings window |
