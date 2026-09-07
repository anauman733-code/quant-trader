//+------------------------------------------------------------------+
//| XAU_HyperScalper_V3.mq5                                         |
//| Execution-aware XAUUSD tick scalper for MetaTrader 5             |
//| Passive pullback LIMIT entries, regime filter, strict risk       |
//+------------------------------------------------------------------+
#property strict
#property version   "3.00"
#property description "Demo-first XAUUSD tick scalper using broker-side passive LIMIT entries, M1 regime filtering and strict risk controls."

#include <Trade/Trade.mqh>

CTrade trade;

#define MAX_TICK_BUFFER 160

//--------------------------- Inputs ---------------------------------
input group "Safety"
input bool   InpDemoOnly                    = true;
input bool   InpEnableTrading               = true;
input long   InpMagicNumber                 = 26090830;
input double InpRiskPerTradePct             = 0.05;   // % equity risk at hard stop
input double InpMaxLots                     = 0.03;
input double InpDailyLossStopPct            = 1.50;
input int    InpMaxConsecutiveLosses        = 4;
input int    InpMaxTradesPerHour            = 40;
input int    InpCooldownAfterExitMs         = 1500;
input int    InpMaxOpenPositions            = 1;

input group "Execution / Cost Control"
input int    InpMaxSpreadPoints             = 25;
input int    InpHardStopPoints              = 100;
input int    InpPassiveOffsetPoints         = 3;      // buy below bid / sell above ask
input int    InpPendingMaxAgeMs             = 3000;
input int    InpNoSignalCancelMs            = 900;
input int    InpMinOrderActionIntervalMs    = 300;
input double InpMinTargetToSpreadRatio      = 2.20;
input int    InpSlippagePointsForClose      = 25;

input group "Tick Momentum Signal"
input int    InpLookbackTicks               = 16;
input int    InpMinTickWindowMs             = 250;
input int    InpMaxTickWindowMs             = 1800;
input double InpMinMomentumPoints           = 7.0;
input double InpMinDirectionalRatio         = 0.64;
input double InpMinRecentMomentumPoints     = 3.0;
input double InpRecentMomentumShare         = 0.35;   // recent move must be this share of full move

input group "M1 Regime / Volatility Filter"
input bool   InpUseM1RegimeFilter           = true;
input int    InpFastEmaPeriod               = 8;
input int    InpSlowEmaPeriod               = 21;
input double InpMinEmaSeparationPoints      = 8.0;
input bool   InpUseM5Confirmation           = false;
input bool   InpUseAtrFilter                = true;
input int    InpAtrPeriod                   = 14;
input double InpMinAtrPoints                = 35.0;
input double InpMaxAtrPoints                = 450.0;

input group "Exit Engine"
input int    InpProfitTargetPoints          = 60;
input int    InpTrailStartPoints            = 30;
input int    InpTrailGivebackPoints         = 10;
input int    InpBreakEvenArmPoints          = 24;
input int    InpBreakEvenLockPoints         = 3;
input int    InpMaxHoldSeconds              = 25;
input bool   InpExitOnMomentumReversal      = true;
input int    InpMinHoldBeforeReversalMs     = 500;
input int    InpStaleLossExitSeconds        = 8;
input int    InpStaleLossPoints             = 20;

input group "Session Filter (broker server time)"
input bool   InpUseSessionFilter            = true;
input int    InpSessionStartHour            = 7;
input int    InpSessionStartMinute          = 0;
input int    InpSessionEndHour              = 22;
input int    InpSessionEndMinute            = 0;

input group "Diagnostics"
input bool   InpVerboseLogging              = true;
input int    InpHeartbeatSeconds            = 5;

//--------------------------- State ----------------------------------
double g_tickMid[MAX_TICK_BUFFER];
long   g_tickMs[MAX_TICK_BUFFER];
int    g_tickCount = 0;
int    g_tickHead  = 0;

long   g_lastOrderActionMs = 0;
long   g_lastExitMs        = 0;
long   g_lastSignalMs      = 0;
long   g_lastHeartbeatMs   = 0;
int    g_lastSignalDir     = 0;

