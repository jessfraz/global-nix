import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = (
    pathlib.Path(__file__).resolve().parents[1] / "scripts/znc-savebuff-metadata.pl"
)


class MetadataTest(unittest.TestCase):
    def test_preserves_only_verified_metadata_and_is_idempotent(self):
        with tempfile.TemporaryDirectory(prefix="znc state ") as temp:
            root = pathlib.Path(temp)
            saved = root / "users/user/networks/network/moddata/savebuff"
            saved.mkdir(parents=True)
            metadata = bytes.fromhex("00051607") + b"metadata"
            (saved / "._buffer").write_bytes(metadata)
            (saved / "buffer").write_bytes(b"encrypted-buffer")
            (saved / "._not-appledouble").write_bytes(b"other")
            for _ in range(2):
                subprocess.run(
                    ["perl", str(SCRIPT), str(root)], check=True, capture_output=True
                )
            self.assertEqual((saved / "buffer").read_bytes(), b"encrypted-buffer")
            self.assertEqual((saved / "._not-appledouble").read_bytes(), b"other")
            archive = (
                root
                / ".appledouble-savebuff/users/user/networks/network/moddata/savebuff/._buffer"
            )
            self.assertEqual(archive.read_bytes(), metadata)
            self.assertFalse((saved / "._buffer").exists())

    def test_rejects_symlink_without_moving_target(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            saved = root / "users/user/networks/network/moddata/savebuff"
            saved.mkdir(parents=True)
            target = root / "target"
            target.write_bytes(bytes.fromhex("00051607") + b"metadata")
            (saved / "._buffer").symlink_to(target)
            result = subprocess.run(
                ["perl", str(SCRIPT), str(root)], capture_output=True, check=False
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(target.exists())
            self.assertTrue((saved / "._buffer").is_symlink())


if __name__ == "__main__":
    unittest.main()
