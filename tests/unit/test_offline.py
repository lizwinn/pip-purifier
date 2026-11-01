# SPDX-License-Identifier: MIT
"""Unit tests of nix/lib/offline.py and nix/lib/vcs_shim.py: rebuilding a
shallow .git from a plain checkout and a recorded commit object (with a
submodule), and the answers of the hg, svn and bzr shims."""

import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

import offline

SHIM = os.path.join(os.path.dirname(offline.__file__), "vcs_shim.py")
ENV = dict(
    os.environ,
    GIT_AUTHOR_NAME="t",
    GIT_AUTHOR_EMAIL="t@t",
    GIT_COMMITTER_NAME="t",
    GIT_COMMITTER_EMAIL="t@t",
    GIT_CONFIG_GLOBAL=os.devnull,
)


def git(cwd, *args):
    return subprocess.run(["git", "-c", "protocol.file.allow=always", *args], cwd=cwd, env=ENV, capture_output=True, check=True).stdout.decode().strip()


class RebuildGit(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def repo(self, name, files):
        path = os.path.join(self.root, name)
        os.makedirs(path)
        git(path, "init", "-q", "-b", "main")
        for rel, (text, mode) in files.items():
            os.makedirs(os.path.dirname(os.path.join(path, rel)), exist_ok=True)
            with open(os.path.join(path, rel), "w") as f:
                f.write(text)
            os.chmod(os.path.join(path, rel), mode)
        git(path, "add", "-A")
        git(path, "commit", "-q", "-m", name)
        return path

    def plain_copy(self, repo, name):
        """The checkout without .git, as fetchgit makes it."""
        copy = os.path.join(self.root, name)
        shutil.copytree(repo, copy, ignore=shutil.ignore_patterns(".git"), symlinks=True)
        return copy

    def test_rebuild(self):
        repo = self.repo("plain", {"a.py": ("x = 1\n", 0o644), "bin/run": ("#!/bin/sh\n", 0o755)})
        rev = git(repo, "rev-parse", "HEAD")
        raw = subprocess.run(["git", "cat-file", "commit", rev], cwd=repo, capture_output=True, check=True).stdout
        copy = self.plain_copy(repo, "copy")
        offline.rebuild_git(copy, rev, base64.b64encode(raw).decode(), [])
        self.assertEqual(git(copy, "rev-parse", "HEAD"), rev)
        self.assertEqual(git(copy, "status", "--porcelain"), "")

    def test_rebuild_with_submodule(self):
        sub = self.repo("sub", {"s.txt": ("sub\n", 0o644)})
        top = self.repo("top", {"t.txt": ("top\n", 0o644)})
        git(top, "submodule", "add", "-q", sub, "vendored")
        git(top, "commit", "-q", "-m", "add submodule")
        rev = git(top, "rev-parse", "HEAD")
        sub_rev = git(sub, "rev-parse", "HEAD")
        raw = subprocess.run(["git", "cat-file", "commit", rev], cwd=top, capture_output=True, check=True).stdout
        # fetchgit without submodules leaves the submodule directory empty.
        copy = self.plain_copy(top, "copy")
        shutil.rmtree(os.path.join(copy, "vendored"))
        os.makedirs(os.path.join(copy, "vendored"))
        offline.rebuild_git(copy, rev, base64.b64encode(raw).decode(), [{"path": "vendored", "rev": sub_rev}])
        self.assertEqual(git(copy, "rev-parse", "HEAD"), rev)
        self.assertIn(sub_rev, git(copy, "ls-tree", "HEAD", "vendored"))

    def test_rebuild_refuses_other_files(self):
        repo = self.repo("plain", {"a.py": ("x = 1\n", 0o644)})
        rev = git(repo, "rev-parse", "HEAD")
        raw = subprocess.run(["git", "cat-file", "commit", rev], cwd=repo, capture_output=True, check=True).stdout
        copy = self.plain_copy(repo, "copy")
        with open(os.path.join(copy, "a.py"), "w") as f:
            f.write("x = 2\n")
        with self.assertRaises(SystemExit):
            offline.rebuild_git(copy, rev, base64.b64encode(raw).decode(), [])


class Shims(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.checkout = os.path.join(self.tmp.name, "checkout")
        os.makedirs(self.checkout)
        with open(os.path.join(self.checkout, "setup.py"), "w") as f:
            f.write("")
        self.table = os.path.join(self.tmp.name, "shims.json")
        with open(self.table, "w") as f:
            json.dump(
                [
                    {"vcs": "hg", "url": "https://hg.example/r", "rev": "a" * 40, "version": None, "path": self.checkout},
                    {"vcs": "svn", "url": "https://svn.example/r", "rev": "7", "version": None, "path": self.checkout},
                    {"vcs": "bzr", "url": "https://bzr.example/r", "rev": "3", "version": None, "path": self.checkout},
                ],
                f,
            )

    def tearDown(self):
        self.tmp.cleanup()

    def shim(self, vcs, *args, cwd=None, check=True):
        result = subprocess.run(
            [sys.executable, SHIM, vcs, *args],
            cwd=cwd or self.tmp.name,
            env=dict(os.environ, PIP_PURIFIER_VCS_SHIMS=self.table),
            capture_output=True,
            text=True,
        )
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_hg(self):
        dest = os.path.join(self.tmp.name, "hg")
        self.shim("hg", "clone", "--noupdate", "-q", "https://hg.example/r", dest)
        self.shim("hg", "update", "-q", "--rev=" + "a" * 40, cwd=dest)
        self.assertEqual(self.shim("hg", "parents", "--template={node}", cwd=dest).stdout, "a" * 40)
        self.assertEqual(self.shim("hg", "showconfig", "paths.default", cwd=dest).stdout.strip(), "https://hg.example/r")
        self.assertTrue(os.path.exists(os.path.join(dest, "setup.py")))

    def test_svn(self):
        dest = os.path.join(self.tmp.name, "svn")
        self.assertTrue(self.shim("svn", "--version").stdout.startswith("svn, version "))
        self.shim("svn", "checkout", "-q", "--non-interactive", "-r", "7", "https://svn.example/r", dest)
        xml = self.shim("svn", "info", "--xml", dest).stdout
        self.assertIn('revision="7"', xml)
        self.assertIn("<url>https://svn.example/r</url>", xml)

    def test_bzr(self):
        dest = os.path.join(self.tmp.name, "bzr")
        self.shim("bzr", "checkout", "--lightweight", "-q", "-r", "3", "https://bzr.example/r", dest)
        self.assertEqual(self.shim("bzr", "revno", cwd=dest).stdout.strip(), "3")

    def test_unknown_url_and_command(self):
        result = self.shim("hg", "clone", "https://other.example/r", os.path.join(self.tmp.name, "x"), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Run `pip-purifier lock`", result.stderr)
        dest = os.path.join(self.tmp.name, "hg")
        self.shim("hg", "clone", "https://hg.example/r", dest)
        result = self.shim("hg", "log", cwd=dest, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not a command the locked checkout can answer", result.stderr)


if __name__ == "__main__":
    unittest.main()
