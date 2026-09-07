//+------------------------------------------------------------------+
//| XAU_HyperScalper_V2.mq5                                         |
//| Demo-first XAUUSD tick/micro-breakout scalper for MetaTrader 5   |
//| Pending stop execution, rapid repricing, strict risk controls    |
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"
#property description "Demo-first XAUUSD tick-driven micro-breakout scalper using near-market pending stops and programmatic exits."

#include <Trade/Trade.mqh>

CTrade trade;

#define MAX_TICK_BUFFER 128

//--------------------------- Inputs ---------------------------------
input group "Safety"
input bool   InpDemoOnly                  = true;
input bool   InpEnableTrading             = true;
input long   InpMagicNumber               = 26090820;
input double InpRiskPerTradePct           = 0.10;   // percent of equity
input double InpMaxLots                   = 0.05;
input double InpDailyLossStopPct          = 2.00;
input int    InpMaxConsecutiveLosses      = 5;
input int    InpMaxTradesPerHour          = 60;
input int    InpCooldownAfterExitMs       = 750;
input int    InpMaxOpenPositions          = 1;

input group "Broker / Execution"
input int    InpMaxSpreadPoints           = 30;
input int    InpSlippagePoints            = 20;
input int    InpHardStopPoints            = 80;
input int    InpEntryOffsetPoints         = 8;
input int    InpRepriceThresholdPoints    = 5;
input int    InpPendingMaxAgeMs           = 1500;
input int    InpNoSignalCancelMs          = 750;
input int    InpMinOrderActionIntervalMs  = 250;

input group "Tick Momentum Signal"
input int    InpLookbackTicks             = 12;
input int    InpMinTickWindowMs           = 200;
input int    InpMaxTickWindowMs           = 1500;
input double InpMinMomentumPoints         = 5.0;
input double InpMinDirectionalRatio       = 0.60;
input double InpMinRecentMomentumPoints   = 2.0;

input group "Fast Exit Engine"
input int    InpProfitTargetPoints        = 45;
input int    InpTrailStartPoints          = 20;
input int    InpTrailGivebackPoints       = 8;
input int    InpMaxHoldSeconds            = 20;
input bool   InpExitOnMomentumReversal    = true;
input int    InpMinHoldBeforeReversalMs   = 300;

input group "Session Filter (broker server time)"
input bool   InpUseSessionFilter          = true;
input int    InpSessionStartHour          = 7;
input int    InpSessionStartMinute        = 0;
input int    InpSessionEndHour            = 22;
input int    InpSessionEndMinute          = 0;

input group "Diagnostics"
input bool   InpVerboseLogging            = true;
input int    InpHeartbeatSeconds          = 5;

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

int    g_consecutiveLosses = 0;
double g_dayStartEquity    = 0.0;
string g_dayEquityKey      = "";

//--------------------------- Logging --------------------------------
void Log(string text)
{
   if(InpVerboseLogging)
      Print("[XAU-HS2] ", text);
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
   string login = IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN));
   return StringFormat("XAUHS2_%s_%I64d_%04d%02d%02d", login, InpMagicNumber, dt.year, dt.mon, dt.day);
}

void RefreshDayStartEquity()
{
   string key = TodayKey();
   if(key == g_dayEquityKey && g_dayStartEquity > 0.0)
      return;

   g_dayEquityKey = key;

   // Keep Strategy Tester runs independent of terminal global variables.
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

   Log(StringFormat("Day-start equity guard: %.2f", g_dayStartEquity));
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
   if(!InpDemoOnly)
      return true;

   if(MQLInfoInteger(MQL_TESTER))
      return true;

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
   if(!InpUseSessionFilter)
      return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMin   = dt.hour * 60 + dt.min;
   int startMin = InpSessionStartHour * 60 + InpSessionStartMinute;
   int endMin   = InpSessionEndHour * 60 + InpSessionEndMinute;

   if(startMin <= endMin)
      return (nowMin >= startMin && nowMin <= endMin);

   return (nowMin >= startMin || nowMin <= endMin);
}

double CurrentSpreadPoints()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return 999999.0;
   return (tick.ask - tick.bid) / _Point;
}

bool IsSpreadOK()
{
   if(InpMaxSpreadPoints <= 0)
      return true;
   return (CurrentSpreadPoints() <= InpMaxSpreadPoints);
}

