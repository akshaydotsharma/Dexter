# Shipping a build to your phone (cable or LAN wifi)

Free Apple Developer account, no TestFlight, no $99/year. The trade-off: the
dev provisioning profile expires every 7 days, so you re-run the script
weekly. Installs happen over a USB cable or the same wifi network as the
Mac — there is no internet-facing install path (#579).

## Prereqs (one-time)

- Xcode signed in with the Apple ID that owns team `PJFPUSSNUW` ("Akshay Sharma" personal team)
- Your iPhone has been plugged into this Mac at least once via cable so its UDID is
  registered in the development profile (already done for this project — UDID
  `00008140-000E79CE0244801C` is in the current profile)
- `xcodegen` installed: `brew install xcodegen`

## Per-build flow

```bash
bash mobile/ota/ship-lan.sh
```

The script:
1. Regenerates the Xcode project
2. Archives + exports a development-signed `.ipa` to `/tmp/ota/`
3. Prints the `app.ipa` path and a ready-to-run install command

```bash
xcrun devicectl device install app --device <UDID> /tmp/ota/app.ipa
```

Find `<UDID>` with `xcrun devicectl list devices`. The phone must show
`available (paired)`, over USB or the same wifi network as the Mac.

## Common issues

- **"Could not install — App not available"**: the device UDID isn't in the
  current development profile. Plug the iPhone into the Mac, open Xcode, build
  to the device once. Xcode refreshes the profile to include the UDID. Then
  re-run `ship-lan.sh`.
- **"Untrusted Developer"** dialog when launching the installed app: Settings →
  General → VPN & Device Management → Developer App → trust the certificate.
  One-time per developer.
- **Install succeeds but the app looks unchanged**: the phone already had that
  exact build version, so iOS silently no-op'd. Force-quit and relaunch; if
  that doesn't help, bump `mobile/.build_count` and re-ship.
- **Profile expired** (>7 days since last build): just re-run the script. Free
  team profiles auto-renew on each archive as long as Xcode is signed in.

## Files in `mobile/ota/`

- `ship-lan.sh` — archives, signs, and exports `app.ipa`; prints the `devicectl` install command
- `ExportOptions.plist` — tells `xcodebuild -exportArchive` to produce a
  development-signed IPA
- `setup-signing-noprompt.sh` — one-time setup that stops the keychain password prompt on every ship

`/tmp/ota/` is staged fresh on every run; nothing there is precious. A failed
run also cleans itself up, since the archive and the IPA both carry the
Anthropic/OpenAI keys in plaintext.
