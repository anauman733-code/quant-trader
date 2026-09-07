# XAU HyperScalper V2 — Micro Breakout Engine

V2 replaces the slower EMA/M1/M5 entry logic from V1 with a tick-driven, pending-stop micro-breakout engine inspired by the uploaded US30 execution video.

## Core behaviour

1. Read live bid/ask ticks.
2. Measure very short-term net movement, recent movement and directional tick consistency.
3. When micro-momentum is strong enough, place one BUY STOP or SELL STOP close to market.
4. If momentum disappears, cancel the pending order.
5. If price moves before fill, cancel/reprice the pending order.
6. If momentum flips, remove the old side and prepare the opposite side.
7. When filled, manage the position with:
   - hard broker-side stop loss,
   - programmatic profit target,
   - micro trailing giveback exit,
   - momentum reversal exit,
   - maximum holding-time exit.

## Important differences from V1

- no 10-second candle warm-up;
- no M5 trend confirmation;
- no M1 EMA confirmation;
- tick-based signal window is normally ready within seconds;
- pending stop entries instead of market orders;
- pending orders are actively cancelled/repriced;
- up to 60 filled trades per hour by default;
- one pending order / one live position at a time;
- no martingale, no grid, no averaging down.

## Demo safety defaults

- DemoOnly = true
- RiskPerTradePct = 0.10%
- MaxLots = 0.05
- DailyLossStopPct = 2.0%
- MaxConsecutiveLosses = 5
- MaxOpenPositions = 1
- HardStopPoints = 80
- MaxTradesPerHour = 60

The EA refuses to initialize on a non-demo account while `InpDemoOnly=true`. It also requires the attached symbol to report FULL ACCESS.

## Recommended first symbol

For the current IC Markets demo account, use the fully tradable gold symbol that showed Full Access in Specification, e.g. `XAUUSD.a`.

## Compile

1. Put `XAU_HyperScalper_V2.mq5` in `MQL5/Experts/`.
2. Open MetaEditor (F4).
3. Open the file and press F7.
4. Do not continue until compilation reports 0 errors.

## First backtest

Use MT5 Strategy Tester:

- Expert: XAU_HyperScalper_V2
- Symbol: XAUUSD.a
- Period: M1
- Model: **Every tick based on real ticks**
- Optimization: Off
- Load: `PRESET_DEMO_MICRO.set`
- Visual mode: Off initially

Start with 1 month to confirm behaviour and trade frequency, then 3 months.

## What to evaluate

Do not judge only by net profit. Capture:

- total trades;
- trades per trading hour;
- win rate;
- profit factor;
- expected payoff;
- max drawdown;
- average winner / loser;
- long vs short performance;
- average holding time;
- pending-order rejection rate;
- average spread during entries;
- commission and slippage sensitivity.

## Validation status

Prototype / research build. It has not yet been independently compiled in MetaEditor or validated on historical IC Markets real-tick data. Keep it on demo until compilation, backtest, walk-forward and forward-demo gates pass.
