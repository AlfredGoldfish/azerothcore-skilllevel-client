@echo off
title IASIM Setup
echo.
echo   Setting up IASIM  -  It's a Skill issue Mikey
echo.
echo   This takes a few seconds. A window will pop up when it's done.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=[IO.File]::ReadAllText('%~f0'); iex $c.Substring($c.LastIndexOf('#PSBODY#')+8)"
exit /b %errorlevel%

#PSBODY#
# ============================================================================
#  IASIM one-time installer  (the batch wrapper above runs everything below).
#  Sets up the self-updating "It's a Skill issue Mikey" launcher.
#
#  It only fetches the ~15 KB launcher from the repo - NOT the game. Your
#  existing client and settings live in %LOCALAPPDATA%\SkillIssueLauncher,
#  separate from this folder, so nothing big is re-downloaded and your
#  remembered game folder carries over automatically.
#
#  After this, the launcher keeps ITSELF up to date - this is the last file
#  anyone needs to send you.
# ============================================================================
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoOwner = 'AlfredGoldfish'
$RepoName  = 'azerothcore-skilllevel-client'
$Branch    = 'main'
$RawBase   = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"
$Dest      = Join-Path $env:LOCALAPPDATA 'IASIM'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-Info($msg) { [void][System.Windows.Forms.MessageBox]::Show($msg, 'IASIM Setup', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) }
function Show-Fail($msg) { [void][System.Windows.Forms.MessageBox]::Show($msg, 'IASIM Setup', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) }

function Get-File($url, $out) {
  # tiny download with a couple of retries; returns $true on success
  for ($i = 0; $i -lt 3; $i++) {
    try { Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -TimeoutSec 90 -Headers @{ 'Cache-Control' = 'no-cache' }; return $true }
    catch { Start-Sleep -Seconds 2 }
  }
  return $false
}

try {
  New-Item -ItemType Directory -Force -Path $Dest | Out-Null

  # Pull the self-updating launcher + its Play.bat from the repo.
  if (-not (Get-File "$RawBase/SkillIssueLauncher.ps1" (Join-Path $Dest 'SkillIssueLauncher.ps1'))) {
    throw "Couldn't download the launcher. Check your internet connection and try again."
  }
  if (-not (Get-File "$RawBase/Play.bat" (Join-Path $Dest 'Play.bat'))) {
    throw "Couldn't download Play.bat. Check your internet connection and try again."
  }
  # icon is a nice-to-have; ignore if it fails
  [void](Get-File "$RawBase/icon.ico" (Join-Path $Dest 'icon.ico'))

  # Clear only the saved *client path* (kept in a shared config, separate from this
  # folder). The old path points at an incomplete/DLL-broken client, so blanking it
  # makes the launcher greet you with "Download & install the game" - a fresh, complete
  # ChromieCraft client with every runtime DLL included. Nothing else is reset.
  $cfgFile = Join-Path $env:LOCALAPPDATA 'SkillIssueLauncher\config.json'
  if (Test-Path $cfgFile) {
    try {
      $j = Get-Content $cfgFile -Raw | ConvertFrom-Json
      $j | Add-Member -NotePropertyName WowPath -NotePropertyValue '' -Force
      $j | ConvertTo-Json | Set-Content -Path $cfgFile -Encoding UTF8
    } catch { Remove-Item $cfgFile -Force -ErrorAction SilentlyContinue }
  }

  # Desktop shortcut named "IASIM" pointing at Play.bat
  $desktop = [Environment]::GetFolderPath('Desktop')
  $ws  = New-Object -ComObject WScript.Shell
  $lnk = $ws.CreateShortcut((Join-Path $desktop 'IASIM.lnk'))
  $lnk.TargetPath       = Join-Path $Dest 'Play.bat'
  $lnk.WorkingDirectory = $Dest
  $lnk.Description       = "It's a Skill issue Mikey - launch the game"
  $ico = Join-Path $Dest 'icon.ico'
  if (Test-Path $ico) { $lnk.IconLocation = $ico }
  $lnk.Save()

  # Tidy up the old shortcut if it's still on the Desktop, so there aren't two
  $oldLnk = Join-Path $desktop 'Skill Issue Launcher.lnk'
  if (Test-Path $oldLnk) { Remove-Item $oldLnk -Force -ErrorAction SilentlyContinue }

  Show-Info ("IASIM is installed!`r`n`r`nA shortcut named IASIM is on your Desktop - double-click it any time to update and play.`r`n`r`nYour existing game and settings were kept. Opening it now...")

  Start-Process -FilePath (Join-Path $Dest 'Play.bat') -WorkingDirectory $Dest
} catch {
  Show-Fail ("Setup hit a problem:`r`n`r`n" + $_.Exception.Message)
  exit 1
}