ulong  g_trackedPositionTicket = 0;
double g_peakProfitPoints      = 0.0;
bool   g_breakEvenArmed        = false;

int    g_consecutiveLosses = 0;
double g_dayStartEquity    = 0.0;
string g_dayEquityKey      = "";

double g_lastPlacedLimitPrice = 0.0;
int    g_lastPlacedDirection  = 0;

int g_emaFastM1 = INVALID_HANDLE;
int g_emaSlowM1 = INVALID_HANDLE;
int g_emaFastM5 = INVALID_HANDLE;
int g_emaSlowM5 = INVALID_HANDLE;
int g_atrM1     = INVALID_HANDLE;

//--------------------------- Logging --------------------------------
void Log(string text)
{
   if(InpVerboseLogging)
      Print("[XAU-HS3] ", text);
}

string DirText(int dir)
{
   if(dir > 0) return "BUY";
   if(dir < 0) return "SELL";
   return "NONE";
}

//--------------------------- Day guard -------------------------------
string TodayKey()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   long login = (long)AccountInfoInteger(ACCOUNT_LOGIN);
   return StringFormat("XAUHS3_%I64d_%I64d_%04d%02d%02d", login, InpMagicNumber, dt.year, dt.mon, dt.day);
}

void RefreshDayStartEquity()
{
   string key = TodayKey();
   if(key == g_dayEquityKey && g_dayStartEquity > 0.0)
      return;

   g_dayEquityKey = key;

   if(MQLInfoInteger(MQL_TESTER))
   {
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      return;
   }

   if(GlobalVariableCheck(key))
      g_dayStartEquity = GlobalVariableGet(key);
   else
   {
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      GlobalVariableSet(key, g_dayStartEquity);
   }

   Log(StringFormat("Day-start equity guard %.2f", g_dayStartEquity));
}

bool DailyLossGuardOK()
{
   RefreshDayStartEquity();
   if(InpDailyLossStopPct <= 0.0 || g_dayStartEquity <= 0.0)
      return true;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double floorEquity = g_dayStartEquity * (1.0 - InpDailyLossStopPct / 100.0);
   return (equity > floorEquity);
}

//--------------------------- Environment -----------------------------
bool IsDemoAllowed()
{
   if(!InpDemoOnly) return true;
   if(MQLInfoInteger(MQL_TESTER)) return true;
   ENUM_ACCOUNT_TRADE_MODE mode = (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
   return (mode == ACCOUNT_TRADE_MODE_DEMO || mode == ACCOUNT_TRADE_MODE_CONTEST);
}

bool IsFullTradeSymbol()
{
   ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   return (mode == SYMBOL_TRADE_MODE_FULL);
}

bool IsSessionOK()
{
   if(!InpUseSessionFilter) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMin   = dt.hour * 60 + dt.min;
   int startMin = InpSessionStartHour * 60 + InpSessionStartMinute;
   int endMin   = InpSessionEndHour * 60 + InpSessionEndMinute;
   if(startMin <= endMin) return (nowMin >= startMin && nowMin <= endMin);
   return (nowMin >= startMin || nowMin <= endMin);
}

double CurrentSpreadPoints()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return 999999.0;
   return (tick.ask - tick.bid) / _Point;
}

bool IsSpreadOK()
{
   if(InpMaxSpreadPoints <= 0) return true;
   return (CurrentSpreadPoints() <= InpMaxSpreadPoints);
}

bool CostEdgeOK()
{
   double spread = CurrentSpreadPoints();
   if(spread <= 0.0) return false;
   if(InpProfitTargetPoints <= 0) return true;
   return (((double)InpProfitTargetPoints / spread) >= InpMinTargetToSpreadRatio);
}

//--------------------------- Indicator helpers -----------------------
bool ReadHandleValue(int handle, double &value)
{
   value = 0.0;
   if(handle == INVALID_HANDLE) return false;
   double a[1];
   if(CopyBuffer(handle, 0, 0, 1, a) != 1) return false;
   value = a[0];
   return true;
}

