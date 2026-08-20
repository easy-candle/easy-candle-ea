#property copyright "Easy Candle"
#property version   "1.00"
#property description "Streams M1 OHLC to Easy Candle (ws://127.0.0.1:17321)."

#include "EasyCandleProtocol.mqh"
#include "EasyCandleWs.mqh"

#define EASY_CANDLE_HISTORY_MIN     15000
#define EASY_CANDLE_HISTORY_MAX     500000
#define EASY_CANDLE_HISTORY_DEFAULT 100000
#define EASY_CANDLE_CHUNK_MIN       2000
#define EASY_CANDLE_CHUNK_MAX       5000

input string InpHost        = "127.0.0.1";
input int    InpPort        = 17321;
input int    InpHistoryBars = EASY_CANDLE_HISTORY_DEFAULT; // M1 candles to send (15000–500000)
input int    InpPingSec     = 15;
input int    InpReconnectMs = 2000;

CEasyCandleWs g_ws;
bool          g_m1_ok = false;
bool          g_live = false;
string        g_symbol = "";
int           g_digits = 5;
int           g_history_bars = EASY_CANDLE_HISTORY_DEFAULT;
int           g_chunk_bars = EASY_CANDLE_CHUNK_MIN;
int           g_ping_sec = 15;
int           g_reconnect_ms = 2000;
uint          g_last_connect_try = 0;
uint          g_last_ping_ms = 0;
uint          g_last_bar_ms = 0;
long          g_last_bar_t = 0;

void EasyCandleTryLiveBar(void);

int EasyCandleClampHistoryBars(const int requested)
  {
   if(requested < EASY_CANDLE_HISTORY_MIN)
      return EASY_CANDLE_HISTORY_MIN;
   if(requested > EASY_CANDLE_HISTORY_MAX)
      return EASY_CANDLE_HISTORY_MAX;
   return requested;
  }

// ~10 chunks per dump, bounded so each JSON frame stays modest (and under
// Easy Candle's 20,000-bar per-message cap).
int EasyCandleChunkBarsFor(const int history_bars)
  {
   int chunk = history_bars / 10;
   if(chunk < EASY_CANDLE_CHUNK_MIN)
      chunk = EASY_CANDLE_CHUNK_MIN;
   if(chunk > EASY_CANDLE_CHUNK_MAX)
      chunk = EASY_CANDLE_CHUNK_MAX;
   return chunk;
  }

long EasyCandleUtcAdjust(void)
  {
   // CopyRates datetime is broker/server time. Easy Candle stores UTC unix seconds.
   return ((long)TimeTradeServer() - (long)TimeGMT());
  }

long EasyCandleUtcSeconds(const datetime server_time)
  {
   return (long)server_time - EasyCandleUtcAdjust();
  }

string EasyCandleSymbol(void)
  {
   string s = _Symbol;
   StringToUpper(s);
   return s;
  }

void EasyCandleStatus(const string text)
  {
   Comment("Easy Candle: ", text);
  }

bool EasyCandleSend(const string json)
  {
   if(!g_ws.SendText(json))
     {
      g_live = false;
      EasyCandleStatus("disconnected, retrying");
      return false;
     }
   return true;
  }

bool EasyCandleIsForming(const MqlRates &bar)
  {
   return (TimeCurrent() < bar.time + PeriodSeconds(PERIOD_M1));
  }

bool EasyCandleSendHistory(void)
  {
   const int want = g_history_bars;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   ResetLastError();
   const int copied = CopyRates(_Symbol, PERIOD_M1, 0, want, rates);
   if(copied <= 0)
     {
      Print("EasyCandle: CopyRates failed, error ", GetLastError());
      return false;
     }

   int newest = 0;
   if(EasyCandleIsForming(rates[0]))
      newest = 1;

   if(newest >= copied)
     {
      Print("EasyCandle: no closed M1 bars to send yet");
      return true;
     }

   const int oldest = copied - 1;
   const long adjust = EasyCandleUtcAdjust();
   int sent = 0;
   int chunks = 0;

   for(int from = oldest; from >= newest; )
     {
      int count = g_chunk_bars;
      if(count < 1)
         count = 1;
      if(count > from - newest + 1)
         count = from - newest + 1;

      const int to = from - count + 1;
      const string json = EasyCandleJsonHistory(g_symbol, rates, from, to, adjust, g_digits);
      if(!EasyCandleSend(json))
         return false;

      sent += count;
      chunks++;
      from = to - 1;
      g_ws.Poll();
      if(!g_ws.IsOpen())
         return false;
     }

   Print("EasyCandle: history sent ", sent, " bars in ", chunks,
         " chunk(s), server GMT offset ", adjust, "s");
   return true;
  }

bool EasyCandleHandshakeSession(void)
  {
   g_live = false;
   g_last_bar_t = 0;

   if(!EasyCandleSend(EasyCandleJsonHello(g_symbol)))
      return false;
   Print("EasyCandle: hello sent ", g_symbol, " M1");

   if(!EasyCandleSendHistory())
      return false;

   g_live = true;
   g_last_ping_ms = GetTickCount();
   EasyCandleTryLiveBar();
   EasyCandleStatus("connected - " + g_symbol);
   return true;
  }

