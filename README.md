# Yihao's Notch

A quiet companion for the MacBook Pro's notch, inspired by Boring Notch. The notch
stays a plain black notch until it has something to say, and opens into a small panel
when you want it.

**Closed**, the notch grows small "wings" either side for whatever matters right now:
the album art and bars of what's playing, a countdown before your next event, a
running timer, the charger connecting, or your AirPods switching on.

**Open** (rest the pointer on the notch, click it, or swipe down on it with two
fingers), it shows:

- **Now Playing** for Music and Spotify: artwork, controls, a scrubber and a synced
  lyric line.
- **Calendar**: a five-day strip you can scroll a week either way, and the agenda for
  the chosen day. Zoom, Teams, Meet and Webex links get a Join button that opens the
  meeting straight in its app.
- **Timer**: click the clock in the header.
- **Camera mirror**: a quick check before a call.

Optionally, the volume and brightness keys show a small indicator in the notch instead
of the macOS pop-up.

It runs only on the built-in display, sits at 0% CPU when idle, and uses about 20–30 MB
of memory.

## Requirements

- A MacBook with a notch (it does nothing on Macs without one).
- macOS 15 or later.
- Xcode, to build it.

## Permissions

Each is asked for only when the feature that needs it is first used.

| Permission | Used for |
|---|---|
| Calendars | Showing your events and meeting links. Read-only. |
| Camera | The mirror. The camera runs only while the mirror is on screen. |
| Automation (Music, Spotify) | Reading what's playing and controlling playback. |
| Accessibility | Only for the optional volume/brightness indicator, which needs to catch those keys before macOS does. Off by default. |

## Privacy

Nothing leaves your Mac except lyrics lookups: the title, artist, album and length of
the current track are sent to [LRCLIB](https://lrclib.net), a free lyrics database.
There are no analytics.

Display brightness has no public API, so it's set through Apple's private
DisplayServices framework (as MonitorControl and similar tools do). If that ever stops
working, the brightness keys simply fall back to macOS.

## Build and run

```sh
./scripts/make-signing-identity.sh   # once: a local signing identity in .signing/ (then back it up, below)
./scripts/build.sh                   # builds build/Yihao's Notch.app
./scripts/build.sh --install         # also installs to ~/Applications and launches it
```

Signing every build with the same identity lets macOS remember the app's permissions
across rebuilds; without it, the build is signed ad hoc and permissions are asked
for again after every rebuild. The identity lives in its own keychain in `.signing/`
(git-ignored). Its password is kept in your login keychain with no trusted apps, so
each build shows a macOS dialog: click **Allow** (not *Always Allow*). That way no
other software can sign as this app and inherit its permissions. Only allow that
dialog right after you've started `./scripts/build.sh` yourself: any program can
trigger it, so one that appears out of the blue should be denied.

Builds use the hardened runtime with only the entitlements in
`Resources/YihaosNotch.entitlements`.

**Back up the identity** once after creating it, so a damaged keychain never costs you
the app's permissions:

```sh
./scripts/backup-signing-identity.sh            # writes ~/Documents/YihaosNotch-signing-backup.p12
```

Check it once with `./scripts/verify-signing-backup.sh`, which confirms the backup
opens with your passphrase and holds the identity the app is signed with. Keep the
file and its passphrase in your password manager: together they let anyone sign as
this app. If a build ever reports that the signing keychain didn't unlock,
restore the same identity (every permission keeps working):

```sh
security delete-keychain .signing/*.keychain-db && rm -rf .signing
./scripts/make-signing-identity.sh --restore ~/path/to/YihaosNotch-signing-backup.p12
```

Open the app again (from Finder or Spotlight) to show Settings; it has no Dock icon or
menu bar item.

### Development flags

Pass these to the built app, e.g. `open "build/Yihao's Notch.app" --args --preview-open`:

| Flag | Effect |
|---|---|
| `--preview-open` | Opens the panel at launch and keeps it open (for screenshots). |
| `--preview-cycle` | Opens and closes the panel every 1.5 s (for tuning animations). |
| `--preview-timer` | Starts a 25-minute timer and shows the timer view. |
| `--preview-swap` | Flips the right column between calendar and timer every 2 s. |
| `--preview-hud` | Cycles the volume, brightness and headphone indicators with sample values. The real volume and brightness are untouched. |

The media-key handling logs to the unified log:
`log stream --predicate 'subsystem == "com.yihao.YihaosNotch"' --level debug`.

The app icon is drawn in code (`scripts/icon/render-icon.swift`); run
`./scripts/make-icon.sh` after changing it.

## Layout

| Path | What |
|---|---|
| `Window/` | Overlay panel, built-in screen and notch detection, hover/click/swipe handling |
| `Core/` | Settings, theme and transitions, notch shape, view model (state and live-activity priority) |
| `Views/` | The morphing shape, open panel, compact live activities |
| `Features/NowPlaying` | Music and Spotify via distributed notifications and AppleScript; LRCLIB lyrics |
| `Features/Calendar` | EventKit events, meeting-link detection (Zoom/Teams/Meet/Webex) |
| `Features/Battery` | IOKit power-source notifications |
| `Features/Camera` | Mirror; the camera runs only while it's visible |
| `Features/System` | Volume/brightness keys (event tap, opt-in), headphone connection |
| `Features/Timer` | Countdown timer, opened from the header clock |
| `Settings/` | Settings window |
