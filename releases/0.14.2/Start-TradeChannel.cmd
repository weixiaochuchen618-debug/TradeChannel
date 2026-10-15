@echo off
chcp 65001 >nul
cd /d "%~dp0"
if not exist "%~dp0TradeChannel.exe" (
 echo 完整启动器缺失。请重新全部解压 TradeChannel 0.14.2 完整包。
 pause
 exit /b 1
)
start "" "%~dp0TradeChannel.exe"
