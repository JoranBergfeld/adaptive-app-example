from collections.abc import Iterator
from functools import lru_cache

import httpx
from fastapi import Depends, HTTPException
from sqlalchemy import create_engine
from sqlalchemy.engine import URL, Engine
from sqlalchemy.orm import Session

from shop_api import dapr
from shop_api.config import Settings, get_settings


@lru_cache
def get_engine(database_url: str) -> Engine:
    return create_engine(database_url, pool_pre_ping=True)


def get_database_url(settings: Settings) -> str:
    if settings.database_url:
        return settings.database_url

    password = dapr.get_secret(
        settings.dapr_http_endpoint,
        settings.dapr_secret_store,
        settings.database_password_secret_name,
        settings.database_password_secret_key,
    )
    return URL.create(
        "postgresql+psycopg",
        username=settings.database_user,
        password=password,
        host=settings.database_host,
        port=settings.database_port,
        database=settings.database_name,
        query={"sslmode": settings.database_sslmode},
    ).render_as_string(hide_password=False)


def get_db(settings: Settings = Depends(get_settings)) -> Iterator[Session]:
    try:
        database_url = get_database_url(settings)
    except httpx.HTTPError as exc:
        raise HTTPException(
            status_code=503,
            detail="Database credentials are temporarily unavailable",
        ) from exc
    with Session(get_engine(database_url)) as session:
        yield session
