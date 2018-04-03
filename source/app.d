import std.stdio;
import std.file;
import std.algorithm;
import std.string;
import std.datetime;
import std.math;
import std.digest.crc;
import std.zip;
import std.algorithm;
import std.conv;
import std.process;
import d2sqlite3;
import vibe.http.router;
import vibe.http.server;
import vibe.core.core;
import vibe.http.fileserver;
import mustache;
import vibe.inet.url;
import dini;

Database db;
alias MustacheEngine!(string) Mustache;
string buildTime = __TIMESTAMP__;
auto kkVersion = 0.1;
// The path to where the comics on stored on disk
string globalPathToComics;

void main()
{
	db = Database("db.sqlite");
	auto ini = Ini.Parse("config.ini");
	globalPathToComics = ini["config"].getKey("comic_path");

	// getCovers();

	auto router = new URLRouter;
	auto settings = new HTTPServerSettings;
	settings.bindAddresses = ["127.0.0.1"];
	settings.port = 8080;
	router.get("/", &indexPage);
	router.get("/comics", &listComics);
	router.get("/comics/", &listComics);
	router.get("/comics/:page", &listComics);
	router.get("/comic/:comic", &comicPage);
	router.get("/covers/*", &images);
	router.get("/style.css", &css);
	router.any("/indexcomics", &indexComics);
	// The api endpoint for setting a comics rating
	router.post("/rating/:comic", &setComicRating);
	router.post("/settags", &setComicTags);
	router.get("/tags/:tag/:page", &tagPage);
	// TODO add a single regex to match both these urls
	router.get("/tags/:tag/", &tagPageFirst);
	router.get("/tags/:tag", &tagPageFirst);
	// As vibe.d doesn't support "?PARAM=" for some ungodly reason we have to use java script to get the search to work
	router.get("/search/:searchTerm", &searchPageFirst);
	router.get("/search/:searchTerm/:page", &search);
	listenHTTP(settings, router);
	runApplication();

}

struct comic {
	string name;
	string path;
	string type;
	int rating;
	ulong size;
}

comic getComic(DirEntry e) {
	comic c;
	c.name = e.name.split("/")[e.name.split("/").length - 1];
	c.path = e.name;
	c.rating = 0;
	c.type =  c.name.split(".")[c.name.split(".").length - 1];
	c.size = e.size;
	return c;
}

comic[] getComics(string pathToComics) {
	// Make sure the comics dir exists
	if (!exists(pathToComics)) {
		writeln(pathToComics, "does not exists");
		return null;
	}
	auto cbrComics = dirEntries(pathToComics, SpanMode.depth).filter!(f => f.name.endsWith(".cbr"));
	auto cbzComics = dirEntries(pathToComics, SpanMode.depth).filter!(f => f.name.endsWith(".cbz"));
	auto cbtComics = dirEntries(pathToComics, SpanMode.depth).filter!(f => f.name.endsWith(".cbt"));
	comic[] comicsToReturn;
	db.begin();
	foreach (DirEntry e; cbzComics)
	{
		if (checkInDB(e.name.split("/")[e.name.split("/").length - 1]) == false) {
			comicsToReturn ~= getComic(e);
		} else {
			writeln(e.name, " is already in the DB");
		}
	}
	foreach (DirEntry e; cbrComics)
	{
    	if (checkInDB(e.name.split("/")[e.name.split("/").length - 1]) == false) {
			comicsToReturn ~= getComic(e);
		} else {
			writeln(e.name, " is already in the DB");
		}
	}
	db.commit();
	return comicsToReturn;
}

