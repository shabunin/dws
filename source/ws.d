/*
   (c) Vladimir Shabunin
   The base of this class is taked from dmd repo: listener.d
   https://github.com/dlang/dmd/blob/master/samples/listener.d
   Thanks it's authors for great example.

   Thanks to Mozilla Foundation for explanations of WebSockets
     https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_WebSocket_server
     https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_a_WebSocket_server_in_Java
     https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_WebSocket_servers
 */


import core.time;
import std.datetime.stopwatch;
import std.algorithm : remove;
import std.conv : to;
import std.socket : InternetAddress, Socket, SocketException, SocketSet, TcpSocket;
import std.stdio : writeln, writefln;
import std.regex;
import std.digest.crc, std.digest.md, std.digest.sha;
import std.base64;
import std.utf;
import std.bitmanip;

enum BUFF_SIZE = 4096;
enum MAX_MSGLEN = 65535;

class ListenerSocket {
  ushort max_connections;
  TcpSocket listener;
  SocketSet socketSet;
  Socket[] reads;
  string[] addrs;

  this(ushort port, ushort max_connections = 50) {
    listener = new TcpSocket();
    assert(listener.isAlive);
    listener.blocking(false);
    listener.bind(new InternetAddress(port));
    listener.listen(10);
    // Room for listener.
    this.max_connections = max_connections;
    socketSet = new SocketSet(max_connections + 1);
  }

  void onMessage(Socket sock, string addr, char[] data) {
    // empty, should be overrided
    // sock.send("hello, whats ur name?\n");
  }
  void onConnectionClose(Socket sock, string addr) {
    // should be overrided
    writeln(addr, ": closed");
  }
  void onConnectionOpen(Socket sock, string addr) {
    // should be overrided
    writeln(addr, ": new connection");
  }

  void broadcast(char[] data) {
    foreach(sock; reads) {
      sock.send(data);
    }
  }

  void loop() {

    socketSet.add(listener);
    foreach (sock; reads) {
      socketSet.add(sock);
    }

    // with timeout, so, won't block
    Socket.select(socketSet, null, null, 1.msecs);

    for (size_t i = 0; i < reads.length; i++)    {
      if (socketSet.isSet(reads[i])) {
        char[BUFF_SIZE] buf;
        auto datLength = reads[i].receive(buf[]);

        if (datLength == Socket.ERROR) {
          onConnectionClose(reads[i], addrs[i]);
        } else if (datLength != 0) {
          onMessage(reads[i], addrs[i], buf[0..datLength]);
          continue;
        } else {
          onConnectionClose(reads[i], addrs[i]);
        }

        // release socket resources now
        reads[i].close();

        reads = reads.remove(i);
        addrs = addrs.remove(i);
        // i will be incremented by the for, we don't want it to be.
        i--;
      }
    }

    // connection request
    if (socketSet.isSet(listener)) {
      Socket sn = null;
      scope (failure) {
        if (sn) {
          sn.close();
        }
      }
      sn = listener.accept();
      assert(sn.isAlive);
      assert(listener.isAlive);

      if (reads.length < max_connections) {
        reads ~= sn;
        auto addr = sn.remoteAddress().toString();
        addrs ~= addr;
        onConnectionOpen(sn, addr);
      } else {
        sn.close();
        assert(!sn.isAlive);
        assert(listener.isAlive);
      }
    }

    socketSet.reset();
  }
}

class WsListener: ListenerSocket {
  // fragmented frame chunks?
  string[string] fragmented;

