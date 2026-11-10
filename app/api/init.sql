CREATE TABLE IF NOT EXISTS products (
    id INTEGER PRIMARY KEY,
    name VARCHAR(120) NOT NULL,
    description TEXT NOT NULL,
    price NUMERIC(10, 2) NOT NULL
);

INSERT INTO products (id, name, description, price) VALUES
    (1, 'Summit backpack', 'A durable day pack for the next adventure.', 64.00),
    (2, 'Trail bottle', 'Insulated stainless steel, ready for the long route.', 28.50),
    (3, 'Camp mug', 'A lightweight enamel mug for coffee outdoors.', 16.00)
ON CONFLICT (id) DO NOTHING;
