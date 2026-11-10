import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PWSH = shutil.which("pwsh")
MOCK_TOOL = r'''import json
import os
import sys
from pathlib import Path

tool = sys.argv.pop(1) if Path(sys.argv[0]).name == "mock.py" else Path(sys.argv[0]).name
args = sys.argv[1:]
entry = {"tool": tool, "args": args}
if "--stdin" in args or ("--filename" in args and args[args.index("--filename") + 1] == "-"):
    entry["stdin"] = sys.stdin.read()
with open(os.environ["SHOP_TEST_LOG"], "a") as log:
    log.write(json.dumps(entry) + "\n")
if os.environ.get("SHOP_TEST_FAIL") == tool:
    print("Mock command failed", file=sys.stderr)
    sys.exit(9)
if tool == "az":
    if args[:2] == ["account", "show"]:
        print("test-tenant" if "tenantId" in args else "test-subscription")
    elif args[:3] == ["ad", "sp", "create-for-rbac"]:
        print(json.dumps({"appId": "test-client", "password": "test-secret",
                          "tenant": "test-tenant"}))
    elif args[:3] == ["ad", "sp", "show"]:
        if os.environ.get("SHOP_TEST_LOOKUP_FAIL"):
            print("Mock directory lookup failed", file=sys.stderr)
            sys.exit(1)
        print("test-object")
    elif args[:2] == ["aro", "get-versions"]:
        print('["4.9.9", "4.20.1", "4.19.9"]')
    elif args[:2] == ["aro", "get-admin-kubeconfig"]:
        if "--overwrite-existing" in args:
            raise SystemExit("Unsupported ARO argument: --overwrite-existing")
        with Path(args[args.index("--file") + 1]).open("x") as file:
            file.write("current-context: same-admin-name\n")
    elif args[:2] == ["aro", "show"]:
        print("https://console-openshift-console.apps.demo.example/")
    elif args[:3] == ["afd", "origin", "list"]:
        print("aro\nonprem" if "tsv" in args else '["aro", "onprem"]')
    elif args[:3] == ["keyvault", "secret", "list"]:
        print('["shop-db-password", "shop-redis-password"]')
    elif args[:3] == ["afd", "endpoint", "show"]:
        print("frontdoor.example")
    elif args[:3] == ["redisenterprise", "database", "list-keys"]:
        print("redis-secret")
    elif args[:3] == ["deployment", "group", "show"]:
        print("managed-identity-client")
    elif args[:3] == ["deployment", "group", "create"]:
        value = args[args.index("--parameters") + 1]
        if value.startswith("@"):
            document = json.loads(Path(value[1:]).read_text(encoding="utf-8"))
            with open(os.environ["SHOP_TEST_PARAMETERS"], "w") as file:
                json.dump(document, file)
        else:
            assert value == "frontDoorProfileName=test-frontdoor"
            log_lines = Path(os.environ["SHOP_TEST_LOG"]).read_text().splitlines()
            entries = [json.loads(line) for line in log_lines]
            updates = [
                entry["args"] for entry in entries
                if entry["args"][:3] == ["afd", "origin", "update"]
            ]
            assert updates[-1][updates[-1].index("--enabled-state") + 1] == "Enabled"
elif tool == "kubectl":
    if "config" in args and "view" in args:
        print(json.dumps({
            "current-context": "same-admin-name",
            "contexts": [{"name": "same-admin-name",
                          "context": {"cluster": "cluster", "user": "admin"}}],
            "clusters": [{"name": "cluster", "cluster": {"server": "https://cluster.example"}}],
            "users": [{"name": "admin", "user": {"token": "fake-token"}}]
        }))
    elif "create" in args:
        print("apiVersion: v1\nkind: Secret\nmetadata:\n  name: mock")
elif tool == "rad":
    if args[:2] == ["resource", "show"]:
        cache = "redisCaches" in args[2]
        print(json.dumps({"properties": {"host": "redis.example" if cache else "db.example",
                                         "port": 10000 if cache else 5432}}))
elif tool == "oc":
    print("apiVersion: route.openshift.io/v1\nkind: Route\nmetadata:\n  name: shop")
'''


