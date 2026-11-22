#!/usr/bin/env python3
"""Spike S1 — does Google Picker + drive.file give us what Zennox needs?

Answers, on your real account:
  1. Can the desktop Picker (trigger_onepick) return picked audio files and folders?
  2. If a folder is picked, can drive.file list the files inside it?
  3. Can we read those files (metadata + an HTTP Range request on the audio bytes)?

Stdlib only. Tokens stay in memory, are never printed or written, and are revoked at the end.
Setup: docs/google-cloud-setup.md.   Run:  python3 tools/spike_drive_picker.py --client-json ~/Downloads/client_secret_XXX.json
"""
import argparse, base64, glob, hashlib, http.server, json, os, secrets, sys, time, urllib.error, urllib.parse, urllib.request, webbrowser

AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
REVOKE_URL = "https://oauth2.googleapis.com/revoke"
DRIVE = "https://www.googleapis.com/drive/v3"
SCOPE = "https://www.googleapis.com/auth/drive.file"  # Picker for desktop allows only this scope
FOLDER_MIME = "application/vnd.google-apps.folder"
AUDIO_MAGIC = {b"fLaC": "flac", b"ID3": "mp3 (ID3)", b"OggS": "ogg", b"RIFF": "wav", b"FORM": "aiff"}


def pkce_pair():
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(48)).rstrip(b"=").decode()
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    return verifier, challenge


def build_auth_url(client_id, redirect_uri, state, challenge, allow_folders=True, mimetypes=None):
    params = {
        "client_id": client_id, "redirect_uri": redirect_uri, "response_type": "code",
        "scope": SCOPE, "access_type": "offline", "prompt": "consent", "trigger_onepick": "true",
        "allow_multiple": "true", "state": state,
        "code_challenge": challenge, "code_challenge_method": "S256",
    }
    if allow_folders:
        params["allow_folder_selection"] = "true"
    if mimetypes:
        params["mimetypes"] = ",".join(mimetypes)
    return AUTH_URL + "?" + urllib.parse.urlencode(params)


def parse_callback(path, expected_state):
    """Returns (code, picked_ids). Raises ValueError on error, cancel or state mismatch."""
    query = urllib.parse.parse_qs(urllib.parse.urlparse(path).query)
    if "error" in query:
        raise ValueError("Google returned error: " + query["error"][0])
    if query.get("state", [""])[0] != expected_state:
        raise ValueError("state mismatch (possible forged redirect); aborting")
    code = query.get("code", [""])[0]
    if not code:
        raise ValueError("no authorization code in redirect")
    picked = [i for i in query.get("picked_file_ids", [""])[0].split(",") if i]
    return code, picked


def magic_kind(head: bytes):
    for magic, kind in AUDIO_MAGIC.items():
        if head.startswith(magic):
            return kind
    if head[4:8] == b"ftyp":
        return "mp4/m4a"
    return None


def find_client_json(given, downloads="~/Downloads"):
    """Resolves the OAuth client file: the given path, or the only client_secret_*.json in Downloads."""
    if given and "XXXX" not in given:
        path = os.path.expanduser(given)
        if not os.path.isfile(path):
            raise SystemExit(f"File not found: {path}\nList candidates with:  ls ~/Downloads/client_secret_*.json")
        return path
    found = sorted(glob.glob(os.path.join(os.path.expanduser(downloads), "client_secret_*.json")))
    if len(found) == 1:
        print(f"Using {found[0]}")
        return found[0]
    if not found:
        raise SystemExit("No client_secret_*.json in ~/Downloads. Download it from Google Cloud → "
                         "Google Auth platform → Clients → your Desktop client → Download JSON.")
    raise SystemExit("Several client files in ~/Downloads; pass one with --client-json:\n  " + "\n  ".join(found))


def load_client(given):
    with open(find_client_json(given)) as fh:
        data = json.load(fh)
    if "installed" not in data:
        kind = next(iter(data), "unknown")
        raise SystemExit(f"This client is type '{kind}', not 'Desktop app'. Create a Desktop app client "
                         "(docs/google-cloud-setup.md, section 3) and download its JSON.")
    return data["installed"]["client_id"], data["installed"].get("client_secret", "")


def loopback_server():
    result = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            result["path"] = self.path
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write("<p>Zennox spike: you can close this tab and return to the terminal.</p>".encode())

        def log_message(self, *args):  # keep codes out of the terminal
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)  # random free port, loopback only
    server.timeout = 1
    return server, server.server_address[1], result


