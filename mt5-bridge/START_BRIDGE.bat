@echo off
cd /d %~dp0
py -3.11 -m pip install --quiet MetaTrader5 fastapi uvicorn
py -3.11 mt5_bridge.py
pause
