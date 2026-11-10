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
        target = "onprem" if "-onprem-" in args[args.index("--name") + 1] else "test"
        print(json.dumps({"appId": target + "-client", "password": target + "-secret",
                          "tenant": "test-tenant"}))
    elif args[:3] == ["ad", "sp", "show"]:
        if os.environ.get("SHOP_TEST_LOOKUP_FAIL"):
            print("Mock directory lookup failed", file=sys.stderr)
            sys.exit(1)
        if os.environ.get("SHOP_TEST_PROVIDER_EMPTY") and \
                args[args.index("--id") + 1] == "f1dd0a37-89c6-4e07-bcd1-ffd3d43d8875":
            print("")
        else:
            print({
                "onprem-client": "onprem-object",
                "f1dd0a37-89c6-4e07-bcd1-ffd3d43d8875": "provider-object",
            }.get(args[args.index("--id") + 1], "test-object"))
    elif args[:2] == ["aro", "get-versions"]:
        print('["4.9.9", "4.20.1", "4.19.9"]')
    elif args[:2] == ["bicep", "build"]:
        print(json.dumps({"resources": [
            {"type": "Microsoft.RedHatOpenShift/openShiftClusters",
             "name": "[parameters('%s')]" % parameter,
             "properties": {"masterProfile": {"vmSize": "[parameters('aroMasterVmSize')]"},
                            "workerProfiles": [{"vmSize": "[parameters('aroWorkerVmSize')]",
                                                "count": 3}]}}
            for parameter in ("aroClusterName", "onpremClusterName")
        ]}))
    elif args[:2] == ["vm", "list-skus"]:
        print(os.environ.get("SHOP_TEST_SKUS", json.dumps([
            {"name": name, "family": "standardDSv5Family", "restrictions": [],
             "capabilities": [{"name": "vCPUs", "value": str(cores)}]}
            for name, cores in (("Standard_D8s_v5", 8), ("Standard_D4s_v5", 4))
        ])))
    elif args[:2] == ["vm", "list-usage"]:
        print(os.environ.get("SHOP_TEST_USAGE", json.dumps([
            {"name": {"value": name}, "currentValue": 0, "limit": 100}
            for name in ("cores", "standardDSv5Family")
        ])))
    elif args[:2] == ["group", "exists"]:
        print("true")
    elif args[:3] == ["role", "assignment", "list"]:
        if os.environ.get("SHOP_TEST_ROLE_LOOKUP_FAIL"):
            print("Mock role assignment lookup failed", file=sys.stderr)
            sys.exit(1)
        scope = args[args.index("--scope") + 1]
        print(os.environ.get("SHOP_TEST_ROLES", "[]").replace("TEST_VNET_SCOPE", scope.upper()))
    elif args[:2] == ["aro", "list"]:
        print(os.environ.get("SHOP_TEST_CLUSTERS", "[]"))
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
    elif args[:3] == ["deployment", "group", "validate"]:
        if os.environ.get("SHOP_TEST_VALIDATION_FAIL"):
            print("Mock provider validation failed", file=sys.stderr)
            sys.exit(1)
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
        for path in (ROOT / "scripts/lib").glob("*"):
            if path.suffix in (".ps1", ".sh"):
                shutil.copy2(path, scripts / "lib" / path.name)
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
        (self.credentials.parent / "onprem-service-principal.json").write_text(json.dumps({
            "appId": "onprem-client", "password": "onprem-secret", "tenant": "test-tenant",
            "objectId": "onprem-object",
        }))

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

    def test_creates_and_reuses_separate_onprem_principal_without_changing_primary(self):
        self.save_credentials()
        original = self.credentials.read_bytes()
        onprem = self.credentials.parent / "onprem-service-principal.json"
        onprem.unlink()
        for _ in range(2):
            self.assert_success(self.run_ps(
                "& ./scripts/05-create-service-principal.ps1 -Target onprem"))
        self.assertEqual(self.credentials.read_bytes(), original)
        self.assertEqual(json.loads(onprem.read_text())["appId"], "onprem-client")
        creations = [entry for entry in self.entries() if "create-for-rbac" in entry["args"]]
        self.assertEqual(len(creations), 1)
        result = self.run_ps(
            ". ./scripts/lib/common.ps1; $c = Get-ShopConfig; "
            "@{aro=$c.ARO_SERVICE_PRINCIPAL_CLIENT_ID; "
            "onprem=$c.ONPREM_SERVICE_PRINCIPAL_CLIENT_ID} | ConvertTo-Json")
        self.assert_success(result)
        self.assertEqual(json.loads(result.stdout), {"aro": "test-client", "onprem": "onprem-client"})

    def test_onprem_partial_explicit_configuration_does_not_mix_saved_credentials(self):
        self.save_credentials()
        with self.env_file.open("a") as file:
            file.write("ONPREM_SERVICE_PRINCIPAL_CLIENT_ID=another-client\n")
        result = self.run_ps("& ./scripts/05-create-service-principal.ps1 -Target onprem")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ONPREM_SERVICE_PRINCIPAL_CLIENT_SECRET", result.stderr)
        self.assertFalse(any("create-for-rbac" in entry["args"] for entry in self.entries()))

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
        self.assertEqual(parameters["onpremServicePrincipalClientId"]["value"], "onprem-client")
        self.assertEqual(parameters["onpremServicePrincipalClientSecret"]["value"], "onprem-secret")
        self.assertEqual(parameters["onpremServicePrincipalObjectId"]["value"], "onprem-object")
        self.assertEqual(parameters["aroResourceProviderObjectId"]["value"], "provider-object")
        self.assertFalse(list(self.credentials.parent.glob("infra-parameters-*")))
        commands = [entry["args"][:3] for entry in self.entries()]
        self.assertLess(commands.index(["deployment", "group", "validate"]),
                        commands.index(["deployment", "group", "create"]))

    def test_infrastructure_rejects_shared_or_missing_cluster_principals_before_cloud_changes(self):
        self.save_credentials()
        onprem = self.credentials.parent / "onprem-service-principal.json"
        for key in ("appId", "objectId"):
            with self.subTest(key=key):
                value = {"appId": "onprem-client", "password": "onprem-secret",
                         "tenant": "test-tenant", "objectId": "onprem-object"}
                value[key] = json.loads(self.credentials.read_text())[key]
                onprem.write_text(json.dumps(value))
                result = self.run_ps("& ./scripts/10-apply-infrastructure.ps1")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unique service principal", result.stderr)
        onprem.unlink()
        result = self.run_ps("& ./scripts/10-apply-infrastructure.ps1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ONPREM_SERVICE_PRINCIPAL_CLIENT_ID", result.stderr)
        self.assertEqual(self.entries(), [])

    def test_missing_resource_provider_identity_stops_before_deployment(self):
        self.save_credentials()
        self.env["SHOP_TEST_PROVIDER_EMPTY"] = "1"
        result = self.run_ps("& ./scripts/10-apply-infrastructure.ps1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("resource provider service principal object ID", result.stderr)
        self.assertFalse(any(entry["args"][:2] == ["deployment", "group"]
                             for entry in self.entries()))

    def test_existing_provider_network_role_name_is_reused_at_exact_scope(self):
        self.save_credentials()
        self.env["SHOP_TEST_ROLES"] = json.dumps([
            {"name": name, "scope": scope, "principalId": principal,
             "roleDefinitionId": "/providers/Microsoft.Authorization/roleDefinitions/" + role}
            for name, scope, principal, role in (
                ("existing-provider-role", "TEST_VNET_SCOPE", "PROVIDER-OBJECT",
                 "4D97B98B-1D4F-4787-A291-C67834D212E7"),
                ("other-principal", "TEST_VNET_SCOPE", "other",
                 "4d97b98b-1d4f-4787-a291-c67834d212e7"),
                ("other-role", "TEST_VNET_SCOPE", "provider-object",
                 "b24988ac-6180-42a0-ab88-20f7382dd24c"),
                ("inherited-role", "/subscriptions/test-subscription", "provider-object",
                 "4d97b98b-1d4f-4787-a291-c67834d212e7"),
            )
        ])
        result = self.run_ps("& ./scripts/10-apply-infrastructure.ps1")
        self.assert_success(result)
        parameters = json.loads((self.root / "parameters.json").read_text())["parameters"]
        for key in ("aroProviderNetworkRoleName", "onpremProviderNetworkRoleName"):
            self.assertEqual(parameters[key]["value"], "existing-provider-role")
        self.assertFalse(any(entry["args"][:3] in
                             (["role", "assignment", "delete"], ["role", "assignment", "create"])
                             for entry in self.entries()))

    def test_provider_role_lookup_failure_stops_before_deployment(self):
        self.save_credentials()
        self.env["SHOP_TEST_ROLE_LOOKUP_FAIL"] = "1"
        result = self.run_ps("& ./scripts/10-apply-infrastructure.ps1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("role assignment lookup failed", result.stderr)
        self.assertFalse(any(entry["args"][:2] == ["deployment", "group"]
                             for entry in self.entries()))

    @unittest.skipUnless(os.name != "nt" and shutil.which("bash") and shutil.which("jq"),
                         "Requires POSIX Bash and jq")
    def test_bash_provider_role_lookup_reuses_exact_match_and_fails_closed(self):
        self.save_credentials()
        with self.env_file.open("a") as file:
            file.write("OPENSHIFT_VERSION=4.20.1\n")
        role = {
            "name": "existing-provider-role", "scope": "TEST_VNET_SCOPE",
            "principalId": "PROVIDER-OBJECT",
            "roleDefinitionId": "/providers/Microsoft.Authorization/roleDefinitions/"
                                "4D97B98B-1D4F-4787-A291-C67834D212E7",
        }
        for roles, expected in (([], ""), ([role], "existing-provider-role")):
            self.env["SHOP_TEST_ROLES"] = json.dumps(roles)
            result = subprocess.run(
                ["bash", "scripts/10-apply-infrastructure.sh"],
                cwd=self.root, env=self.env, capture_output=True, text=True,
            )
            self.assert_success(result)
            parameters = json.loads((self.root / "parameters.json").read_text())["parameters"]
            for key in ("aroProviderNetworkRoleName", "onpremProviderNetworkRoleName"):
                self.assertEqual(parameters[key]["value"], expected)
        (self.root / "commands.jsonl").unlink()
        self.env["SHOP_TEST_ROLE_LOOKUP_FAIL"] = "1"
        result = subprocess.run(
            ["bash", "scripts/10-apply-infrastructure.sh"],
            cwd=self.root, env=self.env, capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("role assignment lookup failed", result.stderr)
        self.assertFalse(any(entry["args"][:2] == ["deployment", "group"]
                             for entry in self.entries()))

    def test_capacity_restrictions_stop_before_any_cloud_creation(self):
        self.save_credentials()
        self.env["SHOP_TEST_SKUS"] = json.dumps([
            {"name": "Standard_D8s_v5", "restrictions": [
                {"type": "Location", "reasonCode": "NotAvailableForSubscription",
                 "restrictionInfo": {"locations": ["eastus"]}}
            ]},
            {"name": "Standard_D4s_v5", "restrictions": []},
        ])
        result = self.run_ps("& ./scripts/10-apply-infrastructure.ps1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Standard_D8s_v5", result.stderr)
        self.assertIn("NotAvailableForSubscription", result.stderr)
        self.assertFalse(any(
            entry["args"][:2] in (["provider", "register"], ["group", "create"])
            or entry["args"][:2] == ["deployment", "group"]
            for entry in self.entries()
        ))

    def test_custom_vm_sizes_are_checked_and_passed_to_both_clusters(self):
        self.save_credentials()
        with self.env_file.open("a") as file:
            file.write("ARO_MASTER_VM_SIZE=Standard_D8s_v6\n"
                       "ARO_WORKER_VM_SIZE=Standard_D4s_v6\n")
        self.env["SHOP_TEST_SKUS"] = json.dumps([
            {"name": name, "family": "StandardDsv6Family", "restrictions": [],
             "capabilities": [{"name": "vCPUs", "value": str(cores)}]}
            for name, cores in (("Standard_D8s_v6", 8), ("Standard_D4s_v6", 4))
        ])
        self.env["SHOP_TEST_USAGE"] = json.dumps([
            {"name": {"value": name}, "currentValue": 0, "limit": 100}
            for name in ("cores", "StandardDsv6Family")
        ])
        result = self.run_ps("& ./scripts/10-apply-infrastructure.ps1")
        self.assert_success(result)
        parameters = json.loads((self.root / "parameters.json").read_text())["parameters"]
        self.assertEqual(parameters["aroMasterVmSize"]["value"], "Standard_D8s_v6")
        self.assertEqual(parameters["aroWorkerVmSize"]["value"], "Standard_D4s_v6")
        queries = [
            entry["args"] for entry in self.entries()
            if entry["args"][:2] == ["vm", "list-skus"]
        ]
        self.assertEqual(len(queries), 1)
        self.assertIn("Standard_D8s_v6", queries[0][queries[0].index("--query") + 1])
        with self.env_file.open("a") as file:
            file.write("OPENSHIFT_VERSION=4.18.34\n")
        result = self.run_ps("& ./scripts/10-apply-infrastructure.ps1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("4.19", result.stderr)

    def test_capacity_checks_both_clusters_against_regional_and_family_quota(self):
        for quota in ("cores", "standardDSv5Family"):
            with self.subTest(quota=quota):
                self.env["SHOP_TEST_USAGE"] = json.dumps([
                    {"name": {"value": name}, "currentValue": 29 if name == quota else 0,
                     "limit": 100}
                    for name in ("cores", "standardDSv5Family")
                ])
                result = self.run_ps("& ./scripts/09-check-capacity.ps1")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(quota, result.stderr)
                self.assertIn("72", result.stderr)
                self.assertIn("71", result.stderr)

    def test_capacity_missing_sku_or_quota_is_not_treated_as_available(self):
        for key in ("SHOP_TEST_SKUS", "SHOP_TEST_USAGE"):
            with self.subTest(missing=key):
                self.env[key] = "[]"
                result = self.run_ps("& ./scripts/09-check-capacity.ps1")
                self.assertNotEqual(result.returncode, 0)
                del self.env[key]

    def test_capacity_missing_restriction_metadata_is_not_treated_as_available(self):
        self.env["SHOP_TEST_SKUS"] = json.dumps([
            {"name": "Standard_D8s_v5"}, {"name": "Standard_D4s_v5"}
        ])
        result = self.run_ps("& ./scripts/09-check-capacity.ps1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("restriction metadata", result.stderr)

    def test_capacity_check_is_read_only_and_ignores_zone_only_restrictions(self):
        self.env["SHOP_TEST_SKUS"] = json.dumps([
            {"name": name, "family": "standardDSv5Family",
             "restrictions": [
                 {"type": "Zone", "reasonCode": "NotAvailableForSubscription"},
                 {"type": "Location", "reasonCode": "NotAvailableForSubscription",
                  "restrictionInfo": {"locations": ["another-region"]}},
             ],
             "capabilities": [{"name": "vCPUs", "value": str(cores)}]}
            for name, cores in (("Standard_D8s_v5", 8), ("Standard_D4s_v5", 4))
        ])
        result = self.run_ps("& ./scripts/09-check-capacity.ps1")
        self.assert_success(result)
        self.assertIn("72", result.stdout)
        self.assertFalse(any(
            "create" in entry["args"] or "register" in entry["args"]
            for entry in self.entries()
        ))

    def test_capacity_does_not_double_count_existing_successful_clusters(self):
        self.env["SHOP_TEST_CLUSTERS"] = json.dumps([
            {"name": "adaptive-aro", "provisioningState": "Succeeded",
             "masterProfile": {"vmSize": "Standard_D8s_v5"},
             "workerProfiles": [{"vmSize": "Standard_D4s_v5", "count": 3}]}
        ])
        self.env["SHOP_TEST_USAGE"] = json.dumps([
            {"name": {"value": name}, "currentValue": 36, "limit": 72}
            for name in ("cores", "standardDSv5Family")
        ])
        result = self.run_ps("& ./scripts/09-check-capacity.ps1")
        self.assert_success(result)
        self.assertIn("36", result.stdout)

    def test_provider_validation_failure_stops_deployment_and_cleans_parameters(self):
        self.save_credentials()
        self.env["SHOP_TEST_VALIDATION_FAIL"] = "1"
        result = self.run_ps("& ./scripts/10-apply-infrastructure.ps1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(
            entry["args"][:3] == ["deployment", "group", "create"]
            for entry in self.entries()
        ))
        self.assertFalse(list(self.credentials.parent.glob("infra-parameters-*")))

    def test_custom_front_door_endpoint_is_used_throughout_deployment_and_switch(self):
        self.save_credentials()
        with self.env_file.open("a") as file:
            file.write("FRONT_DOOR_ENDPOINT_NAME=test-endpoint\n")
        self.assert_success(self.run_ps("& ./scripts/10-apply-infrastructure.ps1"))
        parameters = json.loads((self.root / "parameters.json").read_text())["parameters"]
        self.assertEqual(parameters["frontDoorEndpointName"]["value"], "test-endpoint")
        for script in ("50-deploy-target", "90-switch-traffic"):
            self.assert_success(self.run_ps(
                "function Invoke-WebRequest { @{ StatusCode = 200 } }; "
                f"& ./scripts/{script}.ps1 -Target aro"
            ))
        endpoints = [
            entry["args"] for entry in self.entries()
            if entry["args"][:3] == ["afd", "endpoint", "show"]
        ]
        self.assertEqual(len(endpoints), 2)
        for args in endpoints:
            self.assertEqual(args[args.index("--endpoint-name") + 1], "test-endpoint")
        routes = [
            entry["args"] for entry in self.entries()
            if entry["args"][:3] == ["deployment", "group", "create"]
            and "adaptive-shop-front-door-route" in entry["args"]
        ]
        self.assertEqual(len(routes), 1)
        self.assertIn("frontDoorEndpointName=test-endpoint", routes[0])

    @unittest.skipIf(os.name == "nt", "Bash parity is checked on Linux")
    def test_bash_capacity_and_validation_stop_before_deployment(self):
        self.save_credentials()
        for script in ("09-check-capacity", "10-apply-infrastructure"):
            result = subprocess.run(
                ["bash", f"scripts/{script}.sh"], cwd=self.root, env=self.env,
                capture_output=True, text=True,
            )
            self.assert_success(result)
        self.env["SHOP_TEST_USAGE"] = json.dumps([
            {"name": {"value": "cores"}, "currentValue": 29, "limit": 100}
        ])
        result = subprocess.run(
            ["bash", "scripts/09-check-capacity.sh"], cwd=self.root, env=self.env,
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("72", result.stderr)
        del self.env["SHOP_TEST_USAGE"]
        self.env["SHOP_TEST_SKUS"] = json.dumps([
            {"name": "Standard_D8s_v5", "restrictions": [
                {"type": "Location", "reasonCode": "NotAvailableForSubscription"}
            ]}
        ])
        log = self.root / "commands.jsonl"
        log.unlink()
        result = subprocess.run(
            ["bash", "scripts/10-apply-infrastructure.sh"], cwd=self.root, env=self.env,
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NotAvailableForSubscription", result.stderr)
        self.assertFalse(any("create" in entry["args"] for entry in self.entries()))

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
            self.assertIn("frontDoorEndpointName=shop", args)
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
