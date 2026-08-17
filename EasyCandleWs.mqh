#ifndef EASY_CANDLE_WS_MQH
#define EASY_CANDLE_WS_MQH

// TCP + WebSocket client (RFC 6455). MQL5 has no WebSocket API: handshake and
// masked text frames are built on SocketCreate / SocketConnect.

class CEasyCandleWs
  {
private:
   int               m_socket;
   bool              m_open;
   uchar             m_rx[];
   int               m_rx_len;

   bool              SendBytes(const uchar &data[], const int count);
   bool              SendFrame(const uchar opcode, const uchar &payload[], const int payload_len);
   bool              Handshake(const string host, const uint port);
   bool              ReadHttpHeaders(string &headers, const uint timeout_ms);
   void              AppendRx(const uchar &data[], const int count);
   void              ConsumeRx(const int count);
   bool              ProcessRx(void);
   string            RandomKey(void);
   uchar             RandByte(void);

public:
                     CEasyCandleWs(void);
                    ~CEasyCandleWs(void);

   bool              IsOpen(void) const { return (m_open && m_socket != INVALID_HANDLE && SocketIsConnected(m_socket)); }
   bool              Connect(const string host, const uint port, const uint timeout_ms);
   bool              SendText(const string payload);
   void              Poll(void);
   void              Close(void);
  };

void CEasyCandleWs::CEasyCandleWs(void)
  {
   m_socket = INVALID_HANDLE;
   m_open = false;
   m_rx_len = 0;
   ArrayResize(m_rx, 0);
  }

void CEasyCandleWs::~CEasyCandleWs(void)
  {
   Close();
  }

uchar CEasyCandleWs::RandByte(void)
  {
   return (uchar)((MathRand() ^ (int)GetMicrosecondCount() ^ GetTickCount()) & 0xFF);
  }

string CEasyCandleWs::RandomKey(void)
  {
   uchar raw[16];
   for(int i = 0; i < 16; i++)
      raw[i] = RandByte();

   uchar dummy[1];
   dummy[0] = 0;
   uchar encoded[];
   if(CryptEncode(CRYPT_BASE64, raw, dummy, encoded) <= 0)
      return "";

   string key = CharArrayToString(encoded, 0, WHOLE_ARRAY, CP_ACP);
   StringReplace(key, "\r", "");
   StringReplace(key, "\n", "");
   StringReplace(key, " ", "");
   return key;
  }

bool CEasyCandleWs::SendBytes(const uchar &data[], const int count)
  {
   if(m_socket == INVALID_HANDLE || count < 0)
      return false;
   if(count == 0)
      return true;

   int sent = 0;
   while(sent < count)
     {
      if(!SocketIsConnected(m_socket))
         return false;

      const int remain = count - sent;
      const int chunk = (remain > 4096 ? 4096 : remain);
      uchar slice[];
      ArrayResize(slice, chunk);
      ArrayCopy(slice, data, 0, sent, chunk);

      const int n = SocketSend(m_socket, slice, (uint)chunk);
      if(n <= 0)
         return false;
      sent += n;
     }
   return true;
  }

bool CEasyCandleWs::SendFrame(const uchar opcode, const uchar &payload[], const int payload_len)
  {
   if(payload_len < 0)
      return false;

   uchar mask[4];
   mask[0] = RandByte();
   mask[1] = RandByte();
   mask[2] = RandByte();
   mask[3] = RandByte();

   int hdr = 2;
   if(payload_len >= 126 && payload_len <= 65535)
      hdr = 4;
   else if(payload_len > 65535)
      hdr = 10;

   const int total = hdr + 4 + payload_len;
   uchar frame[];
   ArrayResize(frame, total);

   frame[0] = (uchar)(0x80 | (opcode & 0x0F));

   if(payload_len < 126)
     {
      frame[1] = (uchar)(0x80 | payload_len);
     }
   else if(payload_len <= 65535)
     {
      frame[1] = (uchar)(0x80 | 126);
      frame[2] = (uchar)((payload_len >> 8) & 0xFF);
      frame[3] = (uchar)(payload_len & 0xFF);
     }
   else
     {
      frame[1] = (uchar)(0x80 | 127);
      const ulong ulen = (ulong)payload_len;
      for(int i = 0; i < 8; i++)
         frame[2 + i] = (uchar)((ulen >> (8 * (7 - i))) & 0xFF);
     }

   const int mask_at = hdr;
   frame[mask_at + 0] = mask[0];
   frame[mask_at + 1] = mask[1];
   frame[mask_at + 2] = mask[2];
   frame[mask_at + 3] = mask[3];

   const int body_at = hdr + 4;
   for(int i = 0; i < payload_len; i++)
      frame[body_at + i] = (uchar)(payload[i] ^ mask[i & 3]);

   return SendBytes(frame, total);
  }

