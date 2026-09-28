"""Exercise the private Git backup against a local bare remote."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "Scripts" / "backup-repo.sh"


def git(*args: str, cwd: Path) -> str:
    result = subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
    )
    return result.stdout.strip()


class BackupRepoTests(unittest.TestCase):
    def setUp(self) -> None:
        if not SOURCE.exists():
            self.skipTest("private backup script is absent from the public snapshot")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.remote = root / "seedbed-private.git"
        self.local = root / "local"
        self.other = root / "other"
        git("init", "--bare", str(self.remote), cwd=root)
        git("init", "-b", "main", str(self.local), cwd=root)
        git("config", "user.email", "backup-test@example.invalid", cwd=self.local)
        git("config", "user.name", "Backup Test", cwd=self.local)
        git("remote", "add", "origin", str(self.remote), cwd=self.local)
        (self.local / "data.txt").write_text("initial\n")
        git("add", "data.txt", cwd=self.local)
        git("commit", "-m", "initial", cwd=self.local)
        git("push", "-u", "origin", "main", cwd=self.local)
        (self.local / "Scripts").mkdir()
        shutil.copy2(SOURCE, self.local / "Scripts" / "backup-repo.sh")
        git("clone", "-b", "main", str(self.remote), str(self.other), cwd=root)
        git("config", "user.email", "backup-test@example.invalid", cwd=self.other)
        git("config", "user.name", "Backup Test", cwd=self.other)

    def run_backup(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "Scripts/backup-repo.sh"],
            cwd=self.local,
            capture_output=True,
            text=True,
        )

    def advance_other(self) -> str:
        (self.other / "data.txt").write_text("remote ahead\n")
        git("add", "data.txt", cwd=self.other)
        git("commit", "-m", "remote ahead", cwd=self.other)
        git("push", "origin", "main", cwd=self.other)
        return git("rev-parse", "HEAD", cwd=self.other)

    def test_remote_ahead_covers_local_without_rewriting_it(self) -> None:
        remote_tip = self.advance_other()
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already covered: main", result.stdout)
        self.assertEqual(git("ls-remote", "origin", "refs/heads/main", cwd=self.local).split()[0], remote_tip)

    def test_divergent_branch_refuses_and_preserves_remote(self) -> None:
        remote_tip = self.advance_other()
        (self.local / "data.txt").write_text("local diverged\n")
        git("add", "data.txt", cwd=self.local)
        git("commit", "-m", "local diverged", cwd=self.local)
        result = self.run_backup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("diverged", result.stderr)
        self.assertEqual(git("ls-remote", "origin", "refs/heads/main", cwd=self.local).split()[0], remote_tip)

    def test_local_ahead_pushes_branch_and_tag(self) -> None:
        (self.local / "data.txt").write_text("local ahead\n")
        git("add", "data.txt", cwd=self.local)
        git("commit", "-m", "local ahead", cwd=self.local)
        git("tag", "backup-proof", cwd=self.local)
        local_tip = git("rev-parse", "HEAD", cwd=self.local)
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git("ls-remote", "origin", "refs/heads/main", cwd=self.local).split()[0], local_tip)
        self.assertEqual(git("ls-remote", "origin", "refs/tags/backup-proof", cwd=self.local).split()[0], local_tip)


if __name__ == "__main__":
    unittest.main()