bool AtrFilterOK(double &atrPts)
{
   atrPts = 0.0;
   if(!InpUseAtrFilter) return true;
   double atr = 0.0;
   if(!ReadHandleValue(g_atrM1, atr) || atr <= 0.0) return false;
   atrPts = atr / _Point;
   if(InpMinAtrPoints > 0.0 && atrPts < InpMinAtrPoints) return false;
   if(InpMaxAtrPoints > 0.0 && atrPts > InpMaxAtrPoints) return false;
   return true;
}

bool RegimeAllows(int direction, double &m1GapPts, double &m5GapPts, double &atrPts)
{
   m1GapPts = 0.0;
   m5GapPts = 0.0;
   atrPts = 0.0;

   if(!AtrFilterOK(atrPts)) return false;
   if(!InpUseM1RegimeFilter) return true;

   double f1 = 0.0, s1 = 0.0;
   if(!ReadHandleValue(g_emaFastM1, f1) || !ReadHandleValue(g_emaSlowM1, s1)) return false;
   m1GapPts = (f1 - s1) / _Point;

   if(direction > 0)
   {
      if(m1GapPts < InpMinEmaSeparationPoints) return false;
   }
   else if(direction < 0)
   {
      if(m1GapPts > -InpMinEmaSeparationPoints) return false;
   }
   else return false;

   if(InpUseM5Confirmation)
   {
      double f5 = 0.0, s5 = 0.0;
      if(!ReadHandleValue(g_emaFastM5, f5) || !ReadHandleValue(g_emaSlowM5, s5)) return false;
      m5GapPts = (f5 - s5) / _Point;
      if(direction > 0 && m5GapPts <= 0.0) return false;
      if(direction < 0 && m5GapPts >= 0.0) return false;
   }

   return true;
}

//--------------------------- Tick buffer -----------------------------
void PushTick(const MqlTick &tick)
{
   double mid = (tick.bid + tick.ask) * 0.5;
   g_tickMid[g_tickHead] = mid;
   g_tickMs[g_tickHead]  = tick.time_msc;
   g_tickHead = (g_tickHead + 1) % MAX_TICK_BUFFER;
   if(g_tickCount < MAX_TICK_BUFFER) g_tickCount++;
}

bool TickByOffset(int offset, double &mid, long &ms)
{
   if(offset < 0 || offset >= g_tickCount) return false;
   int idx = g_tickHead - 1 - offset;
   while(idx < 0) idx += MAX_TICK_BUFFER;
   idx %= MAX_TICK_BUFFER;
   mid = g_tickMid[idx];
   ms  = g_tickMs[idx];
   return true;
}

int TickSignal(double &netPts, double &dirRatio, long &ageMs, double &recentPts)
{
   netPts = 0.0; dirRatio = 0.0; ageMs = 0; recentPts = 0.0;
   if(g_tickCount < 4) return 0;

   int maxOffset = InpLookbackTicks - 1;
   if(maxOffset > g_tickCount - 1) maxOffset = g_tickCount - 1;
   if(maxOffset > MAX_TICK_BUFFER - 1) maxOffset = MAX_TICK_BUFFER - 1;
   if(maxOffset < 2) return 0;

   double latestMid = 0.0; long latestMs = 0;
   if(!TickByOffset(0, latestMid, latestMs)) return 0;

   int chosen = -1;
   for(int off = 1; off <= maxOffset; ++off)
   {
      double oldMid = 0.0; long oldMs = 0;
      if(!TickByOffset(off, oldMid, oldMs)) break;
      long age = latestMs - oldMs;
      if(age > InpMaxTickWindowMs) break;
      if(age >= InpMinTickWindowMs) chosen = off;
   }
   if(chosen < 2) return 0;

   double oldMid = 0.0; long oldMs = 0;
   TickByOffset(chosen, oldMid, oldMs);
   ageMs = latestMs - oldMs;
   netPts = (latestMid - oldMid) / _Point;

   int upMoves = 0, downMoves = 0, meaningful = 0;
   for(int off = chosen; off >= 1; --off)
   {
      double older = 0.0, newer = 0.0; long t1 = 0, t2 = 0;
      TickByOffset(off, older, t1);
      TickByOffset(off - 1, newer, t2);
      double d = (newer - older) / _Point;
      if(d > 0.05) { upMoves++; meaningful++; }
      else if(d < -0.05) { downMoves++; meaningful++; }
   }
   if(meaningful <= 0) return 0;

   int halfOffset = chosen / 2;
   if(halfOffset < 1) halfOffset = 1;
   double halfMid = 0.0; long halfMs = 0;
   TickByOffset(halfOffset, halfMid, halfMs);
   recentPts = (latestMid - halfMid) / _Point;

   double upRatio = (double)upMoves / (double)meaningful;
   double downRatio = (double)downMoves / (double)meaningful;
   double share = (MathAbs(netPts) > 0.0 ? MathAbs(recentPts / netPts) : 0.0);

   if(netPts >= InpMinMomentumPoints && recentPts >= InpMinRecentMomentumPoints &&
      upRatio >= InpMinDirectionalRatio && share >= InpRecentMomentumShare)
   {
      dirRatio = upRatio; return 1;
   }
   if(netPts <= -InpMinMomentumPoints && recentPts <= -InpMinRecentMomentumPoints &&
      downRatio >= InpMinDirectionalRatio && share >= InpRecentMomentumShare)
   {
      dirRatio = downRatio; return -1;
   }

   dirRatio = MathMax(upRatio, downRatio);
   return 0;
}

