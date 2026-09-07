# XAUUSD Hyper-Scalper V1 Test Plan

Do not enable live trading until every gate below is passed.

## Stage 1 — Compile and attach

1. Compile `XAU_HyperScalper_V1.mq5` in MetaEditor.
2. Require **0 errors**. Record any warnings.
3. Attach to the broker's XAUUSD M1 chart on a demo account.
4. Confirm Journal/Experts shows the demo-only guard and warm-up message.
5. Confirm the EA does not trade until sufficient 10-second synthetic bars have accumulated.

## Stage 2 — Functional demo checks

Verify separately:

- BUY and SELL orders contain a hard SL and TP.
- Position size changes with account equity and SL distance.
- `InpMaxLots` is never exceeded.
- Only the configured number of EA positions can be open.
- Spread filter blocks entries when spread exceeds the configured threshold.
- Session filter blocks entries outside configured broker-server hours.
- Hourly trade cap blocks new entries after the limit is reached.
- Cooldown prevents immediate re-entry after an exit.
- Opposite micro-trend exit closes the EA position when enabled.
- Time-stop closes a position that exceeds `InpMaxHoldSeconds`.
- Five consecutive losing exits block additional entries with the default preset.
- Daily equity loss of 2% blocks further entries and remains blocked after EA restart during the same broker day.

## Stage 3 — Strategy Tester

Use MT5 Strategy Tester with **Every tick based on real ticks** where available.

Test at minimum:

- 12 months of XAUUSD history.
- Multiple spread conditions.
- At least two broker symbol specifications if available.
- London session, New York session, and full configured session.

Track:

- Net return.
- Profit factor.
- Max equity drawdown.
- Win rate.
- Average win / average loss.
- Expectancy per trade.
- Trades per hour.
- Average holding time.
- Spread cost as a percentage of gross profit.
- Slippage sensitivity.
- Long-vs-short performance.
- Monthly consistency.

Reject configurations that rely on a tiny number of exceptional days for most of the profit.

## Stage 4 — Robustness

Do not select parameters purely because they maximize historical return.

Run:

- Walk-forward periods.
- Out-of-sample months not used for tuning.
- Wider-spread stress tests.
- Increased slippage tests.
- Small changes around EMA, momentum, ATR and stop parameters.

A useful configuration should remain viable when parameters are changed slightly. If a tiny parameter change destroys profitability, treat the result as overfit.

## Stage 5 — Demo forward test

Run continuously on demo for at least several hundred completed trades before considering any live mode.

Compare actual demo results against tester assumptions:

- actual spread,
- actual slippage,
- rejected orders,
- missed fills,
- trading frequency,
- drawdown,
- expectancy.

## AI phase after baseline

Only after the non-AI baseline is measurable, add an ONNX classifier that outputs:

- BUY probability,
- SELL probability,
- NO-TRADE probability.

The AI may filter entries, but it must not bypass risk controls, daily shutdowns, spread limits, lot caps, SL/TP requirements, or demo/live guards.
