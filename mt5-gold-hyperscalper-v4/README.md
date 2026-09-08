# XAU HyperScalper V4 — Quality Engine

V4 is a clean signal redesign after V3 forward-demo results showed that raw tick momentum plus a simple EMA regime filter did not provide enough entry quality.

## What changed

V4 intentionally trades less often. It does not treat every micro impulse as an entry signal.

Signal path:

1. Adaptive tick impulse threshold scaled by M1 ATR.
2. Two impulse confirmations inside a short time window.
3. Mandatory M1 EMA alignment and fast-EMA slope.
4. Mandatory M5 EMA confirmation by default.
5. ATR regime band.
6. ADX trend-strength gate with DI direction scoring.
7. Closed M1 candle quality scoring.
8. Current-price location relative to M1 fast EMA.
9. Strong tick directional ratio adds quality score.
10. Only signals meeting the minimum quality score can place an order.
11. Entry is a real broker-side BUY LIMIT / SELL LIMIT on a pullback, not a market chase.

## Execution / risk

- Demo-only by default.
- One position maximum.
- 0.12% desired equity risk.
- If calculated size is below the broker's minimum lot, 0.01 lot is only allowed when its effective stop risk remains <= 0.18% of equity.
- Adaptive ATR stop with hard min/max bounds.
- Broker-side SL and TP are placed with the pending order.
- Target must be at least 4x the live spread.
- Break-even and trailing protection use broker-side SL modifications.
- 1% daily loss stop.
- 3 consecutive losses stops new trading for the day.
- 12 filled entries per hour maximum.
- No martingale, grid, averaging down, Kelly sizing, position stacking or LLM/API in the execution path.

## Diagnostics

Unlike V3, V4 separates `raw` impulse from `confirmed` signal. Candidate rejection logs show quality score and M1/M5/ADX/ATR/candle measurements so weak signals can be diagnosed without guessing.

## Validation order

Do not optimize before baseline validation.

1. Compile in MetaEditor: 0 errors, ideally 0 warnings.
2. Strategy Tester: XAUUSD.a, M1, Every tick based on real ticks, $1,000, 1 month, 50 ms.
3. Repeat same month at 200 ms and 500 ms.
4. Test a different month and then 3–12 months.
5. Forward test on IC Markets demo and compare tester fills, spread, stop distance and effective min-lot risk.

The goal is not to manufacture a high trade count. V4 is a research EA and profitability is not guaranteed; the acceptance criterion is robust positive expectancy after realistic costs and execution stress.
