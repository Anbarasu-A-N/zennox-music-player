import pathlib, sys, unittest, urllib.parse, base64, hashlib
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import spike_drive_picker as s

class SpikeHelpers(unittest.TestCase):
    def test_pkce_s256(self):
        v, c = s.pkce_pair()
        self.assertTrue(43 <= len(v) <= 128)
        self.assertEqual(c, base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b"=").decode())

    def test_auth_url_has_required_picker_params_and_only_drive_file(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(s.build_auth_url("cid", "http://127.0.0.1:1/callback", "st", "ch")).query)
        self.assertEqual(q["scope"], ["https://www.googleapis.com/auth/drive.file"])
        for k, v in {"prompt": "consent", "trigger_onepick": "true", "allow_folder_selection": "true",
                     "code_challenge_method": "S256", "state": "st"}.items():
            self.assertEqual(q[k], [v])

    def test_callback_parsing(self):
        code, ids = s.parse_callback("/callback?state=st&code=abc&picked_file_ids=a,b", "st")
        self.assertEqual((code, ids), ("abc", ["a", "b"]))
        with self.assertRaises(ValueError): s.parse_callback("/callback?state=evil&code=abc", "st")
        with self.assertRaises(ValueError): s.parse_callback("/callback?error=access_denied&state=st", "st")

    def test_magic(self):
        self.assertEqual(s.magic_kind(b"fLaC\x00"), "flac")
        self.assertEqual(s.magic_kind(b"\x00\x00\x00\x20ftypM4A "), "mp4/m4a")
        self.assertIsNone(s.magic_kind(b"<html>"))

class ClientFile(unittest.TestCase):
    def setUp(self):
        import tempfile, os, json
        self.dir = tempfile.mkdtemp(); self.os, self.json = os, json

    def write(self, name, data):
        p = self.os.path.join(self.dir, name); open(p, "w").write(self.json.dumps(data)); return p

    def test_placeholder_falls_back_to_single_download(self):
        p = self.write("client_secret_123.json", {"installed": {"client_id": "x"}})
        self.assertEqual(s.find_client_json("~/Downloads/client_secret_XXXX.json", self.dir), p)

    def test_none_or_many_give_clear_errors(self):
        with self.assertRaises(SystemExit): s.find_client_json(None, self.dir)
        self.write("client_secret_1.json", {}); self.write("client_secret_2.json", {})
        with self.assertRaises(SystemExit) as e: s.find_client_json(None, self.dir)
        self.assertIn("Several", str(e.exception))

    def test_missing_explicit_path(self):
        with self.assertRaises(SystemExit) as e: s.find_client_json(self.dir + "/nope.json", self.dir)
        self.assertIn("File not found", str(e.exception))

if __name__ == "__main__":
    unittest.main()
