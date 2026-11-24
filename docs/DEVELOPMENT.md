# Developing Yihao's Notch

For using the app, see the [README](../README.md).

## Build and run

```sh
./scripts/make-signing-identity.sh   # once: a local signing identity and its backup (below)
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

**The identity's backup** is written as it's created (it asks for a passphrase), to
`~/Documents/YihaosNotch-signing-backup-<date>.p12`, so a damaged keychain never costs
you the app's permissions. It's made from the key before it enters the keychain;
afterwards the key can only be exported by typing the keychain's password, which is
never shown, so an identity made before this has the one backup it already has.
Check it once with `./scripts/verify-signing-backup.sh FILE.p12`, which confirms the backup
opens with your passphrase and holds the identity the app is signed with. Keep the
file and its passphrase in your password manager: together they let anyone sign as
this app. If a build ever reports that the signing keychain didn't unlock,
restore the same identity (every permission keeps working):

```sh
security delete-keychain ~/.yihaos-notch/signing/*.keychain-db && rm -rf ~/.yihaos-notch/signing
./scripts/make-signing-identity.sh --restore ~/path/to/YihaosNotch-signing-backup.p12
```

Only one copy runs at a time (see the README). A launch with arguments (the
development flags below) is exempt, so a test build runs beside the installed app.

## Releasing

To give the app to someone, build a disk image:

```sh
./scripts/release.sh                 # writes dist/YihaosNotch-<version>.dmg
```

They open it, drag the app into Applications, and the welcome screen takes it from
there: no Terminal, no Xcode. Before each release, raise the version with
`./scripts/bump-version.sh patch|minor|major` (fixes, features, big changes); it also
raises the build number, which macOS and the app use to tell which copy is newer.
`release.sh` only releases a committed tree, runs `scripts/check.sh` first, refuses a
version that's already tagged on another commit, and tags the commit `v<version>`
when it's done (push with `git push origin HEAD v<version>`). Then
`./scripts/publish-release.sh NOTES.md` publishes it as a GitHub Release, with NOTES.md
(what's new, for people using the app) at the top: the image under its
own name and as `YihaosNotch.dmg` (the README's always-latest download link), with
HOW-TO-OPEN.txt and notes giving the SHA-256 and the signing certificate's hash. `--allow-dirty` makes an
untagged trial image. The first run asks whether the script may control Finder, which
it uses to lay out the disk image window.

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
| `--simulate-notch WxH` | Lays out as if the notch were W×H points, to check other models and display scalings (a 14" ranges from about 140×24 to 225×38). Accepts 60–400 × 16–60. |
| `--music-idle-seconds N` | Paused music leaves the closed notch after N seconds instead of 120. |
| `--preview-settings` | Opens Settings at launch. |
| `--preview-welcome N` | Shows the welcome screen at page N (0–2), even if it has been finished. |
| `--preview-hud` | Cycles the volume, brightness, headphone and charging indicators (charging shows the real power state). The real volume and brightness are untouched. |
| `--preview-convert PATH` | Shows PATH as if dropped on the notch (add `--preview-open` to keep the panel open on it). |
| `--preview-convert-to FORMAT` | With `--preview-convert`, converts the file a second later as if FORMAT's button were clicked. FORMAT is a `ConvertTarget` case: `pdf`, `png`, `jpeg`, `word`, `text`, `powerPoint`, `excel`, `csv`… The result is saved where Settings says (Downloads by default). |
| `--without-office` | Converts as if Microsoft Office weren't installed, so slides, spreadsheets and Word files go to Keynote, Numbers and Pages. |
| `--demo` | Shows made-up content for screenshots: a track with lyrics and artwork drawn in code, and a week of invented events with a meeting on the next quarter hour. Music, Calendar, headphones, the media keys and update checks aren't started, so nothing real appears. Add `--preview-open`, `--preview-timer` or `--preview-convert PATH` for the other scenes. |
| `--demo-meeting` | As `--demo`, with the track paused, so the closed notch counts down to the meeting (add `-eventReminderMinutes 15` if the reminder is set shorter). With the join shortcut on, pressing it within 10 minutes of the meeting shows Zoom in the notch but opens nothing (the demo's links are made up). |
| `--clean-seconds N` | Clean Keyboard runs for N seconds (5 to 60) instead of the Settings length, for quick tests. |
| `--update-feed URL` | Reads the release description from URL (a copy of GitHub's `releases/latest` JSON) instead of GitHub, checks two seconds after launch, and accepts the image from any address; the signature check still applies, so only a build signed with your identity installs. Logs the permission state at launch (category Updater), for checking an update keeps it. |

The README's screenshots are taken with `--demo` (plus `-welcomeCompleted N`, N being
`AppSettings.welcomeVersion`, and `-calendarEnabled 1`), capturing only the app's
window (`screencapture -o -l WINDOWID`, the window ID from
`CGWindowListCopyWindowInfo` for the test copy's PID) so the menu bar and desktop stay
out, then placed on a plain background. The opening animation is the same window
recorded with ScreenCaptureKit under `--demo --preview-cycle`, one open-and-close
cycle on a flat background (a gradient bands in a GIF's 256 colours). The dropped photo is a made-up picture too:
screenshots in this public repository must never show real events, tracks, file names
or device names.

The media-key handling and Clean Keyboard (category CleanKeyboard; at debug level
it logs each system key's subtype, which is how the Touch ID button's was found) log
to the unified log:
`log stream --predicate 'subsystem == "com.yihao.YihaosNotch"' --level debug`.

The app icon is drawn in code (`scripts/icon/render-icon.swift`); run
`./scripts/make-icon.sh` after changing it.

### Checks and tests

```sh
./scripts/check.sh   # debug build, tests, plist and script syntax; no signing, under a minute
```

Run it before every commit. The tests (`Tests/YihaosNotchTests`, Swift Testing) cover
the pure logic where past bugs landed: what the closed notch shows, lyrics parsing,
meeting links (look-alike domains, redirects, https only), player data, which copy
carries on when two run, and the version bump. Clean Keyboard's rules are kept apart
from the system so they can be tested: which events the tap swallows
(`CleaningPolicy`), when the watchdog steps in (`Watchdog`), and the session's steps,
run against a fake system (`CleanKeyboardSession` with `CleaningSystem`). A real
session is checked by hand, with `--clean-seconds 5`. They never touch Calendar, the camera,
Apple events or event taps: those would ask for permissions on Terminal's behalf, or
control the real Music app. Window behaviour is checked by eye with the flags above.

GitHub Actions runs the same script on every push to master and every pull request
(`.github/workflows/check.yml`, on a `macos-26` runner with Xcode 26.6 selected through
`DEVELOPER_DIR`). It reads the repository and nothing else: no secrets and no signing,
which stays on the Mac that releases. On CI a failure also prints the full build or test
output, folded under "Full output". Third-party actions are pinned to a commit SHA;
when updating one, pin the new release's commit and keep the version in the comment.

## Layout

| Path | What |
|---|---|
| `Window/` | Overlay panel, built-in screen and notch detection, hover/click/swipe handling |
| `Core/` | Settings, theme and transitions, notch shape, view model (state and live-activity priority) |
| `Views/` | The morphing shape, open panel, compact live activities |
| `Features/NowPlaying` | Music and Spotify via distributed notifications and AppleScript; LRCLIB lyrics |
| `Features/Calendar` | EventKit events, meeting-link detection (Zoom/Teams/Meet/Webex), which meeting the join shortcut picks |
| `Features/Battery` | IOKit power-source notifications |
| `Features/Camera` | Mirror; the camera runs only while it's visible |
| `Features/System` | Volume/brightness keys (event tap, opt-in), headphone connection, global shortcuts (Carbon hot keys, no permission) |
| `Features/Timer` | Countdown timer, opened from the header clock |
| `Features/Convert` | Files dropped on the notch: which formats each kind can become (`ConvertCatalog`), the conversions (ImageIO, PDFKit, AVFoundation, the text system, and over AppleScript Microsoft Office or, without it, Keynote, Numbers and Pages: `ConvertApp` picks and prepares them, `Office` and `IWork` drive them), Markdown to HTML with Foundation's parser, and saving without replacing anything |
| `Features/CleanKeyboard` | Turning input off for wiping: one HID event tap on its own thread, its rules and watchdog, the session's steps, the overlay, and putting Caps Lock back |
| `Features/Update` | Daily check of GitHub's latest release; installs it by swapping the bundle after checking the image's SHA-256 and that it's signed by the same certificate |
| `Settings/` | Settings window |
| `Onboarding/` | First-launch welcome: what it is, how to open it, permissions one at a time |
