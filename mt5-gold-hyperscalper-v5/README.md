# XAU HyperScalper V5 — Continuous Micro-Maker

Demo/research EA for MT5 XAUUSD.a.

## Purpose
V5 is designed for continuous activity rather than rare directional signals. When flat it maintains two broker-side passive quotes:
- BUY LIMIT below current bid
- SELL LIMIT above current ask

A weighted tick-flow score moves the two quotes asymmetrically: the quote aligned with recent flow is pulled closer, while the adverse-side quote is pushed farther away. Once either side fills, the sibling pending order is cancelled and the position is managed with server-side SL/TP, break-even, trailing, adverse-flow exit, and a short time stop. After exit the engine re-quotes after a 250 ms cooldown.

## Research basis
The design borrows two ideas rather than copying a claimed profitable EA:
1. continuous two-sided quoting / reservation-price skew from Avellaneda–Stoikov market-making logic;
2. short-horizon order-flow imbalance as a microstructure signal.

A retail MT5 CFD account is not a true exchange market maker, so no assumption is made that the EA earns exchange maker spread or rebates. The purpose is to test whether passive quote placement plus flow skew can produce robust retail fills on the user's broker.

## Default demo controls
- 0.01 lots
- one open position maximum
- 180 fills/hour cap
- 250 ms post-exit cooldown
- 18-point max spread
- quote refresh every 350 ms, with drift/age checks
- 35–90 point adaptive target
- 70–140 point adaptive hard stop
- 0.25% maximum effective hard-stop risk
- 1.5% daily loss stop
- 6-loss streak stop
- 18 second maximum hold
- demo-only guard enabled

## Validation
Compile first. Then forward demo is the primary test because passive near-market limits are execution-sensitive. For Strategy Tester use XAUUSD.a / M1 / Every tick based on real ticks / commissions enabled / 50 ms, then repeat 200 ms and 500 ms. Do not infer live profitability from tester results alone.
