# XAU HyperScalper V6 — Range Burst

Demo-first XAUUSD MT5 research EA built around a published strategy structure used by current gold tick scalpers: compressed M1 range breakout, frozen breakout level, consecutive bid-tick burst, tick velocity and short momentum confirmation.

## Why V6 exists
V5 continuous two-sided quoting produced immediate forward-demo losses on a retail CFD feed. V6 abandons passive market-making and instead looks for short-horizon continuation after a real range break.

## Core path
1. Build a range from the previous 3 closed M1 bars.
2. Arm when bid clears the range by a small breakout buffer.
3. Freeze the breakout level.
4. Require 3 consecutive directional bid ticks.
5. Require minimum burst distance and points/second velocity.
6. Require short-window net momentum, directional bias and pressure.
7. Place a very short-lived continuation BUY STOP / SELL STOP.
8. Attach broker-side hard SL and TP.
9. Reject effective risk above the configured cap and flag excessive fill slippage.

## Frequency defaults
- 0.01 lot
- 750 ms post-exit cooldown
- 2.5 s same-direction pause
- up to 120 fills/hour
- M5 trend filter OFF
- ATR filter OFF

The optional filters are intentionally off in the first demo preset because the research target is frequent trading. Signal quality comes from the range break + burst + velocity + momentum stack rather than slow higher-timeframe gating.

## Risk defaults
- 120 point hard stop
- 200 point TP
- effective risk cap 0.25% on 0.01 lot
- 1.5% daily equity loss stop
- 5 consecutive-loss stop
- one position at a time
- no martingale, grid, averaging down or Kelly sizing

## Validation
Compile in MetaEditor, then use XAUUSD.a M1 on demo. For Strategy Tester use Every tick based on real ticks, profit-in-pips OFF, and test 50/200/500 ms execution delays. Forward-demo fill/slippage behavior matters more than tester headline return.