//--------------------------- Tick buffer -----------------------------
void PushTick(const MqlTick &tick)
{
   double mid = (tick.bid + tick.ask) * 0.5;
   g_tickMid[g_tickHead] = mid;
   g_tickMs[g_tickHead]  = tick.time_msc;
   g_tickHead = (g_tickHead + 1) % MAX_TICK_BUFFER;
   if(g_tickCount < MAX_TICK_BUFFER)
      g_tickCount++;
}

bool TickByOffset(int offset, double &mid, long &ms)
{
   if(offset < 0 || offset >= g_tickCount)
      return false;

   int idx = g_tickHead - 1 - offset;
   while(idx < 0) idx += MAX_TICK_BUFFER;
   idx %= MAX_TICK_BUFFER;

   mid = g_tickMid[idx];
   ms  = g_tickMs[idx];
   return true;
}

int TickSignal(double &netPts, double &dirRatio, long &ageMs, double &recentPts)
{
   netPts = 0.0;
   dirRatio = 0.0;
   ageMs = 0;
   recentPts = 0.0;

   if(g_tickCount < 4)
      return 0;

   int maxOffset = InpLookbackTicks - 1;
   if(maxOffset > g_tickCount - 1) maxOffset = g_tickCount - 1;
   if(maxOffset > MAX_TICK_BUFFER - 1) maxOffset = MAX_TICK_BUFFER - 1;
   if(maxOffset < 2) return 0;

   double latestMid = 0.0;
   long latestMs = 0;
   if(!TickByOffset(0, latestMid, latestMs))
      return 0;

   int chosen = -1;
   for(int off = 1; off <= maxOffset; ++off)
   {
      double oldMid = 0.0;
      long oldMs = 0;
      if(!TickByOffset(off, oldMid, oldMs))
         break;

      long age = latestMs - oldMs;
      if(age > InpMaxTickWindowMs)
         break;
      if(age >= InpMinTickWindowMs)
         chosen = off;
   }

   if(chosen < 2)
      return 0;

   double oldMid = 0.0;
   long oldMs = 0;
   TickByOffset(chosen, oldMid, oldMs);
   ageMs = latestMs - oldMs;
   netPts = (latestMid - oldMid) / _Point;

   int upMoves = 0;
   int downMoves = 0;
   int meaningfulMoves = 0;

   for(int off = chosen; off >= 1; --off)
   {
      double olderMid = 0.0, newerMid = 0.0;
      long olderMs = 0, newerMs = 0;
      TickByOffset(off, olderMid, olderMs);
      TickByOffset(off - 1, newerMid, newerMs);

      double dPts = (newerMid - olderMid) / _Point;
      if(dPts > 0.05)
      {
         upMoves++;
         meaningfulMoves++;
      }
      else if(dPts < -0.05)
      {
         downMoves++;
         meaningfulMoves++;
      }
   }

   if(meaningfulMoves <= 0)
      return 0;

   int halfOffset = chosen / 2;
   if(halfOffset < 1) halfOffset = 1;
   double halfMid = 0.0;
   long halfMs = 0;
   TickByOffset(halfOffset, halfMid, halfMs);
   recentPts = (latestMid - halfMid) / _Point;

   double upRatio = (double)upMoves / (double)meaningfulMoves;
   double downRatio = (double)downMoves / (double)meaningfulMoves;

   if(netPts >= InpMinMomentumPoints &&
      recentPts >= InpMinRecentMomentumPoints &&
      upRatio >= InpMinDirectionalRatio)
   {
      dirRatio = upRatio;
      return 1;
   }

   if(netPts <= -InpMinMomentumPoints &&
      recentPts <= -InpMinRecentMomentumPoints &&
      downRatio >= InpMinDirectionalRatio)
   {
      dirRatio = downRatio;
      return -1;
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
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      count++;
   }
   return count;
}

bool GetOurPosition(ulong &ticket, ENUM_POSITION_TYPE &type, double &openPrice, long &openMs)
{
   ticket = 0;
   openPrice = 0.0;
   openMs = 0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

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
   ticket = 0;
   price = 0.0;
   setupMs = 0;

   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;

      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot != ORDER_TYPE_BUY_STOP && ot != ORDER_TYPE_SELL_STOP)
         continue;

      ticket = t;
      type = ot;
      price = OrderGetDouble(ORDER_PRICE_OPEN);
      setupMs = (long)OrderGetInteger(ORDER_TIME_SETUP_MSC);
      return true;
   }
   return false;
}

