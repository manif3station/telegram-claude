@echo off
rem telegram-claude-managed-windows-make-wrapper
setlocal

if "%~1"=="" goto default
if /I "%~1"=="default" goto default
if /I "%~1"=="install" goto install
if /I "%~1"=="test" exit /b 0
if /I "%~1"=="tests" exit /b 0
if /I "%~1"=="clean" exit /b 0

echo Unsupported telegram-claude make target: %~1 1>&2
exit /b 1

:default
exit /b 0

:install
perl -Ilib -MTelegram::Claude::Manager -e "Telegram::Claude::Manager->new()->auto_setup()"
exit /b %ERRORLEVEL%
