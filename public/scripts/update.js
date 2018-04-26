function handleInfoResponse(response)
{
    for (var i=0; i<response.length; ++i) {
        var mountPoint = response[i];
        var serverName = mountPoint.server_name;
        var element = document.getElementById(serverName);
        if (element) {
            var listeners = document.getElementById(serverName + ".listeners");
            listeners.innerHTML = mountPoint.listeners;
            var title = document.getElementById(serverName + ".title");
            if (title.innerHTML != mountPoint.title) {
                var vote_status = document.getElementById(serverName + ".vote_status");
                vote_status.innerHTML = "";
            }
            title.innerHTML = mountPoint.title;
            var previous_title = document.getElementById(serverName + ".previous_title");
            if (previous_title)
                previous_title.innerHTML = mountPoint.previous_title;
        }
    }
}

function update()
{
    var xhttp = new XMLHttpRequest();
    xhttp.onreadystatechange = function() {
        if (this.readyState == 4 && this.status == 200) {
            var response = JSON.parse(this.responseText);
            handleInfoResponse(response);
        }
    };
    xhttp.open("GET", "/info", true);
    xhttp.send();
}

function fallback_to_javascript()
{
    setInterval(update, 15000);
}

function start_update()
{
    var audios = document.getElementsByTagName('audio');
    for (var i=0; i<audios.length; ++i)
    {
        (function() {
            var a = audios[i];
            a.addEventListener('pause', function() {var tmpsrc = a.getElementsByTagName('source')[0].src; a.src = ''; a.load(); a.src = tmpsrc;});
        })();
    }

    try {
        var socket = new WebSocket('ws://' + window.location.host + '/ws_info');
        socket.onerror = function(err) {
            console.error(err);
            console.log("Could not connect via web socket, fallback to polling via AJAX");
            fallback_to_javascript();
        }
        socket.onmessage = function (event) {
            var response = JSON.parse(event.data);
            handleInfoResponse(response);
        };
        socket.onclose = function() {
            console.log("Connection to web socket closed, fallback to polling via AJAX");
            fallback_to_javascript();
        }
    } catch(e) {
        console.error(e);
        console.log("Could not create WebSocket, fallback to polling via AJAX");
        fallback_to_javascript();
    }
}

function voteForSkip(server_name)
{
    var xhttp = new XMLHttpRequest();
    xhttp.onreadystatechange = function() {
        if (this.readyState == 4 && this.status == 200) {
            var vote_status = document.getElementById(server_name + ".vote_status");
            if (vote_status) {
                var response = JSON.parse(this.responseText);
                var msg = null;
                switch(response.status) {
                    case "wait":
                        msg = "Вы уже голосовали недавно, подождите немного";
                        break;
                    case "vote":
                        msg = "Запрос будет исполнен, если другие пользователи тоже захотят сменить трек";
                        break;
                    case "change":
                        msg = "Запускаю следующий трек...";
                        break;
                    default:
                        break;
                }
                if (msg) {
                    vote_status.innerHTML = msg;
                }
            }
        }
    };
    xhttp.open("POST", "/skip?server_name=" + server_name, true);
    xhttp.send();
}
