import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    database_url: str | None
    database_host: str
    database_port: int
    database_name: str
    database_user: str
    database_sslmode: str
    database_password_secret_name: str
    database_password_secret_key: str
    dapr_http_endpoint: str
    dapr_state_store: str
    dapr_secret_store: str
    environment: str
    cluster_name: str
    platform: str
    database_service: str
    cache_service: str
    secrets_service: str
    image_registry: str

    @classmethod
    def from_env(cls) -> "Settings":
        required_names = {
            "database_host": "DATABASE_HOST",
            "database_port": "DATABASE_PORT",
            "database_name": "DATABASE_NAME",
            "database_user": "DATABASE_USER",
            "database_sslmode": "DATABASE_SSLMODE",
            "database_password_secret_name": "DATABASE_PASSWORD_SECRET_NAME",
            "database_password_secret_key": "DATABASE_PASSWORD_SECRET_KEY",
            "dapr_http_endpoint": "DAPR_HTTP_ENDPOINT",
            "dapr_state_store": "DAPR_STATE_STORE",
            "dapr_secret_store": "DAPR_SECRET_STORE",
            "environment": "SHOP_ENVIRONMENT",
            "cluster_name": "SHOP_CLUSTER_NAME",
            "platform": "SHOP_PLATFORM",
            "database_service": "DATABASE_SERVICE_NAME",
            "cache_service": "CACHE_SERVICE_NAME",
            "secrets_service": "SECRETS_SERVICE_NAME",
            "image_registry": "IMAGE_REGISTRY",
        }
        missing = [
            env_name for env_name in required_names.values() if not os.getenv(env_name)
        ]
        if missing:
            raise RuntimeError(f"Missing required configuration: {', '.join(missing)}")

        values = {
            field: os.environ[env_name] for field, env_name in required_names.items()
        }
        values["database_url"] = os.getenv("DATABASE_URL")
        values["database_port"] = int(values["database_port"])
        values["dapr_http_endpoint"] = values["dapr_http_endpoint"].rstrip("/")
        return cls(**values)


def get_settings() -> Settings:
    return Settings.from_env()
