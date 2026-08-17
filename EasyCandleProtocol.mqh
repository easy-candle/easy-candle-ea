#ifndef EASY_CANDLE_PROTOCOL_MQH
#define EASY_CANDLE_PROTOCOL_MQH

// JSON builders for Easy Candle v=1. Each helper returns one object on a single line.

string EasyCandleJsonEscape(const string value)
  {
   const int n = StringLen(value);
   string out = "";
   StringReserve(out, n + 8);

   for(int i = 0; i < n; i++)
     {
      const ushort c = StringGetCharacter(value, i);
      if(c == '"')
         out += "\\\"";
      else if(c == '\\')
         out += "\\\\";
      else if(c == '\b')
         out += "\\b";
      else if(c == '\f')
         out += "\\f";
      else if(c == '\n')
         out += "\\n";
      else if(c == '\r')
         out += "\\r";
      else if(c == '\t')
         out += "\\t";
      else if(c < 32)
         out += StringFormat("\\u%04x", c);
      else
         out += ShortToString(c);
     }

   return out;
  }

string EasyCandleJsonPrice(const double price, const int digits)
  {
   int d = digits;
   if(d < 0)
      d = 0;
   if(d > 8)
      d = 8;
   return DoubleToString(price, d);
  }

string EasyCandleJsonBarObject(const long t, const double o, const double h,
                               const double l, const double c, const long vol,
                               const int digits)
  {
   return "{\"t\":" + IntegerToString(t) +
          ",\"o\":" + EasyCandleJsonPrice(o, digits) +
          ",\"h\":" + EasyCandleJsonPrice(h, digits) +
          ",\"l\":" + EasyCandleJsonPrice(l, digits) +
          ",\"c\":" + EasyCandleJsonPrice(c, digits) +
          ",\"vol\":" + IntegerToString(vol) + "}";
  }

string EasyCandleJsonHello(const string symbol)
  {
   return "{\"v\":1,\"type\":\"hello\",\"symbol\":\"" + EasyCandleJsonEscape(symbol) +
          "\",\"tf\":\"M1\",\"token\":\"\"}";
  }

string EasyCandleJsonPing(void)
  {
   return "{\"v\":1,\"type\":\"ping\"}";
  }

string EasyCandleJsonBar(const string symbol, const long t, const double o,
                         const double h, const double l, const double c,
                         const long vol, const int digits)
  {
   return "{\"v\":1,\"type\":\"bar\",\"symbol\":\"" + EasyCandleJsonEscape(symbol) +
          "\",\"tf\":\"M1\",\"t\":" + IntegerToString(t) +
          ",\"o\":" + EasyCandleJsonPrice(o, digits) +
          ",\"h\":" + EasyCandleJsonPrice(h, digits) +
          ",\"l\":" + EasyCandleJsonPrice(l, digits) +
          ",\"c\":" + EasyCandleJsonPrice(c, digits) +
          ",\"vol\":" + IntegerToString(vol) + "}";
  }

// rates[] must be as-series (index 0 = newest). from_idx is the oldest index
// in the chunk, to_idx the newest (from_idx >= to_idx). time_adjust is subtracted
// from each bar open time to produce UTC unix seconds.
string EasyCandleJsonHistory(const string symbol, const MqlRates &rates[],
                             const int from_idx, const int to_idx,
                             const long time_adjust, const int digits)
  {
   string json = "{\"v\":1,\"type\":\"history\",\"symbol\":\"" +
                 EasyCandleJsonEscape(symbol) + "\",\"tf\":\"M1\",\"bars\":[";

   const int count = from_idx - to_idx + 1;
   if(count > 0)
      StringReserve(json, 96 + count * 96);

   bool first = true;
   for(int i = from_idx; i >= to_idx; i--)
     {
      if(!first)
         json += ",";
      first = false;

      const long t = (long)rates[i].time - time_adjust;
      json += EasyCandleJsonBarObject(t,
                                      rates[i].open,
                                      rates[i].high,
                                      rates[i].low,
                                      rates[i].close,
                                      (long)rates[i].tick_volume,
                                      digits);
     }

   json += "]}";
   return json;
  }

#endif
