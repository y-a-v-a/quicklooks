-- Builds sample.sqlite: sqlite3 sample.sqlite < sample.sql
PRAGMA application_id = 0x51554C4B;    -- 'QULK', shown as a FourCC
PRAGMA user_version = 7;

CREATE TABLE teams (
  id    INTEGER PRIMARY KEY,
  name  TEXT NOT NULL UNIQUE
);

CREATE TABLE users (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  email       TEXT NOT NULL,
  team_id     INTEGER REFERENCES teams(id) ON DELETE SET NULL,
  bio         TEXT,
  avatar      BLOB,
  score       REAL DEFAULT 0.0,
  created_at  TEXT DEFAULT CURRENT_TIMESTAMP,
  email_lower TEXT GENERATED ALWAYS AS (lower(email)) VIRTUAL
);
CREATE UNIQUE INDEX users_email ON users (email);
CREATE INDEX users_active ON users (team_id) WHERE team_id IS NOT NULL;

-- A name that needs quoting, and a composite key without a rowid.
CREATE TABLE "order ""items""" (
  order_id  INTEGER,
  line      INTEGER,
  sku       TEXT,
  PRIMARY KEY (order_id, line)
) WITHOUT ROWID;

CREATE TABLE empty_table (x);

-- Full-text search: a virtual table plus the shadow tables it creates.
CREATE VIRTUAL TABLE notes USING fts5(title, body);

CREATE VIEW team_sizes AS
  SELECT t.name, count(u.id) AS members   -- one row per team
  FROM teams t LEFT JOIN users u ON u.team_id = t.id
  GROUP BY t.id;

CREATE TRIGGER users_touch AFTER UPDATE OF email ON users
BEGIN
  UPDATE users SET created_at = 'it''s changed' WHERE id = NEW.id;
END;

INSERT INTO teams (name) VALUES ('Platform'), ('Design'), ('Data');
INSERT INTO users (email, team_id, bio, avatar, score) VALUES
  ('ada@example.com', 1, 'Wrote the first program.', x'89504E470D0A1A0A', 99.5),
  ('grace@example.com', 1, 'Line one
line two	with a tab', NULL, 87),
  ('linus@example.com', NULL, NULL, zeroblob(2048), -1.25e-3),
  ('émilie@example.com', 2, 'Unicode: café — naïve — 日本語', NULL, 0),
  ('long@example.com', 3, 'A very long biography that goes on well past the forty characters a cell is allowed before it is clipped.', NULL, 1e100);
INSERT INTO "order ""items""" VALUES (1, 1, 'SKU-1'), (1, 2, 'SKU-2'), (2, 1, 'SKU-3');
INSERT INTO notes VALUES ('Quick Look', 'Space bar previews for SQLite.');
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 40)
INSERT INTO users (email, team_id, score) SELECT 'user' || i || '@example.com', i % 3 + 1, i FROM n;
