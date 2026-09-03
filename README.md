# Quant Trader

Browser-based quantitative trading research and paper-trading platform with Interactive Brokers market data.

## Current capabilities
- IBKR TWS / IB Gateway market-data connection
- Live Markets watchlist
- Strategy Bots and Forecast Lab
- ORB Bot
- Pair Trading Bot
- Oil / Intermarket Correlation Bot
- Multi-timeframe oil correlations: 5m, 15m, 30m, 1h, 4h, 1d
- Oil lead/lag tests: same bar, +5m, +15m, +30m, +60m
- Forecast performance tracking
- Paper signal routing and risk controls
- Live broker order execution remains locked

## Local development
The permanent local project folder is:

```text
C:\Users\Nauman\Desktop\quant
```

After the one-time Git setup, future updates use:

```powershell
cd C:\Users\Nauman\Desktop\quant
git pull
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
python -m uvicorn app.main:app --reload
```

Open http://127.0.0.1:8000 and keep TWS running for IBKR data.

## Safety
This project is currently analytics and paper-trading tooling. Real order execution is intentionally locked until broker execution, risk controls, and paper results are validated.
