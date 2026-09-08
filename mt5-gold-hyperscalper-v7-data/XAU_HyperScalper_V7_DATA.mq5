//+------------------------------------------------------------------+
//| XAU_HyperScalper_V7_DATA.mq5                                    |
//| Data logger for evidence-driven XAUUSD high-frequency research   |
//| No trading. Records V6-style breakout candidates + future paths. |
//+------------------------------------------------------------------+
#property strict
#property version   "7.00"
#property description "Research-only XAUUSD signal logger. Records V6-style tick breakout features and 1/3/5/10/20 second forward outcomes to CSV."

#define TICK_BUF 512
#define MAX_OBS  512

input group "V6 FAST_QUALITY candidate engine"
input int    InpRangeLookbackBars           = 2;
input int    InpMinRangePoints              = 70;
input int    InpMaxRangePoints              = 450;
input int    InpBreakoutBufferPoints        = 8;
input int    InpMaxChasePoints              = 45;
input int    InpSignalValidTicks            = 60;
input int    InpBurstTicks                  = 3;
input double InpBurstMinPoints              = 5.0;
input double InpMinVelocityPointsPerSec     = 7.0;
input int    InpMomentumWindowTicks         = 10;
input double InpMinMomentumNetPoints        = 9.0;
input double InpMinTickBias                 = 0.60;
input double InpMinPressurePct              = 25.0;
input int    InpMaxSpreadPoints             = 18;
input int    InpCandidateCooldownMs         = 500;
input int    InpSameDirectionPauseMs        = 1500;

input group "Extra research features"
input int    InpAtrPeriod                   = 14;
input int    InpStatsWindow2                = 20;
input int    InpStatsWindow3                = 32;

input group "CSV output"
input string InpCsvFileName                 = "XAU_V7_SIGNALS.csv";
input bool   InpOverwriteCsv                = true;
input int    InpFlushEveryRows              = 250;
input bool   InpVerboseLogging              = false;
input int    InpProgressEverySignals        = 1000;

struct Observation
{
   bool     active;
   long     id;
   long     signal_ms;
   datetime signal_time;
   int      dir;

   double bid0;
   double ask0;
   double spread_pts;

   double range_width;
   double range_hi;
   double range_lo;
   double breakout_level;
   double chase;

   double burst;
   double velocity;

   double mom10;
   double bias10;
   double pressure10;
   double mom20;
   double bias20;
   double pressure20;
   double mom32;
   double bias32;
   double pressure32;
   double tick_range32;
   double avg_abs_delta32;
   double atr_m1;

   double mfe;
   double mae;

   bool h1;
   bool h3;
   bool h5;
   bool h10;
   bool h20;

   double move1;
   double mfe1;
   double mae1;
   double move3;
   double mfe3;
   double mae3;
   double move5;
   double mfe5;
   double mae5;
   double move10;
   double mfe10;
   double mae10;
   double move20;
   double mfe20;
   double mae20;
};

double g_bid[TICK_BUF];
long   g_ms[TICK_BUF];
int    g_count=0;
int    g_head=0;
long   g_tickSerial=0;

int    g_armDir=0;
double g_breakoutLevel=0.0;
long   g_armSerial=0;

long   g_lastSignalMs=0;
long   g_lastBuySignalMs=0;
long   g_lastSellSignalMs=0;
long   g_nextId=1;
long   g_signalsCreated=0;
long   g_rowsWritten=0;
long   g_droppedObservations=0;

Observation g_obs[MAX_OBS];
int g_atrM1=INVALID_HANDLE;
int g_file=INVALID_HANDLE;

void Log(const string s)
{
   if(InpVerboseLogging) Print("[XAU-V7-DATA] ",s);
}

string DirText(const int d)
{
   if(d>0) return "BUY";
   if(d<0) return "SELL";
   return "NONE";
}

void PushBid(const MqlTick &t)
{
   g_bid[g_head]=t.bid;
   g_ms[g_head]=t.time_msc;
   g_head=(g_head+1)%TICK_BUF;
   if(g_count<TICK_BUF) g_count++;
   g_tickSerial++;
}

bool TickAt(const int offset,double &bid,long &ms)
{
   if(offset<0 || offset>=g_count) return false;
   int idx=g_head-1-offset;
   while(idx<0) idx+=TICK_BUF;
   idx%=TICK_BUF;
   bid=g_bid[idx];
   ms=g_ms[idx];
   return true;
}

