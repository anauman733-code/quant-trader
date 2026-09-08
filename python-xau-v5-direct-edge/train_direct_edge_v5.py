from __future__ import annotations
import argparse, math, os, random, sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

import joblib
import MetaTrader5 as mt5
import numpy as np
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import balanced_accuracy_score, confusion_matrix

SYMBOL = 'XAUUSD.a'
MODEL_FILE = 'xau_direct_edge_v5.joblib'
RESULTS_FILE = 'V5_RESULTS.txt'
HORIZONS = (5, 10, 20, 30)

FEATURE_NAMES = [
    'spread_pts',
    'net3','net5','net8','net15','net30','net50','net100',
    'upbias5','upbias8','upbias15','upbias30','upbias50','upbias100',
    'range10','range30','range50','range100',
    'avgabs10','avgabs30','avgabs50','avgabs100',
    'vel8','vel30','vel100',
    'z50','z100','pos50','pos100',
    'last_bid_delta','last_ask_delta','spread_delta5','spread_delta20',
    'run_len','flip_rate20',
    'iat_mean10','iat_std10','iat_mean30','iat_std30','iat_mean100','iat_std100',
    'tod_sin','tod_cos'
]

class Tee:
    def __init__(self, *files): self.files = files
    def write(self, data):
        for f in self.files:
            f.write(data); f.flush()
    def flush(self):
        for f in self.files: f.flush()

def bias(x):
    d=np.diff(x); nz=d[d!=0]
    if len(nz)==0: return 0.5
    return float(np.mean(nz>0))

def window_stats(bids,times,n,point):
    x=bids[-n:]; t=times[-n:]
    net=(x[-1]-x[0])/point
    rng=(x.max()-x.min())/point
    avgabs=float(np.mean(np.abs(np.diff(x))/point)) if len(x)>1 else 0.0
    dt=max((t[-1]-t[0])/1000.0,1e-6)
    return net,rng,avgabs,net/dt

def interarrival(times,n):
    t=times[-n:].astype(np.float64)
    if len(t)<2: return 0.0,0.0
    d=np.diff(t)
    return float(np.mean(d)),float(np.std(d))

def directional_run(bids,point):
    d=np.diff(bids[-25:])/point; s=np.sign(d); s=s[s!=0]
    if len(s)==0: return 0.0
    last=s[-1]; n=0
    for v in s[::-1]:
        if v!=last: break
        n+=1
    return float(n if last>0 else -n)

def flip_rate(bids):
    d=np.diff(bids[-21:]); s=np.sign(d); s=s[s!=0]
    if len(s)<2: return 0.0
    return float(np.mean(s[1:]!=s[:-1]))

