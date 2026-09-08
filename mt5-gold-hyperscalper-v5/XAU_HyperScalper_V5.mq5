//+------------------------------------------------------------------+
//| XAU_HyperScalper_V5.mq5                                         |
//| Continuous two-sided passive micro-maker for MetaTrader 5       |
//| Tick-flow skew + rapid quote refresh + strict demo risk guards   |
//+------------------------------------------------------------------+
#property strict
#property version   "5.00"
#property description "Demo-first XAUUSD continuous passive two-sided quoting engine with tick-flow skew and server-side protection."

#include <Trade/Trade.mqh>
CTrade trade;

#define MAX_TICKS 128

input group "Safety"
input bool   InpDemoOnly                    = true;
input bool   InpEnableTrading               = true;
input long   InpMagicNumber                 = 26090850;
input double InpLots                        = 0.01;
input double InpMaxEffectiveRiskPct         = 0.25;
input double InpDailyLossStopPct            = 1.50;
input int    InpMaxConsecutiveLosses        = 6;
input int    InpMaxTradesPerHour            = 180;
input int    InpCooldownAfterExitMs         = 250;
input int    InpMaxOpenPositions            = 1;

input group "Continuous Quote Engine"
input int    InpMaxSpreadPoints             = 18;
input int    InpMinQuoteDistancePoints      = 3;
input int    InpMaxQuoteDistancePoints      = 18;
input double InpQuoteSpreadFraction         = 0.30;
input double InpVolatilityQuoteFactor       = 1.25;
input int    InpFlowSkewMaxPoints           = 8;
input int    InpRequoteThresholdPoints      = 3;
input int    InpQuoteMaxAgeMs               = 1500;
input int    InpQuoteCycleMs                = 350;

input group "Tick Flow"
input int    InpFlowLookbackTicks           = 20;
input double InpMeaningfulMovePoints        = 0.25;
input double InpAdverseFlowExit             = 0.70;
input int    InpMinHoldBeforeFlowExitMs     = 500;

input group "Target / Stop"
input int    InpMinTargetPoints             = 35;
input int    InpMaxTargetPoints             = 90;
input double InpTargetSpreadMultiple        = 3.20;
input double InpTargetMicroVolMultiple      = 10.0;
input int    InpMinStopPoints               = 70;
input int    InpMaxStopPoints               = 140;
input double InpStopToTargetMultiple        = 1.80;
input double InpStopMicroVolMultiple        = 18.0;

input group "Position Management"
input double InpBreakEvenTargetFraction     = 0.55;
input int    InpBreakEvenLockPoints         = 2;
input double InpTrailTargetFraction         = 0.80;
input int    InpTrailDistancePoints         = 14;
input int    InpMinModifyIntervalMs         = 400;
input int    InpMaxHoldSeconds              = 18;

input group "Diagnostics"
input bool   InpVerboseLogging              = true;
input int    InpHeartbeatSeconds            = 3;

//--------------------------- State ----------------------------------
double g_mid[MAX_TICKS];
long   g_ms[MAX_TICKS];
int    g_count = 0;
int    g_head = 0;
long   g_lastQuoteCycleMs = 0;
long   g_lastExitMs = 0;
long   g_lastModifyMs = 0;
long   g_lastHeartbeatMs = 0;
int    g_consecutiveLosses = 0;
double g_dayStartEquity = 0.0;
string g_dayKey = "";
ulong  g_trackedPosition = 0;
double g_peakProfitPts = 0.0;
double g_positionTargetPts = 0.0;

void Log(const string s)
{
   if(InpVerboseLogging) Print("[XAU-HS5] ", s);
}

string TodayKey()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   long login = (long)AccountInfoInteger(ACCOUNT_LOGIN);
   return StringFormat("XAUHS5_%I64d_%I64d_%04d%02d%02d", login, InpMagicNumber, dt.year, dt.mon, dt.day);
}