def http_json(method, url, token=None, data=None, headers=None):
    req = urllib.request.Request(url, method=method, data=data, headers=dict(headers or {}))
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.status, resp.headers, resp.read()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--client-json", help="OAuth client JSON (Desktop app). Default: the only client_secret_*.json in ~/Downloads")
    ap.add_argument("--audio-only-filter", action="store_true", help="pass audio MIME types to the Picker filter")
    ap.add_argument("--show-names", action="store_true", help="print file names (off by default for privacy)")
    ap.add_argument("--keep-token", action="store_true", help="do not revoke the grant at the end")
    args = ap.parse_args()

    client_id = os.environ.get("ZENNOX_GOOGLE_CLIENT_ID", "")
    client_secret = os.environ.get("ZENNOX_GOOGLE_CLIENT_SECRET", "")
    if args.client_json or not client_id:
        client_id, client_secret = load_client(args.client_json)

    server, port, result = loopback_server()
    redirect_uri = f"http://127.0.0.1:{port}/callback"
    state = secrets.token_urlsafe(24)
    verifier, challenge = pkce_pair()
    mimes = ["audio/flac", "audio/x-flac", "audio/mpeg", "audio/mp4", "audio/x-m4a", "audio/aac",
             "audio/ogg", "audio/opus", "audio/wav", "audio/x-wav", "audio/aiff", "audio/x-aiff", FOLDER_MIME] if args.audio_only_filter else None
    url = build_auth_url(client_id, redirect_uri, state, challenge, True, mimes)

    print("\nOpening Google in your browser. In the Picker, select:\n"
          "  • 2–3 audio files, AND\n  • 1 folder that contains music (not opened, just selected)\n"
          "then click Select/Insert.\n")
    webbrowser.open(url)
    deadline = time.time() + 300
    while "path" not in result and time.time() < deadline:
        server.handle_request()
    server.server_close()
    if "path" not in result:
        sys.exit("Timed out waiting for Google redirect.")

    code, picked = parse_callback(result["path"], state)
    body = urllib.parse.urlencode({"code": code, "client_id": client_id, "client_secret": client_secret,
                                   "redirect_uri": redirect_uri, "grant_type": "authorization_code",
                                   "code_verifier": verifier}).encode()
    _, _, raw = http_json("POST", TOKEN_URL, data=body, headers={"Content-Type": "application/x-www-form-urlencoded"})
    tok = json.loads(raw)
    access = tok["access_token"]
    report = {"date": time.strftime("%Y-%m-%d"), "granted_scope": tok.get("scope"),
              "refresh_token_issued": "refresh_token" in tok, "picked_count": len(picked), "items": []}

    # L4 needs a stable per-account id without extra scopes: does about.get work with drive.file alone?
    try:
        st, _, raw = http_json("GET", f"{DRIVE}/about?fields=user(permissionId,displayName,emailAddress)", access)
        user = json.loads(raw).get("user", {})
        report["about_status"] = st
        report["about_has_permission_id"] = bool(user.get("permissionId"))
        report["about_has_email"] = bool(user.get("emailAddress"))
    except urllib.error.HTTPError as e:
        report["about_status"] = e.code

    def name(f):
        return f.get("name") if args.show_names else f"<{f['mimeType']}>"

    def probe_file(f):
        entry = {"kind": "file", "mime": f["mimeType"], "size": int(f.get("size", 0) or 0), "name": name(f)}
        try:
            st, hdr, head = http_json("GET", f"{DRIVE}/files/{f['id']}?alt=media", access, headers={"Range": "bytes=0-15"})
            entry.update(range_status=st, content_range=hdr.get("Content-Range"), magic=magic_kind(head))
            if entry["size"] > 1_000_000:
                mid = entry["size"] // 2
                st2, _, _ = http_json("GET", f"{DRIVE}/files/{f['id']}?alt=media", access, headers={"Range": f"bytes={mid}-{mid + 65535}"})
                entry["mid_seek_status"] = st2
        except urllib.error.HTTPError as e:
            entry.update(error=e.code)
        return entry

    for fid in picked:
        try:
            _, _, raw = http_json("GET", f"{DRIVE}/files/{fid}?fields=id,name,mimeType,size,md5Checksum", access)
            f = json.loads(raw)
        except urllib.error.HTTPError as e:
            report["items"].append({"kind": "picked", "error": e.code}); continue
        if f["mimeType"] != FOLDER_MIME:
            report["items"].append(probe_file(f)); continue
        q = urllib.parse.quote(f"'{fid}' in parents and trashed = false")
        folder = {"kind": "folder", "name": name(f)}
        try:
            _, _, raw = http_json("GET", f"{DRIVE}/files?q={q}&pageSize=100&fields=files(id,name,mimeType,size)", access)
            children = json.loads(raw).get("files", [])
            folder["children_listed"] = len(children)
            folder["child_mimes"] = sorted({c["mimeType"] for c in children})
            folder["child_probes"] = [probe_file(c) for c in children if c["mimeType"].startswith("audio/")][:3]
        except urllib.error.HTTPError as e:
            folder["list_error"] = e.code
        report["items"].append(folder)

    if not args.keep_token:
        try:
            http_json("POST", REVOKE_URL, data=urllib.parse.urlencode({"token": tok.get("refresh_token", access)}).encode(),
                      headers={"Content-Type": "application/x-www-form-urlencoded"})
            report["revoked"] = True
        except urllib.error.HTTPError:
            report["revoked"] = False

    print(json.dumps(report, indent=2))
    folders = [i for i in report["items"] if i["kind"] == "folder"]
    if folders:
        ok = any(f.get("children_listed", 0) > 0 and any(p.get("range_status") == 206 for p in f.get("child_probes", [])) for f in folders)
        print("\nVERDICT folder pick:", "children ARE accessible with drive.file" if ok else "children NOT accessible (or folder had no audio)")
    print("Paste the JSON above back into the chat. It contains no tokens" + ("" if args.show_names else " and no file names") + ".")


if __name__ == "__main__":
    main()
