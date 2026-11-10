from urllib.parse import quote

import httpx


def get_metadata(endpoint: str) -> dict:
    response = httpx.get(f"{endpoint}/v1.0/metadata", timeout=3.0)
    response.raise_for_status()
    return response.json()


def get_secret(endpoint: str, store: str, name: str, key: str) -> str:
    response = httpx.get(
        f"{endpoint}/v1.0/secrets/{quote(store, safe='')}/{quote(name, safe='')}",
        timeout=3.0,
    )
    response.raise_for_status()
    value = response.json().get(key)
    if not isinstance(value, str) or not value:
        raise RuntimeError(f"Dapr secret '{name}' does not contain key '{key}'")
    return value


def get_cart(endpoint: str, store: str) -> dict:
    key = quote("shop-cart", safe="")
    response = httpx.get(
        f"{endpoint}/v1.0/state/{quote(store, safe='')}/{key}",
        timeout=3.0,
    )
    if response.status_code == 204 or not response.content:
        return {"items": []}
    response.raise_for_status()
    return response.json() or {"items": []}


def save_cart(endpoint: str, store: str, cart: dict) -> None:
    response = httpx.post(
        f"{endpoint}/v1.0/state/{quote(store, safe='')}",
        json=[{"key": "shop-cart", "value": cart}],
        timeout=3.0,
    )
    response.raise_for_status()


def clear_cart(endpoint: str, store: str) -> None:
    key = quote("shop-cart", safe="")
    response = httpx.delete(
        f"{endpoint}/v1.0/state/{quote(store, safe='')}/{key}",
        timeout=3.0,
    )
    response.raise_for_status()