bool CanOrderAction(long nowMs)
{
   if(g_lastOrderActionMs <= 0)
      return true;
   return ((nowMs - g_lastOrderActionMs) >= InpMinOrderActionIntervalMs);
}

bool DeletePending(ulong ticket, long nowMs, string reason)
{
   if(ticket == 0 || !CanOrderAction(nowMs))
      return false;

   trade.SetExpertMagicNumber(InpMagicNumber);
   if(trade.OrderDelete(ticket))
   {
      g_lastOrderActionMs = nowMs;
      Log("DELETE pending #" + IntegerToString((long)ticket) + " reason=" + reason);
      return true;
   }

   Log(StringFormat("Delete failed #%I64u ret=%u %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   g_lastOrderActionMs = nowMs;
   return false;
}

void DeleteAllPending(string reason)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP)
         continue;

      if(!CanOrderAction(tick.time_msc))
         return;
      DeletePending(ticket, tick.time_msc, reason);
   }
}

//--------------------------- Trade count / loss streak ---------------
int CountEntriesLastHour()
{
   datetime now = TimeCurrent();
   if(!HistorySelect(now - 3600, now))
      return 0;

   int count = 0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; ++i)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
         count++;
   }
   return count;
}

void RebuildLossStreak()
{
   g_consecutiveLosses = 0;
   g_lastExitMs = 0;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime dayStart = StructToTime(dt);

   if(!HistorySelect(dayStart, TimeCurrent()))
      return;

   for(int i = HistoryDealsTotal() - 1; i >= 0; --i)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
         continue;

      long tms = (long)HistoryDealGetInteger(deal, DEAL_TIME_MSC);
      if(g_lastExitMs == 0)
         g_lastExitMs = tms;

      double pnl = HistoryDealGetDouble(deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(deal, DEAL_SWAP)
                 + HistoryDealGetDouble(deal, DEAL_COMMISSION);

      if(pnl < 0.0)
         g_consecutiveLosses++;
      else
         break;
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

   if(lots < minLot)
      return 0.0;

   lots = MathMin(lots, maxLot);
   lots = MathMin(lots, InpMaxLots);
   lots = MathFloor(lots / step + 1e-9) * step;

   if(lots < minLot)
      return 0.0;

   int digits = 2;
   if(step >= 1.0) digits = 0;
   else if(step >= 0.1) digits = 1;
   else if(step >= 0.01) digits = 2;
   else digits = 3;

   return NormalizeDouble(lots, digits);
}

double LotsForRisk(int direction, double entryPrice, double stopPrice)
{
   if(direction == 0 || InpRiskPerTradePct <= 0.0)
      return 0.0;

   double lossOneLot = 0.0;
   ENUM_ORDER_TYPE calcType = (direction > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcProfit(calcType, _Symbol, 1.0, entryPrice, stopPrice, lossOneLot))
      return 0.0;

   lossOneLot = MathAbs(lossOneLot);
   if(lossOneLot <= 0.0)
      return 0.0;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPerTradePct / 100.0;
   return NormalizeVolumeFloor(riskMoney / lossOneLot);
}

//--------------------------- Pending engine --------------------------
bool PlacePending(int direction, const MqlTick &tick)
{
   if(direction == 0 || !CanOrderAction(tick.time_msc))
      return false;

   string gate = RiskGateReason(tick.time_msc);
   if(gate != "")
   {
      Log("Entry blocked: " + gate);
      return false;
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   int brokerGap = MathMax(stopsLevel, freezeLevel) + 2;
   int entryOffset = MathMax(InpEntryOffsetPoints, brokerGap);
   int stopPts = MathMax(InpHardStopPoints, stopsLevel + 2);

   double entry = 0.0;
   double sl = 0.0;

   if(direction > 0)
   {
      entry = NormalizeDouble(tick.ask + entryOffset * _Point, digits);
      sl    = NormalizeDouble(entry - stopPts * _Point, digits);
   }
   else
   {
      entry = NormalizeDouble(tick.bid - entryOffset * _Point, digits);
      sl    = NormalizeDouble(entry + stopPts * _Point, digits);
   }

   double lots = LotsForRisk(direction, entry, sl);
   if(lots <= 0.0)
   {
      Log("Entry blocked: risk size below broker minimum lot.");
      return false;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool sent = false;
   if(direction > 0)
      sent = trade.BuyStop(lots, entry, _Symbol, sl, 0.0, ORDER_TIME_GTC, 0, "XAU-HS2 BSTOP");
   else
      sent = trade.SellStop(lots, entry, _Symbol, sl, 0.0, ORDER_TIME_GTC, 0, "XAU-HS2 SSTOP");

   g_lastOrderActionMs = tick.time_msc;

   if(!sent)
   {
      Log(StringFormat("Pending failed dir=%s lots=%.3f entry=%.2f sl=%.2f ret=%u %s",
                       DirText(direction), lots, entry, sl, trade.ResultRetcode(), trade.ResultRetcodeDescription()));
      return false;
   }

   Log(StringFormat("PLACE %s STOP lots=%.3f entry=%.2f sl=%.2f spread=%.1f",
                    DirText(direction), lots, entry, sl, CurrentSpreadPoints()));
   return true;
}

void ManagePending(int signalDir, const MqlTick &tick)
{
   ulong ticket = 0;
   ENUM_ORDER_TYPE type = ORDER_TYPE_BUY_STOP;
   double price = 0.0;
   long setupMs = 0;
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
      PlacePending(signalDir, tick);
      return;
   }

   int pendingDir = (type == ORDER_TYPE_BUY_STOP ? 1 : -1);
   if(pendingDir != signalDir)
   {
      DeletePending(ticket, tick.time_msc, "direction-flip");
      return;
   }

   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   int brokerGap = MathMax(stopsLevel, freezeLevel) + 2;
   int entryOffset = MathMax(InpEntryOffsetPoints, brokerGap);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double desired = (signalDir > 0)
                    ? NormalizeDouble(tick.ask + entryOffset * _Point, digits)
                    : NormalizeDouble(tick.bid - entryOffset * _Point, digits);

   double driftPts = MathAbs(desired - price) / _Point;
   long age = tick.time_msc - setupMs;

   if(driftPts >= InpRepriceThresholdPoints || age >= InpPendingMaxAgeMs)
      DeletePending(ticket, tick.time_msc, (age >= InpPendingMaxAgeMs ? "age-reprice" : "price-reprice"));
}

//--------------------------- Exit engine -----------------------------
bool CloseOurPosition(ulong ticket, string reason)
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(trade.PositionClose(ticket))
   {
      Log("CLOSE #" + IntegerToString((long)ticket) + " reason=" + reason);
      return true;
   }

   Log(StringFormat("Close failed #%I64u ret=%u %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   return false;
}

void ManageOpenPosition(int signalDir, const MqlTick &tick)
{
   ulong ticket = 0;
   ENUM_POSITION_TYPE type = POSITION_TYPE_BUY;
   double openPrice = 0.0;
   long openMs = 0;

   if(!GetOurPosition(ticket, type, openPrice, openMs))
   {
      g_trackedPositionTicket = 0;
      g_peakProfitPoints = 0.0;
      return;
   }

   if(g_trackedPositionTicket != ticket)
   {
      g_trackedPositionTicket = ticket;
      g_peakProfitPoints = 0.0;
      Log("TRACK filled position #" + IntegerToString((long)ticket));
   }

   double profitPts = 0.0;
   if(type == POSITION_TYPE_BUY)
      profitPts = (tick.bid - openPrice) / _Point;
   else
      profitPts = (openPrice - tick.ask) / _Point;

   if(profitPts > g_peakProfitPoints)
      g_peakProfitPoints = profitPts;

   if(InpProfitTargetPoints > 0 && profitPts >= InpProfitTargetPoints)
   {
      CloseOurPosition(ticket, "profit-target");
      return;
   }

   if(InpTrailStartPoints > 0 && InpTrailGivebackPoints > 0 &&
      g_peakProfitPoints >= InpTrailStartPoints &&
      profitPts <= (g_peakProfitPoints - InpTrailGivebackPoints))
   {
      CloseOurPosition(ticket, "micro-trail");
      return;
   }

   long heldMs = tick.time_msc - openMs;
   if(InpMaxHoldSeconds > 0 && heldMs >= (long)InpMaxHoldSeconds * 1000)
   {
      CloseOurPosition(ticket, "time-exit");
      return;
   }

   if(InpExitOnMomentumReversal && heldMs >= InpMinHoldBeforeReversalMs && signalDir != 0)
   {
      if(type == POSITION_TYPE_BUY && signalDir < 0)
      {
         CloseOurPosition(ticket, "momentum-reversal");
         return;
      }
      if(type == POSITION_TYPE_SELL && signalDir > 0)
      {
         CloseOurPosition(ticket, "momentum-reversal");
         return;
      }
   }
}

//--------------------------- Diagnostics -----------------------------
void Heartbeat(const MqlTick &tick, int signalDir, double netPts, double ratio, long ageMs, double recentPts)
{
   if(!InpVerboseLogging || InpHeartbeatSeconds <= 0)
      return;

   if(g_lastHeartbeatMs > 0 && (tick.time_msc - g_lastHeartbeatMs) < (long)InpHeartbeatSeconds * 1000)
      return;

   g_lastHeartbeatMs = tick.time_msc;

   ulong pticket = 0;
   ENUM_POSITION_TYPE ptype = POSITION_TYPE_BUY;
   double popen = 0.0;
   long pms = 0;
   bool hasPos = GetOurPosition(pticket, ptype, popen, pms);

   ulong oticket = 0;
   ENUM_ORDER_TYPE otype = ORDER_TYPE_BUY_STOP;
   double oprice = 0.0;
   long oms = 0;
   bool hasPending = GetOurPending(oticket, otype, oprice, oms);

   string state = hasPos ? "POSITION" : (hasPending ? "PENDING" : "FLAT");
   string gate = RiskGateReason(tick.time_msc);
   if(gate == "") gate = "OK";

   Log(StringFormat("HB state=%s sig=%s net=%.1f recent=%.1f ratio=%.2f age=%I64dms spread=%.1f gate=%s",
                    state, DirText(signalDir), netPts, recentPts, ratio, ageMs, CurrentSpreadPoints(), gate));
}

//--------------------------- MT5 events ------------------------------
int OnInit()
{
   if(InpRiskPerTradePct <= 0.0 || InpRiskPerTradePct > 1.0)
   {
      Print("[XAU-HS2] Risk per trade must be >0 and <=1.0%.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpLookbackTicks < 4 || InpLookbackTicks > MAX_TICK_BUFFER ||
      InpMinTickWindowMs <= 0 || InpMaxTickWindowMs <= InpMinTickWindowMs ||
      InpMinDirectionalRatio < 0.50 || InpMinDirectionalRatio > 1.0)
   {
      Print("[XAU-HS2] Invalid tick signal configuration.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpHardStopPoints <= 0 || InpEntryOffsetPoints <= 0)
   {
      Print("[XAU-HS2] Hard stop and entry offset must be positive.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!IsDemoAllowed())
   {
      Print("[XAU-HS2] Demo-only guard blocked initialization on a real account.");
      return INIT_FAILED;
   }

   if(!IsFullTradeSymbol())
   {
      Print("[XAU-HS2] Symbol is not FULL ACCESS. Use a fully tradable symbol such as XAUUSD.a if your broker requires it.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   RefreshDayStartEquity();
   RebuildLossStreak();

   Log(StringFormat("Initialized V2 on %s. Tick-driven pending-stop engine. risk=%.2f%% maxTrades/hr=%d",
                    _Symbol, InpRiskPerTradePct, InpMaxTradesPerHour));
   Log("Warm-up is tick based only; normally a few seconds, not several minutes.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   DeleteAllPending("ea-deinit");
}

void OnTick()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   RefreshDayStartEquity();
   PushTick(tick);

   double netPts = 0.0;
   double ratio = 0.0;
   long ageMs = 0;
   double recentPts = 0.0;
   int signalDir = TickSignal(netPts, ratio, ageMs, recentPts);

   if(CountOurOpenPositions() > 0)
   {
      DeleteAllPending("position-open");
      ManageOpenPosition(signalDir, tick);
      Heartbeat(tick, signalDir, netPts, ratio, ageMs, recentPts);
      return;
   }

   g_trackedPositionTicket = 0;
   g_peakProfitPoints = 0.0;

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
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if((long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber)
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
      return;

   double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
              + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
              + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   g_lastExitMs = (long)HistoryDealGetInteger(trans.deal, DEAL_TIME_MSC);
   if(pnl < 0.0)
      g_consecutiveLosses++;
   else
      g_consecutiveLosses = 0;

   g_trackedPositionTicket = 0;
   g_peakProfitPoints = 0.0;

   Log(StringFormat("EXIT pnl=%.2f consecutiveLosses=%d", pnl, g_consecutiveLosses));
}
