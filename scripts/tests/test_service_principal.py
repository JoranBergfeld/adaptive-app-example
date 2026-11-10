import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MOCK_AZ = """#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
with open(os.environ["AZ_TEST_LOG"], "a") as log:
    log.write(json.dumps(args) + "\\n")
if args[:4] == ["ad", "sp", "create-for-rbac", "--name"]:
    if os.environ.get("AZ_TEST_CREATE_FAILURE"):
        print("Directory permission denied", file=sys.stderr)
        sys.exit(1)
    print(json.dumps({"appId": "test-client", "password": "test-secret",
                      "tenant": "test-tenant"}))
elif args[:3] == ["ad", "sp", "show"]:
    if os.environ.get("AZ_TEST_LOOKUP_FAILURE"):
        print("Directory lookup failed", file=sys.stderr)
        sys.exit(1)
    print("test-object")
elif args[:2] != ["account", "set"]:
    raise SystemExit("Unexpected Azure command: " + repr(args))
"""


class ServicePrincipalTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "scripts/lib").mkdir(parents=True)
        for path in ("scripts/lib/common.sh", "scripts/05-create-service-principal.sh"):
            shutil.copy2(ROOT / path, self.root / path)
        (self.root / ".env").write_text(
            "ARO_SERVICE_PRINCIPAL_CLIENT_ID=\n"
            "ARO_SERVICE_PRINCIPAL_CLIENT_SECRET=\n"
            "ARO_SERVICE_PRINCIPAL_OBJECT_ID=\n"
        )
        tools = self.root / "bin"
        tools.mkdir()
        for name, content in (
            ("az", MOCK_AZ),
            ("sleep", "#!/usr/bin/env bash\nexit 0\n"),
        ):
            tool = tools / name
            tool.write_text(content)
            tool.chmod(0o755)
        self.env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("ARO_SERVICE_PRINCIPAL_", "AZ_TEST_"))
        }
        self.env.update(
            PATH=f"{tools}:{os.environ['PATH']}",
            AZ_TEST_LOG=str(self.root / "az.log"),
            AZURE_SUBSCRIPTION_ID="test-subscription",
            AZURE_RESOURCE_GROUP="test-group",
            IMAGE_TAG="test",
        )
        self.credentials = self.root / ".secrets/service-principal.json"

    def run_setup(self):
        return subprocess.run(
            ["bash", "scripts/05-create-service-principal.sh"],
            cwd=self.root, env=self.env, capture_output=True, text=True,
        )

    def commands(self):
        return [
            json.loads(line)
            for line in (self.root / "az.log").read_text().splitlines()
        ]

    def test_creates_private_credentials_and_reuses_them(self):
        first = self.run_setup()
        self.assertEqual(first.returncode, 0, first.stderr)
        original = self.credentials.read_bytes()
        self.assertEqual(json.loads(original)["objectId"], "test-object")
        self.assertEqual(stat.S_IMODE(self.credentials.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.credentials.parent.stat().st_mode), 0o700)
        second = self.run_setup()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.credentials.read_bytes(), original)
        creations = [
            args for args in self.commands() if args[:3] == ["ad", "sp", "create-for-rbac"]
        ]
        self.assertEqual(len(creations), 1)
        self.assertIn("--skip-assignment", creations[0])
        self.assertNotIn("--role", creations[0])
        self.assertNotIn("test-secret", first.stdout + first.stderr + second.stdout + second.stderr)
        loaded = subprocess.run(
            ["bash", "-c", "source scripts/lib/common.sh; load_config; "
             'printf "%s/%s" "$ARO_SERVICE_PRINCIPAL_OBJECT_ID" "$AZURE_TENANT_ID"'],
            cwd=self.root, env={**self.env, "AZURE_TENANT_ID": ""},
            capture_output=True, text=True, check=True,
        )
        self.assertEqual(loaded.stdout, "test-object/test-tenant")

    def test_directory_lookup_failure_preserves_password_for_retry(self):
        self.env["AZ_TEST_LOOKUP_FAILURE"] = "1"
        first = self.run_setup()
        self.assertNotEqual(first.returncode, 0)
        self.assertEqual(json.loads(self.credentials.read_text())["password"], "test-secret")
        del self.env["AZ_TEST_LOOKUP_FAILURE"]
        second = self.run_setup()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(
            sum(args[:3] == ["ad", "sp", "create-for-rbac"] for args in self.commands()), 1,
        )

    def test_partial_explicit_configuration_does_not_create_or_mix_credentials(self):
        self.assertEqual(self.run_setup().returncode, 0)
        saved = self.credentials.read_bytes()
        (self.root / ".env").write_text("ARO_SERVICE_PRINCIPAL_CLIENT_ID=another-client\n")
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ARO_SERVICE_PRINCIPAL_CLIENT_SECRET", result.stderr)
        self.assertEqual(self.credentials.read_bytes(), saved)
        self.assertEqual(
            sum(args[:3] == ["ad", "sp", "create-for-rbac"] for args in self.commands()), 1,
        )

    def test_explicit_credentials_are_kept(self):
        (self.root / ".env").write_text(
            "ARO_SERVICE_PRINCIPAL_CLIENT_ID=existing-client\n"
            "ARO_SERVICE_PRINCIPAL_CLIENT_SECRET=existing-secret\n"
            "ARO_SERVICE_PRINCIPAL_OBJECT_ID=existing-object\n"
        )
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.credentials.exists())
        self.assertFalse(any(args[:2] == ["ad", "sp"] for args in self.commands()))

    def test_explicit_credentials_do_not_overwrite_a_different_saved_principal(self):
        self.assertEqual(self.run_setup().returncode, 0)
        saved = self.credentials.read_bytes()
        (self.root / ".env").write_text(
            "ARO_SERVICE_PRINCIPAL_CLIENT_ID=another-client\n"
            "ARO_SERVICE_PRINCIPAL_CLIENT_SECRET=another-secret\n"
        )
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ARO_SERVICE_PRINCIPAL_OBJECT_ID", result.stderr)
        self.assertEqual(self.credentials.read_bytes(), saved)

    def test_invalid_saved_credentials_fail_without_creating_an_identity(self):
        self.credentials.parent.mkdir()
        self.credentials.write_text("{}")
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid saved service principal credentials", result.stderr)
        self.assertFalse((self.root / "az.log").exists())
        self.assertEqual(self.credentials.read_text(), "{}")

    def test_creation_failure_is_not_saved_as_success(self):
        self.env["AZ_TEST_CREATE_FAILURE"] = "1"
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Directory permission denied", result.stderr)
        self.assertFalse(self.credentials.exists())
        self.assertFalse(list((self.root / ".secrets").iterdir()))


if __name__ == "__main__":
    unittest.main()