bool CEasyCandleWs::ReadHttpHeaders(string &headers, const uint timeout_ms)
  {
   headers = "";
   uchar buf[];
   ArrayResize(buf, 1024);
   const uint start = GetTickCount();

   while((GetTickCount() - start) < timeout_ms)
     {
      if(m_socket == INVALID_HANDLE || !SocketIsConnected(m_socket))
         return false;

      const uint avail = SocketIsReadable(m_socket);
      if(avail == 0)
        {
         Sleep(10);
         continue;
        }

      int want = (int)avail;
      if(want > 1024)
         want = 1024;
      const int n = SocketRead(m_socket, buf, (uint)want, 50);
      if(n <= 0)
        {
         Sleep(10);
         continue;
        }

      headers += CharArrayToString(buf, 0, n, CP_UTF8);
      if(StringFind(headers, "\r\n\r\n") >= 0)
         return true;
      if(StringLen(headers) > 16384)
         return false;
     }
   return false;
  }

bool CEasyCandleWs::Handshake(const string host, const uint port)
  {
   const string key = RandomKey();
   if(StringLen(key) < 16)
      return false;

   const string req =
      "GET / HTTP/1.1\r\n" +
      "Host: " + host + ":" + IntegerToString((int)port) + "\r\n" +
      "Upgrade: websocket\r\n" +
      "Connection: Upgrade\r\n" +
      "Sec-WebSocket-Version: 13\r\n" +
      "Sec-WebSocket-Key: " + key + "\r\n" +
      "\r\n";

   uchar raw[];
   const int n = StringToCharArray(req, raw, 0, WHOLE_ARRAY, CP_UTF8);
   if(n <= 0)
      return false;
   int bytes = n;
   if(raw[bytes - 1] == 0)
     {
      bytes--;
      ArrayResize(raw, bytes);
     }
   if(!SendBytes(raw, bytes))
      return false;

   string headers = "";
   if(!ReadHttpHeaders(headers, 3000))
      return false;

   const int end = StringFind(headers, "\r\n\r\n");
   if(end < 0)
      return false;

   const string status = StringSubstr(headers, 0, end);
   if(StringFind(status, " 101") < 0)
      return false;

   const string leftover = StringSubstr(headers, end + 4);
   m_rx_len = 0;
   ArrayResize(m_rx, 0);
   if(StringLen(leftover) > 0)
     {
      uchar extra[];
      int extra_n = StringToCharArray(leftover, extra, 0, WHOLE_ARRAY, CP_UTF8);
      if(extra_n > 0 && extra[extra_n - 1] == 0)
        {
         extra_n--;
         ArrayResize(extra, extra_n);
        }
      if(extra_n > 0)
         AppendRx(extra, extra_n);
     }
   return true;
  }

bool CEasyCandleWs::Connect(const string host, const uint port, const uint timeout_ms)
  {
   Close();

   m_socket = SocketCreate();
   if(m_socket == INVALID_HANDLE)
     {
      Print("EasyCandle: SocketCreate failed, error ", GetLastError());
      return false;
     }

   SocketTimeouts(m_socket, 2000, 2000);

   if(!SocketConnect(m_socket, host, port, timeout_ms))
     {
      Print("EasyCandle: SocketConnect ", host, ":", port, " failed, error ", GetLastError(),
            ". Allow 127.0.0.1 in Tools -> Options -> Expert Advisors -> WebRequest.");
      SocketClose(m_socket);
      m_socket = INVALID_HANDLE;
      return false;
     }

   if(!Handshake(host, port))
     {
      Print("EasyCandle: WebSocket handshake failed, error ", GetLastError());
      SocketClose(m_socket);
      m_socket = INVALID_HANDLE;
      return false;
     }

   m_open = true;
   if(m_rx_len > 0)
      ProcessRx();
   return IsOpen();
  }

