@echo off
cd /d "%~dp0"
"%LOCALAPPDATA%\Programs\Python\Python311\python.exe" evaluate_60s_thresholds.py --eval-days 7 --commission-points 7 --margin 0.05 --max-samples 150000
pause
