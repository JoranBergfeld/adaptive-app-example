import json
import re
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
AZ = shutil.which("az")


@unittest.skipUnless(AZ, "Azure CLI is not installed")
class InfrastructureTests(unittest.TestCase):
    @classmethod
    def compile_template(cls, name):
        result = subprocess.run(
            [AZ, "bicep", "build", "--file", str(ROOT / "infra/azure" / name), "--stdout"],
            capture_output=True, text=True, encoding="utf-8",
        )
        if result.returncode:
            raise AssertionError(result.stderr)
        return json.loads(result.stdout)

    def test_clusters_have_stable_distinct_domains(self):
        template = self.compile_template("main.bicep")
        clusters = [
            resource for resource in template["resources"]
            if resource["type"] == "Microsoft.RedHatOpenShift/openShiftClusters"
        ]
        self.assertEqual(len(clusters), 2)
        domains = []
        for cluster in clusters:
            domain = cluster["properties"]["clusterProfile"].get("domain", "")
            self.assertTrue(domain, f'{cluster["name"]}: clusterProfile.domain is empty')
            seed = f"uniqueString(resourceGroup().id, {cluster['name'][1:-1]})"
            match = re.fullmatch(r"\[format\('([^']+)', " + re.escape(seed) + r"\)\]", domain)
            self.assertIsNotNone(match, "Domain must prefix the stable hash with a DNS label")
            for hash_value in ("7binlw4ugm7qm", "a" * 13, "0" * 13):
                rendered = match[1].format(hash_value)
                self.assertRegex(rendered, r"^[a-z][-a-z0-9]{0,61}[a-z0-9]$")
            domains.append(domain)
        self.assertEqual(len(set(domains)), 2)

    def test_clusters_have_separate_managed_resource_group_ids(self):
        template = self.compile_template("main.bicep")
        clusters = [
            resource for resource in template["resources"]
            if resource["type"] == "Microsoft.RedHatOpenShift/openShiftClusters"
        ]
        self.assertEqual(len(clusters), 2)
        group_ids = []
        for cluster in clusters:
            group_id = cluster["properties"]["clusterProfile"].get("resourceGroupId", "")
            seed = f"uniqueString(resourceGroup().id, {cluster['name'][1:-1]})"
            expression = (
                r"\[format\('([^']+)', subscription\(\)\.subscriptionId, "
                + re.escape(seed) + r"\)\]"
            )
            match = re.fullmatch(expression, group_id)
            self.assertIsNotNone(match, "Managed resource group must use the cluster subscription")
            rendered = match[1].format("00000000-0000-0000-0000-000000000001", "7binlw4ugm7qm")
            self.assertRegex(
                rendered,
                r"^/subscriptions/00000000-0000-0000-0000-000000000001/"
                r"resourceGroups/aro-managed-[-a-z0-9_().]{1,78}$",
            )
            self.assertNotEqual(
                rendered.rsplit("/", 1)[-1], "adaptive-shop-demo",
            )
            group_ids.append(group_id)
        self.assertEqual(len(set(group_ids)), 2)
        self.assertFalse(any(
            resource["type"] == "Microsoft.Resources/resourceGroups"
            for resource in template["resources"]
        ), "ARO creates and manages its infrastructure resource groups")

    def test_outbound_type_matches_case_sensitive_aro_api(self):
        template = self.compile_template("main.bicep")
        clusters = [
            resource for resource in template["resources"]
            if resource["type"] == "Microsoft.RedHatOpenShift/openShiftClusters"
        ]
        self.assertEqual(len(clusters), 2)
        for cluster in clusters:
            self.assertEqual(cluster["properties"]["networkProfile"]["outboundType"], "Loadbalancer")

    def test_initial_infrastructure_does_not_create_route_without_origins(self):
        template = self.compile_template("main.bicep")
        self.assertFalse(any(
            resource["type"] == "Microsoft.Cdn/profiles/afdEndpoints/routes"
            for resource in template["resources"]
        ), "Front Door route must wait until an origin is enabled")

    def test_deferred_route_preserves_routing_settings(self):
        template = self.compile_template("front-door-route.bicep")
        routes = [
            resource for resource in template["resources"]
            if resource["type"] == "Microsoft.Cdn/profiles/afdEndpoints/routes"
        ]
        self.assertEqual(len(routes), 1)
        properties = routes[0]["properties"]
        self.assertIn("shop-origins", properties["originGroup"]["id"])
        self.assertEqual(properties["patternsToMatch"], ["/*"])
        self.assertEqual(properties["supportedProtocols"], ["Https", "Http"])
        for name, value in (
            ("forwardingProtocol", "HttpsOnly"),
            ("httpsRedirect", "Enabled"),
            ("enabledState", "Enabled"),
            ("linkToDefaultDomain", "Enabled"),
        ):
            self.assertEqual(properties[name], value)


if __name__ == "__main__":
    unittest.main()