  // simple constructor
  this(ushort port) {
    super(port);
  }
  override void onMessage(Socket sock, string addr, char[] data) {
    auto sockAddr = sock.remoteAddress.toString();
    auto s = data.toUTF8();
    try {
      validate(s);
      //writeln("correct UTF8 string?");
    } catch(Exception e) {
      //writeln("NOT correct UTF8 string?");
      auto bytes = cast(ubyte[]) data;
      bool fin = (bytes[0] & 0b10000000) != 0;

      // mask must be true, "All messages from the client to the server have this bit set"

      int opcode = bytes[0] & 0b00001111;
      if (!(opcode == 0x00 || opcode == 0x01)) {
        //("nor fragmented frame, neither text: ", opcode);
        // pass fragmented frame or 
        return;
      }
      bool rsv = (bytes[0] & 0b01110000) == 0;
      if (!rsv) {
        // reserved frames should be 0
        //("reserverd 3 bits should be 0!");
        return;
      }

      bool mask = (bytes[1] & 0b10000000) != 0; 
      if (!mask) {
        //("mask should be true!");
        return;
      }

      // & 0111 1111
      ulong msglen = bytes[1] - 128; 
      int offset = 2;
      if (msglen == 126) {
        msglen = bytes.peek!ushort(2);
        offset = 4;
      } else if (msglen == 127) {
        msglen = bytes.peek!ulong(2);
        offset = 10;
      }
      if (msglen > MAX_MSGLEN || msglen == 0) {
        return;
      }

      // try to receive whole message if there was not
      auto currentLen = data.length - offset - 4;
      if (currentLen < msglen) {
        while (currentLen < msglen) {
          char[BUFF_SIZE] buf;
          auto datLength = sock.receive(buf[]);
          if (datLength != 0) {
            data ~= buf[0..datLength];
            currentLen += datLength;

            // if two and more messages arrived in one buffer chunk
            if (datLength < buf.length) {
              onMessage(sock, addr, buf[datLength..$]);
            }
            continue;
          }
        }

        // finally, when we receive full frame
        onMessage(sock, addr, data);
        return;
      }

      // decode msg
      ubyte[] decoded;
      decoded.length = msglen;
      ubyte[4] masks = bytes[offset..offset+4];
      offset += 4;

      for (auto i = 0; i < msglen; ++i) {
        decoded[i] = cast(ubyte) (bytes[offset + i] ^ masks[i % 4]);
      }

      string text = (cast(char[])decoded).toUTF8();
      // if whole frame or the end of fragmented
      if (fin) {
        if (((sockAddr in fragmented) !is null) && (opcode == 0x00)) {
          fragmented[sockAddr] ~= text;
          // the end of fragmented frame
          onWsMessage(sock, addr, fragmented[sockAddr]);
          fragmented.remove(sockAddr);
        } else if (opcode == 0x01) {
          // whole frame
          onWsMessage(sock, addr, text);
        }
      } else if (opcode == 0x01) {
        // if the beginning of fragmented frame
        fragmented[sockAddr] = text;
        // now wait for other messages, but from this client
      }

      // if two or more messages arrived in one buffer
      auto expectedlen = offset + msglen;
      if (expectedlen < data.length) {
        onMessage(sock, addr, data[expectedlen..$]);
      }

      return;
    }
    auto r = ctRegex!(`^GET`);
    auto m = matchFirst(s, r);
    if (!m.empty) {
      auto krex = ctRegex!(`Sec-WebSocket-Key: (.*)`);
      auto k = matchFirst(s, krex);
      if (k.empty) {
        return;
      }
      auto swka = k[1]~"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
      auto swkaSha1 = sha1Of(swka);
      string swkaSha1Base64 = Base64.encode(swkaSha1);

      // send handshake
      auto response = "HTTP/1.1 101 Switching Protocols\r\n";
      response ~= "Connection: Upgrade\r\n";
      response ~= "Upgrade: websocket\r\n";
      response ~= "Sec-WebSocket-Accept: ";
      response ~= swkaSha1Base64;
      response ~= "\r\n\r\n";

      sock.send(response.toUTF8);

    } else {
      return;
    }
  }

  void onWsMessage(Socket sock, string addr, string data) {
    // empty. should be overrided
  }
  void sendWsMessage(Socket sock, string data) {
    ubyte[] encoded;
    if (data.length < 126) {
      encoded.length = 2 + data.length;
      // fin = 1; opcode = 1;
      encoded[0] = cast(ubyte)0b10000001;
      encoded[1] = cast(ubyte)(data.length);
      encoded[2..$] = cast(ubyte[])data[0..$];
      sock.send(encoded);
    } else if (data.length >= 126 && data.length <= 65535) {
      encoded.length = 4 + data.length;
      encoded[0] = cast(ubyte)0b10000001;
      encoded[1] = cast(ubyte)(126);
      encoded.write!ushort(cast(ushort)data.length, 2);
      encoded[4..$] = cast(ubyte[])data[0..$];
      sock.send(encoded);
    } else if (data.length > 65535) {
      encoded.length = 10 + data.length;
      encoded[0] = cast(ubyte)0b10000001;
      encoded[1] = cast(ubyte)(127);
      encoded.write!ulong(cast(ulong)data.length, 2);
      encoded[10..$] = cast(ubyte[])data[0..$];
      sock.send(encoded);
    }
  }
  void broadcastWsMessage(string data) { 
    foreach(s; reads) {
      sendWsMessage(s, data);
    }
  }
}