void RefreshDayStartEquity()
{
   string k = TodayKey();
   if(k == g_dayKey && g_dayStartEquity > 0.0) return;
   g_dayKey = k;
   if(MQLInfoInteger(MQL_TESTER))
   {
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      return;
   }
   if(GlobalVariableCheck(k)) g_dayStartEquity = GlobalVariableGet(k);
   else
   {
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      GlobalVariableSet(k, g_dayStartEquity);
   }
   Log(StringFormat("Day-start equity %.2f", g_dayStartEquity));
}

bool DailyLossOK()
{
   RefreshDayStartEquity();
   if(InpDailyLossStopPct <= 0.0 || g_dayStartEquity <= 0.0) return true;
   double floorEq = g_dayStartEquity * (1.0 - InpDailyLossStopPct / 100.0);
   return AccountInfoDouble(ACCOUNT_EQUITY) > floorEq;
}

bool IsDemoAllowed()
{
   if(!InpDemoOnly || MQLInfoInteger(MQL_TESTER)) return true;
   ENUM_ACCOUNT_TRADE_MODE m = (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
   return (m == ACCOUNT_TRADE_MODE_DEMO || m == ACCOUNT_TRADE_MODE_CONTEST);
}

bool IsFullTradeSymbol()
{
   return ((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_FULL);
}

double SpreadPts()
{
   MqlTick t; if(!SymbolInfoTick(_Symbol, t)) return 999999.0;
   return (t.ask - t.bid) / _Point;
}

void PushTick(const MqlTick &t)
{
   g_mid[g_head] = (t.bid + t.ask) * 0.5;
   g_ms[g_head] = t.time_msc;
   g_head = (g_head + 1) % MAX_TICKS;
   if(g_count < MAX_TICKS) g_count++;
}

bool TickAt(const int offset, double &mid, long &ms)
{
   if(offset < 0 || offset >= g_count) return false;
   int idx = g_head - 1 - offset;
   while(idx < 0) idx += MAX_TICKS;
   idx %= MAX_TICKS;
   mid = g_mid[idx]; ms = g_ms[idx];
   return true;
}

void MicroStats(double &flow, double &microVolPts, double &netPts)
{
   flow = 0.0; microVolPts = 0.0; netPts = 0.0;
   if(g_count < 4) return;

   int n = MathMin(InpFlowLookbackTicks, g_count - 1);
   if(n < 3) return;

   double newest = 0.0, oldest = 0.0; long dummy = 0;
   TickAt(0, newest, dummy);
   TickAt(n, oldest, dummy);
   netPts = (newest - oldest) / _Point;

   double signedAbs = 0.0;
   double totalAbs = 0.0;
   int meaningful = 0;
   for(int off = n; off >= 1; --off)
   {
      double a = 0.0, b = 0.0; long t1 = 0, t2 = 0;
      TickAt(off, a, t1);
      TickAt(off - 1, b, t2);
      double d = (b - a) / _Point;
      if(MathAbs(d) < InpMeaningfulMovePoints) continue;
      double w = 1.0 + 0.75 * (1.0 - (double)(off - 1) / (double)n); // recent ticks weigh more
      signedAbs += (d > 0.0 ? 1.0 : -1.0) * MathAbs(d) * w;
      totalAbs += MathAbs(d) * w;
      microVolPts += MathAbs(d);
      meaningful++;
   }

   if(meaningful > 0) microVolPts /= (double)meaningful;
   if(totalAbs > 0.0) flow = signedAbs / totalAbs;
   flow = MathMax(-1.0, MathMin(1.0, flow));
}

int CountOurPositions()
{
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      c++;
   }
   return c;
}

bool GetOurPosition(ulong &ticket, ENUM_POSITION_TYPE &type, double &openPrice, double &sl, double &tp, long &openMs)
{
   ticket = 0; openPrice = 0.0; sl = 0.0; tp = 0.0; openMs = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      ticket = tk;
      type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      sl = PositionGetDouble(POSITION_SL);
      tp = PositionGetDouble(POSITION_TP);
      openMs = (long)PositionGetInteger(POSITION_TIME_MSC);
      return true;
   }
   return false;
}

