"""Regressions for package omissions and accidental configuration publication."""

import importlib.util
import json
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "cache_coverage",
    Path(__file__).resolve().parents[1] / "scripts/check-cache-coverage.py",
)
coverage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(coverage)


def derivation(name, path, **attrs):
    return {
        "name": name,
        "env": {},
        "structuredAttrs": attrs,
        "inputSrcs": [],
        "outputs": {"out": {"path": path}},
    }


class CacheCoverageTests(unittest.TestCase):
    def test_new_host_package_fails_even_without_pname(self):
        missing, _, _ = coverage.inspect_coverage(
            {"/cache"}, {"/new"}, {"new.drv": derivation("new-tool", "/new")}
        )
        self.assertEqual(missing, ["/new"])

    def test_local_script_does_not_exempt_its_package_dependencies(self):
        drvs = {
            "script.drv": derivation("relay", "/script", preferLocalBuild=True),
            "socat.drv": derivation("socat", "/socat", pname="socat"),
        }
        missing, _, local = coverage.inspect_coverage(
            {"/cache"}, {"/script", "/socat"}, drvs
        )
        self.assertEqual(missing, ["/socat"])
        self.assertEqual(local, ["/script"])
        self.assertEqual(
            coverage.inspect_coverage({"/socat"}, {"/script", "/socat"}, drvs)[0],
            [],
        )

    def test_private_configuration_cannot_be_published(self):
        for name in [
            "Corefile",
            "nix.custom.conf",
            "hm_gitconfig",
            "darwin-system-1",
            "home-manager-agents",
            "org.nix-community.home.gpg-agent.plist",
            "ca-certificates.crt",
        ]:
            with self.subTest(name=name):
                _, private, _ = coverage.inspect_coverage(
                    {"/private"},
                    {"/private"},
                    {
                        "private.drv": derivation(
                            name, "/private", preferLocalBuild=True
                        )
                    },
                )
                self.assertEqual(private, ["/private"])

    def test_exact_generator_exception_cannot_hide_a_package(self):
        d = derivation("darwin-version", "/version")
        self.assertEqual(
            coverage.inspect_coverage(set(), {"/version"}, {"d": d})[0], []
        )
        d["structuredAttrs"]["pname"] = "new-package"
        self.assertEqual(
            coverage.inspect_coverage(set(), {"/version"}, {"d": d})[0], ["/version"]
        )

    def test_legacy_derivation_attributes_and_source_files(self):
        d = derivation("local-config", "/config")
        d["env"]["preferLocalBuild"] = "1"
        d["inputSrcs"] = ["/source"]
        missing, _, local = coverage.inspect_coverage(
            set(), {"/config", "/source", "/unknown"}, {"d": d}
        )
        self.assertEqual(missing, ["/unknown"])
        self.assertEqual(local, ["/config", "/source"])

    def test_legacy_embedded_structured_attributes(self):
        d = derivation("local-config", "/config")
        d["env"]["__json"] = json.dumps({"preferLocalBuild": True})
        missing, _, local = coverage.inspect_coverage(set(), {"/config"}, {"d": d})
        self.assertEqual(missing, [])
        self.assertEqual(local, ["/config"])


if __name__ == "__main__":
    unittest.main()
