-- Tables are made only here, in migrations. Each file runs once, in name order, when the Worker
-- starts. Never edit a file that has run: add 0002_….sql instead.

CREATE TABLE notes (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  text       TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
