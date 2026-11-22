# Google Cloud setup (free)

Zennox uses Google sign-in and the Drive API with only the `drive.file` scope. No paid
services, no security assessment. Do this once; ~10 minutes.

## 1. Project and APIs
1. Open https://console.cloud.google.com/ → project picker → **New project** → name `zennox-music-player`.
2. **APIs & Services → Library**: enable **Google Drive API** and **Google Picker API**.

## 2. Google Auth platform (consent screen)
1. **Google Auth platform → Branding**: App name `Zennox Music Player`, your support email, developer contact email.
2. **Audience**: User type **External**, leave publishing status **Testing**.
   Add yourself (and up to 100 testers) under **Test users**.
   Note: while in Testing, Google expires refresh tokens after 7 days — expect to sign in again weekly until the app is published.
3. **Data access → Add or remove scopes**: add `.../auth/drive.file` only. Also `openid` and `email` later for the app (not needed for the spike).

## 3. OAuth clients (one per platform)
**Google Auth platform → Clients → Create client**

| For | Application type | Notes |
|---|---|---|
| Spike S1 and Windows app | Desktop app | Download the JSON. Its `client_secret` is not secret for installed apps, but keep the file out of git (`.gitignore` covers `client_secret*.json`). |
| macOS + iOS app | iOS | Bundle ID `com.anbarasu.zennox.music`; redirect is the reversed client ID scheme |
| Android app | Android | Package name + SHA-1 of your release signing key |

## 4. Run spike S1
```bash
python3 tools/spike_drive_picker.py --client-json ~/Downloads/client_secret_XXXX.json
```
In the browser: sign in with a **test user**, accept, then in the Picker select 2–3 audio files
**and** one folder that contains music. Paste the printed JSON back into the chat.
Optional second run with `--audio-only-filter` to see whether the MIME filter still shows folders.

The script revokes its grant at the end; you can also check https://myaccount.google.com/permissions.

## 5. Before publishing (later, Phase 6)
Switch publishing status to **In production**. `drive.file` is not a restricted scope, so no
CASA assessment; Google may still ask for brand verification (privacy policy URL, homepage on a
domain you control — a GitHub Pages site works and is free).
