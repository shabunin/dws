/**
  This module provedes simple websocket pubsub service.
  
  Connected client may subsribe/unsubscribe to channels and publish messages.

  Subscribe/unsubscribe request should has following structure:
  [<req_id>, <method>, <channels>]
  where
  <req_id> - int or string. So, result with this id will be send to client.
  <method> - string. "subscribe"/"unsubscribe".
  <channels> - string or array of strings.

  Publish request: 
  [<req_id>, <method>, <channels>, <message>]
  where message is any valid json.

  Any request should be valid JSON.

  Copyright (c) 2020 Vladimir Shabunin

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
  **/

import core.thread;
import std.algorithm : remove;
import std.stdio;
import std.socket : Socket;
import std.json;

import ws;

const string PUBLISH = "publish";
const string SUBSCRIBE = "subscribe";
const string UNSUBSCRIBE = "unsubscribe";
const string DEBUG_CHANNEL = "dws_debug_channel";

struct Subscription {
  string channel;
  Socket sock;
  string addr;
}

class MyPubSub: WsListener {
  Subscription[] subs;
  this(ushort port) {
    super(port);
  }
  void publish(string[] channels, JSONValue message) {
    // check channel and message
    foreach(Subscription s; subs) {
      foreach(string channel; channels) {
        if (s.channel == channel || s.channel == DEBUG_CHANNEL) {
          auto json2publish = parseJSON("[]");
          json2publish.array.length = 4;
          json2publish.array[0] = JSONValue(-1);
          json2publish.array[1] = JSONValue(PUBLISH);
          json2publish.array[2] = JSONValue(channel);
          json2publish.array[3] = message;
          sendWsMessage(s.sock, json2publish.toJSON());
        }
      }
    }
  }
  void subscribe(Socket sock, string addr, string[] channels) {
    // if there is no subscription in 
    foreach(Subscription s; subs) {
      foreach(string channel; channels) {
        if (s.addr == addr && s.channel == channel) {
          throw new Exception("Already subscribed");
        }
      }
    }
    // if no error was throws add subscriptions
    foreach(string channel; channels) {
      // append to array
      Subscription sub;
      sub.channel = channel;
      sub.sock = sock;
      sub.addr = addr;
      subs ~= sub;
    }
  }

  void unsubscribe(Socket sock, string addr, string[] channels) {
    // if there is no subscription in 
    foreach(string channel; channels) {
      bool subFound = false;
      for(auto i = 0; i < subs.length; i += 1) {
        auto s = subs[i];
        if (s.addr == addr && s.channel == channel) {
          subFound = true;
        }
      }
      if (!subFound) {
        throw new Exception("Subscription not found");
      }
    }
    // finally, if no error was thrown, delete subscriptions
    foreach(string channel; channels) {
      for(auto i = 0; i < subs.length; i += 1) {
        auto s = subs[i];
        if (s.addr == addr && s.channel == channel) {
          subs = subs.remove(i);
          i -= 1;
        }
      }
    }
  }

  override void onConnectionOpen(Socket sock, string addr) {
    writeln("New connection: ", addr);
  }
  override void onConnectionClose(Socket sock, string addr) {
    writeln("Disconnected: ", addr);
    for(auto i = 0; i < subs.length; i += 1) {
      auto s = subs[i];
      // remove all subscriptions
      if (s.addr == addr) {
        subs = subs.remove(i);
        i -= 1;
      }
    }
  }
  override void onWsMessage(Socket sock, string addr, string data) {
    JSONValue j;
    try {
      j = parseJSON(data);
    } catch(Exception e) {
      //writeln("error processing message: ", e.message);
    }

    if (j.type() !is JSONType.array) {
      return;
    }
    if (j.array.length < 3) {
      return;
    }
    // each message should be JSON-serialized array
    // [REQ_ID, method, payload]
    // ["xxx", "subscribe", "channel"]
    // ["yyy", "subscribe", ["channel1", "channel2"]]
    auto jreq_id = j.array[0];
    // req_id: integer or string
    if (jreq_id.type() != JSONType.integer
        && jreq_id.type() != JSONType.string) {
      return;
    }
    // method: only string
    auto jmethod = j.array[1];
    if (jmethod.type() != JSONType.string) {
      return;
    }
    // payload of any type
    auto jpayload = j.array[2];

    void sendResponse(JSONValue method, JSONValue res) {
      auto jres = parseJSON("[]");
      jres.array ~= jreq_id;
      jres.array ~= method;
      jres.array ~= res;
      sendWsMessage(sock, jres.toJSON());
    }

    // now depends on method
    auto method = jmethod.str;
    switch (method) {
      case PUBLISH:
        try {
          string[] channels;

          // check request array len
          if (j.array.length < 4) {
            throw new Exception("Few arguments for PUBLISH command");
          }

          JSONValue jchannels = jpayload;
          if (jchannels.type() == JSONType.string) {
            channels ~= jchannels.str;
          } else if (jchannels.type() == JSONType.array) {
            foreach(JSONValue t; jchannels.array) {
              if (t.type() != JSONType.string) {
                throw new Exception("Channel item in array in not string");
              }
              channels ~= t.str;
            }
          } else {
            throw new Exception("Channel field in not string/array");
          }

          JSONValue jmessage = j.array[3];
          publish(channels, jmessage);
          sendResponse(JSONValue("success"), JSONValue(0));
        } catch(Exception e) {
          sendResponse(JSONValue("error"), JSONValue(e.message));
        }
        break;
      case SUBSCRIBE:
        try {
          string[] channels;
          if (jpayload.type() == JSONType.string) {
            channels ~= jpayload.str;
            subscribe(sock, addr, channels);
          } else if (jpayload.type() == JSONType.array) {
            foreach(JSONValue t; jpayload.array) {
              if (t.type() != JSONType.string) {
                throw new Exception("Channel array should be of string");
              }
              channels ~= t.str;
            }
            subscribe(sock, addr, channels);
          } else {
            throw new Exception("Channels value is not string or array of strings");
          }
          sendResponse(JSONValue("success"), JSONValue(0));
        } catch(Exception e) {
          sendResponse(JSONValue("error"), JSONValue(e.message));
        }
        break;
      case UNSUBSCRIBE:
        try {
          string[] channels;
          if (jpayload.type() == JSONType.string) {
            channels ~= jpayload.str;
            unsubscribe(sock, addr, channels);
          } else if (jpayload.type() == JSONType.array) {
            foreach(JSONValue t; jpayload.array) {
              if (t.type() != JSONType.string) {
                throw new Exception("Channel array should be of string");
              }
              channels ~= t.str;
            }
            unsubscribe(sock, addr, channels);
          } else {
            throw new Exception("Channels value is not string or array of strings");
          }
          sendResponse(JSONValue("success"), JSONValue(0));
        } catch(Exception e) {
          sendResponse(JSONValue("error"), JSONValue(e.message));
        }
        break;
      default:
        break;
    }
  }
}

void main()
{
  writeln("hello, friend");
  ushort port = 45000;
  writeln("listening on port: ", port);
  auto pubsub = new MyPubSub(port);
  while (true) {
    pubsub.loop();
    Thread.sleep(1.msecs);
  }
}
