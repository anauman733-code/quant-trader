# XAU HyperScalper V7 — evidence-driven candidate

Source dataset: `XAU_V7_SIGNALS.csv`, 90,190 confirmed V6-style XAUUSD.a candidates from 2026-06-08 through 2026-09-04 using MT5 Every Tick Based on Real Ticks.

The raw V6-style candidate set had negative executable expectancy after spread at every 1/3/5/10/20 second horizon. The average 20-second executable move was approximately -5.2 points, showing that the unfiltered signal was not good enough.

The stable pattern was low spread + sufficiently large 2-bar M1 range + elevated recent tick activity. V7 therefore uses two evidence tiers:

- CORE: spread <= 7 points, 2-bar range >= 284 points, average absolute bid-tick delta over 32 ticks >= 5.0 points.
- EXPANSION: spread <= 8 points, 2-bar range >= 322 points, average absolute bid-tick delta over 32 ticks >= 4.0 points.

The CSV outcomes include spread. IC Markets commodity specifications publish a Raw Spread commission of 7 USD per round-turn lot, equivalent to approximately $0.07 at 0.01 lot, so research also subtracted an estimated 7 points per round trip.

A conservative one-position simulation was used: at most one selected signal every 20 seconds, 15-point hard stop, 400-point target, otherwise exit at 20 seconds. If both stop and target were present in the 20-second MFE/MAE window, the simulation conservatively counted the stop first.

For the union of the two V7 evidence tiers, estimated post-commission expectancy remained positive in all chronological splits:

- Train (2026-06-08 to 2026-07-31): about +2.25 points/trade after estimated commission, about 2.44 selected trades/hour.
- Validation (2026-08-03 to 2026-08-19): about +1.51 points/trade after estimated commission, about 2.62 selected trades/hour.
- Holdout test (2026-08-20 to 2026-09-04): about +1.25 points/trade after estimated commission, about 3.09 selected trades/hour.

These figures are research estimates, not a profitability guarantee. Live/demo execution can differ because of latency, fill quality, commissions, slippage, stop execution, server throttling and changing market regime.

V7 intentionally uses immediate market entry after confirmation because the V7 DATA forward-return calculation assumed executable entry at the signal bid/ask. It also uses a separate magic number and remains demo-only by default.
