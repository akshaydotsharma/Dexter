# Shipping a build to your phone (OTA install via Cloudflare tunnel)

Same setup as `summariz`. Free Apple Developer account, no TestFlight, no $99/year.
The trade-off: the dev provisioning profile expires every 7 days, so you re-run
the script weekly. Otherwise, builds install on your phone over the internet from
anywhere — no cable, no shared WiFi.

## Prereqs (one-time)

- Xcode signed in with the Apple ID that owns team `PJFPUSSNUW` ("Akshay Sharma" personal team)
- Your iPhone has been plugged into this Mac at least once via cable so its UDID is
  registered in the development profile (already done for this project — UDID
  `00008140-000E79CE0244801C` is in the current profile)
- `cloudflared` installed: `brew install cloudflared`
- `xcodegen` installed: `brew install xcodegen`

## Per-build flow

```bash
bash mobile/ota/ship.sh
```

The script:
1. Regenerates the Xcode project
2. Archives + exports a development-signed `.ipa`
3. Stages everything in `/tmp/ota/`
4. Boots a local HTTP server on `:8081`
5. Opens a Cloudflare quick tunnel and captures the public HTTPS URL
6. Renders `manifest.plist` and `index.html` with the tunnel URL baked in
7. Prints (and `pbcopy`s) the install URL

Open the printed URL **in Safari on your iPhone** (Chrome and in-app browsers
block `itms-services://`). The page has a single big "Install" button. Tap it.
iOS confirms, downloads the IPA over the tunnel, installs.

When the install starts, you can `Ctrl-C` the script — the IPA has already
streamed across.

## Common issues

- **"Cannot connect to ..."** when tapping Install: the cloudflared tunnel went
  down or the script was killed before download completed. Re-run `ship.sh`.
- **"Could not install — App not available"**: the device UDID isn't in the
  current development profile. Plug the iPhone into the Mac, open Xcode, build
  to the device once. Xcode refreshes the profile to include the UDID. Then
  re-run `ship.sh`.
- **"Untrusted Developer"** dialog when launching the installed app: Settings →
  General → VPN & Device Management → Developer App → trust the certificate.
  One-time per developer.
- **Tunnel URL never printed** / script hangs on "starting cloudflared": check
  `/tmp/ota/cloudflared.log`. If the message is "failed to dial", Cloudflare's
  quick-tunnel endpoint is having a moment — retry in a minute.
- **Profile expired** (>7 days since last build): just re-run the script. Free
  team profiles auto-renew on each archive as long as Xcode is signed in.

## Files in `mobile/ota/`

- `ship.sh` — the orchestrator
- `ExportOptions.plist` — tells `xcodebuild -exportArchive` to produce a
  development-signed IPA
- `manifest.template.plist` — OTA install manifest, with `__IPA_URL__` placeholder
- `index.template.html` — landing page with the tap-to-install button

`/tmp/ota/` is staged fresh on every run; nothing there is precious.
