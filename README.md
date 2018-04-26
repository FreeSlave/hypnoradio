# Hypnoradio

Http server that provides simple web interface to icecast radio server, that's meant to be shown to listeners, not icecast administrators.
Made with [vibe.d](https://vibed.org/)

Features:

* Name of the currently playing track and the number of listeners are automatically updating on browser side via WebSockets
* Users can vote to skip the track when liquidsoap is used for streaming to icecast

## Usage

    ./hypnoradio --pageTitle="My cool radio" --icecastAddress=http://127.0.0.1:8000/ # put actual icecast address here

If you want to use *skip* feature with liquidsoap don't forget to include the following line in your liquidsoap script:

    set("server.telnet", true)
