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

if __name__ == "__main__":
    unittest.main()
