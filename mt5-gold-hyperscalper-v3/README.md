# XAU HyperScalper V3

V3 is an execution-aware redesign of V2 for MT5/XAUUSD. It is built specifically to address the live-demo problem observed with market-chasing micro-scalpers: tester fills can look exceptional while real execution produces adverse fills.

## Core execution model

1. Detect short-window tick momentum.
2. Confirm the direction with a lightweight M1 EMA regime filter and ATR volatility band.
3. Reject trades when spread is too wide or target/spread economics are poor.
4. Place a real broker-side BUY LIMIT below bid or SELL LIMIT above ask.
5. Cancel the order quickly if momentum disappears, direction flips, or the limit becomes stale.
6. Allow only one position.
7. Manage exits tick-by-tick using target, virtual break-even protection, micro-trailing, stale-loss exit, time exit and momentum-reversal exit.
8. Keep a broker-side hard SL on every entry.

## What V3 deliberately does NOT use

- No martingale
- No grid
- No averaging down
- No Kelly sizing
- No OpenAI/LLM call in the execution path
- No position stacking
- No market-order breakout chasing for entries

## Default demo risk

- 0.05% equity risk per trade
- 0.03 lot hard cap
- 1.5% daily equity-loss stop
- 4 consecutive losses stops new entries
- 40 fills/hour maximum
- one open position

## Install

Copy `XAU_HyperScalper_V3.mq5` to MT5 -> File -> Open Data Folder -> MQL5 -> Experts.

Compile in MetaEditor with F7. Target: 0 errors and 0 warnings.

Attach to the broker's fully tradable gold symbol. On the current IC Markets demo setup this has been `XAUUSD.a` rather than the close-only `XAUUSD` symbol.

Load `PRESET_DEMO_EXECUTION_AWARE.set` from the EA Inputs tab.

## Backtest protocol

Use:

- XAUUSD.a
- M1
- Every tick based on real ticks
- $1,000 initial deposit
- Profit in pips for faster calculations: OFF
- First test: 1 month
- Then the same period at 50 ms, 200 ms and 500 ms execution delay where supported

Do not optimize parameters until the same logic survives multiple non-overlapping periods and forward demo execution.

## Forward-demo evidence to inspect

The Journal logs `FILL entry price=... vsLimit=...pts`. Passive LIMIT fills should generally be at the requested limit or better. Repeated materially adverse entry deltas, rejected limits or broker throttling are reasons to stop and revise execution rather than loosen controls.

This is research software. Backtests and demo results do not guarantee profitability in live trading.
