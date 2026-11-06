# Working on Yihao's Notch

A macOS notch app (SwiftPM, Swift 6, macOS 15+). README.md is for people using the app;
docs/DEVELOPMENT.md explains build, release and layout; this file holds the rules
that aren't obvious from the code.

## Every change
- Run `./scripts/check.sh` before committing; it needs no signing.
- `./scripts/build.sh` signs with the local identity, so the user has to click **Allow**
  (not Always Allow) on the "YihaosNotchSigning" dialog. Tell them before each build.
- Commits are authored "Yihao Liu" with the GitHub noreply address set in the repo
  config. Never use another email. No "Co-Authored-By" or other AI attribution lines
  in commit messages, tags, releases or PRs.
- The repo is **public**: never commit `notes/`, `dist/`, screenshots with personal
  data (real events, device names, camera frames), signing material or absolute paths
  under /Users.
- Versions: `scripts/bump-version.sh patch|minor|major`, then `scripts/release.sh`
  (clean tree; it tags), then push the branch and the tag, then
  `scripts/publish-release.sh` (GitHub Release). Keep only the latest DMG in `dist/`.
- `notes/` (reviews) is git-ignored on purpose.

## Invariants
- Nothing asks for a permission at launch or before the welcome is finished. Each
  prompt comes from something the user just did (`CalendarService.start` takes
  `requestingAccess` with no default for this reason).
- Reading Music or Spotify sends Apple events, which prompts: NowPlaying only starts
  after the welcome.
- Only one copy runs (`SingleInstance`). A launch with arguments is exempt, so always
  start test copies with at least one development flag (e.g. `-welcomeCompleted 1` or
  `--preview-open`), or they'll take over from or defer to the user's installed app.
- Stop test copies by PID or exact path, never `pkill -x YihaosNotch`: that also kills
  the user's app.
- Don't click, type or post synthetic key events while the user is using the Mac, and
  don't turn on the camera in tests. Delete screenshots after use.
- Tests must never touch EventKit, AVCaptureDevice, Apple events or event taps.
- The signing identity lives in `~/.yihaos-notch/signing`, never in the project. Never
  create a new one (every permission would have to be granted again); restore the
  backup with `make-signing-identity.sh --restore`. Never run `security
  show-keychain-info` or `set-keychain-settings` on the signing keychain.
