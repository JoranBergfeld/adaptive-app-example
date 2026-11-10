const apiBase = (window.SHOP_CONFIG?.apiBaseUrl ?? "").replace(/\/$/, "");
const productsElement = document.querySelector("#products");
const cartItemsElement = document.querySelector("#cart-items");
const cartCountElement = document.querySelector("#cart-count");
const cartTotalElement = document.querySelector("#cart-total");
const errorElement = document.querySelector("#error");
const currency = new Intl.NumberFormat(undefined, {
  style: "currency",
  currency: "USD",
});

let products = [];
let cart = { items: [] };

async function request(path, options = {}) {
  const response = await fetch(`${apiBase}${path}`, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      ...options.headers,
    },
  });
  if (!response.ok) {
    throw new Error(`${path} returned HTTP ${response.status}`);
  }
  return response.status === 204 ? null : response.json();
}

function showError(message) {
  errorElement.textContent = message;
  errorElement.hidden = false;
}

function renderProducts() {
  productsElement.replaceChildren();
  for (const product of products) {
    const card = document.createElement("article");
    card.className = "product-card";

    const label = document.createElement("p");
    label.className = "eyebrow";
    label.textContent = "SUMMIT ESSENTIAL";

    const name = document.createElement("h3");
    name.textContent = product.name;

    const description = document.createElement("p");
    description.textContent = product.description;

    const price = document.createElement("div");
    price.className = "product-price";
    price.textContent = currency.format(Number(product.price));

    const button = document.createElement("button");
    button.className = "add-button";
    button.type = "button";
    button.textContent = "Add to cart";
    button.addEventListener("click", () => addToCart(product.id));

    card.append(label, name, description, price, button);
    productsElement.append(card);
  }
}

function renderCart() {
  cartItemsElement.replaceChildren();
  const count = cart.items.reduce((sum, item) => sum + item.quantity, 0);
  cartCountElement.textContent = String(count);
  let total = 0;

  if (cart.items.length === 0) {
    const empty = document.createElement("p");
    empty.className = "cart-empty";
    empty.textContent = "Your cart is ready for an adventure.";
    cartItemsElement.append(empty);
  }

  for (const item of cart.items) {
    const product = products.find((candidate) => candidate.id === item.product_id);
    if (!product) {
      continue;
    }
    const line = document.createElement("div");
    line.className = "cart-line";

    const name = document.createElement("span");
    name.className = "cart-line-name";
    name.textContent = product.name;

    const detail = document.createElement("span");
    detail.className = "cart-line-detail";
    detail.textContent = `${item.quantity} × ${currency.format(Number(product.price))}`;

    line.append(name, detail);
    cartItemsElement.append(line);
    total += Number(product.price) * item.quantity;
  }

  cartTotalElement.textContent = currency.format(total);
}

async function addToCart(productId) {
  const items = [...cart.items];
  const existing = items.find((item) => item.product_id === productId);
  if (existing) {
    existing.quantity = Math.min(existing.quantity + 1, 99);
  } else {
    items.push({ product_id: productId, quantity: 1 });
  }
  cart = await request("/api/cart", {
    method: "PUT",
    body: JSON.stringify({ items }),
  });
  renderCart();
}

async function start() {
  try {
    const [whereami, loadedProducts, loadedCart] = await Promise.all([
      request("/api/whereami"),
      request("/api/products"),
      request("/api/cart"),
    ]);
    products = loadedProducts;
    cart = loadedCart;
    document.querySelector("#whereami").textContent =
      `${whereami.cluster} | ${whereami.platform} | ` +
      `PostgreSQL: ${whereami.backing_services.database} | ` +
      `Redis: ${whereami.backing_services.cache} | ` +
      `Secrets: ${whereami.backing_services.secrets} | ` +
      `Images: ${whereami.backing_services.image_registry}`;
    renderProducts();
    renderCart();
  } catch (error) {
    showError(`Could not load the storefront: ${error.message}`);
  }

  document.querySelector("#clear-cart").addEventListener("click", async () => {
    try {
      cart = await request("/api/cart", { method: "DELETE" });
      renderCart();
    } catch (error) {
      showError(`Could not clear the cart: ${error.message}`);
    }
  });
}

start();