bool GetRange(double &hi,double &lo,double &widthPts)
{
   hi=-DBL_MAX;
   lo= DBL_MAX;
   widthPts=0.0;
   if(InpRangeLookbackBars<1) return false;

   for(int s=1;s<=InpRangeLookbackBars;s++)
   {
      double h=iHigh(_Symbol,PERIOD_M1,s);
      double l=iLow(_Symbol,PERIOD_M1,s);
      if(h<=0.0 || l<=0.0 || h<=l) return false;
      if(h>hi) hi=h;
      if(l<lo) lo=l;
   }

   widthPts=(hi-lo)/_Point;
   return (widthPts>=InpMinRangePoints && widthPts<=InpMaxRangePoints);
}

bool BurstConfirm(const int dir,double &burstPts,double &velocity)
{
   burstPts=0.0;
   velocity=0.0;
   if(InpBurstTicks<2 || g_count<InpBurstTicks) return false;

   double newest=0.0,oldest=0.0;
   long newestMs=0,oldestMs=0;
   if(!TickAt(0,newest,newestMs)) return false;
   if(!TickAt(InpBurstTicks-1,oldest,oldestMs)) return false;

   for(int off=InpBurstTicks-1;off>=1;off--)
   {
      double a=0.0,b=0.0;
      long ta=0,tb=0;
      if(!TickAt(off,a,ta) || !TickAt(off-1,b,tb)) return false;
      if(dir>0 && b<=a) return false;
      if(dir<0 && b>=a) return false;
   }

   burstPts=(dir>0 ? newest-oldest : oldest-newest)/_Point;
   long dt=newestMs-oldestMs;
   if(dt<=0) return false;
   velocity=burstPts/((double)dt/1000.0);
   return (burstPts>=InpBurstMinPoints && velocity>=InpMinVelocityPointsPerSec);
}

bool DirectionalStats(const int n,const int dir,double &netPts,double &bias,double &pressure,double &rangePts,double &avgAbsDeltaPts)
{
   netPts=0.0;
   bias=0.0;
   pressure=0.0;
   rangePts=0.0;
   avgAbsDeltaPts=0.0;

   if(n<3 || g_count<n) return false;

   double newest=0.0,oldest=0.0;
   long tn=0,to=0;
   if(!TickAt(0,newest,tn) || !TickAt(n-1,oldest,to)) return false;

   double rawNet=(newest-oldest)/_Point;
   netPts=(dir>0 ? rawNet : -rawNet);

   int up=0,down=0,meaningful=0;
   double hi=-DBL_MAX,lo=DBL_MAX;
   double absSum=0.0;

   for(int off=n-1;off>=0;off--)
   {
      double p=0.0;
      long tm=0;
      if(!TickAt(off,p,tm)) return false;
      if(p>hi) hi=p;
      if(p<lo) lo=p;

      if(off>=1)
      {
         double q=0.0;
         long tq=0;
         if(!TickAt(off-1,q,tq)) return false;
         double d=(q-p)/_Point;
         absSum+=MathAbs(d);
         if(d>0.0){up++;meaningful++;}
         else if(d<0.0){down++;meaningful++;}
      }
   }

   if(meaningful<=0) return false;
   double upBias=(double)up/(double)meaningful;
   double dnBias=(double)down/(double)meaningful;
   bias=(dir>0 ? upBias : dnBias);
   pressure=100.0*MathAbs((double)(up-down))/(double)meaningful;
   rangePts=(hi-lo)/_Point;
   avgAbsDeltaPts=absSum/(double)(n-1);
   return true;
}

bool CoreMomentumConfirm(const int dir,double &net,double &bias,double &pressure)
{
   double rangePts=0.0,avgAbs=0.0;
   if(!DirectionalStats(InpMomentumWindowTicks,dir,net,bias,pressure,rangePts,avgAbs)) return false;
   return (net>=InpMinMomentumNetPoints && bias>=InpMinTickBias && pressure>=InpMinPressurePct);
}

bool ReadAtr(double &atrPts)
{
   atrPts=0.0;
   if(g_atrM1==INVALID_HANDLE) return false;
   double a[1];
   if(CopyBuffer(g_atrM1,0,1,1,a)!=1 || a[0]<=0.0) return false;
   atrPts=a[0]/_Point;
   return true;
}

