@echo off
cd /d "%~dp0"
"%LOCALAPPDATA%\Programs\Python\Python311\python.exe" -m pip install -q MetaTrader5 numpy scikit-learn joblib
"%LOCALAPPDATA%\Programs\Python\Python311\python.exe" train_direct_edge_v5.py --days 30 --sample-ms 1500 --commission-points 7 --label-min-points 8 --label-margin-points 8 --train-cap 140000 --val-cap 50000 --hold-cap 70000
echo.
echo Finished. Results are also saved in V5_RESULTS.txt
pause