// Takes a array of comic and writes the data to the DB
void writeComicsToDB(comic[] comics) {
	db.begin();
	foreach (comic c; comics) {
		debug {
			writeln("Adding comic ", c.name, " to database");
		}
		Statement statement = db.prepare(
    	"INSERT INTO comics (name, path, type, rating, size)
    	VALUES (:name, :path, :type, :rating, :size)");
		statement.bind(":name", c.name);
		statement.bind(":path", c.path);
		statement.bind(":type", c.type);
		statement.bind(":rating", c.rating);
		statement.bind(":size", c.size);
		statement.execute();
		statement.reset();
	}
	db.commit();
}

ubyte[] resizeImages(ubyte[] image) {
	std.file.write("/tmp/komic_keeper/cover.tmp", image);
	auto pid = spawnProcess(["convert", "-resize", "20%", "/tmp/komic_keeper/cover.tmp", "/tmp/komic_keeper/cover.resized"]);
	wait(pid);
	ubyte[] toReturn = cast(ubyte[])(read("/tmp/komic_keeper/cover.resized"));
	std.file.remove("/tmp/komic_keeper/cover.tmp");
	std.file.remove("/tmp/komic_keeper/cover.resized");
	return toReturn;

}

bool unarInstalled() {
	try {
		spawnProcess("unar -h");
		return true;
	} catch (std.process.ProcessException e) {
		return false;
	}
}

bool checkInDB(string itemName) {
	Statement statement = db.prepare(
    	"SELECT * FROM comics WHERE name = :name");
	statement.bind(":name", itemName);
	ResultRange results = statement.execute();
	statement.reset();
	foreach (Row row; results) {
		return row["name"].as!string == null;
	}
	return false;
}

// Loops over all comics and extracts their cover to ./covers. This is very slow
// TODO: Add on the fly cover grabbing
// void getCovers()
// {
// 	ResultRange results = db.execute("SELECT * FROM comics WHERE type = 'cbr'");
// 	foreach (Row row; results) {
// 		string comicName = row["name"].as!string;
// 		if (exists("covers/" ~ comicName ~ "_" ~ "cover")) {
// 			writeln("Already got cover for ", comicName);
// 		} else {

// 			writeln("getting cover for ", comicName);

// 			ubyte[] tmpImage = cbrGetCover(row["path"].as!string, comicName);

// 			if (tmpImage != null) {
// 				ubyte[] toWrite;
// 				writeln(tmpImage.length);
// 				if (tmpImage.length /1000/1000 > 1) {
// 					toWrite = resizeImages(tmpImage);
// 				} else {
// 					toWrite = tmpImage;
// 				}
// 				std.file.write("covers/" ~ comicName ~ "_" ~ "cover", toWrite);
// 			}	
// 		}
// 	}

// 	results = db.execute("SELECT * FROM comics WHERE type = 'cbz'");
// 	foreach (Row row; results) {
// 		string comicName = row["name"].as!string;
// 		if (exists("covers/" ~ comicName ~ "_" ~ "cover")) {
// 			writeln("Already got cover for ", comicName);
// 		} else {

// 			writeln("getting cover for ", comicName);

// 			ubyte[] tmpImage = cbzGetCover(row["path"].as!string, comicName);

// 			if (tmpImage != null) {
// 				ubyte[] toWrite;
// 				writeln(tmpImage.length);
// 				if (tmpImage.length /1000/1000 > 1) {
// 					toWrite = resizeImages(tmpImage);
// 				} else {
// 					toWrite = tmpImage;
// 				}
// 				std.file.write("covers/" ~ comicName ~ ".cbz_" ~ "cover", toWrite);
// 			}	
// 		}	
// 		ubyte[] toWrite = cbzGetCover(row["path"].as!string);
// 		std.file.write("covers/" ~ row["name"].as!string ~ ".cbz_" ~ "cover", toWrite);
// 	}
// }

void onTheFlyCoverscbz(string[] paths) {
	foreach(string path; paths) {
		Statement statement = db.prepare(
    	"SELECT * FROM comics WHERE path = :path");
		statement.bind(":path", path);
		ResultRange results = statement.execute();
		statement.reset();
		foreach (Row row; results) {
			string comicName = row["name"].as!string;
			if (exists("covers/" ~ comicName ~ "_" ~ "cover")) {
				writeln("Already got cover for ", comicName);
			} else {

				writeln("getting cover for ", comicName);

				ubyte[] tmpImage = cbzGetCover(row["path"].as!string);

				if (tmpImage != null) {
					ubyte[] toWrite;
					writeln(tmpImage.length);
					if (tmpImage.length /1000/1000 > 1) {
						toWrite = resizeImages(tmpImage);
					} else {
						toWrite = tmpImage;
					}
					std.file.write("covers/" ~ comicName ~ ".cbz_" ~ "cover", toWrite);
				}	
			}	
			ubyte[] toWrite = cbzGetCover(row["path"].as!string);
			std.file.write("covers/" ~ row["name"].as!string ~ ".cbz_" ~ "cover", toWrite);
		}
	}
}

void indexPage(HTTPServerRequest req, HTTPServerResponse res)
{
	res.contentType = "text/html";
	Mustache mustache;
	auto context = new Mustache.Context;
	context["title"]  = "KomicKeeper";
	context["version"] = kkVersion;
	context["built"] = buildTime;
	context["totalComics"] = 5;
	res.writeBody(mustache.render("templates/index", context));
}

ubyte[] cbzGetCover(string comicPath) {
	writeln("Getting cover for " ~ comicPath);
	string[] fileNames;
	string coverName;
	auto zip = new ZipArchive(read(comicPath));
	// loop over the zip and add the names of all files in it to an array
	foreach (name, am; zip.directory)
	{
		// This if is here so we skip over folders
		if (am.expandedSize != 0) {
			fileNames ~= name;
		}
	}
	// This orders the file by name meaning that the first file in this array will be the cover
	auto f = fileNames.sort();
	foreach (name, am; zip.directory)
	{
		// Some comics include a XML file with their metadata which we want to skip
		if (name == f[0] && name.split(".")[name.split(".").length - 1] != "xml") {
			return zip.expand(am);
		}
	}
	return null;
}

ubyte[] cbrGetCover(string comicPath, string comicName) {
	string[] fileNames;
	string coverName;
	DirIterator comicFiles;
	debug {
		writeln("Unraring ", comicPath);
	}
	// Because of RAR closed source nature we have to use external tools to get the covers for cbr files
	// This shell call extracts the first file in the cbr to "/tmp/komic_keeper/$comicName"
	auto pid = spawnProcess(["unar", comicPath, "-o", "/tmp/komic_keeper/", "-s", "-i", "0"]);
	wait(pid);
	try {
		// loop over the dir and get the first file
		comicFiles = dirEntries("/tmp/komic_keeper/" ~ comicName.split(".cbr")[0] ~ "/", SpanMode.depth);
	} catch (std.file.FileException e) {
		return null;
	}

	foreach (DirEntry e; comicFiles)
	{
		ubyte[] toReturn = cast(ubyte[])(read(e.name));
    	return toReturn;
	}


	return null;
}

void listComics(HTTPServerRequest req, HTTPServerResponse res) 
{
	ResultRange results;
	Mustache mustache;
	auto context = new Mustache.Context;
	try {
		auto pageString = req.params["page"];
		int page = to!int(pageString);
		// TODO make it so the page number won't go below 1
		context["lastPage"]  = page - 1;
		context["nextPage"]  = page + 1;
		// The limit is 101 here because for some reason the first row returned is null
		Statement statement = db.prepare("SELECT * FROM comics LIMIT 101 OFFSET :offset");
		statement.bind(":offset", (page - 1) * 100);
		debug {
			writeln("SQL statement is SELECT * FROM comics LIMIT 100 OFFSET ", (page - 1) * 100);
		}
		results = statement.execute();
		statement.reset();
	} catch (object.Exception e) {
		context["nextPage"]  = 2;
		results = db.execute("SELECT * FROM comics LIMIT 100");
	}
	string page;
	string[] cbzPaths;
	foreach (Row row; results) {
		// This if makes sure we don't write any null rows
		if (row["name"].as!string != null) {
			if (row["type"].as!string == "cbz") {
				cbzPaths ~= row["path"].as!string;
			}
			float size = row["size"].as!int / 1000 / 1000;
			context["comicName"]  = row["name"].as!string;
			context["comicRating"]  = row["rating"].as!string;
			context["comicTags"]  = generateTagsHTML(row["tags"].as!string);
			context["comicSize"]  = ceil(size);
			context["comicLink"]  = "comix:///" ~ row["path"].as!string;
			page ~= mustache.render("templates/comicTable", context);
		}
	}
	// TODO: Think of a better name for the url context
	context["url"]  = "comics";
	context["comicTable"]  = page;
	res.contentType = "text/html";
	res.writeBody(mustache.render("templates/comicsBroswePage", context));
}

void tagPage(HTTPServerRequest req, HTTPServerResponse res) {
	// TODO: This code is repeated a few times and should be put in its own func
	ResultRange results;
	Mustache mustache;
	auto context = new Mustache.Context;
	auto pageString = req.params["page"];
	auto tag = req.params["tag"];
	int page1 = to!int(pageString);
	context["lastPage"]  = page1 - 1;
	context["nextPage"]  = page1 + 1;
	context["url"]  = "tags";
	Statement statement = db.prepare("SELECT * FROM comics WHERE instr(tags, :tag)>0 LIMIT 101 OFFSET :offset");
	statement.bind(":offset", (page1 - 1) * 100);
	statement.bind(":tag", tag);

	string page = generateTableHtml(statement);
	context["comicTable"]  = page;
	res.contentType = "text/html";
	res.writeBody(mustache.render("templates/comicsBroswePage", context));
}

void searchPageFirst(HTTPServerRequest req, HTTPServerResponse res) {
	ResultRange results;
	Mustache mustache;
	auto context = new Mustache.Context;
	auto searchTerm = req.params["searchTerm"];
	context["nextPage"] = 2;
	context["url"]  = "search";
	Statement statement = db.prepare("SELECT * FROM comics WHERE instr(name, :search)>0 LIMIT 100");
	statement.bind(":search", searchTerm);

	string page = generateTableHtml(statement);
	context["comicTable"]  = page;
	res.contentType = "text/html";
	res.writeBody(mustache.render("templates/comicsBroswePage", context));
}

void search(HTTPServerRequest req, HTTPServerResponse res) {
	ResultRange results;
	Mustache mustache;
	auto context = new Mustache.Context;
	auto searchTerm = req.params["searchTerm"];
	auto pageString = req.params["page"];
	int pageNumber = to!int(pageString);
	context["lastPage"]  = pageNumber - 1;
	context["nextPage"]  = pageNumber + 1;
	context["url"]  = "search";
	Statement statement = db.prepare("SELECT * FROM comics WHERE instr(tags, :search)>0 LIMIT 101 OFFSET :offset");
	statement.bind(":offset", (pageNumber - 1) * 100);
	statement.bind(":search", searchTerm);

	string page = generateTableHtml(statement);
	context["comicTable"]  = page;
	res.contentType = "text/html";
	res.writeBody(mustache.render("templates/comicsBroswePage", context));
}

void tagPageFirst(HTTPServerRequest req, HTTPServerResponse res) {
	ResultRange results;
	Mustache mustache;
	auto context = new Mustache.Context;
	auto tag = req.params["tag"];
	context["nextPage"]  = 2;
	context["url"]  = "tags";
	Statement statement = db.prepare("SELECT * FROM comics WHERE instr(tags, :tag)>0 LIMIT 100");
	statement.bind(":tag", tag);
	
	string page = generateTableHtml(statement);
	
	context["comicTable"]  = page;
	res.contentType = "text/html";
	res.writeBody(mustache.render("templates/comicsBroswePage", context));
}

string generateTableHtml(Statement statement) {
	Mustache mustache;
	auto context = new Mustache.Context;
	ResultRange results = statement.execute();
	statement.reset();
	string page;
	foreach (Row row; results) {
		// This if makes sure we don't write any null rows
		if (row["name"].as!string != null) {
			float size = row["size"].as!int / 1000 / 1000;
			context["comicName"]  = row["name"].as!string;
			context["comicRating"]  = row["rating"].as!string;
			context["comicTags"]  = generateTagsHTML(row["tags"].as!string);
			context["comicSize"]  = ceil(size);
			context["comicLink"]  = "comix:///" ~ row["path"].as!string;
			page ~= mustache.render("templates/comicTable", context);
		}
	}
	return page;

}

string generateTagsHTML(string tagsFromDB) {
	if (tagsFromDB == null) {
		return null;
	}
	string htmlToReturn;
	string[] tags = tagsFromDB.split(", ");
	Mustache mustache;
	auto context = new Mustache.Context;
	foreach (string tag; tags) {
		context["tagName"] = tag;
		htmlToReturn ~= mustache.render("templates/link", context);
	}
	return htmlToReturn;
}

void images(HTTPServerRequest req, HTTPServerResponse res)
{
	// TODO: fix this arbitrary file download vuln
    sendFile(req, res, NativePath("." ~ req.path));

}

void css(HTTPServerRequest req, HTTPServerResponse res)
{
    sendFile(req, res, NativePath("./static/style.css"));

}

void setComicRating(HTTPServerRequest req, HTTPServerResponse res) 
{
	// TODO: Make sure the rating is a number between 0 and 100
	auto comicName = req.params["comic"];
	auto newRating = req.form["rating"];
	writeln(comicName, newRating);
	Statement statement = db.prepare(
    	"UPDATE comics SET rating = :rating WHERE name = :name");
	statement.bind(":name", comicName);
	statement.bind(":rating", newRating);
	statement.execute();
	statement.reset();
}

void setComicTags(HTTPServerRequest req, HTTPServerResponse res) 
{
	auto comicName = req.form["comicName"];
	auto comicTags = req.form["tags"];
	foreach (string tag ; comicTags.split(", ")) {
		string currentTags = getComicTags(comicName);
		string tagsToWrite;
		if (currentTags != null) {
			tagsToWrite = currentTags ~ ", " ~ tag;
		} else {
			tagsToWrite = tag;
		}
		Statement statement = db.prepare(
			"UPDATE comics SET tags = :tags WHERE name = :name");
		statement.bind(":name", comicName);
		debug {
			writefln("Updating tags for %s to %s ", comicName, tagsToWrite);
		}
		statement.bind(":tags", tagsToWrite);
		statement.execute();
		statement.reset();
	}
}

// Returns the tags of a comic or null
string getComicTags(string comicName) {
	Statement statement = db.prepare(
    	"SELECT tags FROM comics WHERE name = :name");
	statement.bind(":name", comicName);
	ResultRange results = statement.execute();
	foreach (Row row; results) {
		return row["tags"].as!string;
	}
	return null;

}

void comicPage(HTTPServerRequest req, HTTPServerResponse res) {
	Mustache mustache;
	auto context = new Mustache.Context;
	auto comicName = req.params["comic"];
	context["comicName"]  = comicName;
	context["title"]  = "Komic Keeper";
	Statement statement = db.prepare("SELECT * FROM comics WHERE name = :name");
	statement.bind(":name", comicName);
	ResultRange results = statement.execute();
	statement.reset();
	foreach (Row row; results) {
		float size = row["size"].as!int / 1000 / 1000;
		context["comicName"]  = row["name"].as!string;
		context["comicRating"]  = row["rating"].as!string;
		context["comicSize"]  = ceil(size);
		context["comicLink"]  = "comix:///" ~ row["path"].as!string;
	}
	res.contentType = "text/html";
	res.writeBody(mustache.render("templates/comicPage", context));
}

void indexComics(HTTPServerRequest req, HTTPServerResponse res) {
	writeComicsToDB(getComics(globalPathToComics));
	res.writeBody("done");
}