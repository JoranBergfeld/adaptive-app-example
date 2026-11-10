import json
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
            self.assertIn("uniqueString(resourceGroup().id,", domain)
            self.assertIn(cluster["name"][1:-1], domain)
            domains.append(domain)
        self.assertEqual(len(set(domains)), 2)

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
