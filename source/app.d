import vibe.http.router;
import vibe.http.server;
import vibe.http.fileserver;
import vibe.http.client;
import vibe.core.core;
import vibe.core.net;
import vibe.core.args;
import vibe.core.sync;
import vibe.data.json;
import vibe.core.log;
import vibe.http.websockets;
import vibe.stream.operations;
import std.algorithm.searching : find;
import std.string : replace, representation;
import std.range : front, empty;
import std.datetime.systime;
import core.time;
import mofile;

struct MountPoint
{
    string server_name;
    string description;
    uint listeners;
    string title;
    string genre;
    string previous_title;
}

Json mountPointsToJson(const(MountPoint)[] mountPoints)
{
    Json toReturn = Json.emptyArray;
    foreach(mountPoint; mountPoints)
    {
        Json mpJson = Json.emptyObject;
        mpJson["server_name"] = mountPoint.server_name;
        mpJson["listeners"] = mountPoint.listeners;
        mpJson["title"] = mountPoint.title;
        mpJson["previous_title"] = mountPoint.previous_title;
        toReturn.appendArrayElement(mpJson);
    }
    return toReturn;
}

struct VoteForSkip
{
    bool[string] ips;
    SysTime lastTrackChangeTime;

    void reset() {
        ips.clear();
    }
}

void main(string[] args)
{
    string icecastServerAddress = "http://127.0.0.1:8000/";
    string pageTitle = "Some cool music";
    string liquidsoapIp = "127.0.0.1";
    ushort liquidsoapTelnetPort = 1234;
    string mofilePath;

    readOption("pageTitle", &pageTitle, "Page title");
    readOption("icecastAddress", &icecastServerAddress, "Icecast server address");
    readOption("liquidsoapIp", &liquidsoapIp, "ip address where liquidsoap is running (without port)");
    readOption("liquidsoapTelnetPort", &liquidsoapTelnetPort, "liquidsoap port to talk via telnet");
    readOption("mofile", &mofilePath, "Path to .mo translation file");
    if (icecastServerAddress.length && icecastServerAddress[$-1] != '/') {
        icecastServerAddress ~= '/';
    }

    if (!finalizeCommandLineOptions()) {
        return;
    }

    MoFile moFile;
    if (mofilePath.length)
        moFile = MoFile(mofilePath);

    string icecastJsonEndpoint = icecastServerAddress ~ "json.xsl";
    MountPoint[] mountPoints;
    VoteForSkip[string] votes;

    auto settings = new HTTPServerSettings;
    settings.port = 8080;
    settings.bindAddresses = ["0.0.0.0"];

    auto router = new URLRouter;

    auto mutex = new TaskMutex;
    auto condition = new TaskCondition(mutex);

    void handleWebSocketConnection(scope WebSocket sock)
    {
        while (sock.connected) {
            synchronized(mutex) condition.wait();
            if (sock.connected) {
                Json toRespond = mountPointsToJson(mountPoints);
                sock.send(toRespond.toString());
            }
        }
    }

    auto gettext = delegate string(string msg) {
        return moFile.gettext(msg);
    };

    void index(HTTPServerRequest req, HTTPServerResponse res)
    {
        res.render!("radio.dt", mountPoints, pageTitle, icecastServerAddress, gettext);
    }

    void info(HTTPServerRequest req, HTTPServerResponse res)
    {
        Json toRespond = mountPointsToJson(mountPoints);
        res.writeJsonBody(toRespond);
    }

    void skip(HTTPServerRequest req, HTTPServerResponse res)
    {
        string server_name = req.query.get("server_name", "");
        if (server_name.length) {
            auto mountPoint =  mountPoints.find!("a.server_name == b")(server_name);
            if (!mountPoint.empty) {
                auto serverVote = server_name in votes;
                if (!serverVote) {
                    votes[server_name] = VoteForSkip();
                    serverVote = server_name in votes;
                }
                if ((Clock.currTime - serverVote.lastTrackChangeTime).total!"seconds" < 10) {
                    Json response = Json.emptyObject;
                    response["status"] = "wait";
                    res.writeJsonBody(response);
                    return;
                }
                serverVote.ips[req.clientAddress.toAddressString()] = true;
                if (serverVote.ips.length > mountPoint.front.listeners/2) {
                    serverVote.reset();
                    serverVote.lastTrackChangeTime = Clock.currTime;
                    try
                    {
                        auto socket = connectTCP(liquidsoapIp, liquidsoapTelnetPort);
                        auto request = server_name.replace(".", "(dot)") ~ ".skip\r\n";
                        socket.write(request.representation);
                        socket.close();
                        Json response = Json.emptyObject;
                        response["status"] = "change";
                        res.writeJsonBody(response);
                    }
                    catch(Exception e)
                    {
                        logError("Error during tcp request to icecast telnet interface: %s", e);
                        res.statusCode = HTTPStatus.internalServerError;
                        res.writeVoidBody();
                    }

                } else {
                    Json response = Json.emptyObject;
                    response["status"] = "vote";
                    res.writeJsonBody(response);
                }
            } else {
                res.statusCode = HTTPStatus.notFound;
                res.writeVoidBody();
            }
        } else {
            res.statusCode = HTTPStatus.BadRequest;
            res.writeBody("server_name must be supplied", "text/plain");
        }
    }

    router.get("/", &index);
    router.get("/info", &info);
    router.get("/ws_info", handleWebSockets(&handleWebSocketConnection));
    router.post("/skip", &skip);
    import std.path;
    import std.file;
    string publicDir = buildPath(dirName(thisExePath()), "public");
    router.get("*", serveStaticFiles(publicDir));

    listenHTTP(settings, router);

    runTask({
        while(true)
        {
            HTTPClientResponse res;
            try {
                res = requestHTTP(icecastJsonEndpoint, (scope HTTPClientRequest req) {});
            } catch(Exception e) {
                logError("Error during http request to icecast endpoint: %s", e);
                sleep(dur!"msecs"(5000));
                continue;
            }
            try {
                auto data = res.bodyReader.readAllUTF8();
                auto jsonArr = data.parseJsonString();
                mountPoints.reserve(jsonArr.length);
                bool shouldNotify;
                foreach(json; jsonArr)
                {
                    string server_name = json["server_name"].to!string;
                    auto findResult = mountPoints.find!("a.server_name == b")(server_name);
                    MountPoint mp;
                    mp.server_name = server_name;
                    mp.description = json["description"].to!string;
                    mp.listeners = json["listeners"].to!uint;
                    mp.title = json["title"].to!string;
                    mp.genre = json["genre"].to!string;
                    if (!findResult.empty) {
                        auto foundMountPoint = &findResult.front;
                        if (foundMountPoint.title != mp.title || foundMountPoint.listeners != mp.listeners) {
                            if (foundMountPoint.title != mp.title) {
                                mp.previous_title = foundMountPoint.title;
                                auto vote = mp.server_name in votes;
                                if (vote)
                                    vote.reset();
                            } else {
                                mp.previous_title = foundMountPoint.previous_title;
                            }
                            *foundMountPoint = mp;
                            shouldNotify = true;
                        }
                    } else  {
                        mountPoints ~= mp;
                    }
                }
                if (shouldNotify) {
                    condition.notifyAll();
                }
            } catch(Exception e) {
                logError("Error during processing response from icecast: %s", e);
            }
            sleep(dur!"msecs"(5000));
        }
    });


    logInfo("Please open http://127.0.0.1:%s/ in your browser.", settings.port);
    runApplication();
}
