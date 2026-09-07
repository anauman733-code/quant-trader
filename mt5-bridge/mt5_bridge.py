import os
import secrets
from datetime import datetime, timedelta, timezone

import MetaTrader5 as mt5
from fastapi import FastAPI, HTTPException, Query

app = FastAPI(title="MT5 Read-Only Bridge", version="1.0")

TOKEN_FILE = os.path.join(os.path.dirname(__file__), ".bridge_token")


def _load_token():
    token = os.getenv("MT5_BRIDGE_TOKEN", "").strip()
    if token:
        return token
    if os.path.exists(TOKEN_FILE):
        return open(TOKEN_FILE, "r", encoding="utf-8").read().strip()
    token = secrets.token_urlsafe(24)
    with open(TOKEN_FILE, "w", encoding="utf-8") as f:
        f.write(token)
    return token


BRIDGE_TOKEN = _load_token()


def auth(token: str):
    if not secrets.compare_digest(token or "", BRIDGE_TOKEN):
        raise HTTPException(status_code=401, detail="invalid token")


def ensure_mt5():
    if not mt5.initialize():
        raise HTTPException(status_code=503, detail=f"MT5 initialize failed: {mt5.last_error()}")


def objdict(x):
    return x._asdict() if x is not None and hasattr(x, "_asdict") else None


@app.get("/health")
def health(token: str = Query(...)):
    auth(token)
    ensure_mt5()
    terminal = mt5.terminal_info()
    return {
        "ok": True,
        "mt5_connected": terminal is not None,
        "server_time_utc": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/snapshot")
def snapshot(symbol: str = "XAUUSD.a", token: str = Query(...)):
    auth(token)
    ensure_mt5()

    info = mt5.symbol_info(symbol)
    tick = mt5.symbol_info_tick(symbol)
    account = mt5.account_info()
    terminal = mt5.terminal_info()

    if info is None:
        raise HTTPException(status_code=404, detail=f"symbol not found: {symbol}")

    positions = mt5.positions_get(symbol=symbol) or []
    orders = mt5.orders_get(symbol=symbol) or []

    rates = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_M1, 0, 100)
    bars = []
    if rates is not None:
        for r in rates[-100:]:
            bars.append({
                "time": datetime.fromtimestamp(int(r[0]), tz=timezone.utc).isoformat(),
                "open": float(r[1]), "high": float(r[2]), "low": float(r[3]), "close": float(r[4]),
                "tick_volume": int(r[5]), "spread": int(r[6]), "real_volume": int(r[7]),
            })

    now = datetime.now()
    start = now - timedelta(hours=24)
    mt5.history_deals_get(start, now)
    deals_raw = mt5.history_deals_get(start, now, group=f"*{symbol}*") or []
    deals = []
    for d in deals_raw[-200:]:
        deals.append({
            "ticket": int(d.ticket), "time": int(d.time), "type": int(d.type), "entry": int(d.entry),
            "volume": float(d.volume), "price": float(d.price), "profit": float(d.profit),
            "commission": float(d.commission), "swap": float(d.swap), "symbol": d.symbol,
            "comment": d.comment, "magic": int(d.magic),
        })

    tick_data = None
    if tick is not None:
        tick_data = {
            "time_msc": int(tick.time_msc), "bid": float(tick.bid), "ask": float(tick.ask),
            "last": float(tick.last), "volume": float(tick.volume),
            "spread_price": float(tick.ask - tick.bid),
            "spread_points": float((tick.ask - tick.bid) / info.point) if info.point else None,
        }

    account_data = None
    if account is not None:
        account_data = {
            "trade_mode": int(account.trade_mode), "leverage": int(account.leverage),
            "balance": float(account.balance), "equity": float(account.equity),
            "profit": float(account.profit), "margin": float(account.margin),
            "margin_free": float(account.margin_free), "margin_level": float(account.margin_level),
            "currency": account.currency,
        }

    return {
        "ok": True,
        "symbol": symbol,
        "tick": tick_data,
        "symbol_info": {
            "description": info.description, "digits": int(info.digits), "point": float(info.point),
            "trade_mode": int(info.trade_mode), "trade_stops_level": int(info.trade_stops_level),
            "volume_min": float(info.volume_min), "volume_max": float(info.volume_max),
            "volume_step": float(info.volume_step), "trade_tick_size": float(info.trade_tick_size),
            "trade_tick_value": float(info.trade_tick_value),
        },
        "account": account_data,
        "terminal": {
            "connected": bool(terminal.connected) if terminal else False,
            "trade_allowed": bool(terminal.trade_allowed) if terminal else False,
        },
        "positions": [objdict(p) for p in positions],
        "orders": [objdict(o) for o in orders],
        "m1_bars": bars,
        "deals_24h": deals,
    }


if __name__ == "__main__":
    import uvicorn
    print("\nMT5 READ-ONLY BRIDGE")
    print("TOKEN:", BRIDGE_TOKEN)
    print("Keep this window open. No trading/write endpoints exist.\n")
    uvicorn.run(app, host="127.0.0.1", port=8765, log_level="warning")
