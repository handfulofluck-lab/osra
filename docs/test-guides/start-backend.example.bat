@echo off
REM ============================================================================
REM  OSRA test backend launcher (Windows host PC) — EXAMPLE
REM  Copy to start-backend.bat next to your test bundle and set real secrets.
REM  Starts Redis, PostgreSQL (service OSRA-Postgres), migrations, seed, API.
REM  Adjust ROOT/TOOLS paths to your machine if different.
REM ============================================================================
setlocal
set ROOT=C:\KARIM
set TOOLS=%ROOT%\tools
set API=%ROOT%\familyshield\services\api

echo [1/5] Checking Redis...
"%TOOLS%\redis\redis-cli.exe" -h 127.0.0.1 -p 6379 ping >nul 2>&1
if errorlevel 1 (
  echo      starting Redis on 6379...
  start "OSRA Redis" /min "%TOOLS%\redis\redis-server.exe" --port 6379 --save "" --appendonly no
  timeout /t 2 >nul
) else ( echo      already running. )

echo [2/5] Checking PostgreSQL (Windows service OSRA-Postgres)...
sc query OSRA-Postgres >nul 2>&1
if errorlevel 1 (
  echo      service not registered - starting PostgreSQL directly...
  "%TOOLS%\pg\pgsql\bin\pg_ctl.exe" -D %ROOT%\pgdata status >nul 2>&1
  if errorlevel 1 (
    if not exist %ROOT%\pgdata\PG_VERSION (
      echo      first run: initializing database cluster...
      "%TOOLS%\pg\pgsql\bin\initdb.exe" -D %ROOT%\pgdata -U familyshield --auth=trust -E UTF8 || goto :fail
    )
    "%TOOLS%\pg\pgsql\bin\pg_ctl.exe" -D %ROOT%\pgdata -o "-p 5432" -l %ROOT%\pgdata\server.log -w -t 120 start || goto :fail
  )
) else (
  sc query OSRA-Postgres | findstr /c:"RUNNING" >nul 2>&1
  if errorlevel 1 ( net start OSRA-Postgres >nul 2>&1 || goto :fail ) else ( echo      already running. )
)

echo [3/5] Ensuring database 'familyshield' exists...
"%TOOLS%\pg\pgsql\bin\psql.exe" -h 127.0.0.1 -U familyshield -d familyshield -c "SELECT 1" >nul 2>&1
if errorlevel 1 "%TOOLS%\pg\pgsql\bin\createdb.exe" -h 127.0.0.1 -U familyshield familyshield

set PATH=%TOOLS%\node;%PATH%
set DATABASE_URL=postgres://familyshield@127.0.0.1:5432/familyshield
set REDIS_URL=redis://127.0.0.1:6379
REM === SET REAL SECRETS BEFORE GOING ONLINE (any long random strings) ===
set JWT_SECRET=CHANGE_ME-long-random-hex
set INTERNAL_HMAC_SECRET=CHANGE_ME-long-random-hex
set PORT=3000
REM base64 32-byte AES key, e.g. from: node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"
set VAULT_KEY=CHANGE_ME-base64-32-bytes
REM =====================================================================

echo [4/5] Applying migrations + seed...
cd /d %API%
call pnpm exec prisma migrate deploy || goto :fail
call pnpm exec tsx scripts/seed.ts || goto :fail

echo [5/5] Starting API on port 3000...
echo.
for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /c:"IPv4"') do echo    LAN address candidate: http://%%a:3000
echo.
echo    Demo parent login:  demo@familyshield.dev / CorrectHorseBatteryStaple!
echo.
node dist\server.js
goto :eof

:fail
echo.
echo FAILED - see messages above.
exit /b 1
