@echo off
REM Cline 设备码登录 —— Windows 便捷包装
REM 用法: cline-login.cmd [额外参数, 例如 -OutFile "%USERPROFILE%\.cline-token.json"]
setlocal

set "PS=powershell"
where pwsh >nul 2>nul && set "PS=pwsh"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0cline-device-login.ps1" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
  echo.
  echo [脚本以退出码 %RC% 结束]
  pause
)

endlocal & exit /b %RC%