//--------------------------- Positions / orders ----------------------
int CountOurOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      count++;
   }
   return count;
}

bool GetOurPosition(ulong &ticket, ENUM_POSITION_TYPE &type, double &openPrice, long &openMs)
{
   ticket = 0; openPrice = 0.0; openMs = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      ticket = t;
      type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      openMs = (long)PositionGetInteger(POSITION_TIME_MSC);
      return true;
   }
   return false;
}

bool GetOurPending(ulong &ticket, ENUM_ORDER_TYPE &type, double &price, long &setupMs)
{
   ticket = 0; price = 0.0; setupMs = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot != ORDER_TYPE_BUY_LIMIT && ot != ORDER_TYPE_SELL_LIMIT) continue;
      ticket = t; type = ot;
      price = OrderGetDouble(ORDER_PRICE_OPEN);
      setupMs = (long)OrderGetInteger(ORDER_TIME_SETUP_MSC);
      return true;
   }
   return false;
}

bool CanOrderAction(long nowMs)
{
   if(g_lastOrderActionMs <= 0) return true;
   return ((nowMs - g_lastOrderActionMs) >= InpMinOrderActionIntervalMs);
}

bool DeletePending(ulong ticket, long nowMs, string reason)
{
   if(ticket == 0 || !CanOrderAction(nowMs)) return false;
   trade.SetExpertMagicNumber(InpMagicNumber);
   if(trade.OrderDelete(ticket))
   {
      g_lastOrderActionMs = nowMs;
      Log(StringFormat("DELETE LIMIT #%I64u reason=%s", ticket, reason));
      return true;
   }
   Log(StringFormat("Delete failed #%I64u ret=%u %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   g_lastOrderActionMs = nowMs;
   return false;
}

void DeleteAllPending(string reason)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT) continue;
      if(!CanOrderAction(tick.time_msc)) return;
      DeletePending(ticket, tick.time_msc, reason);
   }
}

//--------------------------- Trade count / loss streak ---------------
int CountEntriesLastHour()
{
   datetime now = TimeCurrent();
   if(!HistorySelect(now - 3600, now)) return 0;
   int count = 0;
   for(int i = 0; i < HistoryDealsTotal(); ++i)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT) count++;
   }
   return count;
}

void RebuildLossStreak()
{
   g_consecutiveLosses = 0; g_lastExitMs = 0;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime dayStart = StructToTime(dt);
   if(!HistorySelect(dayStart, TimeCurrent())) return;

   for(int i = HistoryDealsTotal() - 1; i >= 0; --i)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT) continue;
      long tms = (long)HistoryDealGetInteger(deal, DEAL_TIME_MSC);
      if(g_lastExitMs == 0) g_lastExitMs = tms;
      double pnl = HistoryDealGetDouble(deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(deal, DEAL_SWAP)
                 + HistoryDealGetDouble(deal, DEAL_COMMISSION);
      if(pnl < 0.0) g_consecutiveLosses++;
      else break;
   }
}

