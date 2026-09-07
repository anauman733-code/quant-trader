# XAUUSD Hyper-Scalper V1

Demo-first MetaTrader 5 Expert Advisor for rapid XAUUSD scalping using synthetic 10-second bars, multi-timeframe confirmation, strict risk controls, and a future ONNX AI filter hook.

## Goals

- Evaluate XAUUSD every 10 seconds using synthetic mid-price bars.
- Trade only when short-term momentum aligns with M1/M5 trend filters.
- Keep execution in native MQL5 for low latency.
- Use percentage-based risk sizing instead of martingale/grid lot escalation.
- Enforce spread, session, daily-loss, consecutive-loss and cooldown controls.
- Keep AI optional in V1; later add an ONNX classifier as a trade filter rather than allowing AI to override safety rules.

## Default safety profile

- Demo mode guard: enabled by default.
- Risk per trade: 0.10% of equity.
- Max open positions for this EA/symbol: 1.
- Daily loss stop: 2.0% of day-start equity.
- Consecutive-loss stop: 5 losses.
- Max trades per hour: 15.
- Cooldown after exit: 20 seconds.
- Spread filter: enabled.
- Hard ATR-derived stop loss and take profit on every entry.
- No martingale, no grid, no averaging down.

## V1 signal model

1. Build 10-second synthetic OHLC bars from live bid/ask midpoint ticks.
2. Calculate fast/medium/slow EMAs on those synthetic bars.
3. Require M1 EMA trend alignment.
4. Optionally require M5 EMA trend alignment.
5. Require minimum short-term momentum and acceptable volatility/spread.
6. Enter on a fresh 10-second momentum continuation/reversal trigger.
7. Exit via hard SL/TP, opposite micro-trend signal, or optional time stop.

## Files

- `XAU_HyperScalper_V1.mq5` — Expert Advisor source.
- `PRESET_DEMO_SAFE.set` — conservative demo-testing defaults.
- `TEST_PLAN.md` — validation procedure before changing risk or enabling live trading.

## Installation

1. Open MT5 and press **F4** to open MetaEditor.
2. Copy `XAU_HyperScalper_V1.mq5` into `MQL5/Experts/`.
3. Compile it with **F7**.
4. Attach it to your broker's XAUUSD M1 chart.
5. Keep `InpDemoOnly=true` for initial testing.
6. Load `PRESET_DEMO_SAFE.set` or use the built-in defaults.

## Important

Trade frequency is a ceiling, not a target. The EA is allowed to take zero trades when spread, volatility, trend or risk conditions are poor. High turnover magnifies spread, slippage and execution quality, so broker-specific demo forward testing is mandatory before any live deployment.