def make_features(bids,asks,times,point):
    if len(bids)<100: return None
    bids=np.asarray(bids,float); asks=np.asarray(asks,float); times=np.asarray(times,np.int64)
    spread=(asks[-1]-bids[-1])/point
    n3,_,_,_=window_stats(bids,times,3,point)
    n5,_,_,_=window_stats(bids,times,5,point)
    n8,_,_,v8=window_stats(bids,times,8,point)
    n15,_,_,_=window_stats(bids,times,15,point)
    n30,r30,a30,v30=window_stats(bids,times,30,point)
    n50,r50,a50,_=window_stats(bids,times,50,point)
    n100,r100,a100,v100=window_stats(bids,times,100,point)
    _,r10,a10,_=window_stats(bids,times,10,point)
    b5,b8,b15,b30,b50,b100=[bias(bids[-n:]) for n in (5,8,15,30,50,100)]
    x50=bids[-50:]; sd50=float(x50.std()); z50=(x50[-1]-float(x50.mean()))/sd50 if sd50>0 else 0.0
    pos50=(x50[-1]-float(x50.min()))/float(x50.max()-x50.min()) if x50.max()>x50.min() else 0.5
    x100=bids[-100:]; sd100=float(x100.std()); z100=(x100[-1]-float(x100.mean()))/sd100 if sd100>0 else 0.0
    pos100=(x100[-1]-float(x100.min()))/float(x100.max()-x100.min()) if x100.max()>x100.min() else 0.5
    last_bid_delta=(bids[-1]-bids[-2])/point
    last_ask_delta=(asks[-1]-asks[-2])/point
    sp=(asks-bids)/point
    spread_delta5=sp[-1]-sp[-5]; spread_delta20=sp[-1]-sp[-20]
    run_len=directional_run(bids,point); flips=flip_rate(bids)
    im10,is10=interarrival(times,10); im30,is30=interarrival(times,30); im100,is100=interarrival(times,100)
    sec=(int(times[-1]//1000)%86400); ang=2.0*math.pi*sec/86400.0
    vals=[spread,n3,n5,n8,n15,n30,n50,n100,b5,b8,b15,b30,b50,b100,r10,r30,r50,r100,a10,a30,a50,a100,v8,v30,v100,z50,z100,pos50,pos100,last_bid_delta,last_ask_delta,spread_delta5,spread_delta20,run_len,flips,im10,is10,im30,is30,im100,is100,math.sin(ang),math.cos(ang)]
    return np.asarray(vals,np.float64)

def fetch_ticks(days):
    end=datetime.now(timezone.utc); start=end-timedelta(days=days); chunks=[]; cur=start
    while cur<end:
        nxt=min(cur+timedelta(days=1),end)
        a=mt5.copy_ticks_range(SYMBOL,cur,nxt,mt5.COPY_TICKS_ALL)
        n=0 if a is None else len(a)
        print(f'Fetched {cur.date()} -> {nxt.date()} : {n:,} ticks')
        if a is not None and len(a): chunks.append(a)
        cur=nxt
    if not chunks: raise RuntimeError('No historical ticks returned by MT5')
    return np.concatenate(chunks)

def reservoir_add(store,key,row,seen,cap,rng):
    seen[key]+=1; n=seen[key]
    if len(store[key])<cap: store[key].append(row); return
    j=rng.randrange(n)
    if j<cap: store[key][j]=row

def build_states(ticks,point,sample_ms,train_cap,val_cap,hold_cap,commission_pts,label_min_pts,label_margin_pts):
    times=ticks['time_msc'].astype(np.int64); bids=ticks['bid'].astype(float); asks=ticks['ask'].astype(float)
    good=(bids>0)&(asks>0)&(asks>=bids); times,bids,asks=times[good],bids[good],asks[good]
    start=int(times[0]); end=int(times[-1]); span=max(end-start,1)
    t70=start+int(span*0.70); t85=start+int(span*0.85)
    print('STRICT TIME CUTS')
    print('TRAIN      :',datetime.fromtimestamp(start/1000,timezone.utc),'->',datetime.fromtimestamp(t70/1000,timezone.utc))
    print('VALIDATION :',datetime.fromtimestamp(t70/1000,timezone.utc),'->',datetime.fromtimestamp(t85/1000,timezone.utc))
    print('HOLDOUT    :',datetime.fromtimestamp(t85/1000,timezone.utc),'->',datetime.fromtimestamp(end/1000,timezone.utc))
    store=defaultdict(list); seen=defaultdict(int); rng=random.Random(20260908); last_sample=-10**18
    for i in range(100,len(times)-1):
        t=int(times[i])
        if t-last_sample<sample_ms: continue
        j30=int(np.searchsorted(times,t+30000,side='left'))
        if j30>=len(times): break
        feat=make_features(bids[i-99:i+1],asks[i-99:i+1],times[i-99:i+1],point)
        if feat is None: continue
        split='train' if t<t70 else ('val' if t<t85 else 'hold')
        cap=train_cap if split=='train' else (val_cap if split=='val' else hold_cap)
        outcomes={}
        for h in HORIZONS:
            j=int(np.searchsorted(times,t+h*1000,side='left'))
            if j>=len(times): continue
            buy_net=(bids[j]-asks[i])/point-commission_pts
            sell_net=(bids[i]-asks[j])/point-commission_pts
            if buy_net>=label_min_pts and buy_net>=sell_net+label_margin_pts: label=2
            elif sell_net>=label_min_pts and sell_net>=buy_net+label_margin_pts: label=0
            else: label=1
            outcomes[h]=(float(buy_net),float(sell_net),int(times[j]),int(label))
        reservoir_add(store,split,(t,feat,outcomes),seen,cap,rng)
        last_sample=t
    print('\nFULL-PERIOD sampling')
    for split in ('train','val','hold'):
        print(f'{split:5s}: raw={seen[split]:,} sampled={len(store[split]):,}')
        store[split].sort(key=lambda r:r[0])
    return store

def class_weights(y):
    counts=np.bincount(y,minlength=3).astype(float); w=np.zeros(3,float); ok=counts>0
    w[ok]=len(y)/(3.0*counts[ok])
    return w[y],counts.astype(int)

def trade_stats(rows,probs,threshold,margin,horizon):
    selected=[]
    for r,p in zip(rows,probs):
        ps,pf,pb=float(p[0]),float(p[1]),float(p[2]); direction=0; confidence=0.0
        if pb>=threshold and pb>=ps+margin and pb>pf: direction=1; confidence=pb
        elif ps>=threshold and ps>=pb+margin and ps>pf: direction=-1; confidence=ps
        if direction: selected.append((r,direction,confidence))
    selected.sort(key=lambda z:z[0][0]); free_at=-1; pnls=[]; buys=sells=0
    for r,direction,conf in selected:
        t,feat,outcomes=r
        if t<free_at: continue
        buy_net,sell_net,exit_t,label=outcomes[horizon]
        pnl=buy_net if direction>0 else sell_net
        pnls.append(pnl); buys+=direction>0; sells+=direction<0; free_at=exit_t
    if not pnls: return None
    a=np.asarray(pnls,float); hours=max((rows[-1][0]-rows[0][0])/3_600_000.0,1e-9)
    return {'trades':len(a),'buy':int(buys),'sell':int(sells),'win_rate':float(np.mean(a>0)),'avg':float(np.mean(a)),'median':float(np.median(a)),'total':float(np.sum(a)),'trades_hr':len(a)/hours,'net_hr':float(np.sum(a))/hours}

def label_summary(rows,horizon):
    y=np.asarray([r[2][horizon][3] for r in rows],int)
    return np.bincount(y,minlength=3)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--days',type=int,default=30); ap.add_argument('--sample-ms',type=int,default=1500)
    ap.add_argument('--commission-points',type=float,default=7.0); ap.add_argument('--label-min-points',type=float,default=8.0); ap.add_argument('--label-margin-points',type=float,default=8.0)
    ap.add_argument('--train-cap',type=int,default=140000); ap.add_argument('--val-cap',type=int,default=50000); ap.add_argument('--hold-cap',type=int,default=70000)
    args=ap.parse_args()
    results_path=os.path.join(os.path.dirname(os.path.abspath(__file__)),RESULTS_FILE); log_file=open(results_path,'w',encoding='utf-8'); original_stdout=sys.stdout; sys.stdout=Tee(original_stdout,log_file)
    try:
        print('XAU PYTHON V5 — DIRECT TICK-STATE EDGE DISCOVERY')
        print('No breakout/momentum/pullback/reversion entry formula is used.')
        print('Every sampled market state is classified directly as BUY / FLAT / SELL.')
        print('Spread is included through executable bid/ask; estimated commission is subtracted separately.')
        if not mt5.initialize(): raise RuntimeError(f'MT5 initialize failed: {mt5.last_error()}')
        try:
            sym=mt5.symbol_info(SYMBOL)
            if sym is None: raise RuntimeError(f'{SYMBOL} unavailable')
            ticks=fetch_ticks(args.days)
            store=build_states(ticks,sym.point,args.sample_ms,args.train_cap,args.val_cap,args.hold_cap,args.commission_points,args.label_min_points,args.label_margin_points)
        finally: mt5.shutdown()
        train,val,hold=store['train'],store['val'],store['hold']
        Xtr=np.vstack([r[1] for r in train]); Xva=np.vstack([r[1] for r in val]); Xho=np.vstack([r[1] for r in hold])
        thresholds=(0.40,0.45,0.50,0.55,0.60,0.65,0.70,0.75); margins=(0.03,0.05,0.08); models={}; validation_candidates=[]
        for h in HORIZONS:
            print('\n'+'='*92); print(f'HORIZON {h}s')
            ytr=np.asarray([r[2][h][3] for r in train],int); yva=np.asarray([r[2][h][3] for r in val],int); yho=np.asarray([r[2][h][3] for r in hold],int)
            print('TRAIN labels SELL/FLAT/BUY:',label_summary(train,h).tolist()); print('VAL   labels SELL/FLAT/BUY:',label_summary(val,h).tolist()); print('HOLD  labels SELL/FLAT/BUY:',label_summary(hold,h).tolist())
            sw,counts=class_weights(ytr)
            if np.sum(counts>0)<3: print('SKIP: training labels do not contain all three classes.'); continue
            model=HistGradientBoostingClassifier(max_iter=220,learning_rate=0.045,max_leaf_nodes=31,l2_regularization=3.0,min_samples_leaf=40,random_state=50+h)
            print('Training model...'); model.fit(Xtr,ytr,sample_weight=sw); models[h]=model
            pva_cls=model.predict(Xva); pho_cls=model.predict(Xho)
            print('VALIDATION balanced_accuracy=',round(balanced_accuracy_score(yva,pva_cls),4)); print(confusion_matrix(yva,pva_cls))
            print('HOLDOUT classification-only balanced_accuracy=',round(balanced_accuracy_score(yho,pho_cls),4)); print(confusion_matrix(yho,pho_cls))
            pva=model.predict_proba(Xva)
            print('\nVALIDATION TRADING SCREEN'); print('thr  margin trades  tr/hr   win%   avg_pts  total_pts  net/hr  median  buy/sell')
            for th in thresholds:
                for mg in margins:
                    st=trade_stats(val,pva,th,mg,h)
                    if st is None: continue
                    print(f'{th:0.2f} {mg:0.2f} {st["trades"]:6d} {st["trades_hr"]:6.2f} {st["win_rate"]*100:6.2f} {st["avg"]:8.2f} {st["total"]:10.2f} {st["net_hr"]:7.2f} {st["median"]:7.2f} {st["buy"]:4d}/{st["sell"]:<4d}')
                    if st['trades']>=100 and st['trades_hr']>=5.0 and st['avg']>0 and st['total']>0: validation_candidates.append((st['net_hr'],st['avg'],st['trades_hr'],h,th,mg,st))
        if not validation_candidates:
            print('\n'+'!'*92); print('NO VALIDATION CANDIDATE met the minimum requirements:'); print('>=100 trades, >=5 trades/hour, positive average net points and positive total net points.'); print('Do not create a trading bot from this model family yet.'); print('RESULTS SAVED:',results_path); return
        validation_candidates.sort(reverse=True,key=lambda z:(z[0],z[1],z[2])); best=validation_candidates[0]
        _,_,_,best_h,best_th,best_mg,best_val=best
        print('\n'+'*'*92); print('VALIDATION SELECTED CONFIG'); print(f'horizon={best_h}s threshold={best_th:.2f} margin={best_mg:.2f}')
        print(f'validation trades={best_val["trades"]} trades/hr={best_val["trades_hr"]:.2f} win={best_val["win_rate"]*100:.2f}% avg={best_val["avg"]:.2f} total={best_val["total"]:.2f} net/hr={best_val["net_hr"]:.2f}')
        best_model=models[best_h]; pho=best_model.predict_proba(Xho); hold_stats=trade_stats(hold,pho,best_th,best_mg,best_h)
        print('\nFINAL UNTOUCHED HOLDOUT — ONE POSITION AT A TIME')
        if hold_stats is None: print('No holdout trades passed the selected gate.')
        else:
            print(f'trades={hold_stats["trades"]} trades/hr={hold_stats["trades_hr"]:.2f} win={hold_stats["win_rate"]*100:.2f}% avg_net={hold_stats["avg"]:.2f} pts median={hold_stats["median"]:.2f} total_net={hold_stats["total"]:.2f} pts net/hr={hold_stats["net_hr"]:.2f} pts buy/sell={hold_stats["buy"]}/{hold_stats["sell"]}')
            if hold_stats['trades']>=100 and hold_stats['trades_hr']>=5.0 and hold_stats['avg']>0 and hold_stats['total']>0: print('HOLDOUT STATUS: PASS — candidate is worth a demo-only execution engine.')
            else: print('HOLDOUT STATUS: FAIL — do not demo trade this model yet.')
        bundle={'symbol':SYMBOL,'feature_names':FEATURE_NAMES,'models':models,'selected_horizon':best_h,'selected_threshold':best_th,'selected_margin':best_mg,'commission_points':args.commission_points,'trained_at':datetime.now().isoformat(),'days':args.days}
        out=os.path.join(os.path.dirname(os.path.abspath(__file__)),MODEL_FILE); joblib.dump(bundle,out); print('MODEL SAVED:',out); print('RESULTS SAVED:',results_path)
    finally:
        sys.stdout=original_stdout; log_file.close()

if __name__=='__main__': main()