@unittest.skipUnless(PWSH, "PowerShell 7 is not installed")
class PowerShellTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="shop windows test ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        scripts = self.root / "scripts"
        (scripts / "lib").mkdir(parents=True)
        for path in (ROOT / "scripts").glob("*"):
            if path.suffix not in (".ps1", ".sh"):
                continue
            shutil.copy2(path, scripts / path.name)
        for name in ("common.ps1", "common.sh"):
            shutil.copy2(ROOT / "scripts/lib" / name, scripts / "lib" / name)
        for directory in ("infra", "dapr", "radius"):
            shutil.copytree(ROOT / directory, self.root / directory)
        (self.root / "app/api").mkdir(parents=True)
        shutil.copy2(ROOT / "app/api/init.sql", self.root / "app/api/init.sql")
        self.env_file = self.root / ".env"
        self.env_file.write_text(
            "AZURE_RESOURCE_GROUP=test-group\nAZURE_LOCATION=eastus\n"
            "KEY_VAULT_NAME=test-vault\nFRONT_DOOR_PROFILE_NAME=test-frontdoor\n"
            "ARO_SERVICE_PRINCIPAL_CLIENT_ID=\nARO_SERVICE_PRINCIPAL_CLIENT_SECRET=\n"
            "ARO_SERVICE_PRINCIPAL_OBJECT_ID=\nIMAGE_TAG=test\n"
        )
        tools = self.root / "bin"
        tools.mkdir()
        mock = tools / "mock.py"
        mock.write_text(MOCK_TOOL)
        for name in ("az", "kubectl", "rad", "helm", "oc", "git", "docker", "dapr", "curl"):
            if os.name == "nt":
                (tools / f"{name}.cmd").write_text(f'@"{sys.executable}" "{mock}" {name} %*\n')
            else:
                executable = tools / name
                executable.write_text("#!/usr/bin/env python3\n" + MOCK_TOOL)
                executable.chmod(0o755)
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("ARO_", "ONPREM_", "AZURE_", "SHOP_TEST_"))
            and key not in ("KUBECONFIG", "DATABASE_PASSWORD", "IMAGE_TAG", "AZ_TEST_LOG")
        }
        self.env.update(
            PATH=str(tools) + os.pathsep + os.environ["PATH"],
            AZURE_SUBSCRIPTION_ID="test-subscription",
            SHOP_TEST_LOG=str(self.root / "commands.jsonl"),
            SHOP_TEST_PARAMETERS=str(self.root / "parameters.json"),
        )
        self.credentials = self.root / ".secrets/service-principal.json"

    def run_ps(self, command, input_text=None):
        return subprocess.run(
            [PWSH, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command],
            cwd=self.root, env=self.env, input=input_text, capture_output=True,
            text=True, encoding="utf-8",
        )

    def entries(self):
        log = self.root / "commands.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def save_credentials(self, object_id="test-object"):
        self.credentials.parent.mkdir(exist_ok=True)
        value = {"appId": "test-client", "password": "test-secret", "tenant": "test-tenant"}
        if object_id:
            value["objectId"] = object_id
        self.credentials.write_text(json.dumps(value))

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_creates_and_reuses_private_credentials(self):
        first = self.run_ps("& ./scripts/05-create-service-principal.ps1")
        self.assert_success(first)
        saved = self.credentials.read_bytes()
        self.assertEqual(json.loads(saved)["objectId"], "test-object")
        second = self.run_ps("& ./scripts/05-create-service-principal.ps1")
        self.assert_success(second)
        self.assertEqual(self.credentials.read_bytes(), saved)
        creations = [entry for entry in self.entries() if "create-for-rbac" in entry["args"]]
        self.assertEqual(len(creations), 1)
        self.assertIn("--skip-assignment", creations[0]["args"])
        self.assertNotIn("test-secret", first.stdout + first.stderr + second.stdout + second.stderr)
        if os.name == "nt":
            result = self.run_ps(
                ". ./scripts/lib/common.ps1; "
                "$acl = Get-Acl .secrets/service-principal.json; "
                "if (-not $acl.AreAccessRulesProtected) { throw 'Unprotected ACL' }; "
                "$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; "
                "foreach ($rule in $acl.Access) { "
                "$identity = $rule.IdentityReference.Translate("
                "[Security.Principal.SecurityIdentifier]).Value; "
                "if ($identity -ne $sid) { throw 'Unexpected ACL identity' } }"
            )
            self.assert_success(result)
        else:
            self.assertEqual(stat.S_IMODE(self.credentials.stat().st_mode), 0o600)

    def test_resumes_saved_credentials_without_rotating_password(self):
        self.save_credentials(object_id=None)
        self.assert_success(self.run_ps("& ./scripts/05-create-service-principal.ps1"))
        self.assertFalse(any("create-for-rbac" in entry["args"] for entry in self.entries()))
        self.assertEqual(json.loads(self.credentials.read_text())["password"], "test-secret")

    @unittest.skipUnless(os.name == "nt", "Windows access-control regression")
    def test_permissions_work_without_security_privilege_and_preserve_ownership(self):
        self.save_credentials()
        result = self.run_ps(r'''
            $ErrorActionPreference = 'Stop'
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class TestToken {
    [StructLayout(LayoutKind.Sequential)]
    public struct Luid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)]
    public struct TokenPrivileges {
        public uint Count; public Luid Luid; public uint Attributes;
    }
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool LookupPrivilegeValue(string system, string name, out Luid luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll,
        ref TokenPrivileges privileges, uint length, IntPtr previous, IntPtr required);
    public static void RemoveSecurityPrivilege() {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            Luid luid;
            if (!LookupPrivilegeValue(null, "SeSecurityPrivilege", out luid))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            // Remove this privilege only from the disposable test process.
            var privileges = new TokenPrivileges { Count = 1, Luid = luid, Attributes = 4 };
            if (!AdjustTokenPrivileges(token, false, ref privileges, 0,
                                       IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            int error = Marshal.GetLastWin32Error();
            if (error != 0 && error != 1300) // 1300 means it was already absent.
                throw new Win32Exception(error);
        } finally { CloseHandle(token); }
    }
}
'@
            [TestToken]::RemoveSecurityPrivilege()
            . ./scripts/lib/common.ps1
            $paths = @('.secrets', '.secrets/service-principal.json')
            $owners = @{}
            foreach ($path in $paths) { $owners[$path] = (Get-Acl $path).Owner }
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            foreach ($path in $paths) {
                Protect-PrivatePath (Join-Path $PWD $path)
                Protect-PrivatePath (Join-Path $PWD $path)
                $acl = Get-Acl $path
                if ($acl.Owner -ne $owners[$path]) { throw 'Owner changed' }
                if (-not $acl.AreAccessRulesProtected) { throw 'Inherited access remains' }
                if (@($acl.Access).Count -ne 1) { throw 'Unexpected access rules' }
                $rule = @($acl.Access)[0]
                $identity = $rule.IdentityReference.Translate(
                    [Security.Principal.SecurityIdentifier]).Value
                if ($identity -ne $sid -or $rule.AccessControlType -ne 'Allow' -or
                    $rule.FileSystemRights -ne 'FullControl') {
                    throw 'Current-user-only FullControl was not applied'
                }
            }
        ''')
        self.assert_success(result)
        self.assertEqual(json.loads(self.credentials.read_text())["password"], "test-secret")

    def test_partial_explicit_credentials_fail_without_mixing(self):
        self.save_credentials()
        with self.env_file.open("a") as file:
            file.write("ARO_SERVICE_PRINCIPAL_CLIENT_ID=another-client\n")
        result = self.run_ps("& ./scripts/05-create-service-principal.ps1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ARO_SERVICE_PRINCIPAL_CLIENT_SECRET", result.stderr)
        self.assertFalse(any("create-for-rbac" in entry["args"] for entry in self.entries()))

    def test_config_preserves_windows_paths_and_uses_platform_kubeconfig_separator(self):
        with self.env_file.open("a") as file:
            file.write('RED_HAT_PULL_SECRET_FILE="C:\\Users\\Demo User\\pull-secret.json"\n')
        result = self.run_ps(
            ". ./scripts/lib/common.ps1; $c = Get-ShopConfig; "
            "@{path=$c.RED_HAT_PULL_SECRET_FILE; kubeconfig=$env:KUBECONFIG} | ConvertTo-Json"
        )
        self.assert_success(result)
        value = json.loads(result.stdout)
        self.assertEqual(value["path"], r"C:\Users\Demo User\pull-secret.json")
        self.assertEqual([
            Path(path).resolve() for path in value["kubeconfig"].split(os.pathsep)
        ], [
            (self.root / ".secrets/aro-demo.kubeconfig").resolve(),
            (self.root / ".secrets/onprem-demo.kubeconfig").resolve(),
        ])

    def test_native_failure_stops_and_does_not_log_secret_arguments(self):
        self.env["SHOP_TEST_FAIL"] = "az"
        result = self.run_ps(
            ". ./scripts/lib/common.ps1; Invoke-Tool az @('account', 'set', 'private-argument')"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exit code 9", result.stderr)
        # PowerShell can include the source line in error rendering; check the thrown message.
        self.assertNotIn("private-argument", result.stderr.split("Exception:")[-1])

    def test_preflight_and_login_use_saved_credentials_without_printing_them(self):
        self.save_credentials()
        for script in ("00-check-prerequisites", "25-login-service-principal"):
            result = self.run_ps(f"& ./scripts/{script}.ps1")
            self.assert_success(result)
            self.assertNotIn("test-secret", result.stdout + result.stderr)
        logins = [entry["args"] for entry in self.entries() if entry["args"][:1] == ["login"]]
        self.assertEqual(len(logins), 1)
        self.assertIn("--password=test-secret", logins[0])

    def test_infrastructure_uses_latest_version_and_cleans_secret_parameter_file(self):
        self.save_credentials()
        result = self.run_ps("& ./scripts/10-apply-infrastructure.ps1")
        self.assert_success(result)
        parameters = json.loads((self.root / "parameters.json").read_text())["parameters"]
        self.assertEqual(parameters["openShiftVersion"]["value"], "4.20.1")
        self.assertEqual(parameters["aroServicePrincipalClientSecret"]["value"], "test-secret")
        self.assertFalse(list(self.credentials.parent.glob("infra-parameters-*")))

    def test_credentials_have_distinct_cluster_and_user_names(self):
        self.assert_success(self.run_ps("& ./scripts/20-get-cluster-credentials.ps1"))
        self.assert_success(self.run_ps("& ./scripts/20-get-cluster-credentials.ps1"))
        for target in ("aro", "onprem"):
            value = json.loads((self.root / f".secrets/{target}-demo.kubeconfig").read_text())
            self.assertEqual(value["current-context"], f"{target}-demo")
            self.assertEqual(value["clusters"][0]["name"], f"{target}-demo-cluster")
            self.assertEqual(value["users"][0]["name"], f"{target}-demo-user")
        self.assertFalse(list((self.root / ".secrets").glob("*-admin-*")))

    @unittest.skipIf(os.name == "nt", "Bash parity is checked on Linux")
    def test_bash_credentials_tls_route_and_traffic_switch_match_powershell_cli_behavior(self):
        self.save_credentials()
        for script, arguments in (
            ("20-get-cluster-credentials", []),
            ("20-get-cluster-credentials", []),
            ("50-deploy-target", ["aro"]),
            ("90-switch-traffic", ["aro"]),
            ("90-switch-traffic", ["onprem"]),
        ):
            result = subprocess.run(
                ["bash", f"scripts/{script}.sh", *arguments],
                cwd=self.root, env=self.env, capture_output=True, text=True,
            )
            self.assert_success(result)
        routes = [entry for entry in self.entries() if entry["tool"] == "oc"]
        self.assertTrue(any("edge" in entry["args"] for entry in routes))
        route_deployments = [
            entry for entry in self.entries()
            if entry["args"][:3] == ["deployment", "group", "create"]
        ]
        self.assertEqual(len(route_deployments), 2)
        value = json.loads((self.root / ".secrets/aro-demo.kubeconfig").read_text())
        self.assertEqual(value["current-context"], "aro-demo")

    def test_deploys_each_target_with_sql_stdin_and_patch_file(self):
        self.save_credentials()
        for target in ("aro", "onprem"):
            with self.subTest(target=target):
                result = self.run_ps(
                    "function Invoke-WebRequest { @{ StatusCode = 200 } }; "
                    f"& ./scripts/50-deploy-target.ps1 -Target {target}"
                )
                self.assert_success(result)
        entries = self.entries()
        sql = [entry["stdin"] for entry in entries if "--stdin" in entry["args"]]
        self.assertEqual(len(sql), 2)
        self.assertTrue(all("INSERT INTO products" in text for text in sql))
        patches = [entry for entry in entries if "--patch-file" in entry["args"]]
        self.assertEqual(len(patches), 2)
        routes = [entry for entry in entries if entry["tool"] == "oc"]
        self.assertTrue(all("edge" in entry["args"] for entry in routes))
        self.assertFalse(list(self.credentials.parent.glob("*parameters-*")))
        self.assertFalse(list(self.credentials.parent.glob("deployment-patch-*")))

    def test_failed_deployment_cleans_up_without_registering_an_origin(self):
        self.save_credentials()
        self.env["SHOP_TEST_FAIL"] = "rad"
        result = self.run_ps("& ./scripts/50-deploy-target.ps1 -Target aro")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exit code 9", result.stderr)
        self.assertFalse(list(self.credentials.parent.glob("deploy-parameters-*")))
        entries = self.entries()
        self.assertTrue(any(
            "secret/shop-db-seed-credentials" in entry["args"] for entry in entries
        ))
        self.assertFalse(any(entry["args"][:2] == ["afd", "origin"] for entry in entries))

    def test_bootstrap_and_recipes_use_separate_cluster_contexts(self):
        self.save_credentials()
        for script in ("30-bootstrap-clusters", "40-configure-radius"):
            self.assert_success(self.run_ps(f"& ./scripts/{script}.ps1"))
        entries = self.entries()
        installs = [
            entry["args"] for entry in entries
            if entry["tool"] == "rad" and entry["args"][:2] == ["install", "kubernetes"]
        ]
        self.assertEqual(
            [args[args.index("--kubecontext") + 1] for args in installs],
            ["aro-demo", "onprem-demo"],
        )
        self.assertFalse(any("demo-outage.yaml" in " ".join(entry["args"]) for entry in entries))

    def test_reset_disables_origins_before_deleting_applications(self):
        self.assert_success(self.run_ps("& ./scripts/80-reset-demo.ps1"))
        entries = self.entries()
        updates = [
            index for index, entry in enumerate(entries)
            if entry["args"][:3] == ["afd", "origin", "update"]
        ]
        deletions = [
            index for index, entry in enumerate(entries)
            if entry["tool"] == "rad" and entry["args"][:2] == ["app", "delete"]
        ]
        self.assertEqual(len(updates), 2)
        self.assertEqual(len(deletions), 2)
        self.assertLess(max(updates), min(deletions))
        self.assertFalse(any(entry["args"][:2] == ["group", "delete"] for entry in entries))

    def test_switch_disables_old_origin_before_enabling_target(self):
        result = self.run_ps(
            "function Invoke-WebRequest { @{ StatusCode = 200 } }; "
            "& ./scripts/90-switch-traffic.ps1 -Target onprem"
        )
        self.assert_success(result)
        updates = [
            entry["args"] for entry in self.entries()
            if entry["args"][:3] == ["afd", "origin", "update"]
        ]
        self.assertEqual(len(updates), 2)
        self.assertEqual(updates[0][updates[0].index("--origin-name") + 1], "aro")
        self.assertEqual(updates[0][updates[0].index("--enabled-state") + 1], "Disabled")
        self.assertEqual(updates[1][updates[1].index("--enabled-state") + 1], "Enabled")

    def test_switch_deploys_route_after_enabling_origin_on_each_run(self):
        for target in ("aro", "onprem"):
            result = self.run_ps(
                "function Invoke-WebRequest { @{ StatusCode = 200 } }; "
                f"& ./scripts/90-switch-traffic.ps1 -Target {target}"
            )
            self.assert_success(result)
        entries = self.entries()
        deployments = [
            (index, entry["args"]) for index, entry in enumerate(entries)
            if entry["args"][:3] == ["deployment", "group", "create"]
        ]
        self.assertEqual(len(deployments), 2)
        for index, args in deployments:
            self.assertEqual(
                Path(args[args.index("--template-file") + 1]).name, "front-door-route.bicep",
            )
            self.assertEqual(
                args[args.index("--parameters") + 1], "frontDoorProfileName=test-frontdoor",
            )
            self.assertEqual(entries[index - 1]["args"][:3], ["afd", "origin", "update"])
            self.assertEqual(
                entries[index - 1]["args"][entries[index - 1]["args"].index("--enabled-state") + 1],
                "Enabled",
            )

    def test_destroy_rejects_mismatched_confirmation(self):
        result = self.run_ps(
            "function Read-Host { 'wrong-group' }; & ./scripts/95-destroy-infrastructure.ps1"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(entry["args"][:2] == ["group", "delete"] for entry in self.entries()))


if __name__ == "__main__":
    unittest.main()