void ResetArm(const string why)
{
   if(g_armDir!=0) Log("ARM reset reason="+why);
   g_armDir=0;
   g_breakoutLevel=0.0;
   g_armSerial=0;
}

bool SignalThrottleOK(const int dir,const long nowMs)
{
   if(InpCandidateCooldownMs>0 && g_lastSignalMs>0 && nowMs-g_lastSignalMs<InpCandidateCooldownMs)
      return false;

   if(InpSameDirectionPauseMs>0)
   {
      long lastDirMs=(dir>0 ? g_lastBuySignalMs : g_lastSellSignalMs);
      if(lastDirMs>0 && nowMs-lastDirMs<InpSameDirectionPauseMs)
         return false;
   }
   return true;
}

int FreeObservationSlot()
{
   for(int i=0;i<MAX_OBS;i++)
      if(!g_obs[i].active) return i;
   return -1;
}

double ExecMovePts(const Observation &o,const MqlTick &tick)
{
   if(o.dir>0) return (tick.bid-o.ask0)/_Point;
   return (o.bid0-tick.ask)/_Point;
}

void CaptureHorizon(Observation &o,const int seconds,const double move)
{
   if(seconds==1)
   {
      o.h1=true; o.move1=move; o.mfe1=o.mfe; o.mae1=o.mae;
   }
   else if(seconds==3)
   {
      o.h3=true; o.move3=move; o.mfe3=o.mfe; o.mae3=o.mae;
   }
   else if(seconds==5)
   {
      o.h5=true; o.move5=move; o.mfe5=o.mfe; o.mae5=o.mae;
   }
   else if(seconds==10)
   {
      o.h10=true; o.move10=move; o.mfe10=o.mfe; o.mae10=o.mae;
   }
   else if(seconds==20)
   {
      o.h20=true; o.move20=move; o.mfe20=o.mfe; o.mae20=o.mae;
   }
}

void WriteHeader()
{
   FileWrite(g_file,
      "event_id","time_server","time_msc","symbol","dir",
      "signal_bid","signal_ask","spread_pts",
      "range_width_pts","range_hi","range_lo","breakout_level","chase_pts",
      "burst_pts","burst_velocity_pts_s",
      "mom10_pts","bias10","pressure10_pct",
      "mom20_pts","bias20","pressure20_pct",
      "mom32_pts","bias32","pressure32_pct",
      "tick_range32_pts","avg_abs_delta32_pts","atr_m1_pts",
      "move_1s_pts","mfe_1s_pts","mae_1s_pts",
      "move_3s_pts","mfe_3s_pts","mae_3s_pts",
      "move_5s_pts","mfe_5s_pts","mae_5s_pts",
      "move_10s_pts","mfe_10s_pts","mae_10s_pts",
      "move_20s_pts","mfe_20s_pts","mae_20s_pts");
}

void WriteObservation(const Observation &o)
{
   if(g_file==INVALID_HANDLE) return;

   string ts=TimeToString(o.signal_time,TIME_DATE|TIME_SECONDS);
   FileWrite(g_file,
      o.id,ts,o.signal_ms,_Symbol,DirText(o.dir),
      DoubleToString(o.bid0,_Digits),DoubleToString(o.ask0,_Digits),DoubleToString(o.spread_pts,1),
      DoubleToString(o.range_width,1),DoubleToString(o.range_hi,_Digits),DoubleToString(o.range_lo,_Digits),DoubleToString(o.breakout_level,_Digits),DoubleToString(o.chase,1),
      DoubleToString(o.burst,1),DoubleToString(o.velocity,2),
      DoubleToString(o.mom10,1),DoubleToString(o.bias10,4),DoubleToString(o.pressure10,1),
      DoubleToString(o.mom20,1),DoubleToString(o.bias20,4),DoubleToString(o.pressure20,1),
      DoubleToString(o.mom32,1),DoubleToString(o.bias32,4),DoubleToString(o.pressure32,1),
      DoubleToString(o.tick_range32,1),DoubleToString(o.avg_abs_delta32,2),DoubleToString(o.atr_m1,1),
      DoubleToString(o.move1,1),DoubleToString(o.mfe1,1),DoubleToString(o.mae1,1),
      DoubleToString(o.move3,1),DoubleToString(o.mfe3,1),DoubleToString(o.mae3,1),
      DoubleToString(o.move5,1),DoubleToString(o.mfe5,1),DoubleToString(o.mae5,1),
      DoubleToString(o.move10,1),DoubleToString(o.mfe10,1),DoubleToString(o.mae10,1),
      DoubleToString(o.move20,1),DoubleToString(o.mfe20,1),DoubleToString(o.mae20,1));

   g_rowsWritten++;
   if(InpFlushEveryRows>0 && (g_rowsWritten%InpFlushEveryRows)==0)
      FileFlush(g_file);
}

