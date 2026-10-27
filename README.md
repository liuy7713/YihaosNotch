# Yihao's Notch

A quiet companion for the MacBook Pro's notch, inspired by Boring Notch. The notch
stays a plain black notch until it has something to say, and opens into a small panel
when you want it.

**Closed**, the notch grows small "wings" either side for whatever matters right now:
the album art and bars of what's playing, a countdown before your next event, a
running timer, the charger connecting (charging or just plugged in, and the charger's
wattage), or your AirPods switching on.

**Open** (rest the pointer on the notch, click it, or swipe down on it with two
fingers), it shows:

- **Now Playing** for Music and Spotify: artwork, controls, a scrubber and a synced
  lyric line.
- **Calendar**: a five-day strip you can scroll a week either way, and the agenda for
  the chosen day. Zoom, Teams, Meet and Webex links get a Join button that opens the
  meeting straight in its app.
- **Timer**: click the clock in the header.
- **Camera mirror**: a quick check before a call, with Center Stage (keeps you framed as
  you move) on cameras that have it, such as recent MacBooks' 12 MP camera, toggled from a
  button in the mirror.

Optionally, the volume and brightness keys show a small indicator in the notch instead
of the macOS pop-up.

It runs only on the built-in display, sits at 0% CPU when idle, and uses about 20–30 MB
of memory.

## Requirements

- A MacBook with a notch, so Apple silicon (it does nothing on Macs without one, or at
  a display resolution that puts the menu bar below the notch). Any notched model and
  display scaling works: sizes are read from the screen.
- macOS 15 or later. (On an Intel Mac, which never has a notch, macOS says the app
  isn't supported.)
- Xcode, to build it (not to use it: see [Releasing](#releasing)).

## Permissions

The welcome screen on first launch asks for each one in turn, with a reason, and any
can be skipped; a skipped one is asked for when its feature is first used.

| Permission | Used for |
|---|---|
| Calendars | Showing your events and meeting links. Read-only. |
| Camera | The mirror. The camera runs only while the mirror is on screen. |
| Automation (Music, Spotify) | Reading what's playing and controlling playback. |
| Accessibility | Only for the optional volume/brightness indicator, which needs to catch those keys before macOS does. Off by default. A Magic Keyboard's brightness keys arrive as ordinary key presses (codes 144/145), so with this on the app also sees key presses: on its own thread, reading nothing but the key code and passing every other key straight back. |

## Privacy

Nothing leaves your Mac except lyrics lookups: the title, artist, album and length of
the current track are sent to [LRCLIB](https://lrclib.net), a free lyrics database.
There are no analytics.

Display brightness has no public API, so it's set through Apple's private
DisplayServices framework (as MonitorControl and similar tools do). If that ever stops
working, the brightness keys simply fall back to macOS.

## Build and run

```sh
./scripts/make-signing-identity.sh   # once: a local signing identity (then back it up, below)
./scripts/build.sh                   # builds ~/Library/Caches/YihaosNotch/Yihao's Notch.app
./scripts/build.sh --install         # also installs to /Applications and launches it
```

Signing every build with the same identity lets macOS remember the app's permissions
across rebuilds; without it, the build is signed ad hoc and permissions are asked
for again after every rebuild. The identity lives in its own keychain in
`~/.yihaos-notch/signing`, outside the project so it never syncs anywhere. Its password is kept in your login keychain with no trusted apps, so
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
security delete-keychain ~/.yihaos-notch/signing/*.keychain-db && rm -rf ~/.yihaos-notch/signing
./scripts/make-signing-identity.sh --restore ~/path/to/YihaosNotch-signing-backup.p12
```

Open the app again (from Finder or Spotlight), or click the gear in the open panel, to
show Settings; it has no Dock icon or menu bar item. Settings opens beneath the notch;
its footer has Show Tour… (the welcome's tour and permissions) and Quit. ⌘, ⌘W, Esc
and ⌘Q work, and right-clicking the gear offers Settings… and Quit.

## Releasing

To give the app to someone, build a disk image:

```sh
./scripts/release.sh                 # writes dist/YihaosNotch-<version>.dmg
```

They open it, drag the app into Applications, and the welcome screen takes it from
there: no Terminal, no Xcode. Before each release, raise the version with
`./scripts/bump-version.sh patch|minor|major` (fixes, features, big changes); it also
raises the build number, which macOS uses to tell which copy is newer. Each release is
tagged `v<version>` in git. The first run asks whether the script
may control Finder, which it uses to lay out the disk image window.

**Without a Developer ID** (today), the image is signed with the local identity. It
works, but macOS can't verify who made it, so each person allows it once in System
Settings › Privacy & Security › Open Anyway; the script writes `dist/HOW-TO-OPEN.txt`
with those steps to send along.

**With a Developer ID** (Apple Developer Program, $99 a year), the same command signs
the app and image with it and has Apple notarize both, so they open anywhere without a
warning. Once, after installing the "Developer ID Application" certificate from your
developer account, store the notarization credentials (it asks for an app-specific
password, created at account.apple.com):

```sh
xcrun notarytool store-credentials YihaosNotch --apple-id YOU@EXAMPLE.COM --team-id TEAMID
```

Releases signed with a Developer ID are a different identity from your local builds,
so installing one over a local build asks for the permissions again (and vice versa).

### Development flags

Pass these to the built app, e.g. `open ~/Library/Caches/YihaosNotch/Yihao\'s\ Notch.app --args --preview-open`:

| Flag | Effect |
|---|---|
| `--preview-open` | Opens the panel at launch and keeps it open (for screenshots). |
| `--preview-cycle` | Opens and closes the panel every 1.5 s (for tuning animations). |
| `--preview-timer` | Starts a 25-minute timer and shows the timer view. |
| `--preview-swap` | Flips the right column between calendar and timer every 2 s. |
| `--simulate-notch WxH` | Lays out as if the notch were W×H points, to check other models and display scalings (a 14" ranges from about 140×24 to 225×38). |
| `--music-idle-seconds N` | Paused music leaves the closed notch after N seconds instead of 120. |
| `--preview-settings` | Opens Settings at launch. |
| `--preview-welcome N` | Shows the welcome screen at page N (0–2), even if it has been finished. |
| `--preview-hud` | Cycles the volume, brightness, headphone and charging indicators (charging shows the real power state). The real volume and brightness are untouched. |

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
| `Onboarding/` | First-launch welcome: what it is, how to open it, permissions one at a time |
