# Python XAU Multi-Regime V2 + 60s Forecast

Retail-MT5 high-frequency research engine for `XAUUSD.a`.

## What it does
- Scores every new tick.
- Base modes: MOMENTUM, PULLBACK, MEAN_REVERSION.
- Adds a 3-class machine-learning forecast for the next 60 seconds: BUY / FLAT / SELL.
- Momentum requires the 60s model to agree before trading.
- Pullback and mean-reversion use their own model thresholds.
- A very strong model forecast can also create a FORECAST_ONLY trade.
- One position max, 0.01 lot, demo-only execution guard.

This is high-frequency in a retail MT5/Python sense: the engine evaluates every tick and can generate many opportunities per minute. It is not colocated exchange microsecond HFT. Actual trade frequency is intentionally filtered by model confidence, one-position limit, spread, cooldown and hourly caps.

## First-time workflow
1. Keep IC Markets MT5 open and logged into DEMO.
2. Download all files in this folder together.
3. Double-click `TRAIN_60S_MODEL.bat`.
4. Wait for `MODEL SAVED:`. This creates `xau_60s_forecast.joblib` in the same folder.
5. Double-click `START_DRY_RUN_FORECAST.bat` and inspect `DRY APPROVED` / `REJECT` messages.
6. Only after the dry run looks sensible, use `START_DEMO_FORECAST.bat`.

## Training defaults
- 14 days of MT5 historical ticks
- 1-second sampling, automatically widened if needed to cap the dataset
- 60-second forecast horizon
- 20-point minimum executable movement for BUY/SELL labels
- chronological 70% train / 15% validation / 15% holdout
- HistGradientBoostingClassifier

## Live thresholds
- Momentum: direction probability >= 0.58 and >= 0.08 above opposite side
- Pullback: >= 0.55 and >= 0.05 margin
- Mean reversion: >= 0.50 and >= 0.03 margin
- Forecast-only: >= 0.78 with >= 0.15 directional margin

No profitability claim. Demo/research only until forward results demonstrate positive expectancy after spread, commission and slippage.
