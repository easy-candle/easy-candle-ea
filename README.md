# Easy Candle Expert Advisor — technical spec

Build an MT5 Expert Advisor that streams **M1 OHLC** from the attached chart into Easy Candle over a local WebSocket.

Easy Candle is the **server**. The EA is the **client**. Nothing is saved in Easy Candle until the user confirms **Import from MetaTrader**.

Target: **MetaTrader 5** (MQL5). MT4 is possible with a socket DLL, but MQL5 sockets are enough.

---

## 1. What Easy Candle expects

| Item | Value |
|---|---|
| URL | `ws://127.0.0.1:17321` |
| Host | `127.0.0.1` only (non-loopback connections are dropped) |
| Port | `17321` |
| Direction | EA → Easy Candle only (no replies) |
| Clients | **One** socket. A new connect kicks the previous one |
| Encoding | UTF-8 JSON, **one JSON object per WebSocket text frame** |
| Protocol version | `"v": 1` on every message (number, not string) |
| Timeframe | **M1 only** for `history` and `bar` |
| Time | Unix **seconds** UTC (or ms; values `> 1e12` are treated as ms) |
| Symbol | `A–Z`, `0–9`, `.`, `_`, max 32 chars, case-insensitive (stored uppercased) |
| History cap | Easy Candle keeps merged bars; each `history` frame is parsed with a **20,000**-bar per-message cap |
| Import minimum | User cannot confirm import with fewer than **14,400** M1 bars (~10 days of continuous minutes) |

MQL5 has TCP sockets (`SocketCreate` / `SocketConnect`), **not** a WebSocket API. Implement the WebSocket handshake yourself (or use a small helper). Send **text frames**, not binary.

---

## 2. New project (MetaEditor)

1. Open **MetaEditor** from MT5.
2. **File → New → Expert Advisor (template)**.
3. Name: `EasyCandleBridge` (or similar).
4. Create in `MQL5/Experts/EasyCandle/`.
5. Suggested files:
   - `EasyCandleBridge.mq5` — lifecycle, chart attach, reconnect
   - `EasyCandleWs.mqh` — TCP + WebSocket handshake/send
   - `EasyCandleProtocol.mqh` — JSON builders for `hello` / `history` / `bar` / `ping`

**Inputs**

```
InpHost        = "127.0.0.1"
InpPort        = 17321
InpHistoryBars = 100000    // M1 bars to request (clamped 15,000–500,000)
InpPingSec     = 15
InpReconnectMs = 2000
```

Chunk size is **not** an input. The EA splits the dump into about 10 chunks, each clamped to **2,000–5,000** bars so JSON frames stay under Easy Candle’s 20,000-bar per-message cap.

**Attach rules**

- Attach on the symbol the user wants to import.
- Chart period **must be M1** (`PERIOD_M1`). If not, log an error and do not send `history`/`bar`.
- Allow WebRequest/sockets: MT5 **Tools → Options → Expert Advisors** → enable sockets / automated trading as required by the build.
- Easy Candle must be **running** first (it listens on app start).

---

## 3. Connection lifecycle

```
OnInit
  → if Period() != PERIOD_M1 → fail with comment "Attach on M1"
  → start connect timer

Connect
  → TCP connect 127.0.0.1:17321
  → WebSocket handshake:
        GET / HTTP/1.1
        Host: 127.0.0.1:17321
        Upgrade: websocket
        Connection: Upgrade
        Sec-WebSocket-Version: 13
        Sec-WebSocket-Key: <random 16 bytes, base64>
  → expect HTTP 101
  → send hello
  → send history (chunked)
  → go live

OnTimer / OnTick
  → if disconnected → reconnect with backoff
  → ping every InpPingSec
  → on new/updated M1 bar → send bar

OnDeinit
  → close socket
```

Reconnect must repeat **hello + full history dump**, then resume live `bar`s. Easy Candle resets identity on each new socket.

Do not wait for any message from Easy Candle. It never sends JSON back to the EA.

---

## 4. Message protocol

Every payload is **one JSON object**. No JSON Lines batches, no pretty-print across frames.

Required on all messages:

```json
{ "v": 1, "type": "..." }
```

`v` must be the number `1`. Missing/wrong `v` → Easy Candle error: `Unsupported protocol version (expected 1)`.

### 4.1 `hello` — send once after handshake

```json
{
  "v": 1,
  "type": "hello",
  "symbol": "EURUSD",
  "tf": "M1",
  "token": ""
}
```

| Field | Required | Notes |
|---|---|---|
| `symbol` | yes | `Symbol()` of the attached chart |
| `tf` | yes | `"M1"` or `"1m"` |
| `token` | no | optional string; ignored for now |

### 4.2 `history` — snapshot dump

```json
{
  "v": 1,
  "type": "history",
  "symbol": "EURUSD",
  "tf": "M1",
  "bars": [
    { "t": 1786953600, "o": 1.17010, "h": 1.17040, "l": 1.16990, "c": 1.17020, "vol": 120 }
  ]
}
```

| Field | Required | Notes |
|---|---|---|
| `bars` or `candles` | yes | array of bar objects |
| bar `t` / `time` | yes | open time, Unix seconds UTC |
| bar `o` / `open` | yes | |
| `h` / `high` | yes | |
| `l` / `low` | yes | |
| `c` / `close` | yes | |
| `vol` / `volume` | no | tick volume is fine |

