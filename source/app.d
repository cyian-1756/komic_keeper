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
import std.parallelism;
import std.random;
import core.thread;
import std.uni : toUpper;
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
static string randKeyAlph = "qwertyuiopasdfghjklzxcvbnmQWERTYUIOPASDFGHJKLZXCVBNM1234567890";
auto rnd = Random(1);



void main(string[] args)
{
	rnd = Random(unpredictableSeed);
	db = Database("db.sqlite");
	auto ini = Ini.Parse("config.ini");
	globalPathToComics = ini["config"].getKey("comic_path");

	if (args.length > 1) {
		if (args[1] == "--get-covers") {
			getCovers();
			return;
		} else if (args[1] == "--index-comics") {
			getComics(globalPathToComics);
			return;
		}
	} else {

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
	string randString;
	for (int i = 0; i != 10; i++) {
		randString ~= randKeyAlph[uniform(0, 15, rnd)];
	}
	std.file.write("/tmp/komic_keeper/cover.tmp." ~ randString, image);
	try {
		auto pid = spawnProcess(["convert", "-resize", "20%", "/tmp/komic_keeper/cover.tmp." ~ randString, "/tmp/komic_keeper/cover.resized." ~ randString]);
		wait(pid);
	} catch (std.process.ProcessException e) {
		writefln("[!] Failed to spawn convert because of error %s\nTrying again", e.msg);
		// Sleep for a little bit
		Thread.sleep(1.seconds);
		try {
			auto pid = spawnProcess(["convert", "-resize", "20%", "/tmp/komic_keeper/cover.tmp." ~ randString, "/tmp/komic_keeper/cover.resized." ~ randString]);
			wait(pid);
		} catch (std.process.ProcessException e) {
			return null;
		}

	}
	try {
		ubyte[] toReturn = cast(ubyte[])(read("/tmp/komic_keeper/cover.resized." ~ randString));
		std.file.remove("/tmp/komic_keeper/cover.tmp." ~ randString);
		std.file.remove("/tmp/komic_keeper/cover.resized." ~ randString);
		return toReturn;
	} catch (std.file.FileException e) {
		writefln("Could not remove temp files\nGot Error: %s", e.msg);
		return null;
	}

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

comic[] dbToComic(string type) {
	Statement statement = db.prepare(
    	"SELECT * FROM comics WHERE type = :type");
	statement.bind(":type", type);
	ResultRange results = statement.execute();
	comic[] comics;
	foreach (Row row; results) {
		comic c;
		c.name = row["name"].as!string;
		c.path = row["path"].as!string;
		comics ~= c;
	}
	statement.reset();
	return comics;		

}

// Loops over all comics and extracts their cover to ./covers. This is very slow
// TODO: Add on the fly cover grabbing
void getCovers()
{
	comic[] comics = dbToComic("cbr");
	foreach (comic c; comics.parallel(12)) {
		string comicName = c.name;
		if (exists("covers/" ~ comicName ~ "_" ~ "cover")) {
			writeln("[*] Already got cover for ", comicName);
		} else {

			writefln("[*] Getting cover for %s\n", comicName);

			ubyte[] tmpImage = cbrGetCover(c.path, comicName);

			if (tmpImage != null) {
				ubyte[] toWrite;
				if (tmpImage.length /1000/1000 > 1) {
					toWrite = resizeImages(tmpImage);
				} else {
					toWrite = tmpImage;
				}
				std.file.write("covers/" ~ comicName ~ "_" ~ "cover", toWrite);
			}	
		}
	}

	comics = dbToComic("cbz");
	foreach (comic c; comics) {
		string comicName = c.name;
		if (exists("covers/" ~ comicName ~ "_" ~ "cover")) {
			writeln("[*] Already got cover for ", comicName);
		} else {

			writeln("[*] Getting cover for ", comicName);

			ubyte[] tmpImage = cbzGetCover(c.path);

			if (tmpImage != null) {
				ubyte[] toWrite;
				if (tmpImage.length /1000/1000 > 1) {
					toWrite = resizeImages(tmpImage);
				} else {
					toWrite = tmpImage;
				}
				debug {
					writeln("[+] Writing file " ~ "covers/" ~ comicName ~ "_" ~ "cover");
				}
				std.file.write("covers/" ~ comicName ~ "_" ~ "cover", toWrite);
			} else {
				writeln("[!] Couldn't get cover for ", comicName);
			}
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
	string[] fileNames;
	string coverName;
	try {
		writeln("Opening zip ", comicPath);
		auto zip = new ZipArchive(read(comicPath));
		// loop over the zip and add the names of all files in it to an array
		writeln("Looping over zip for file names");
		foreach (name, am; zip.directory)
		{
			// This if is here so we skip over folders
			if (am.expandedSize != 0) {
				fileNames ~= name;
			}
		}
		// This orders the file by name meaning that the first file in this array will be the cover
		writeln("Sorting files");
		auto f = fileNames.sort();
		foreach (name, am; zip.directory)
		{
			// Some comics include a XML file with their metadata which we want to skip
			if (name == f[0] && name.split(".")[name.split(".").length - 1] != "xml") {
				return zip.expand(am);
			}
		}
	} catch (std.zip.ZipException e) {
		writefln("[!] Got error: %s", e.msg);
		return null;
	}
	return null;
}

ubyte[] cbrGetCover(string comicPath, string comicName) {
	string[] fileNames;
	string coverName;
	DirIterator comicFiles;
	debug {
		writeln("[*] Unraring ", comicPath);
	}
	// Because of RAR closed source nature we have to use external tools to get the covers for cbr files
	// This shell call extracts the first file in the cbr to "/tmp/komic_keeper/$comicName"
	auto pid = spawnProcess(["unar", comicPath, "-o", "/tmp/komic_keeper/" ~ comicName.split(".cbr")[0], "-s", "-i", "0", "-D"]);
	wait(pid);
	try {
		// loop over the dir and get the first file
		comicFiles = dirEntries("/tmp/komic_keeper/" ~ comicName.split(".cbr")[0] ~ "/", SpanMode.depth);
	} catch (std.file.FileException e) {
		// Sometimes the cbr extracts a single file so we try this
		if (exists("/tmp/komic_keeper/" ~ comicName.split(".cbr")[0] ~ ".jpg")) {
			return cast(ubyte[])(read("/tmp/komic_keeper/" ~ comicName.split(".cbr")[0] ~ ".jpg"));
		}
		if (exists("/tmp/komic_keeper/" ~ comicName.split(".cbr")[0] ~ ".png")) {
			return cast(ubyte[])(read("/tmp/komic_keeper/" ~ comicName.split(".cbr")[0] ~ ".png"));
		}
		return null;
	}

	foreach (DirEntry e; comicFiles)
	{
		try {
			ubyte[] toReturn = cast(ubyte[])(read(e.name));
			// Delete the temp folder
			// rmdirRecurse("/tmp/komic_keeper/" ~ comicName.split(".cbr")[0]);
    		return toReturn;
		} catch (std.file.FileException e) {
			// 
			writefln("Could not get cover for %s\nGot Error: %s", comicName, e.msg);
		}
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
	string[] cbzNames;
	foreach (Row row; results) {
		// This if makes sure we don't write any null rows
		if (row["name"].as!string != null) {
			if (row["type"].as!string == "cbz") {
				cbzNames ~= row["name"].as!string;
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
	// We turn both the colum we're searching and the search term to upper case
	Statement statement = db.prepare("SELECT * FROM comics WHERE instr(UPPER(name), :search)>0 LIMIT 100");
	statement.bind(":search", toUpper(searchTerm));

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
	ulong currentTag = 1;
	ulong totalTags = tags.length;
	Mustache mustache;
	auto context = new Mustache.Context;
	foreach (string tag; tags) {
		context["tagName"] = tag;
		htmlToReturn ~= mustache.render("templates/link", context);
		if (currentTag != totalTags) {
			htmlToReturn ~= " | ";
		}
		currentTag += 1;
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

unittest {
	// Check the tag generation
	auto tagHtml = generateTagsHTML("test1, test2");
	auto expectedTagHtml = "<a href=\"/tags/test1\">test1 </a> | <a href=\"/tags/test2\">test2 </a>";
	try {
		assert(tagHtml == expectedTagHtml);
	} catch (core.exception.AssertError e) {
		writefln("tag html was \"%s\" not \"%s\"", tagHtml, expectedTagHtml);
		throw(e);
	}
}