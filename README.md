# dws - basic websocket pub/sub in dlang

## Intro

It is very basic app to provide pubsub architecture over websocket.
For websocket server I wrote own implementation(`ws.d`). There is few ws servers can be found at code.dlang.org, but some are depends on heavy frameworks like vibe-d, some are hard to compile(trying to build lighttpd on single-board computer is a lot of pain). So, I implemented own by following guide: 

<https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_WebSocket_server>

There is poor support for fragmented messages and it's not tested completely, so, should be used carefully.
There is no smart algorithms, this app is pretty straight.
No wss support.

## Protocol

Message should be serialized JSON string:

```text
[<req_id>, <method>, <payload>]
```

`req_id` - string or integer
`method` - string
`payload` - type depends on method

Examples of requests:

```text
[1, "subscribe", "hello"]
[2, "unsubscribe", "hello"]
[3, "subscribe", ["friend", "world"]]
[4, "unsubscribe", ["friend", "world"]]
["wrongReq", "unsubscribe", ["logger", "bobaos", "dobaos", 42]]
[5, "publish", "hello", "message"]
[6, "publish", ["hello", "friend"], "message"]
[7, "publish", ["world", "friend"], "message"]
[8, "publish", ["hello", "world"], "message"]
[9, "publish", ["hello", "world"], {"key": "value"}]
```

Response examples:

```text
[1, "success", 0]
["wrong_req", "error", "Error reason"]
```

Incoming message for subscriber:

```text
[-1, "publish", "channel name", "message string"]
```

<req_id> always has value `-1` for published messages.

## License

Copyright (c) 2020 Shabunin Vladimir

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

