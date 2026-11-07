# Yihao's Notch

A quiet companion for the MacBook Pro's notch, inspired by
[Boring Notch](https://github.com/TheBoredTeam/boring.notch). The notch stays a plain
black notch until it has something to say, and opens into a small panel when you
want it.

## Download and install

**[Download the latest version](https://github.com/liuy7713/YihaosNotch/releases/latest/download/YihaosNotch.dmg)**
(free; a MacBook with a notch and macOS 15 or later).

1. Open the downloaded file and drag **Yihao's Notch** into **Applications**.
2. Open it from Applications. macOS says Apple "could not verify" it: click **Done**.
   Not the blue **Move to Bin** (or Move to Trash) button, which is the default and
   deletes the app. The warning is expected: the app isn't notarized by Apple, which
   needs a paid developer account, so macOS can't check who made it.
3. Open **System Settings › Privacy & Security**, scroll down to **Security**, and click
   **Open Anyway** next to "Yihao's Notch" was blocked. Enter your password, then
   click **Open Anyway** once more. (No button? Open the app again and come back: it
   only shows for about an hour.) This step needs an administrator account.
4. The welcome screen does the rest. Every permission is optional and explained.

Only download it from this repository's
[Releases](https://github.com/liuy7713/YihaosNotch/releases) page; copies from
anywhere else aren't mine. Each release lists the file's SHA-256, so you can check
yours with `shasum -a 256 ~/Downloads/YihaosNotch.dmg`.

**Updating:** from version 1.6.0 the app looks for new versions once a day. When one
is out, a small dot appears on the gear in the panel, and Settings offers **Update**:
it downloads the new version, checks it's signed by the same developer, replaces
itself and restarts, with no Open Anyway this time. (If it can't, for example from an
account without permission to change Applications, the button opens this page
instead.) On an older version, download the new one, drag it over the old one in
Applications, open it, and repeat steps 2–3 if macOS says "Not Opened".

## What it does

**Closed**, the notch grows small "wings" either side for whatever matters right now:
the album art and bars of what's playing, a countdown before your next event (which
takes over from music or a timer for the minute before it starts and two after), a
running timer, the charger connecting (charging or just plugged in, and the charger's
wattage), or your AirPods switching on.

**Open** (rest the pointer on the notch, click it, or swipe down on it with two
fingers), it shows:

- **Now Playing** for Music and Spotify: artwork, controls, a scrubber and a synced
  lyric line.
- **Calendar**: a five-day strip you can scroll a week either way, and the agenda for
  the chosen day, with all-day events on one line at the top. Clicking an event shows
  it in Calendar; Zoom, Teams, Meet and Webex links get a Join button (until the event
  ends) that opens the meeting straight in its app. Settings chooses which calendars
  are shown.
- **Timer**: click the clock in the header, or click the timer's wings while it runs.
  Seven presets and a custom tile (marked ↕): scroll on it to pick from 1 to 180
  minutes, one stop per scroll tick (single minutes to 10, fives to an hour, then
  quarter hours), and click to start; it keeps its value. Past an hour the wings show "1h 30". A finished timer stays in
  the notch until you next come to it (up to a minute).
- **Camera mirror**: a quick check before a call, with Center Stage (keeps you framed as
  you move) on cameras that have it, such as recent MacBooks' 12 MP camera, toggled from a
  button in the mirror.

Optionally, the volume and brightness keys show a small indicator in the notch instead
of the macOS pop-up (in the header while the panel is open).

It runs only on the built-in display, sits at 0% CPU when idle, and uses about 20–30 MB
of memory.

Text is at least 4.5:1 against the black, lyrics included, whatever colour the album
art gives them. It follows the Accessibility display settings: Increase Contrast
brightens text, outlines and past events; Differentiate Without Colour rings today in
the calendar; Reduce Motion swaps slides and bounces for fades. Text sizes are fixed,
as the notch has no room to grow.

## Requirements

- A MacBook with a notch, so Apple silicon (it does nothing on Macs without one, or at
  a display resolution that puts the menu bar below the notch). Any notched model and
  display scaling works: sizes are read from the screen.
- macOS 15 or later. (On an Intel Mac, which never has a notch, macOS says the app
  isn't supported.)

## Permissions

The welcome screen on first launch asks for each one in turn, with a reason, and any
can be skipped; a skipped one is asked for when its feature is first used.

| Permission | Used for |
|---|---|
| Calendars | Showing your events and meeting links. Read-only. |
| Camera | The mirror. The camera runs only while the mirror is on screen. |
| Automation (Music, Spotify) | Reading what's playing and controlling playback. |
| Accessibility | Only for the optional volume/brightness indicator, which needs to catch those keys before macOS does. Off by default. A Magic Keyboard's brightness keys arrive as ordinary key presses (codes 144/145), so with this on, and only while an external keyboard is connected (anything that presents itself as one counts, such as some mouse receivers, security keys or Karabiner's virtual keyboard), the app also sees key presses: on its own thread, reading nothing but the key code and passing every other key straight back. Settings says so too. |

## Privacy

Only three things go over the network. Lyrics lookups send the title, artist, album
and length of the current track to [LRCLIB](https://lrclib.net), a free lyrics
database; turning off Synced lyrics in Settings stops them. When Spotify is playing,
its album art is downloaded from Spotify's own image servers (the address Spotify
reports). And once a day the app asks GitHub for this repository's latest release,
which sends nothing about you; turning off Check for updates daily stops it, and an
update downloads only when you click Update. There are no analytics.

Display brightness has no public API, so it's set through Apple's private
DisplayServices framework (as MonitorControl and similar tools do). If that ever stops
working, the brightness keys simply fall back to macOS.

## Using it

Open the app again (from Finder or Spotlight), or click the gear in the open panel, to
show Settings; it has no Dock icon or menu bar item. Settings opens beneath the notch;
its footer has Show Tour… (the welcome's tour and permissions) and Quit. While Settings
or the welcome is open the app shows a Dock icon, so the window gets the keyboard (macOS
won't give it to an app without one) and ⌘, ⌘W and Esc work. ⌘Q closes the window
too rather than quitting, since quitting would silently stop the notch; quit from the
footer, the Dock menu or by right-clicking the gear. On the very first welcome, Esc and
⌘W do nothing, so a stray key can't skip the setup.

Only one copy runs at a time. Opening a second copy (say, the one on the disk image)
hands over to the running one, unless it's a newer build, in which case the older copy
is told to quit. Opening the app again after an update has been dragged over the
running copy restarts it on the new version.

## Uninstall

1. Open the app again to show Settings, turn off **Open at login**, and click **Quit**.
2. Drag **Yihao's Notch** from Applications to the Bin.
3. Optionally, to remove its settings and permission grants, run these in Terminal:
   `defaults delete com.yihao.YihaosNotch` and
   `tccutil reset All com.yihao.YihaosNotch`.

## Troubleshooting

- **Nothing appears:** it only runs on a built-in display with a notch, and not at a
  resolution that puts the menu bar below the notch.
- **No events, music or camera:** check System Settings › Privacy & Security ›
  Calendars, Camera, or Automation (Music, Spotify), or replay the tour from
  Settings › Show Tour….
- **No lyrics for a song:** LRCLIB doesn't have it, so none show.
- **Brightness indicator stopped after a macOS update:** it relies on a private macOS
  framework (see Privacy); the keys fall back to the normal macOS pop-up.
- **Still stuck?** [Open an issue](https://github.com/liuy7713/YihaosNotch/issues/new/choose)
  with your Mac model, macOS version and the app version (shown in Settings).

## Building from source

Needs Xcode 26 (Swift 6.2). `./scripts/build.sh --install` builds and installs it;
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) covers signing, releases, development flags,
tests and the code layout. It's a hobby project: issues and small pull requests are
welcome (run `./scripts/check.sh` first), and replies may take a while.

## Licence

[MIT](LICENSE): use, change and share it freely, keeping the copyright notice. It comes
with no warranty. Lyrics are fetched from [LRCLIB](https://lrclib.net) while the app
runs and belong to their rights holders; none are included here. Not affiliated with
Apple, Spotify or Boring Notch.
