# Lumen

Native SwiftUI (iOS 26, Liquid Glass) audio + video player.

- Crossfade (0–12 s, equal-power) and gapless between tracks, dual-deck AVAudioEngine
- Music haptics: Taptic Engine follows bass energy + beat taps (Core Haptics)
- Liquid Glass UI, animated mesh backdrop from album art, bottom accessory mini player
- 10-band EQ presets, playback speed (pitch-preserving), queue, shuffle/repeat
- Lock screen / Control Center / AirPods controls, background audio, AirPlay picker
- Video: mp4/mov/m4v with glass controls, double-tap ±10 s, speed, fill/fit

## Build on Windows (no Mac needed)

1. Push this folder to a GitHub repo (branch `main`).
2. Actions tab -> "Build IPA" runs automatically (or run it manually).
3. Download the `Lumen-ipa` artifact -> unzip -> `Lumen.ipa`.
4. Sideload with Sideloadly / AltStore (they sign it with your Apple ID).

Add music/videos via the + button, the Files app ("Lumen" folder) or iTunes/Finder file sharing.

If `macos-26` is not available for your account, change `runs-on` in `.github/workflows/build.yml` to `macos-latest` and make sure it has Xcode 26.

## SideStore / LiveContainer

- SideStore source: `https://github.com/deltaspacesystems-ksp/ios_player/releases/download/latest/source.json`
- LiveContainer: install `Lumen.ipa` from the latest release (unsigned IPA, arm64). Files added in-app go to the guest's Documents folder.
  Folder bookmarks may not survive inside LiveContainer; Lumen keeps such folders listed (with a warning) so you can re-grant access in Settings.
