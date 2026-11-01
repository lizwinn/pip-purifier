# SPDX-License-Identifier: MIT
"""Unit tests of src/pip_purifier.py: wheel tags, file names, platform
arguments and URL handling."""

import unittest

import pip_purifier as pp


class Wheels(unittest.TestCase):
    def test_tags(self):
        self.assertEqual(
            pp.wheel_tags("pyyaml-6.0.3-cp314-cp314-manylinux2014_x86_64.manylinux_2_17_x86_64.whl"),
            (["cp314"], ["cp314"], ["manylinux2014_x86_64", "manylinux_2_17_x86_64"]),
        )
        self.assertIsNone(pp.wheel_tags("bad.whl"))

    def test_runs_on(self):
        x86 = "pyyaml-6.0.3-cp314-cp314-manylinux2014_x86_64.manylinux_2_17_x86_64.whl"
        self.assertTrue(pp.wheel_runs_on(x86, "x86_64", "3.14"))
        self.assertFalse(pp.wheel_runs_on(x86, "aarch64", "3.14"))
        self.assertFalse(pp.wheel_runs_on(x86, "x86_64", "3.13"))
        self.assertTrue(pp.wheel_runs_on("six-1.17.0-py2.py3-none-any.whl", "aarch64", "3.14"))
        self.assertTrue(pp.wheel_runs_on("cryptography-46.0.0-cp311-abi3-manylinux_2_28_aarch64.whl", "aarch64", "3.14"))
        self.assertFalse(pp.wheel_runs_on("x-1.0-cp314-cp314-macosx_11_0_arm64.whl", "aarch64", "3.14"))
        self.assertFalse(pp.wheel_runs_on("x-1.0-cp314-cp314-musllinux_1_2_x86_64.whl", "x86_64", "3.14"))

    def test_dist_name_version(self):
        self.assertEqual(pp.dist_name_version("Flit_Core-3.12.0-py3-none-any.whl"), ("flit-core", "3.12.0"))
        self.assertEqual(pp.dist_name_version("docopt-0.6.2.tar.gz"), ("docopt", "0.6.2"))
        self.assertEqual(pp.dist_name_version("zope.interface-7.2.zip"), ("zope-interface", "7.2"))
        self.assertIsNone(pp.dist_name_version("3.2.3.tar.gz"))

    def test_platform_args(self):
        args = pp.platform_args("aarch64", "3.14")
        self.assertIn("manylinux_2_28_aarch64", args)
        self.assertEqual(args[args.index("--python-version") + 1], "3.14")
        self.assertIn("cp314", args)


class Urls(unittest.TestCase):
    def test_strip_credentials(self):
        self.assertEqual(pp.strip_credentials("https://u:p@host.org:8443/simple/"), "https://host.org:8443/simple/")
        self.assertEqual(pp.strip_credentials("https://host.org/x"), "https://host.org/x")

    def test_file_name(self):
        self.assertEqual(pp.file_name("https://h/p/foo%2Bbar-1.0.tar.gz?x=1#sha256=00"), "foo+bar-1.0.tar.gz")

    def test_normalize(self):
        self.assertEqual(pp.normalize("Flit_Core.X"), "flit-core-x")

    def test_sri(self):
        self.assertEqual(pp.sri(bytes(32)), "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")


if __name__ == "__main__":
    unittest.main()