void UpdateObservations(const MqlTick &tick)
{
   for(int i=0;i<MAX_OBS;i++)
   {
      if(!g_obs[i].active) continue;

      double move=ExecMovePts(g_obs[i],tick);
      if(move>g_obs[i].mfe) g_obs[i].mfe=move;
      if(move<g_obs[i].mae) g_obs[i].mae=move;

      long age=tick.time_msc-g_obs[i].signal_ms;
      if(age>=1000  && !g_obs[i].h1)  CaptureHorizon(g_obs[i],1,move);
      if(age>=3000  && !g_obs[i].h3)  CaptureHorizon(g_obs[i],3,move);
      if(age>=5000  && !g_obs[i].h5)  CaptureHorizon(g_obs[i],5,move);
      if(age>=10000 && !g_obs[i].h10) CaptureHorizon(g_obs[i],10,move);
      if(age>=20000 && !g_obs[i].h20)
      {
         CaptureHorizon(g_obs[i],20,move);
         WriteObservation(g_obs[i]);
         g_obs[i].active=false;
      }
   }
}

void CreateObservation(const int dir,const MqlTick &tick,const double hi,const double lo,const double width,const double chase,const double burst,const double velocity)
{
   int slot=FreeObservationSlot();
   if(slot<0)
   {
      g_droppedObservations++;
      if(InpVerboseLogging) Print("[XAU-V7-DATA] Observation buffer full; signal dropped.");
      return;
   }

   Observation o;
   ZeroMemory(o);
   o.active=true;
   o.id=g_nextId++;
   o.signal_ms=tick.time_msc;
   o.signal_time=tick.time;
   o.dir=dir;
   o.bid0=tick.bid;
   o.ask0=tick.ask;
   o.spread_pts=(tick.ask-tick.bid)/_Point;
   o.range_width=width;
   o.range_hi=hi;
   o.range_lo=lo;
   o.breakout_level=g_breakoutLevel;
   o.chase=chase;
   o.burst=burst;
   o.velocity=velocity;

   double r=0.0,a=0.0;
   DirectionalStats(10,dir,o.mom10,o.bias10,o.pressure10,r,a);
   DirectionalStats(InpStatsWindow2,dir,o.mom20,o.bias20,o.pressure20,r,a);
   DirectionalStats(InpStatsWindow3,dir,o.mom32,o.bias32,o.pressure32,o.tick_range32,o.avg_abs_delta32);
   ReadAtr(o.atr_m1);

   double initialMove=ExecMovePts(o,tick);
   o.mfe=initialMove;
   o.mae=initialMove;

   g_obs[slot]=o;
   g_signalsCreated++;
   g_lastSignalMs=tick.time_msc;
   if(dir>0) g_lastBuySignalMs=tick.time_msc;
   else      g_lastSellSignalMs=tick.time_msc;

   if(InpVerboseLogging)
      Log(StringFormat("SIGNAL #%I64d %s range=%.1f chase=%.1f burst=%.1f vel=%.1f mom10=%.1f bias10=%.2f spread=%.1f",
         o.id,DirText(dir),width,chase,burst,velocity,o.mom10,o.bias10,o.spread_pts));

   if(InpProgressEverySignals>0 && (g_signalsCreated%InpProgressEverySignals)==0)
      PrintFormat("[XAU-V7-DATA] signals=%I64d completed_rows=%I64d",g_signalsCreated,g_rowsWritten);
}

bool OpenCsv()
{
   if(StringLen(InpCsvFileName)<1) return false;

   if(InpOverwriteCsv && FileIsExist(InpCsvFileName,FILE_COMMON))
      FileDelete(InpCsvFileName,FILE_COMMON);

   g_file=FileOpen(InpCsvFileName,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON,',');
   if(g_file==INVALID_HANDLE)
   {
      PrintFormat("[XAU-V7-DATA] FileOpen failed error=%d",GetLastError());
      return false;
   }

   if(FileSize(g_file)==0)
      WriteHeader();
   FileSeek(g_file,0,SEEK_END);
   FileFlush(g_file);
   return true;
}

