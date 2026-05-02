# OTA Install — Tailscale transport

`ship.sh` archives the app, serves the `.ipa` and `manifest.plist` over HTTPS,
and prints an `itms-services://` URL you open in Safari on your iPhone.

The default transport is **Tailscale Serve**, which uses the stable MagicDNS
hostname your Mac already has. The iPhone reaches the Mac over Tailscale — works
on any network, no same-LAN requirement.

---

## One-time setup

Do these steps once. They take about five minutes.

1. **Install Tailscale on Mac**: `brew install --cask tailscale`. Start it and log
   in with your Tailscale account.

2. **Install Tailscale on iPhone**: download from the App Store, log in with the
   same account.

3. **Enable MagicDNS**: in the Tailscale admin console
   (`login.tailscale.com/admin/dns`), turn on MagicDNS. This gives your Mac a
   stable hostname like `my-mac.tail1234.ts.net`.

4. **Enable HTTPS Certificates**: on the same DNS settings page, turn on HTTPS
   Certificates. This lets Tailscale issue a browser-trusted TLS cert for your
   hostname so iOS accepts it without any trust prompt. `tailscale serve`
   provisions and renews the cert automatically the first time it runs.

5. **Enable Tailscale Serve**: this is a separate per-tailnet toggle from HTTPS
   Certificates. The first time you run `ship.sh` the script will print a
   one-click admin URL like `https://login.tailscale.com/f/serve?node=...` if
   Serve is disabled. Open it, click enable, and re-run the script.

No auth keys or tokens are needed. `tailscale serve` uses the daemon that is
already authenticated, and the cert is fetched automatically.

---

## Daily use

```bash
bash mobile/ota/ship.sh
```

The script prints an install URL and copies it to your clipboard. Open it in
Safari on your iPhone (Tailscale must be active on the phone) and tap **Install**.

The archived build is pre-configured to call the API at
`https://<your-mac-hostname>.ts.net/api` — no manual URL setup on the device.

After the download starts on your phone, press Ctrl-C in the terminal to stop
Tailscale Serve and the local HTTP server.

The free personal-team provisioning profile expires every 7 days. Re-run
`ship.sh` to install a fresh build.

---

## Troubleshooting / fallback

**Tailscale is unavailable on this network**: fall back to a Cloudflare quick
tunnel. The URL changes every run, so you will need to set `API_URL` manually
on the device (or via scheme env var before archiving).

```bash
OTA_TRANSPORT=cloudflare bash mobile/ota/ship.sh
```

**`tailscale serve` fails with a TLS or cert error**: enable HTTPS Certificates
in the Tailscale admin console (DNS settings) and re-run `ship.sh`.

**`tailscale status` is empty**: make sure `tailscaled` is running
(`open -a Tailscale`).

**Install URL does not load on iPhone**: confirm Tailscale is enabled on the
iPhone (the VPN icon in the status bar).
