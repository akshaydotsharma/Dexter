# Shipping to your phone — cable or LAN wifi

`ship-lan.sh` archives the app, signs it, and exports `app.ipa` to `/tmp/ota/`.
It does not serve the IPA and does not open any tunnel. Install the exported
IPA with `xcrun devicectl device install app`, over a USB cable or over the
same wifi network as the Mac (#579).

There is no internet-facing install path any more. The earlier Tailscale and
Cloudflare tunnel transports (`ship.sh`, `dev-tunnel.sh`) are retired and
removed; nothing in this repo publishes the IPA on a public URL.

---

## Daily use

```bash
bash mobile/ota/ship-lan.sh
```

The script prints the path to `app.ipa` and a ready-to-run install command:

```bash
xcrun devicectl device install app --device <UDID> /tmp/ota/app.ipa
```

Find `<UDID>` with `xcrun devicectl list devices` (the iPhone must show
`available (paired)`, over USB or the same wifi network).

The free personal-team provisioning profile expires every 7 days. Re-run
`ship-lan.sh` to sign a fresh build.

---

## Troubleshooting

- **`devicectl` can't find the device**: plug in a USB cable, or confirm the
  iPhone is on the same wifi network as the Mac and has been paired with this
  Mac at least once (Settings → General → VPN & Device Management).
- **Install reports success but the app looks unchanged**: the phone already
  had that exact build version installed, so iOS silently no-op'd. Force-quit
  and relaunch the app; if that doesn't help, bump `mobile/.build_count` and
  re-ship.
- **`ANTHROPIC_API_KEY not set`**: `ship-lan.sh` reads it from `server/.env` or
  the environment. Copy `server/.env` into the current worktree first if you
  are shipping from a non-main worktree.
- **Keychain password prompt on every ship**: run
  `bash mobile/ota/setup-signing-noprompt.sh` once; `ship-lan.sh` then
  re-authorizes codesign silently on every run.
- **"Certificate expired" on archive**: usually the 7-day provisioning
  profile, not the signing certificate. Re-run the script; `-allowProvisioningUpdates`
  regenerates the profile automatically as long as Xcode has a signed-in
  Apple ID.

## Files in `mobile/ota/`

- `ship-lan.sh` — archive, sign, export `app.ipa`; prints the `devicectl` install command
- `ExportOptions.plist` — tells `xcodebuild -exportArchive` to produce a development-signed IPA
- `setup-signing-noprompt.sh` — one-time setup that stops the keychain password prompt on every ship

`/tmp/ota/` (or `$OTA_DIR`) is staged fresh on every run; nothing there is precious, and a failed run cleans up after itself since the archive and IPA both carry the Anthropic/OpenAI keys in plaintext.
