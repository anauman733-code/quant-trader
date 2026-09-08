from __future__ import annotations
import argparse, os
from datetime import datetime, timedelta, timezone
import numpy as np
import MetaTrader5 as mt5
import joblib
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import classification_report, confusion_matrix, balanced_accuracy_score
from forecast_features import make_features, FEATURE_NAMES

SYMBOL='XAUUSD.a'
MODEL_FILE='xau_60s_forecast.joblib'
SELL,FLAT,BUY=0,1,2


def fetch_ticks(days:int):
    end=datetime.now(timezone.utc)
    start=end-timedelta(days=days)
    chunks=[]
    cur=start
    while cur<end:
        nxt=min(cur+timedelta(days=1),end)
        a=mt5.copy_ticks_range(SYMBOL,cur,nxt,mt5.COPY_TICKS_ALL)
        if a is not None and len(a): chunks.append(a)
        print(f'Fetched {cur.date()} -> {nxt.date()} : {0 if a is None else len(a):,} ticks')
        cur=nxt
    if not chunks: raise RuntimeError('No historical ticks returned by MT5')
    return np.concatenate(chunks)


def build_dataset(ticks, point, sample_ms, horizon_ms, target_pts, max_samples):
    times=ticks['time_msc'].astype(np.int64)
    bids=ticks['bid'].astype(float)
    asks=ticks['ask'].astype(float)
    good=(bids>0)&(asks>0)&(asks>=bids)
    times,bids,asks=times[good],bids[good],asks[good]
    duration=max(int(times[-1]-times[0]),1)
    expected=max(duration//sample_ms,1)
    eff_sample_ms=max(sample_ms, int(duration/max_samples)) if expected>max_samples else sample_ms
    print(f'Usable ticks: {len(times):,}; effective sample interval: {eff_sample_ms} ms')

    X=[]; y=[]; last_sample=-10**18
    for i in range(50,len(times)-1):
        t=int(times[i])
        if t-last_sample<eff_sample_ms: continue
        j=int(np.searchsorted(times,t+horizon_ms,side='left'))
        if j>=len(times): break
        feat=make_features(bids[i-49:i+1],asks[i-49:i+1],times[i-49:i+1],point)
        if feat is None: continue
        buy_move=(bids[j]-asks[i])/point
        sell_move=(bids[i]-asks[j])/point
        if buy_move>=target_pts and buy_move>sell_move: label=BUY
        elif sell_move>=target_pts and sell_move>buy_move: label=SELL
        else: label=FLAT
        X.append(feat); y.append(label); last_sample=t
    X=np.asarray(X,dtype=np.float64); y=np.asarray(y,dtype=np.int64)
    if len(X)<5000: raise RuntimeError(f'Only {len(X)} samples; increase --days')
    return X,y,eff_sample_ms


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--days',type=int,default=14)
    ap.add_argument('--sample-ms',type=int,default=1000)
    ap.add_argument('--horizon-sec',type=int,default=60)
    ap.add_argument('--target-points',type=float,default=20.0)
    ap.add_argument('--max-samples',type=int,default=250000)
    args=ap.parse_args()

    if not mt5.initialize(): raise RuntimeError(f'MT5 initialize failed {mt5.last_error()}')
    try:
        sym=mt5.symbol_info(SYMBOL)
        if sym is None: raise RuntimeError(f'{SYMBOL} unavailable')
        ticks=fetch_ticks(args.days)
        X,y,eff=build_dataset(ticks,sym.point,args.sample_ms,args.horizon_sec*1000,args.target_points,args.max_samples)
        n=len(X); a=int(n*0.70); b=int(n*0.85)
        Xtr,Xva,Xte=X[:a],X[a:b],X[b:]; ytr,yva,yte=y[:a],y[a:b],y[b:]
        counts=np.bincount(ytr,minlength=3).astype(float)
        weights=np.where(counts>0,len(ytr)/(3.0*counts),0.0)
        sw=weights[ytr]
        model=HistGradientBoostingClassifier(max_iter=180,learning_rate=0.06,max_leaf_nodes=31,l2_regularization=1.0,random_state=7)
        print('Training...', {0:'SELL',1:'FLAT',2:'BUY'}, 'train counts=',counts.astype(int).tolist())
        model.fit(Xtr,ytr,sample_weight=sw)
        for name,Xs,ys in [('VALIDATION',Xva,yva),('HOLDOUT',Xte,yte)]:
            p=model.predict(Xs)
            print('\n'+name,'balanced_accuracy=',round(balanced_accuracy_score(ys,p),4))
            print(confusion_matrix(ys,p))
            print(classification_report(ys,p,target_names=['SELL','FLAT','BUY'],digits=3,zero_division=0))
        out=os.path.join(os.path.dirname(os.path.abspath(__file__)),MODEL_FILE)
        joblib.dump({'model':model,'feature_names':FEATURE_NAMES,'symbol':SYMBOL,'point':sym.point,'target_points':args.target_points,'horizon_sec':args.horizon_sec,'sample_ms':eff,'trained_at':datetime.now().isoformat(),'days':args.days},out)
        print('\nMODEL SAVED:',out)
        print('Next: run START_DRY_RUN_FORECAST.bat, then demo only after inspecting forecast behaviour.')
    finally:
        mt5.shutdown()

if __name__=='__main__': main()
