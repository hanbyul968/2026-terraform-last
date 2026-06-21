CREATE TABLE IF NOT EXISTS user (
    id        VARCHAR(255) NOT NULL,
    username  VARCHAR(255) NOT NULL,
    email     VARCHAR(255) NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_username (username)
);

CREATE TABLE IF NOT EXISTS product (
    id          VARCHAR(255) NOT NULL,
    name        VARCHAR(255) NOT NULL,
    price       FLOAT(8)     NOT NULL,
    image_path  VARCHAR(500) DEFAULT NULL,
    PRIMARY KEY (id)
);

GRANT ALL PRIVILEGES ON dev.* TO 'appuser'@'%';
FLUSH PRIVILEGES;
