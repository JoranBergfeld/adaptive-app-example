import os

import httpx
from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import select, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from shop_api import dapr
from shop_api.config import Settings, get_settings
from shop_api.database import get_db
from shop_api.models import Product
from shop_api.schemas import CartResponse, CartUpdate, ProductResponse

app = FastAPI(title="Shop API")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        origin.strip()
        for origin in os.getenv("CORS_ALLOWED_ORIGINS", "http://localhost:8081").split(",")
        if origin.strip()
    ],
    allow_methods=["GET", "PUT", "DELETE"],
    allow_headers=["Content-Type"],
)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz")
def readyz(
    settings: Settings = Depends(get_settings),
    db: Session = Depends(get_db),
) -> dict[str, str]:
    try:
        db.execute(text("SELECT 1"))
        dapr.get_metadata(settings.dapr_http_endpoint)
    except (SQLAlchemyError, httpx.HTTPError) as exc:
        raise HTTPException(status_code=503, detail="A required dependency is unavailable") from exc
    return {"status": "ready"}


@app.get("/api/products", response_model=list[ProductResponse])
def list_products(db: Session = Depends(get_db)) -> list[Product]:
    return list(db.scalars(select(Product).order_by(Product.id)))


@app.get("/api/cart", response_model=CartResponse)
def get_cart(settings: Settings = Depends(get_settings)) -> dict:
    return dapr.get_cart(settings.dapr_http_endpoint, settings.dapr_state_store)


@app.put("/api/cart", response_model=CartResponse)
def update_cart(
    cart: CartUpdate,
    settings: Settings = Depends(get_settings),
) -> dict:
    value = cart.model_dump(mode="json")
    dapr.save_cart(settings.dapr_http_endpoint, settings.dapr_state_store, value)
    return value


@app.delete("/api/cart", response_model=CartResponse)
def delete_cart(settings: Settings = Depends(get_settings)) -> dict:
    dapr.clear_cart(settings.dapr_http_endpoint, settings.dapr_state_store)
    return {"items": []}


@app.get("/api/whereami")
def whereami(settings: Settings = Depends(get_settings)) -> dict:
    return {
        "environment": settings.environment,
        "cluster": settings.cluster_name,
        "platform": settings.platform,
        "backing_services": {
            "database": settings.database_service,
            "cache": settings.cache_service,
            "secrets": settings.secrets_service,
            "image_registry": settings.image_registry,
        },
        "dapr": dapr.get_metadata(settings.dapr_http_endpoint),
    }
