import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from shop_api.database import get_db
from shop_api.main import app
from shop_api.models import Base, Product


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setenv("DATABASE_URL", "sqlite://")
    monkeypatch.setenv("DATABASE_HOST", "localhost")
    monkeypatch.setenv("DATABASE_PORT", "5432")
    monkeypatch.setenv("DATABASE_NAME", "shop")
    monkeypatch.setenv("DATABASE_USER", "shop")
    monkeypatch.setenv("DATABASE_SSLMODE", "disable")
    monkeypatch.setenv("DATABASE_PASSWORD_SECRET_NAME", "shop-db-password")
    monkeypatch.setenv("DATABASE_PASSWORD_SECRET_KEY", "shop-db-password")
    monkeypatch.setenv("DAPR_HTTP_ENDPOINT", "http://daprd:3500")
    monkeypatch.setenv("DAPR_STATE_STORE", "statestore")
    monkeypatch.setenv("DAPR_SECRET_STORE", "secretstore")
    monkeypatch.setenv("SHOP_ENVIRONMENT", "test")
    monkeypatch.setenv("SHOP_CLUSTER_NAME", "test-cluster")
    monkeypatch.setenv("SHOP_PLATFORM", "test-platform")
    monkeypatch.setenv("DATABASE_SERVICE_NAME", "Test PostgreSQL")
    monkeypatch.setenv("CACHE_SERVICE_NAME", "Test Redis")
    monkeypatch.setenv("SECRETS_SERVICE_NAME", "Test secrets")
    monkeypatch.setenv("IMAGE_REGISTRY", "test registry")

    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    with Session(engine) as db:
        db.add(
            Product(
                id=1,
                name="Test product",
                description="A product for the test suite.",
                price="12.50",
            )
        )
        db.commit()

    def override_get_db():
        with Session(engine) as db:
            yield db

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as test_client:
        yield test_client
    app.dependency_overrides.clear()
    engine.dispose()