bool FindPending(const ENUM_ORDER_TYPE wanted, ulong &ticket, double &price, long &setupMs)
{
   ticket = 0; price = 0.0; setupMs = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      ENUM_ORDER_TYPE ty = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ty != wanted) continue;
      ticket = tk;
      price = OrderGetDouble(ORDER_PRICE_OPEN);
      setupMs = (long)OrderGetInteger(ORDER_TIME_SETUP_MSC);
      return true;
   }
   return false;
}

bool DeletePending(const ulong ticket, const string reason)
{
   if(ticket == 0) return false;
   trade.SetExpertMagicNumber(InpMagicNumber);
   bool ok = trade.OrderDelete(ticket);
   if(ok) Log(StringFormat("DELETE #%I64u reason=%s", ticket, reason));
   else Log(StringFormat("Delete failed #%I64u ret=%u %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   return ok;
}

void DeleteAllPending(const string reason)
{
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      ENUM_ORDER_TYPE ty = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ty != ORDER_TYPE_BUY_LIMIT && ty != ORDER_TYPE_SELL_LIMIT) continue;
      DeletePending(tk, reason);
   }
}

int CountEntriesLastHour()
{
   datetime now = TimeCurrent();
   if(!HistorySelect(now - 3600, now)) return 0;
   int c = 0;
   for(int i = 0; i < HistoryDealsTotal(); ++i)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if((long)HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagicNumber) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      ENUM_DEAL_ENTRY e = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY);
      if(e == DEAL_ENTRY_IN || e == DEAL_ENTRY_INOUT) c++;
   }
   return c;
}

void RebuildLossStreak()
{
   g_consecutiveLosses = 0; g_lastExitMs = 0;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt); dt.hour=0; dt.min=0; dt.sec=0;
   if(!HistorySelect(StructToTime(dt), TimeCurrent())) return;
   for(int i = HistoryDealsTotal() - 1; i >= 0; --i)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if((long)HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagicNumber) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      ENUM_DEAL_ENTRY e = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY);
      if(e != DEAL_ENTRY_OUT && e != DEAL_ENTRY_OUT_BY && e != DEAL_ENTRY_INOUT) continue;
      if(g_lastExitMs == 0) g_lastExitMs = (long)HistoryDealGetInteger(d, DEAL_TIME_MSC);
      double pnl = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION);
      if(pnl < 0.0) g_consecutiveLosses++; else break;
   }
}

string GateReason(const long nowMs)
{
   if(!InpEnableTrading) return "disabled";
   if(!IsDemoAllowed()) return "demo-only";
   if(!IsFullTradeSymbol()) return "symbol-access";
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return "terminal-algo";
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return "ea-algo";
   if(SpreadPts() > InpMaxSpreadPoints) return "spread";
   if(!DailyLossOK()) return "daily-loss";
   if(InpMaxConsecutiveLosses > 0 && g_consecutiveLosses >= InpMaxConsecutiveLosses) return "loss-streak";
   if(InpMaxTradesPerHour > 0 && CountEntriesLastHour() >= InpMaxTradesPerHour) return "hour-cap";
   if(InpCooldownAfterExitMs > 0 && g_lastExitMs > 0 && (nowMs - g_lastExitMs) < InpCooldownAfterExitMs) return "cooldown";
   if(CountOurPositions() >= InpMaxOpenPositions) return "position";
   return "";
}

void ComputeTargetStop(const double spread, const double microVol, int &targetPts, int &stopPts)
{
   double t = MathMax((double)InpMinTargetPoints, spread * InpTargetSpreadMultiple);
   t = MathMax(t, microVol * InpTargetMicroVolMultiple);
   t = MathMin(t, (double)InpMaxTargetPoints);
   targetPts = (int)MathCeil(t);

   double s = MathMax((double)InpMinStopPoints, t * InpStopToTargetMultiple);
   s = MathMax(s, microVol * InpStopMicroVolMultiple);
   s = MathMin(s, (double)InpMaxStopPoints);
   stopPts = (int)MathCeil(s);
}

