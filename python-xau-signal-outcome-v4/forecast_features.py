from __future__ import annotations
import math
import numpy as np

FEATURE_NAMES = [
    'spread_pts','net5','net8','net15','net30','net50',
    'upbias8','upbias15','upbias30','upbias50',
    'range10','range30','range50','avgabs10','avgabs30','avgabs50',
    'vel8','vel30','z50','last_delta','accel','tod_sin','tod_cos'
]

def _bias(bids):
    d=np.diff(bids)
    nz=d[d!=0]
    if len(nz)==0: return 0.5
    return float(np.mean(nz>0))

def _window_stats(bids,times_ms,n,point):
    x=bids[-n:]; t=times_ms[-n:]
    net=(x[-1]-x[0])/point
    rng=(x.max()-x.min())/point
    avgabs=float(np.mean(np.abs(np.diff(x))/point)) if len(x)>1 else 0.0
    dt=max((t[-1]-t[0])/1000.0,1e-6)
    return net,rng,avgabs,net/dt

def make_features(bids,asks,times_ms,point):
    bids=np.asarray(bids,dtype=float); asks=np.asarray(asks,dtype=float); times_ms=np.asarray(times_ms,dtype=np.int64)
    if len(bids)<50: return None
    spread=(asks[-1]-bids[-1])/point
    n5,_,_,_= _window_stats(bids,times_ms,5,point)
    n8,_,_,v8= _window_stats(bids,times_ms,8,point)
    n15,_,_,_= _window_stats(bids,times_ms,15,point)
    n30,r30,a30,v30= _window_stats(bids,times_ms,30,point)
    n50,r50,a50,_= _window_stats(bids,times_ms,50,point)
    _,r10,a10,_= _window_stats(bids,times_ms,10,point)
    a8=_bias(bids[-8:]); a15=_bias(bids[-15:]); a30b=_bias(bids[-30:]); a50b=_bias(bids[-50:])
    x=bids[-50:]; mean=float(x.mean()); sd=float(x.std()); z50=(x[-1]-mean)/sd if sd>0 else 0.0
    last_delta=(bids[-1]-bids[-2])/point; prev_delta=(bids[-2]-bids[-3])/point; accel=last_delta-prev_delta
    sec=(int(times_ms[-1]//1000)%86400); ang=2.0*math.pi*sec/86400.0
    vals=[spread,n5,n8,n15,n30,n50,a8,a15,a30b,a50b,r10,r30,r50,a10,a30,a50,v8,v30,z50,last_delta,accel,math.sin(ang),math.cos(ang)]
    return np.asarray(vals,dtype=np.float64)