bool CEasyCandleWs::SendText(const string payload)
  {
   if(!IsOpen())
      return false;

   uchar raw[];
   int n = StringToCharArray(payload, raw, 0, WHOLE_ARRAY, CP_UTF8);
   if(n <= 0)
      return false;
   if(raw[n - 1] == 0)
     {
      n--;
      ArrayResize(raw, n);
     }

   if(!SendFrame(0x01, raw, n))
     {
      Print("EasyCandle: WebSocket send failed, error ", GetLastError());
      Close();
      return false;
     }
   return true;
  }

void CEasyCandleWs::AppendRx(const uchar &data[], const int count)
  {
   if(count <= 0)
      return;
   const int next = m_rx_len + count;
   if(ArraySize(m_rx) < next)
      ArrayResize(m_rx, next);
   ArrayCopy(m_rx, data, m_rx_len, 0, count);
   m_rx_len = next;
  }

void CEasyCandleWs::ConsumeRx(const int count)
  {
   if(count <= 0)
      return;
   if(count >= m_rx_len)
     {
      m_rx_len = 0;
      ArrayResize(m_rx, 0);
      return;
     }
   uchar rest[];
   const int remain = m_rx_len - count;
   ArrayResize(rest, remain);
   ArrayCopy(rest, m_rx, 0, count, remain);
   ArrayResize(m_rx, remain);
   ArrayCopy(m_rx, rest);
   m_rx_len = remain;
  }

bool CEasyCandleWs::ProcessRx(void)
  {
   while(m_rx_len >= 2)
     {
      const int opcode = m_rx[0] & 0x0F;
      const bool masked = ((m_rx[1] & 0x80) != 0);
      int len = (m_rx[1] & 0x7F);
      int hdr = 2;

      if(len == 126)
        {
         if(m_rx_len < 4)
            return true;
         len = ((int)m_rx[2] << 8) | (int)m_rx[3];
         hdr = 4;
        }
      else if(len == 127)
        {
         if(m_rx_len < 10)
            return true;
         ulong big = 0;
         for(int i = 0; i < 8; i++)
            big = (big << 8) | (ulong)m_rx[2 + i];
         if(big > 1024 * 1024)
           {
            Print("EasyCandle: incoming WebSocket frame too large");
            Close();
            return false;
           }
         len = (int)big;
         hdr = 10;
        }

      const int mask_len = (masked ? 4 : 0);
      const int need = hdr + mask_len + len;
      if(m_rx_len < need)
         return true;

      uchar payload[];
      ArrayResize(payload, len);
      if(masked)
        {
         uchar mask[4];
         mask[0] = m_rx[hdr + 0];
         mask[1] = m_rx[hdr + 1];
         mask[2] = m_rx[hdr + 2];
         mask[3] = m_rx[hdr + 3];
         for(int i = 0; i < len; i++)
            payload[i] = (uchar)(m_rx[hdr + 4 + i] ^ mask[i & 3]);
        }
      else if(len > 0)
        {
         ArrayCopy(payload, m_rx, 0, hdr, len);
        }

      ConsumeRx(need);

      if(opcode == 0x08)
        {
         Print("EasyCandle: server closed the WebSocket");
         Close();
         return false;
        }
      if(opcode == 0x09)
        {
         if(!SendFrame(0x0A, payload, len))
           {
            Close();
            return false;
           }
        }
      // Ignore text/binary/pong. Easy Candle never sends JSON to the EA.
     }
   return true;
  }

void CEasyCandleWs::Poll(void)
  {
   if(!IsOpen())
      return;

   const uint avail = SocketIsReadable(m_socket);
   if(avail == 0)
     {
      if(m_rx_len > 0)
         ProcessRx();
      return;
     }

   int want = (int)avail;
   if(want > 4096)
      want = 4096;
   uchar buf[];
   ArrayResize(buf, want);
   const int n = SocketRead(m_socket, buf, (uint)want, 1);
   if(n < 0)
     {
      Print("EasyCandle: socket read failed, error ", GetLastError());
      Close();
      return;
     }
   if(n > 0)
      AppendRx(buf, n);
   ProcessRx();
  }

void CEasyCandleWs::Close(void)
  {
   if(m_open && m_socket != INVALID_HANDLE && SocketIsConnected(m_socket))
     {
      uchar empty[];
      ArrayResize(empty, 0);
      SendFrame(0x08, empty, 0);
     }

   if(m_socket != INVALID_HANDLE)
     {
      SocketClose(m_socket);
      m_socket = INVALID_HANDLE;
     }

   m_open = false;
   m_rx_len = 0;
   ArrayResize(m_rx, 0);
  }

#endif