bool EffectiveRiskOK(const int direction, const double entry, const double stop, const double lots)
{
   double loss = 0.0;
   ENUM_ORDER_TYPE ty = (direction > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcProfit(ty, _Symbol, lots, entry, stop, loss)) return false;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= 0.0) return false;
   double pct = MathAbs(loss) / eq * 100.0;
   if(pct > InpMaxEffectiveRiskPct)
   {
      Log(StringFormat("RISK BLOCK dir=%d risk=%.3f%% cap=%.3f%%", direction, pct, InpMaxEffectiveRiskPct));
      return false;
   }
   return true;
}

bool PlaceQuote(const int direction, const double price, const int targetPts, const int stopPts)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double entry = NormalizeDouble(price, digits);
   double sl = (direction > 0 ? entry - stopPts * _Point : entry + stopPts * _Point);
   double tp = (direction > 0 ? entry + targetPts * _Point : entry - targetPts * _Point);
   sl = NormalizeDouble(sl, digits); tp = NormalizeDouble(tp, digits);

   if(!EffectiveRiskOK(direction, entry, sl, InpLots)) return false;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   bool sent = false;
   if(direction > 0)
      sent = trade.BuyLimit(InpLots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "XAU-HS5 BID");
   else
      sent = trade.SellLimit(InpLots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "XAU-HS5 ASK");

   if(sent)
      Log(StringFormat("QUOTE %s lots=%.2f entry=%.2f sl=%.2f tp=%.2f", direction>0?"BUY":"SELL", InpLots, entry, sl, tp));
   else
      Log(StringFormat("Quote failed %s ret=%u %s", direction>0?"BUY":"SELL", trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   return sent;
}

void ManageQuotes(const MqlTick &tick, const double flow, const double microVol)
{
   if(g_lastQuoteCycleMs > 0 && (tick.time_msc - g_lastQuoteCycleMs) < InpQuoteCycleMs) return;
   g_lastQuoteCycleMs = tick.time_msc;

   string gate = GateReason(tick.time_msc);
   if(gate != "")
   {
      DeleteAllPending("gate-" + gate);
      return;
   }

   double spread = SpreadPts();
   int brokerGap = MathMax((int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                           (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)) + 2;

   double base = MathMax((double)InpMinQuoteDistancePoints, spread * InpQuoteSpreadFraction + microVol * InpVolatilityQuoteFactor);
   base = MathMin(base, (double)InpMaxQuoteDistancePoints);

   double skew = flow * InpFlowSkewMaxPoints;
   double buyDist = MathMax((double)brokerGap, base - skew);
   double sellDist = MathMax((double)brokerGap, base + skew);
   buyDist = MathMin(buyDist, (double)InpMaxQuoteDistancePoints);
   sellDist = MathMin(sellDist, (double)InpMaxQuoteDistancePoints);

   int targetPts = 0, stopPts = 0;
   ComputeTargetStop(spread, microVol, targetPts, stopPts);
   stopPts = MathMax(stopPts, brokerGap + 2);

   double desiredBuy = NormalizeDouble(tick.bid - buyDist * _Point, _Digits);
   double desiredSell = NormalizeDouble(tick.ask + sellDist * _Point, _Digits);

   ulong buyTk=0, sellTk=0; double buyPrice=0.0, sellPrice=0.0; long buyMs=0, sellMs=0;
   bool hasBuy = FindPending(ORDER_TYPE_BUY_LIMIT, buyTk, buyPrice, buyMs);
   bool hasSell = FindPending(ORDER_TYPE_SELL_LIMIT, sellTk, sellPrice, sellMs);

   if(hasBuy)
   {
      double drift = MathAbs(desiredBuy - buyPrice) / _Point;
      long age = tick.time_msc - buyMs;
      if(drift >= InpRequoteThresholdPoints || age >= InpQuoteMaxAgeMs)
      {
         DeletePending(buyTk, drift >= InpRequoteThresholdPoints ? "buy-drift" : "buy-age");
         hasBuy = false;
      }
   }
   if(hasSell)
   {
      double drift = MathAbs(desiredSell - sellPrice) / _Point;
      long age = tick.time_msc - sellMs;
      if(drift >= InpRequoteThresholdPoints || age >= InpQuoteMaxAgeMs)
      {
         DeletePending(sellTk, drift >= InpRequoteThresholdPoints ? "sell-drift" : "sell-age");
         hasSell = false;
      }
   }

   if(!hasBuy) PlaceQuote(1, desiredBuy, targetPts, stopPts);
   if(!hasSell) PlaceQuote(-1, desiredSell, targetPts, stopPts);
}

bool CloseOurPosition(const ulong ticket, const string reason)
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(20);
   bool ok = trade.PositionClose(ticket);
   if(ok) Log(StringFormat("CLOSE #%I64u reason=%s", ticket, reason));
   else Log(StringFormat("Close failed #%I64u ret=%u %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   return ok;
}

bool ModifyOurPosition(const ulong ticket, const double newSL, const double tp, const long nowMs, const string reason)
{
   if(g_lastModifyMs > 0 && (nowMs - g_lastModifyMs) < InpMinModifyIntervalMs) return false;
   trade.SetExpertMagicNumber(InpMagicNumber);
   bool ok = trade.PositionModify(ticket, NormalizeDouble(newSL, _Digits), tp);
   g_lastModifyMs = nowMs;
   if(ok) Log(StringFormat("MODIFY #%I64u SL=%.2f reason=%s", ticket, newSL, reason));
   return ok;
}

void ManagePosition(const MqlTick &tick, const double flow)
{
   ulong tk=0; ENUM_POSITION_TYPE ty=POSITION_TYPE_BUY; double open=0.0, sl=0.0, tp=0.0; long openMs=0;
   if(!GetOurPosition(tk, ty, open, sl, tp, openMs))
   {
      g_trackedPosition=0; g_peakProfitPts=0.0; g_positionTargetPts=0.0; return;
   }

   if(g_trackedPosition != tk)
   {
      g_trackedPosition = tk;
      g_peakProfitPts = 0.0;
      g_positionTargetPts = (tp > 0.0 ? MathAbs(tp - open) / _Point : (double)InpMinTargetPoints);
      Log(StringFormat("TRACK #%I64u type=%s open=%.2f target=%.1f", tk, ty==POSITION_TYPE_BUY?"BUY":"SELL", open, g_positionTargetPts));
   }

   double profitPts = (ty==POSITION_TYPE_BUY ? (tick.bid-open)/_Point : (open-tick.ask)/_Point);
   if(profitPts > g_peakProfitPts) g_peakProfitPts = profitPts;
   long heldMs = tick.time_msc - openMs;

   if(InpBreakEvenTargetFraction > 0.0 && profitPts >= g_positionTargetPts * InpBreakEvenTargetFraction)
   {
      double be = (ty==POSITION_TYPE_BUY ? open + InpBreakEvenLockPoints*_Point : open - InpBreakEvenLockPoints*_Point);
      bool improves = (ty==POSITION_TYPE_BUY ? (sl<=0.0 || be>sl) : (sl<=0.0 || be<sl));
      if(improves) ModifyOurPosition(tk, be, tp, tick.time_msc, "break-even");
   }

   if(InpTrailTargetFraction > 0.0 && g_peakProfitPts >= g_positionTargetPts * InpTrailTargetFraction)
   {
      double trail = (ty==POSITION_TYPE_BUY ? tick.bid - InpTrailDistancePoints*_Point : tick.ask + InpTrailDistancePoints*_Point);
      bool improves = (ty==POSITION_TYPE_BUY ? (sl<=0.0 || trail>sl) : (sl<=0.0 || trail<sl));
      if(improves) ModifyOurPosition(tk, trail, tp, tick.time_msc, "micro-trail");
   }

   if(heldMs >= InpMinHoldBeforeFlowExitMs)
   {
      if(ty==POSITION_TYPE_BUY && flow <= -InpAdverseFlowExit) { CloseOurPosition(tk, "adverse-flow"); return; }
      if(ty==POSITION_TYPE_SELL && flow >= InpAdverseFlowExit) { CloseOurPosition(tk, "adverse-flow"); return; }
   }

   if(InpMaxHoldSeconds > 0 && heldMs >= (long)InpMaxHoldSeconds * 1000)
   {
      CloseOurPosition(tk, "time-exit"); return;
   }
}

void Heartbeat(const MqlTick &tick, const double flow, const double microVol, const double netPts)
{
   if(!InpVerboseLogging || InpHeartbeatSeconds <= 0) return;
   if(g_lastHeartbeatMs > 0 && (tick.time_msc - g_lastHeartbeatMs) < (long)InpHeartbeatSeconds*1000) return;
   g_lastHeartbeatMs = tick.time_msc;
   ulong b=0,s=0; double bp=0.0,sp=0.0; long bm=0,sm=0;
   bool hb = FindPending(ORDER_TYPE_BUY_LIMIT,b,bp,bm);
   bool hs = FindPending(ORDER_TYPE_SELL_LIMIT,s,sp,sm);
   string gate = GateReason(tick.time_msc); if(gate=="") gate="OK";
   Log(StringFormat("HB state=%s flow=%.2f microVol=%.2f net=%.1f spread=%.1f bidQ=%s askQ=%s gate=%s",
                    CountOurPositions()>0?"POSITION":"QUOTING", flow, microVol, netPts, SpreadPts(), hb?"ON":"OFF", hs?"ON":"OFF", gate));
}

int OnInit()
{
   if(!IsDemoAllowed()) { Print("[XAU-HS5] Demo-only guard blocked real account."); return INIT_FAILED; }
   if(!IsFullTradeSymbol()) { Print("[XAU-HS5] Symbol is not FULL ACCESS."); return INIT_FAILED; }
   if(InpLots <= 0.0) return INIT_PARAMETERS_INCORRECT;
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   RefreshDayStartEquity();
   RebuildLossStreak();
   Log(StringFormat("Initialized V5 on %s. CONTINUOUS MICRO-MAKER lots=%.2f maxTrades/hr=%d", _Symbol, InpLots, InpMaxTradesPerHour));
   Log("Logic: always-on two-sided LIMIT quotes -> tick-flow skew -> sibling cancel on fill -> server SL/TP -> fast re-quote.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   DeleteAllPending("ea-deinit");
}

void OnTick()
{
   MqlTick tick; if(!SymbolInfoTick(_Symbol, tick)) return;
   RefreshDayStartEquity();
   PushTick(tick);

   double flow=0.0, microVol=0.0, netPts=0.0;
   MicroStats(flow, microVol, netPts);

   if(CountOurPositions() > 0)
   {
      DeleteAllPending("position-open");
      ManagePosition(tick, flow);
      Heartbeat(tick, flow, microVol, netPts);
      return;
   }

   g_trackedPosition=0; g_peakProfitPts=0.0; g_positionTargetPts=0.0;
   ManageQuotes(tick, flow, microVol);
   Heartbeat(tick, flow, microVol, netPts);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if((long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;

   ENUM_DEAL_ENTRY e = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(e == DEAL_ENTRY_IN || e == DEAL_ENTRY_INOUT)
   {
      DeleteAllPending("sibling-fill");
      return;
   }
   if(e != DEAL_ENTRY_OUT && e != DEAL_ENTRY_OUT_BY) return;

   double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
              + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
              + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   g_lastExitMs = (long)HistoryDealGetInteger(trans.deal, DEAL_TIME_MSC);
   if(pnl < 0.0) g_consecutiveLosses++; else g_consecutiveLosses=0;
   g_trackedPosition=0; g_peakProfitPts=0.0; g_positionTargetPts=0.0;
   Log(StringFormat("EXIT pnl=%.2f lossStreak=%d", pnl, g_consecutiveLosses));
}
//+------------------------------------------------------------------+
