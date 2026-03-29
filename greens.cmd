@echo off
REM greens - Windows launcher (Windows 10/11)
REM Runs sync.sh via Git Bash (bundled with Git for Windows)
REM
REM Prerequisites: Git for Windows (https://git-scm.com/download/win)

setlocal EnableDelayedExpansion

REM Find Git Bash
set "GITBASH="
for %%p in (
    "%ProgramFiles%\Git\bin\bash.exe"
    "%ProgramFiles(x86)%\Git\bin\bash.exe"
    "%LocalAppData%\Programs\Git\bin\bash.exe"
) do (
    if exist %%p set "GITBASH=%%~p"
)

if "!GITBASH!"=="" (
    echo ERROR: Git Bash not found.
    echo Install Git for Windows: https://git-scm.com/download/win
    echo Or install via: winget install Git.Git
    exit /b 1
)

REM Get the directory where this script lives, convert to forward slashes for bash
set "SCRIPT_DIR=%~dp0"
if "!SCRIPT_DIR:~-1!"=="\" set "SCRIPT_DIR=!SCRIPT_DIR:~0,-1!"
set "SCRIPT_DIR=!SCRIPT_DIR:\=/!"

REM Run sync.sh with all arguments
set "MSYS_NO_PATHCONV=1"
"!GITBASH!" --login -c "cd '!SCRIPT_DIR!' && bash sync.sh %*"
