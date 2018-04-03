echo "Making cover dir and DB"
mkdir covers
touch db.sqlite
sqlite3 db.sqlite < schema.sql
echo "Done"