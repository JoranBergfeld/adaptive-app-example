import httpx

from shop_api import dapr
from shop_api.config import Settings
from shop_api.database import get_database_url


def test_health_and_readiness(client, monkeypatch):
    monkeypatch.setattr(dapr, "get_metadata", lambda endpoint: {"id": "test-sidecar"})

    assert client.get("/healthz").json() == {"status": "ok"}
    assert client.get("/readyz").json() == {"status": "ready"}


def test_dapr_secret_api_returns_requested_key(monkeypatch):
    class Response:
        def raise_for_status(self):
            pass

        def json(self):
            return {"shop-db-password": "secret-value"}

    request = {}

    def fake_get(url, timeout):
        request.update(url=url, timeout=timeout)
        return Response()

    monkeypatch.setattr(dapr.httpx, "get", fake_get)

    assert (
        dapr.get_secret(
            "http://daprd:3500",
            "secretstore",
            "shop-db-password",
            "shop-db-password",
        )
        == "secret-value"
    )
    assert request["url"] == (
        "http://daprd:3500/v1.0/secrets/secretstore/shop-db-password"
    )


def test_database_url_uses_secret_without_exposing_password(monkeypatch):
    settings = Settings(
        database_url=None,
        database_host="postgres.internal",
        database_port=5432,
        database_name="shop",
        database_user="shop",
        database_sslmode="require",
        database_password_secret_name="db-password",
        database_password_secret_key="password",
        dapr_http_endpoint="http://daprd:3500",
        dapr_state_store="statestore",
        dapr_secret_store="secretstore",
        environment="test",
        cluster_name="test-cluster",
        platform="test-platform",
        database_service="Test PostgreSQL",
        cache_service="Test Redis",
        secrets_service="Test secrets",
        image_registry="test registry",
    )
    monkeypatch.setattr(dapr, "get_secret", lambda *args: "p@ss/word")
    url = get_database_url(settings)

    assert url.startswith("postgresql+psycopg://shop:")
    assert "p%40ss%2Fword" in url
    assert url.endswith("?sslmode=require")


def test_products_are_read_from_database(client):
    response = client.get("/api/products")

    assert response.status_code == 200
    assert response.json() == [
        {
            "id": 1,
            "name": "Test product",
            "description": "A product for the test suite.",
            "price": "12.50",
        }
    ]


def test_cart_uses_dapr_state_api(client, monkeypatch):
    saved = {}
    monkeypatch.setattr(dapr, "get_cart", lambda endpoint, store: {"items": []})
    monkeypatch.setattr(
        dapr,
        "save_cart",
        lambda endpoint, store, cart: saved.update(endpoint=endpoint, store=store, cart=cart),
    )

    assert client.get("/api/cart").json() == {"items": []}
    response = client.put(
        "/api/cart",
        json={"items": [{"product_id": 1, "quantity": 2}]},
    )

    assert response.status_code == 200
    assert response.json() == {"items": [{"product_id": 1, "quantity": 2}]}
    assert saved == {
        "endpoint": "http://daprd:3500",
        "store": "statestore",
        "cart": {"items": [{"product_id": 1, "quantity": 2}]},
    }


def test_cart_rejects_invalid_quantity(client):
    response = client.put(
        "/api/cart",
        json={"items": [{"product_id": 1, "quantity": 0}]},
    )

    assert response.status_code == 422


def test_cart_delete_clears_dapr_state(client, monkeypatch):
    cleared = {}
    monkeypatch.setattr(
        dapr,
        "clear_cart",
        lambda endpoint, store: cleared.update(endpoint=endpoint, store=store),
    )

    response = client.delete("/api/cart")

    assert response.status_code == 200
    assert response.json() == {"items": []}
    assert cleared == {"endpoint": "http://daprd:3500", "store": "statestore"}


def test_whereami_uses_environment_configuration_and_dapr_metadata(client, monkeypatch):
    monkeypatch.setattr(
        dapr,
        "get_metadata",
        lambda endpoint: {"id": "test-sidecar", "components": [{"name": "statestore"}]},
    )

    response = client.get("/api/whereami")

    assert response.json() == {
        "environment": "test",
        "cluster": "test-cluster",
        "platform": "test-platform",
        "backing_services": {
            "database": "Test PostgreSQL",
            "cache": "Test Redis",
            "secrets": "Test secrets",
            "image_registry": "test registry",
        },
        "dapr": {"id": "test-sidecar", "components": [{"name": "statestore"}]},
    }


def test_readiness_reports_unavailable_dapr_as_503(client, monkeypatch):
    def unavailable(endpoint):
        raise httpx.HTTPError("sidecar unavailable")

    monkeypatch.setattr(dapr, "get_metadata", unavailable)

    response = client.get("/readyz")

    assert response.status_code == 503