void EasyCandleTryConnect(void)
  {
   if(g_ws.IsOpen())
      return;
   if(!g_m1_ok)
      return;

   const uint now = GetTickCount();
   if(g_last_connect_try != 0 && (int)(now - g_last_connect_try) < g_reconnect_ms)
      return;
   g_last_connect_try = now;
   g_live = false;

   int port_i = InpPort;
   if(port_i <= 0 || port_i > 65535)
      port_i = 17321;
   const uint port = (uint)port_i;

   EasyCandleStatus("connecting " + InpHost + ":" + IntegerToString((int)port));
   Print("EasyCandle: connecting ", InpHost, ":", port);

   if(!g_ws.Connect(InpHost, port, 2000))
     {
      EasyCandleStatus("connect failed, retrying");
      return;
     }

   Print("EasyCandle: connected");
   if(!EasyCandleHandshakeSession())
     {
      g_ws.Close();
      EasyCandleStatus("handshake failed, retrying");
     }
  }

void EasyCandleTryPing(void)
  {
   if(!g_ws.IsOpen() || !g_live)
      return;
   if(g_ping_sec <= 0)
      return;

   const uint now = GetTickCount();
   if((int)(now - g_last_ping_ms) < g_ping_sec * 1000)
      return;

   if(EasyCandleSend(EasyCandleJsonPing()))
      g_last_ping_ms = now;
  }

void EasyCandleTryLiveBar(void)
  {
   if(!g_m1_ok || !g_ws.IsOpen() || !g_live)
      return;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M1, 0, 1, rates) < 1)
      return;

   const long t = EasyCandleUtcSeconds(rates[0].time);
   if(g_last_bar_t != 0 && t < g_last_bar_t)
      return;

   const uint now = GetTickCount();
   const bool new_minute = (t != g_last_bar_t);
   if(!new_minute && (int)(now - g_last_bar_ms) < 250)
      return;

   const string json = EasyCandleJsonBar(g_symbol,
                                         t,
                                         rates[0].open,
                                         rates[0].high,
                                         rates[0].low,
                                         rates[0].close,
                                         (long)rates[0].tick_volume,
                                         g_digits);
   if(!EasyCandleSend(json))
      return;

   g_last_bar_t = t;
   g_last_bar_ms = now;
  }

int OnInit()
  {
   MathSrand((int)GetTickCount());

   g_history_bars = EasyCandleClampHistoryBars(InpHistoryBars);
   if(g_history_bars != InpHistoryBars)
      Print("EasyCandle: InpHistoryBars ", InpHistoryBars,
            " clamped to ", g_history_bars,
            " (min ", EASY_CANDLE_HISTORY_MIN,
            ", max ", EASY_CANDLE_HISTORY_MAX, ")");

   g_chunk_bars = EasyCandleChunkBarsFor(g_history_bars);
   Print("EasyCandle: will request ", g_history_bars,
         " M1 bars in chunks of ", g_chunk_bars);

   g_ping_sec = InpPingSec;
   if(g_ping_sec < 1)
      g_ping_sec = 1;

   g_reconnect_ms = InpReconnectMs;
   if(g_reconnect_ms < 200)
      g_reconnect_ms = 200;

   g_symbol = EasyCandleSymbol();
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(g_digits <= 0)
      g_digits = _Digits;

   g_live = false;
   g_last_bar_t = 0;
   g_last_connect_try = 0;

   if(Period() != PERIOD_M1)
     {
      g_m1_ok = false;
      EasyCandleStatus("Attach on M1");
      Print("EasyCandle: Attach on M1 (chart period is not PERIOD_M1)");
      return INIT_FAILED;
     }

   g_m1_ok = true;
   Print("EasyCandle: attached on ", g_symbol, " M1 - one chart at a time");

   if(!EventSetMillisecondTimer(200))
     {
      EventSetTimer(1);
      Print("EasyCandle: millisecond timer unavailable, using 1s timer");
     }

   EasyCandleTryConnect();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   g_live = false;
   g_ws.Close();
   if(!g_m1_ok)
      EasyCandleStatus("Attach on M1");
   else
      Comment("");
   Print("EasyCandle: stopped, reason ", reason);
  }

void OnTimer()
  {
   if(!g_m1_ok)
      return;

   if(!g_ws.IsOpen())
     {
      g_live = false;
      EasyCandleTryConnect();
      return;
     }

   g_ws.Poll();
   if(!g_ws.IsOpen())
     {
      g_live = false;
      EasyCandleStatus("disconnected, retrying");
      return;
     }

   EasyCandleTryPing();
   EasyCandleTryLiveBar();
  }

void OnTick()
  {
   if(!g_m1_ok)
      return;

   if(!g_ws.IsOpen())
     {
      g_live = false;
      EasyCandleTryConnect();
      return;
     }

   g_ws.Poll();
   EasyCandleTryLiveBar();
  }