//--------------------------- Risk -----------------------------------
string RiskGateReason(long nowMs)
{
   if(!InpEnableTrading) return "trading-disabled-input";
   if(!IsDemoAllowed()) return "demo-only";
   if(!IsFullTradeSymbol()) return "symbol-not-full-access";
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return "terminal-algo-disabled";
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return "ea-trading-disabled";
   if(!IsSessionOK()) return "outside-session";
   if(!IsSpreadOK()) return "spread";
   if(!CostEdgeOK()) return "cost-edge";
   if(!DailyLossGuardOK()) return "daily-loss-stop";
   if(InpMaxConsecutiveLosses > 0 && g_consecutiveLosses >= InpMaxConsecutiveLosses) return "loss-streak-stop";
   if(InpMaxTradesPerHour > 0 && CountEntriesLastHour() >= InpMaxTradesPerHour) return "hourly-trade-cap";
   if(InpCooldownAfterExitMs > 0 && g_lastExitMs > 0 && (nowMs - g_lastExitMs) < InpCooldownAfterExitMs) return "cooldown";
   if(CountOurOpenPositions() >= InpMaxOpenPositions) return "position-cap";
   return "";
}

double NormalizeVolumeFloor(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;
   if(lots < minLot) return 0.0;
   lots = MathMin(lots, maxLot);
   lots = MathMin(lots, InpMaxLots);
   lots = MathFloor(lots / step + 1e-9) * step;
   if(lots < minLot) return 0.0;
   int digits = 2;
   if(step >= 1.0) digits = 0; else if(step >= 0.1) digits = 1; else if(step >= 0.01) digits = 2; else digits = 3;
   return NormalizeDouble(lots, digits);
}

double LotsForRisk(int direction, double entryPrice, double stopPrice)
{
   if(direction == 0 || InpRiskPerTradePct <= 0.0) return 0.0;
   double lossOneLot = 0.0;
   ENUM_ORDER_TYPE calcType = (direction > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcProfit(calcType, _Symbol, 1.0, entryPrice, stopPrice, lossOneLot)) return 0.0;
   lossOneLot = MathAbs(lossOneLot);
   if(lossOneLot <= 0.0) return 0.0;
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPerTradePct / 100.0;
   return NormalizeVolumeFloor(riskMoney / lossOneLot);
}

