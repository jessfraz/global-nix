import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/znc-tailscale-listener.pl"
LISTENER = "<Listener main>\n\tPort = 6697\n\tSSL = true\n</Listener>\n"
ACCOUNT = "<User example>\n\t<Network example>\n\t\tServer = irc.example +6697\n\t</Network>\n</User>\n"


class ZncTailscaleListenerTests(unittest.TestCase):
    def run_migration(self, path: Path) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            ["perl", str(SCRIPT), str(path)], capture_output=True, check=False
        )

    def test_changes_only_target_listener_and_preserves_metadata(self) -> None:
        other = LISTENER.replace("main", "other").replace("6697", "7777")
        original = (LISTENER + other + ACCOUNT).encode()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "znc.conf"
            path.write_bytes(original)
            path.chmod(0o640)
            before = path.stat()
            result = self.run_migration(path)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, b"")
            self.assertEqual(result.stderr, b"")
            self.assertEqual(
                path.read_bytes(), original.replace(b"SSL = true", b"SSL = false", 1)
            )
            after = path.stat()
            self.assertEqual(after.st_mode, before.st_mode)
            self.assertEqual(
                (after.st_uid, after.st_gid), (before.st_uid, before.st_gid)
            )
            self.assertEqual(list(Path(directory).iterdir()), [path])
            self.assertEqual(self.run_migration(path).returncode, 0)
            self.assertEqual(path.stat().st_ino, after.st_ino)

    def test_preserves_crlf_and_spacing(self) -> None:
        original = LISTENER.replace("SSL = true", "SSL  =  TRUE  ").replace(
            "\n", "\r\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "znc.conf"
            path.write_bytes(original.encode())
            result = self.run_migration(path)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                path.read_bytes(), original.replace("TRUE", "false").encode()
            )

    def test_rejects_ambiguous_or_malformed_config_without_writes(self) -> None:
        cases = [
            ACCOUNT,
            LISTENER + LISTENER,
            LISTENER.replace("Port = 6697", "Port = 6697\n\tPort = 7777"),
            LISTENER.replace("SSL = true", "SSL = true\n\tSSL = false"),
            LISTENER.replace("\tSSL = true\n", ""),
            LISTENER.replace("SSL = true", "SSL = maybe"),
            LISTENER.replace("</Listener>", "</User>"),
            LISTENER.replace("</Listener>\n", ""),
            "<User example>\n" + LISTENER + "</User>\n",
            LISTENER.replace("\tSSL = true", "<User nested>\nSSL = true\n</User>"),
        ]
        for original in cases:
            with (
                self.subTest(original=original),
                tempfile.TemporaryDirectory() as directory,
            ):
                path = Path(directory) / "znc.conf"
                path.write_text(original)
                inode = path.stat().st_ino
                result = self.run_migration(path)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(path.read_text(), original)
                self.assertEqual(path.stat().st_ino, inode)
                self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_rejects_symlink_without_touching_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "target.conf"
            target.write_text(LISTENER)
            path = Path(directory) / "znc.conf"
            path.symlink_to(target)
            self.assertNotEqual(self.run_migration(path).returncode, 0)
            self.assertTrue(path.is_symlink())
            self.assertEqual(target.read_text(), LISTENER)


if __name__ == "__main__":
    unittest.main()
