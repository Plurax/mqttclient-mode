# mqtt-client

Interact wiht mqtt brokers from simple text files.

## Description

To achieve easy interaction with MQTT brokers, I mixed up [restclient](https://github.com/pashky/restclient.el "restclient") with [mqtt-mode](https://github.com/andrmuel/mqtt-mode "mqtt-mode").
The difference to the existing mqtt-mode is, that it is now using outline mode and the user can interact directly with different payloads and topic configs.
From restclient, I used the regex matching for payloads and variable replacement with inline lisp support. This means you can for example send messages with timestamps (see API.mqtt), generated from lisp code.

## Installation

I dont know yet how to provide this on MELPA, but I try to get the code clean enough to face this.
Unless this is available, just load it manually with require or cask from git. You need to install mosquitto-clients.

``` 1c-enterprise
apt-get install mosquitto-clients
```

## Usage

Require this file and you can call the mqttclient-mode when visiting a buffer containing MQTT api descriptions like in API.mqtt.
I borrowed some keys from the restclient, so the usage is straight forward:

`C-c C-c`: This will publish the data at point with the given parameters if PUB is the prefix, otherwise a subscribe process is started.
`C-c C-p`: Jump to previous
`C-c C-n`: Jump to next
`C-c C-.`: Mark current
`C-c C-u`: Create mosquitto command from request at point

As the mode is derived from outline mode, you can fold the payload. But as we are talking about MQTT those payloads should not be that big though.

## Configuration

All parameters can be derived from the api file which the mode rans on. Variables are interpretede for the whole file until the request at point.
That means you can provide the port once at the beginning...

``` 1c-enterprise
# Initial setup
:mqtt-host := "localhost"
#:mqtt-ca-path := "/path/to/certs"
#:mqtt-tls-version := "tlsv1.2"
#:mqtt-username := "user"
#:mqtt-password := "secret"
:mqtt-port := 1883
SUB #
```

## Contributing

Feel free to spend time in improving this.

### Todos

  * [ ] More testing
  * [ ] Kill existing subscription buffer when pressing `C-c C-c` on SUB again
  * [ ] Each api file creates its own subscribe buffer (e.g. when playing with multiple brokers)
  * [ ] Check multiline body function
  * [ ] Provide info if errors occured during calls (mosquitto_sub / _pub)
  * [ ] Fix some code issues
  * [ ] May be create a package

## Credits

Credits to the authors of restclient and mqtt-mode, I just blended those.

## Author

I am not a lisper - so the code might be not elegant...

## License

MIT