int OnInit()
{
   if(InpRangeLookbackBars<1 || InpBurstTicks<2 || InpMomentumWindowTicks<3 || InpStatsWindow2<3 || InpStatsWindow3<3)
      return INIT_PARAMETERS_INCORRECT;
   if(InpStatsWindow3>=TICK_BUF || InpStatsWindow2>=TICK_BUF)
      return INIT_PARAMETERS_INCORRECT;

   for(int i=0;i<MAX_OBS;i++) g_obs[i].active=false;

   g_atrM1=iATR(_Symbol,PERIOD_M1,InpAtrPeriod);
   if(g_atrM1==INVALID_HANDLE)
   {
      PrintFormat("[XAU-V7-DATA] ATR handle failed error=%d",GetLastError());
      return INIT_FAILED;
   }

   if(!OpenCsv())
      return INIT_FAILED;

   string commonPath=TerminalInfoString(TERMINAL_COMMONDATA_PATH)+"\\Files\\"+InpCsvFileName;
   Print("[XAU-V7-DATA] Initialized. NO TRADING. CSV: ",commonPath);
   Print("[XAU-V7-DATA] Use Strategy Tester: XAUUSD.a, M1, Every tick based on real ticks, 3-6 months.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_file!=INVALID_HANDLE)
   {
      FileFlush(g_file);
      FileClose(g_file);
      g_file=INVALID_HANDLE;
   }
   if(g_atrM1!=INVALID_HANDLE)
   {
      IndicatorRelease(g_atrM1);
      g_atrM1=INVALID_HANDLE;
   }
   PrintFormat("[XAU-V7-DATA] Finished. signals=%I64d completed_rows=%I64d dropped=%I64d",g_signalsCreated,g_rowsWritten,g_droppedObservations);
}

void OnTick()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;

   PushBid(tick);
   UpdateObservations(tick);

   if(g_count<MathMax(InpStatsWindow3,InpMomentumWindowTicks)) return;

   double spread=(tick.ask-tick.bid)/_Point;
   if(spread<=0.0 || (InpMaxSpreadPoints>0 && spread>InpMaxSpreadPoints))
   {
      ResetArm("spread");
      return;
   }

   double hi=0.0,lo=0.0,width=0.0;
   bool rangeOK=GetRange(hi,lo,width);
   if(!rangeOK)
   {
      ResetArm("range-invalid");
      return;
   }

   if(g_armDir==0)
   {
      if(tick.bid>=hi+InpBreakoutBufferPoints*_Point)
      {
         g_armDir=1;
         g_breakoutLevel=hi;
         g_armSerial=g_tickSerial;
      }
      else if(tick.bid<=lo-InpBreakoutBufferPoints*_Point)
      {
         g_armDir=-1;
         g_breakoutLevel=lo;
         g_armSerial=g_tickSerial;
      }
   }

   if(g_armDir==0) return;

   long ageTicks=g_tickSerial-g_armSerial;
   double chase=(g_armDir>0 ? tick.bid-g_breakoutLevel : g_breakoutLevel-tick.bid)/_Point;

   if(ageTicks>InpSignalValidTicks)
   {
      ResetArm("signal-expired");
      return;
   }
   if(chase>InpMaxChasePoints)
   {
      ResetArm("max-chase");
      return;
   }
   if(g_armDir>0 && tick.bid<g_breakoutLevel-InpBreakoutBufferPoints*_Point)
   {
      ResetArm("failed-breakout");
      return;
   }
   if(g_armDir<0 && tick.bid>g_breakoutLevel+InpBreakoutBufferPoints*_Point)
   {
      ResetArm("failed-breakout");
      return;
   }

   double burst=0.0,velocity=0.0,net=0.0,bias=0.0,pressure=0.0;
   bool burstOK=BurstConfirm(g_armDir,burst,velocity);
   bool momentumOK=CoreMomentumConfirm(g_armDir,net,bias,pressure);

   if(burstOK && momentumOK && SignalThrottleOK(g_armDir,tick.time_msc))
   {
      int dir=g_armDir;
      CreateObservation(dir,tick,hi,lo,width,chase,burst,velocity);
      ResetArm("consumed");
   }
}
//+------------------------------------------------------------------+