**How to fill it (MQL5)**

1. `CopyRates(_Symbol, PERIOD_M1, 0, InpHistoryBars, rates)`
2. Skip index `0` if that bar is still forming (send it later via `bar`).
3. Convert `rates[i].time` from broker/server time to **UTC unix seconds**.
4. Sort oldest → newest.
5. Split into chunks of 2,000–5,000 bars (`history / 10`, then clamped). Each chunk is its **own** `history` message. Easy Candle **merges by open time**.
6. Prefer sending **oldest chunks first**.

Target **at least 14,400 closed M1 bars** so the user can confirm import. If the broker has fewer, send what exists; Easy Candle preview will show them, confirm will refuse until the minimum is met.

**Do not** include pretty-printed newlines as separate frames. Build one string, send one WS text frame.

### 4.3 `bar` — live updates

```json
{
  "v": 1,
  "type": "bar",
  "symbol": "EURUSD",
  "tf": "M1",
  "t": 1786954200,
  "o": 1.17030,
  "h": 1.17050,
  "l": 1.17010,
  "c": 1.17040,
  "vol": 77
}
```

OHLC may sit on the **root object** (as above). Same aliases as history bars.

Send:

- On each tick: the **current forming** M1 bar (same `t` replaces the last bar in Easy Candle).
- When a new minute starts: one `bar` with the new open time (appended).

Ignore / do not send bars older than the last sent open time.

Throttle if needed (e.g. max 2–4 updates per second). History already covered the past.

### 4.4 `ping` — keepalive

```json
{ "v": 1, "type": "ping" }
```

Easy Candle ignores the body. Use it so NAT/idle sockets stay up.

---

## 5. Time conversion (critical)

Easy Candle treats `t` as **UTC**.

Broker `datetime` from `CopyRates` is usually **trade server time**, not UTC.

```
utc_seconds = (long)rates[i].time - TimeGMTOffset()
```

Verify with a known bar: Easy Candle preview **Last bar** must match the MT Data Window time when displayed in UTC.

If offset is wrong, the whole series shifts by hours and import/replay times will be wrong.

---

## 6. WebSocket send rules

- Opcode **text** (1).
- Client frames **must be masked** (RFC 6455).
- One JSON object = one frame.
- Close the TCP socket cleanly on deinit.
- If send fails, mark disconnected and reconnect.

Suggested handshake path: `GET / HTTP/1.1` (Easy Candle does not inspect the path, but a valid WS handshake is required).

---

## 7. Chart / product behavior (so the EA matches the UI)

1. User starts **Easy Candle** → listener is already on `127.0.0.1:17321`.
2. User attaches EA on **EURUSD M1**.
3. EA connects → dialog shows **EA connected · EURUSD**.
4. EA sends history → dialog shows **Preview EURUSD · not saved yet** (count + from/to).
5. User clicks **Import from MetaTrader → Confirm & load**.
6. After that, further `bar` / `history` messages **update the saved dataset**.
7. Until confirm, nothing is written to disk.

Scrolling the MT chart **does not** send extra history unless the EA does. If you want “scroll left = more past bars”, detect when `CopyRates` can see older bars than last dump and send another `history` chunk of **only the new older bars**. Easy Candle merges them.

One EA instance = one symbol. To import another symbol, attach another chart/EA (Easy Candle keeps one live socket; last client wins). For v1, document: **one attached chart at a time**.

---

## 8. Implementation checklist

- [ ] TCP connect to `127.0.0.1:17321`
- [ ] WebSocket handshake + masked text frames
- [ ] Refuse to run unless `Period() == PERIOD_M1`
- [ ] `hello` immediately after connect
- [ ] `CopyRates` M1, UTC open times, skip forming bar
- [ ] Chunked `history` (2,000–5,000 bars/message; 15,000–500,000 total, default 100,000)
- [ ] Aim for ≥ 14,400 bars when the broker has them
- [ ] Live `bar` on forming candle + new minute
- [ ] `ping` on a timer
- [ ] Reconnect: hello + history + live
- [ ] Log errors to Experts journal (`Print` / `Comment`)
- [ ] No pretty-printed JSON split across frames

---

## 9. Manual test (before attaching to a live chart)

With Easy Candle running:

1. Attach EA on **EURUSD, M1**.
2. Journal: connected, hello sent, N history bars sent.
3. Easy Candle **Import data** dialog: preview symbol, count, from → last bar.
4. Send ticks: **Last bar** time/count updates.
5. **Import from MetaTrader** → confirm (only if count ≥ 14,400).
6. Chart loads imported EURUSD. Further ticks keep updating that dataset.
7. Remove EA: dialog/status shows disconnected; saved import remains.

---

## 10. Minimal JSON examples

Hello:

```json
{"v":1,"type":"hello","symbol":"EURUSD","tf":"M1"}
```

History chunk (single line when sending):

```json
{"v":1,"type":"history","symbol":"EURUSD","tf":"M1","bars":[{"t":1786953600,"o":1.17,"h":1.171,"l":1.169,"c":1.1705,"vol":100}]}
```

Live bar:

```json
{"v":1,"type":"bar","symbol":"EURUSD","tf":"M1","t":1786953660,"o":1.1705,"h":1.171,"l":1.17,"c":1.1708,"vol":40}
```

Ping:

```json
{"v":1,"type":"ping"}
```