//--------------------------- Passive LIMIT engine --------------------
bool PlacePassiveLimit(int direction, const MqlTick &tick)
{
   if(direction == 0 || !CanOrderAction(tick.time_msc)) return false;
   string gate = RiskGateReason(tick.time_msc);
   if(gate != "") { Log("Entry blocked: " + gate); return false; }

   double m1Gap = 0.0, m5Gap = 0.0, atrPts = 0.0;
   if(!RegimeAllows(direction, m1Gap, m5Gap, atrPts))
   {
      Log(StringFormat("Entry blocked: regime dir=%s m1gap=%.1f m5gap=%.1f atr=%.1f", DirText(direction), m1Gap, m5Gap, atrPts));
      return false;
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   int brokerGap = MathMax(stopsLevel, freezeLevel) + 2;
   int passiveOffset = MathMax(InpPassiveOffsetPoints, brokerGap);
   int stopPts = MathMax(InpHardStopPoints, stopsLevel + 2);

   double entry = 0.0, sl = 0.0;
   if(direction > 0)
   {
      entry = NormalizeDouble(tick.bid - passiveOffset * _Point, digits);
      sl    = NormalizeDouble(entry - stopPts * _Point, digits);
   }
   else
   {
      entry = NormalizeDouble(tick.ask + passiveOffset * _Point, digits);
      sl    = NormalizeDouble(entry + stopPts * _Point, digits);
   }

   double lots = LotsForRisk(direction, entry, sl);
   if(lots <= 0.0) { Log("Entry blocked: risk size below broker minimum lot."); return false; }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   bool sent = false;
   if(direction > 0)
      sent = trade.BuyLimit(lots, entry, _Symbol, sl, 0.0, ORDER_TIME_GTC, 0, "XAU-HS3 BLIMIT");
   else
      sent = trade.SellLimit(lots, entry, _Symbol, sl, 0.0, ORDER_TIME_GTC, 0, "XAU-HS3 SLIMIT");

   g_lastOrderActionMs = tick.time_msc;
   if(!sent)
   {
      Log(StringFormat("LIMIT failed dir=%s lots=%.3f entry=%.2f sl=%.2f ret=%u %s", DirText(direction), lots, entry, sl, trade.ResultRetcode(), trade.ResultRetcodeDescription()));
      return false;
   }

   g_lastPlacedLimitPrice = entry;
   g_lastPlacedDirection = direction;
   Log(StringFormat("PLACE %s LIMIT lots=%.3f entry=%.2f sl=%.2f spread=%.1f m1gap=%.1f atr=%.1f", DirText(direction), lots, entry, sl, CurrentSpreadPoints(), m1Gap, atrPts));
   return true;
}

void ManagePending(int signalDir, const MqlTick &tick)
{
   ulong ticket = 0; ENUM_ORDER_TYPE type = ORDER_TYPE_BUY_LIMIT; double price = 0.0; long setupMs = 0;
   bool hasPending = GetOurPending(ticket, type, price, setupMs);

   if(signalDir == 0)
   {
      if(hasPending && g_lastSignalMs > 0 && (tick.time_msc - g_lastSignalMs) >= InpNoSignalCancelMs)
         DeletePending(ticket, tick.time_msc, "signal-gone");
      return;
   }

   g_lastSignalDir = signalDir;
   g_lastSignalMs = tick.time_msc;

   if(!hasPending)
   {
      PlacePassiveLimit(signalDir, tick);
      return;
   }

   int pendingDir = (type == ORDER_TYPE_BUY_LIMIT ? 1 : -1);
   if(pendingDir != signalDir)
   {
      DeletePending(ticket, tick.time_msc, "direction-flip");
      return;
   }

   long age = tick.time_msc - setupMs;
   if(age >= InpPendingMaxAgeMs)
      DeletePending(ticket, tick.time_msc, "limit-expired");
}

//--------------------------- Exit engine -----------------------------
bool CloseOurPosition(ulong ticket, string reason)
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePointsForClose);
   trade.SetTypeFillingBySymbol(_Symbol);
   if(trade.PositionClose(ticket))
   {
      Log(StringFormat("CLOSE #%I64u reason=%s", ticket, reason));
      return true;
   }
   Log(StringFormat("Close failed #%I64u ret=%u %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   return false;
}

void ManageOpenPosition(int signalDir, const MqlTick &tick)
{
   ulong ticket = 0; ENUM_POSITION_TYPE type = POSITION_TYPE_BUY; double openPrice = 0.0; long openMs = 0;
   if(!GetOurPosition(ticket, type, openPrice, openMs))
   {
      g_trackedPositionTicket = 0; g_peakProfitPoints = 0.0; g_breakEvenArmed = false; return;
   }

   if(g_trackedPositionTicket != ticket)
   {
      g_trackedPositionTicket = ticket;
      g_peakProfitPoints = 0.0;
      g_breakEvenArmed = false;
      Log(StringFormat("TRACK filled position #%I64u", ticket));
   }

   double profitPts = (type == POSITION_TYPE_BUY) ? (tick.bid - openPrice) / _Point : (openPrice - tick.ask) / _Point;
   if(profitPts > g_peakProfitPoints) g_peakProfitPoints = profitPts;

   if(InpProfitTargetPoints > 0 && profitPts >= InpProfitTargetPoints)
   { CloseOurPosition(ticket, "profit-target"); return; }

   if(InpBreakEvenArmPoints > 0 && profitPts >= InpBreakEvenArmPoints)
      g_breakEvenArmed = true;
   if(g_breakEvenArmed && profitPts <= InpBreakEvenLockPoints)
   { CloseOurPosition(ticket, "break-even-protect"); return; }

   if(InpTrailStartPoints > 0 && InpTrailGivebackPoints > 0 &&
      g_peakProfitPoints >= InpTrailStartPoints && profitPts <= (g_peakProfitPoints - InpTrailGivebackPoints))
   { CloseOurPosition(ticket, "micro-trail"); return; }

   long heldMs = tick.time_msc - openMs;
   if(InpStaleLossExitSeconds > 0 && InpStaleLossPoints > 0 &&
      heldMs >= (long)InpStaleLossExitSeconds * 1000 && profitPts <= -InpStaleLossPoints)
   { CloseOurPosition(ticket, "stale-loss"); return; }

   if(InpMaxHoldSeconds > 0 && heldMs >= (long)InpMaxHoldSeconds * 1000)
   { CloseOurPosition(ticket, "time-exit"); return; }

   if(InpExitOnMomentumReversal && heldMs >= InpMinHoldBeforeReversalMs && signalDir != 0)
   {
      if(type == POSITION_TYPE_BUY && signalDir < 0) { CloseOurPosition(ticket, "momentum-reversal"); return; }
      if(type == POSITION_TYPE_SELL && signalDir > 0) { CloseOurPosition(ticket, "momentum-reversal"); return; }
   }
}

//--------------------------- Diagnostics -----------------------------
void Heartbeat(const MqlTick &tick, int signalDir, double netPts, double ratio, long ageMs, double recentPts)
{
   if(!InpVerboseLogging || InpHeartbeatSeconds <= 0) return;
   if(g_lastHeartbeatMs > 0 && (tick.time_msc - g_lastHeartbeatMs) < (long)InpHeartbeatSeconds * 1000) return;
   g_lastHeartbeatMs = tick.time_msc;

   ulong pt = 0; ENUM_POSITION_TYPE ptype = POSITION_TYPE_BUY; double po = 0.0; long pms = 0;
   bool hasPos = GetOurPosition(pt, ptype, po, pms);
   ulong ot = 0; ENUM_ORDER_TYPE otype = ORDER_TYPE_BUY_LIMIT; double op = 0.0; long oms = 0;
   bool hasPending = GetOurPending(ot, otype, op, oms);
   string state = hasPos ? "POSITION" : (hasPending ? "LIMIT" : "FLAT");
   string gate = RiskGateReason(tick.time_msc); if(gate == "") gate = "OK";
   double m1 = 0.0, m5 = 0.0, atr = 0.0;
   bool regime = (signalDir == 0 ? false : RegimeAllows(signalDir, m1, m5, atr));
   Log(StringFormat("HB state=%s sig=%s net=%.1f recent=%.1f ratio=%.2f age=%I64dms spread=%.1f regime=%s m1gap=%.1f atr=%.1f gate=%s",
                    state, DirText(signalDir), netPts, recentPts, ratio, ageMs, CurrentSpreadPoints(), (regime ? "OK" : "NO"), m1, atr, gate));
}

//--------------------------- MT5 events ------------------------------
int OnInit()
{
   if(InpRiskPerTradePct <= 0.0 || InpRiskPerTradePct > 1.0)
   { Print("[XAU-HS3] Risk per trade must be >0 and <=1.0%."); return INIT_PARAMETERS_INCORRECT; }
   if(InpLookbackTicks < 4 || InpLookbackTicks > MAX_TICK_BUFFER || InpMinTickWindowMs <= 0 ||
      InpMaxTickWindowMs <= InpMinTickWindowMs || InpMinDirectionalRatio < 0.50 || InpMinDirectionalRatio > 1.0)
   { Print("[XAU-HS3] Invalid tick signal configuration."); return INIT_PARAMETERS_INCORRECT; }
   if(InpHardStopPoints <= 0 || InpPassiveOffsetPoints < 0 || InpProfitTargetPoints <= 0)
   { Print("[XAU-HS3] Invalid execution/exit configuration."); return INIT_PARAMETERS_INCORRECT; }
   if(!IsDemoAllowed())
   { Print("[XAU-HS3] Demo-only guard blocked initialization on a real account."); return INIT_FAILED; }
   if(!IsFullTradeSymbol())
   { Print("[XAU-HS3] Symbol is not FULL ACCESS. Use XAUUSD.a if required by broker."); return INIT_FAILED; }

   if(InpUseM1RegimeFilter)
   {
      g_emaFastM1 = iMA(_Symbol, PERIOD_M1, InpFastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      g_emaSlowM1 = iMA(_Symbol, PERIOD_M1, InpSlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(g_emaFastM1 == INVALID_HANDLE || g_emaSlowM1 == INVALID_HANDLE)
      { Print("[XAU-HS3] Failed to create M1 EMA handles."); return INIT_FAILED; }
   }
   if(InpUseM5Confirmation)
   {
      g_emaFastM5 = iMA(_Symbol, PERIOD_M5, InpFastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      g_emaSlowM5 = iMA(_Symbol, PERIOD_M5, InpSlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(g_emaFastM5 == INVALID_HANDLE || g_emaSlowM5 == INVALID_HANDLE)
      { Print("[XAU-HS3] Failed to create M5 EMA handles."); return INIT_FAILED; }
   }
   if(InpUseAtrFilter)
   {
      g_atrM1 = iATR(_Symbol, PERIOD_M1, InpAtrPeriod);
      if(g_atrM1 == INVALID_HANDLE)
      { Print("[XAU-HS3] Failed to create M1 ATR handle."); return INIT_FAILED; }
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePointsForClose);
   trade.SetTypeFillingBySymbol(_Symbol);

   RefreshDayStartEquity();
   RebuildLossStreak();
   Log(StringFormat("Initialized V3 on %s. Passive LIMIT engine. risk=%.2f%% maxTrades/hr=%d", _Symbol, InpRiskPerTradePct, InpMaxTradesPerHour));
   Log("V3 does not chase breakout fills: signal -> regime check -> broker-side pullback LIMIT.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   DeleteAllPending("ea-deinit");
   if(g_emaFastM1 != INVALID_HANDLE) IndicatorRelease(g_emaFastM1);
   if(g_emaSlowM1 != INVALID_HANDLE) IndicatorRelease(g_emaSlowM1);
   if(g_emaFastM5 != INVALID_HANDLE) IndicatorRelease(g_emaFastM5);
   if(g_emaSlowM5 != INVALID_HANDLE) IndicatorRelease(g_emaSlowM5);
   if(g_atrM1     != INVALID_HANDLE) IndicatorRelease(g_atrM1);
}

void OnTick()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   RefreshDayStartEquity();
   PushTick(tick);

   double netPts = 0.0, ratio = 0.0, recentPts = 0.0; long ageMs = 0;
   int signalDir = TickSignal(netPts, ratio, ageMs, recentPts);

   if(CountOurOpenPositions() > 0)
   {
      DeleteAllPending("position-open");
      ManageOpenPosition(signalDir, tick);
      Heartbeat(tick, signalDir, netPts, ratio, ageMs, recentPts);
      return;
   }

   g_trackedPositionTicket = 0; g_peakProfitPoints = 0.0; g_breakEvenArmed = false;

   string gate = RiskGateReason(tick.time_msc);
   if(gate != "")
   {
      DeleteAllPending("risk-gate-" + gate);
      Heartbeat(tick, signalDir, netPts, ratio, ageMs, recentPts);
      return;
   }

   ManagePending(signalDir, tick);
   Heartbeat(tick, signalDir, netPts, ratio, ageMs, recentPts);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if((long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   double dealPrice = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   double commission = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
   {
      double deltaPts = 0.0;
      if(g_lastPlacedLimitPrice > 0.0)
      {
         if(g_lastPlacedDirection > 0) deltaPts = (dealPrice - g_lastPlacedLimitPrice) / _Point;
         else if(g_lastPlacedDirection < 0) deltaPts = (g_lastPlacedLimitPrice - dealPrice) / _Point;
      }
      Log(StringFormat("FILL entry price=%.2f vsLimit=%.1fpts commission=%.2f", dealPrice, deltaPts, commission));
      return;
   }

   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;

   double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
              + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
              + commission;
   g_lastExitMs = (long)HistoryDealGetInteger(trans.deal, DEAL_TIME_MSC);
   if(pnl < 0.0) g_consecutiveLosses++; else g_consecutiveLosses = 0;
   g_trackedPositionTicket = 0; g_peakProfitPoints = 0.0; g_breakEvenArmed = false;
   Log(StringFormat("EXIT pnl=%.2f consecutiveLosses=%d", pnl, g_consecutiveLosses));
}
//+------------------------------------------------------------------+
