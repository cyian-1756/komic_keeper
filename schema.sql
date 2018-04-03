CREATE TABLE comics (
  id   INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  path TEXT NOT NULL,
  type TEXT NOT NULL,
  size INT NOT NULL,
  tags TEXT,
  publisher TEXT,
  rating INT,
  writer TEXT,
  release_date TEXT,
  series_name TEXT
);