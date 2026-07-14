# SkillIssueLauncher.ps1
# One-click launcher for the "It's a Skill issue Mikey" server.
# Zero dependencies: Windows PowerShell + WinForms. No install, no Node, no git needed.
# It: (1) installs Tailscale if missing + walks you through sign-in and shows your IP,
#     (2) updates add-ons + the custom patch, (3) sets realmlist, (4) PLAY launches WoW.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ScriptPath = $PSCommandPath                          # full path of THIS script (for self-update)

# ---- CONFIG (edit these if they ever change) ----
$LauncherVersion = 3                                  # BUMP THIS every time you change this script,
                                                      # so everyone's launcher self-updates on next open.
$RepoOwner = 'AlfredGoldfish'
$RepoName  = 'azerothcore-skilllevel-client'
$Branch    = 'main'
$ServerIP  = '100.109.250.55'                       # Josh's PC on Tailscale = where the server lives
$RealmName = "It's a Skill issue Mikey"

# Full 3.3.5a (build 12340) client + optional HD patch, hosted by ChromieCraft.
# The host uses hotlink protection: it 403s unless we send a browser User-Agent AND
# a chromiecraft.com Referer. Both support byte-range resume.
# The canonical URL 302-redirects to the chmi.* host; we try both (canonical first,
# direct as fallback) so a redirect hiccup can't strand the download.
$ClientUrls  = @('https://btground.dedyn.io/chmi/ChromieCraft_3.3.5a.zip',
                 'https://chmi.btground.dedyn.io/ChromieCraft_3.3.5a.zip')
$ClientBytes = 17674749792                          # ~16.5 GB
$HdUrls      = @('https://btground.dedyn.io/chmi/additional_patches_for_335a.zip',
                 'https://chmi.btground.dedyn.io/additional_patches_for_335a.zip')
$HdBytes     = 3397498676                           # ~3.2 GB
$BrowserUA   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
$Referer     = 'https://chromiecraft.com/'
$InstallName = 'WoW-3.3.5a-SkillIssue'              # folder created inside the parent the user picks
# -------------------------------------------------

$ZipUrl  = "https://github.com/$RepoOwner/$RepoName/archive/refs/heads/$Branch.zip"
$ApiUrl  = "https://api.github.com/repos/$RepoOwner/$RepoName/commits/$Branch"
$CfgDir  = Join-Path $env:LOCALAPPDATA 'SkillIssueLauncher'
$CfgFile = Join-Path $CfgDir 'config.json'
$TsCandidates = @(
  (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'),
  'C:\Program Files\Tailscale\tailscale.exe',
  (Join-Path ${env:ProgramFiles(x86)} 'Tailscale\tailscale.exe')
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Load-Config {
  if (Test-Path $CfgFile) { try { return (Get-Content $CfgFile -Raw | ConvertFrom-Json) } catch {} }
  return [pscustomobject]@{ WowPath = ''; LastSha = '' }
}
function Save-Config($c) {
  if (-not (Test-Path $CfgDir)) { New-Item -ItemType Directory -Path $CfgDir -Force | Out-Null }
  $c | ConvertTo-Json | Set-Content -Path $CfgFile -Encoding UTF8
}
function Test-WowFolder($p) { return ($p -and (Test-Path (Join-Path $p 'Wow.exe'))) }
function Pick-WowFolder {
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = 'Select your World of Warcraft 3.3.5a folder (the one containing Wow.exe)'
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
  return $null
}
function Get-TailscaleExe {
  foreach ($p in $TsCandidates) { if ($p -and (Test-Path $p)) { return $p } }
  $c = Get-Command tailscale.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  return $null
}
function Get-TailscaleIP($ts) {
  try {
    $out = & $ts ip -4 2>$null
    $line = ($out | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1)
    if ($line) { return $line.Trim() }
  } catch {}
  return $null
}
function Sleep-Pump($ms) {
  # sleep without freezing the window
  $end = (Get-Date).AddMilliseconds($ms)
  while ((Get-Date) -lt $end) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 80 }
}

# ---- Self-update: pull the latest launcher script from the repo and relaunch if newer ----
# Pull, not push: every open, the launcher compares its own $LauncherVersion to the repo's.
# If the repo is newer, it replaces this file and relaunches - so a change you push reaches
# everyone automatically, with no re-sharing of the launcher folder.
function Self-Update {
  if (-not $ScriptPath -or -not (Test-Path $ScriptPath)) { return }   # can't self-update if we don't know our path
  $raw = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/SkillIssueLauncher.ps1"
  $remote = $null
  try {
    $remote = (Invoke-WebRequest -Uri $raw -UseBasicParsing -TimeoutSec 20 -Headers @{ 'Cache-Control' = 'no-cache' }).Content
  } catch { return }                                                  # offline / GitHub down: run the current version
  if (-not $remote) { return }

  $m = [regex]::Match($remote, '(?m)^\s*\$LauncherVersion\s*=\s*(\d+)')
  if (-not $m.Success) { return }                                     # remote has no version marker: don't touch it
  $remoteVer = [int]$m.Groups[1].Value
  if ($remoteVer -le $LauncherVersion) { return }                     # we're already current (or ahead, e.g. Josh's dev copy)

  # Never replace a working launcher with a broken one: the new script must parse cleanly first.
  $perr = $null
  [void][System.Management.Automation.Language.Parser]::ParseInput($remote, [ref]$null, [ref]$perr)
  if ($perr -and $perr.Count -gt 0) { return }

  try {
    Copy-Item $ScriptPath "$ScriptPath.bak" -Force -ErrorAction SilentlyContinue
    Set-Content -Path $ScriptPath -Value $remote -Encoding UTF8
  } catch { return }                                                  # couldn't write (locked/perms): run the current version

  # Relaunch the freshly-written version and hand off. The new copy sees remoteVer==local -> no loop.
  try {
    Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', $ScriptPath) | Out-Null
    exit
  } catch { return }
}

# ---- Client download / install helpers ----
function Get-CurlExe {
  $sys = Join-Path $env:SystemRoot 'System32\curl.exe'
  if (Test-Path $sys) { return $sys }
  $c = Get-Command curl.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  return $null
}
function Get-FreeSpaceGB($path) {
  try {
    $root = [System.IO.Path]::GetPathRoot($path)
    if (-not $root) { return $null }
    return [math]::Round((New-Object System.IO.DriveInfo $root).AvailableFreeSpace / 1GB, 1)
  } catch { return $null }
}
function Fmt-Speed($bytesPerSec) {
  if ($bytesPerSec -le 0) { return '' }
  if ($bytesPerSec -ge 1MB) { return ('{0:N1} MB/s' -f ($bytesPerSec / 1MB)) }
  return ('{0:N0} KB/s' -f ($bytesPerSec / 1KB))
}

# Resumable download. Uses the built-in curl.exe (handles the required headers, the
# 302 redirect, retries, and byte-range resume); polls the growing file for the GUI bar.
# Tries each URL in turn (resuming the same file), then falls back to WebClient if curl
# is somehow missing (no resume, coarse progress).
function Download-File($urls, $dest, $total, $label) {
  if ($urls -isnot [array]) { $urls = @($urls) }
  $dir = Split-Path $dest -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  if ($total -gt 0 -and (Test-Path $dest) -and ((Get-Item $dest).Length -eq $total)) { return $true }  # already complete

  $curl = Get-CurlExe
  if ($curl) {
    foreach ($url in $urls) {
      # Quote every value that can contain spaces - the browser UA AND the dest path
      # (e.g. "D:\Anime And Movies\...") both do. Start-Process -ArgumentList with an
      # ARRAY does NOT quote, so curl saw "-A Mozilla/5.0" then treated the rest of the
      # UA and the path as bogus URLs and never wrote the file. Drive the process
      # directly with an explicitly-quoted argument string instead.
      $argStr = '-L -C - --retry 8 --retry-delay 3 --retry-all-errors --fail -s ' +
                ('-A "{0}" ' -f $BrowserUA) +
                ('-e "{0}" ' -f $Referer) +
                ('-o "{0}" ' -f $dest) +
                ('"{0}"'    -f $url)
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName        = $curl
      $psi.Arguments       = $argStr
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow  = $true
      $p = [System.Diagnostics.Process]::Start($psi)
      $lastLen = 0; $lastT = Get-Date
      while (-not $p.HasExited) {
        Sleep-Pump 600
        $len = 0; try { $len = (Get-Item $dest -ErrorAction SilentlyContinue).Length } catch {}
        $now = Get-Date; $dt = ($now - $lastT).TotalSeconds
        $spd = if ($dt -gt 0.5) { ($len - $lastLen) / $dt } else { 0 }
        if ($spd -gt 0) { $lastLen = $len; $lastT = $now }
        if ($total -gt 0) {
          $pct = [int](($len / $total) * 100); if ($pct -gt 100) { $pct = 100 }
          $bar.Value = [Math]::Max(1, [Math]::Min(100, $pct))
          Set-Status ("Downloading $label - {0:N1} / {1:N1} GB  ({2}%)   {3}`r`nOne-time download. You can leave this running; it resumes if interrupted." -f ($len/1GB), ($total/1GB), $pct, (Fmt-Speed $spd)) $amber
        } else {
          Set-Status ("Downloading $label - {0:N1} GB..." -f ($len/1GB)) $amber
        }
      }
      $code = $p.ExitCode
      if ($code -eq 0) { return $true }
      if ($total -gt 0 -and (Test-Path $dest) -and ((Get-Item $dest).Length -ge $total)) { return $true }
      # else: try the next URL (curl already retried transient errors); keep partial for resume
    }
    return $false
  }

  # Fallback: WebClient (no resume; the whole file restarts on any error)
  foreach ($url in $urls) {
    try {
      Set-Status "Downloading $label (this PC has no curl - no progress bar; please wait)..." $amber
      $wc = New-Object System.Net.WebClient
      $wc.Headers.Add('User-Agent', $BrowserUA)
      $wc.Headers.Add('Referer', $Referer)
      $wc.DownloadFile($url, $dest)
      return $true
    } catch {}
  }
  return $false
}

function Extract-Zip($zip, $dest, $label) {
  try { Add-Type -AssemblyName System.IO.Compression.FileSystem } catch {}
  if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
  $z = $null
  try {
    $z = [System.IO.Compression.ZipFile]::OpenRead($zip)
    $n = $z.Entries.Count; $i = 0
    foreach ($e in $z.Entries) {
      $i++
      $rel = $e.FullName -replace '/', '\'
      $out = Join-Path $dest $rel
      if ($e.FullName.EndsWith('/')) {
        if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
        continue
      }
      $od = Split-Path $out -Parent
      if (-not (Test-Path $od)) { New-Item -ItemType Directory -Path $od -Force | Out-Null }
      [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
      if (($i % 25) -eq 0 -or $i -eq $n) {
        $pct = [int](($i / [math]::Max(1,$n)) * 100)
        $bar.Value = [Math]::Max(1, [Math]::Min(100, $pct))
        Set-Status ("Extracting $label - $i / $n files  ($pct%)") $amber
        [System.Windows.Forms.Application]::DoEvents()
      }
    }
    return $true
  } catch {
    Set-Status ("Extract failed: " + $_.Exception.Message) $red
    return $false
  } finally { if ($z) { $z.Dispose() } }
}

# Download + extract the HD graphics patch into <wowPath>\Data
function Install-HdPatch($wowPath) {
  $dl = Join-Path $env:TEMP 'sil_hd'
  if (-not (Test-Path $dl)) { New-Item -ItemType Directory -Path $dl -Force | Out-Null }
  $zip = Join-Path $dl 'additional_patches_for_335a.zip'
  Set-Status 'Downloading HD graphics patch (~3.2 GB)...' $amber
  if (-not (Download-File $HdUrls $zip $HdBytes 'HD patch')) { Set-Status 'HD patch download failed (skipped - the game still works without it).' $amber; return $false }
  $ex = Join-Path $dl 'x'
  if (Test-Path $ex) { Remove-Item $ex -Recurse -Force -ErrorAction SilentlyContinue }
  if (-not (Extract-Zip $zip $ex 'HD patch')) { return $false }
  $dataDst = Join-Path $wowPath 'Data'
  if (-not (Test-Path $dataDst)) { New-Item -ItemType Directory -Path $dataDst -Force | Out-Null }
  Set-Status 'Installing HD graphics patch...' $amber
  # The archive may hold a Data\ folder or loose .MPQ files - handle both.
  $dataSrc = Get-ChildItem -Path $ex -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq 'Data' } | Select-Object -First 1
  if ($dataSrc) {
    robocopy $dataSrc.FullName $dataDst /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Set-Status 'HD patch copy hit an error (skipped).' $amber; return $false } else { $global:LASTEXITCODE = 0 }
  } else {
    $mpqs = Get-ChildItem -Path $ex -Recurse -File -Filter '*.MPQ' -ErrorAction SilentlyContinue
    if (-not $mpqs) { Set-Status 'HD patch package looked empty (skipped).' $amber; return $false }
    $mpqs | ForEach-Object { Copy-Item $_.FullName -Destination $dataDst -Force }
  }
  try { Remove-Item $zip -Force -ErrorAction SilentlyContinue; Remove-Item $ex -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  Set-Status 'HD graphics patch installed.' $green
  return $true
}

# Download + extract the full client into <parent>\$InstallName; returns the folder with Wow.exe (or $null)
function Install-Client($parent, $installHd) {
  $free = Get-FreeSpaceGB $parent
  $needGB = if ($installHd) { 55 } else { 45 }
  if ($free -ne $null -and $free -lt $needGB) {
    $r = [System.Windows.Forms.MessageBox]::Show(
      ("This install needs about $needGB GB free, but the chosen drive has only $free GB.`n`nContinue anyway?"),
      'Low disk space', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { Set-Status 'Install cancelled (low disk space).' $amber; return $null }
  }
  $target = Join-Path $parent $InstallName
  if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
  $zip = Join-Path (Join-Path $parent '_sil_download') 'ChromieCraft_3.3.5a.zip'

  Set-Status 'Starting the game download (~16.5 GB)...' $amber
  if (-not (Download-File $ClientUrls $zip $ClientBytes 'game client')) {
    Set-Status 'Client download failed. Re-open the launcher to resume where it left off.' $red; return $null
  }
  Set-Status 'Extracting the game (this takes several minutes)...' $amber
  if (-not (Extract-Zip $zip $target 'game')) { return $null }

  $wowExe = Get-ChildItem -Path $target -Filter 'Wow.exe' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $wowExe) { Set-Status 'Downloaded, but Wow.exe was not found in the package.' $red; return $null }
  $wowPath = Split-Path $wowExe.FullName -Parent
  try { Remove-Item $zip -Force -ErrorAction SilentlyContinue } catch {}   # reclaim ~16.5 GB
  if ($installHd) { Install-HdPatch $wowPath | Out-Null }
  return $wowPath
}

function Pick-InstallParent {
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = 'Choose a folder to install the game into (a WoW-3.3.5a-SkillIssue subfolder is created inside it)'
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
  return $null
}

# First-run modal: "have it / download it / cancel" + optional HD checkbox. Returns @{ Action=...; Hd=$bool }
function Show-SetupChoice {
  $d = New-Object System.Windows.Forms.Form
  $d.Text = 'Set up the game'
  $d.Size = New-Object System.Drawing.Size(460, 300)
  $d.StartPosition = 'CenterParent'
  $d.FormBorderStyle = 'FixedDialog'
  $d.MaximizeBox = $false; $d.MinimizeBox = $false
  $d.BackColor = [System.Drawing.Color]::FromArgb(24, 26, 32)

  $lbl = New-Object System.Windows.Forms.Label
  $lbl.Text = "No World of Warcraft 3.3.5a was found on this PC.`n`nWhat would you like to do?"
  $lbl.ForeColor = [System.Drawing.Color]::Gainsboro
  $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 10)
  $lbl.Location = New-Object System.Drawing.Point(20, 18)
  $lbl.Size = New-Object System.Drawing.Size(410, 56)
  $d.Controls.Add($lbl)

  $bDl = New-Object System.Windows.Forms.Button
  $bDl.Text = 'Download & install the game for me  (~16.5 GB)'
  $bDl.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
  $bDl.Size = New-Object System.Drawing.Size(410, 46)
  $bDl.Location = New-Object System.Drawing.Point(20, 80)
  $bDl.BackColor = [System.Drawing.Color]::FromArgb(64, 130, 82)
  $bDl.ForeColor = [System.Drawing.Color]::White; $bDl.FlatStyle = 'Flat'
  $d.Controls.Add($bDl)

  $bHave = New-Object System.Windows.Forms.Button
  $bHave.Text = 'I already have WoW 3.3.5a - let me pick the folder'
  $bHave.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
  $bHave.Size = New-Object System.Drawing.Size(410, 40)
  $bHave.Location = New-Object System.Drawing.Point(20, 134)
  $bHave.BackColor = [System.Drawing.Color]::FromArgb(48, 52, 62)
  $bHave.ForeColor = [System.Drawing.Color]::Gainsboro; $bHave.FlatStyle = 'Flat'
  $d.Controls.Add($bHave)

  $chk = New-Object System.Windows.Forms.CheckBox
  $chk.Text = 'Also install the HD graphics patch  (+3.2 GB, sharper textures)'
  $chk.ForeColor = [System.Drawing.Color]::Gainsboro
  $chk.Font = New-Object System.Drawing.Font('Segoe UI', 9)
  $chk.Location = New-Object System.Drawing.Point(22, 184)
  $chk.Size = New-Object System.Drawing.Size(410, 24)
  $d.Controls.Add($chk)

  $bCancel = New-Object System.Windows.Forms.Button
  $bCancel.Text = 'Cancel'
  $bCancel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
  $bCancel.Size = New-Object System.Drawing.Size(120, 30)
  $bCancel.Location = New-Object System.Drawing.Point(20, 218)
  $bCancel.BackColor = [System.Drawing.Color]::FromArgb(48, 52, 62)
  $bCancel.ForeColor = [System.Drawing.Color]::Gainsboro; $bCancel.FlatStyle = 'Flat'
  $d.Controls.Add($bCancel)

  $result = @{ Action = 'cancel'; Hd = $false }
  $bDl.Add_Click({ $script:__silChoice = 'download'; $d.Close() })
  $bHave.Add_Click({ $script:__silChoice = 'have'; $d.Close() })
  $bCancel.Add_Click({ $script:__silChoice = 'cancel'; $d.Close() })
  $script:__silChoice = 'cancel'
  [void]$d.ShowDialog()
  return @{ Action = $script:__silChoice; Hd = $chk.Checked }
}

# Check for a newer launcher and hand off to it before we build any UI (silent, ~1s; skipped if offline).
Self-Update

$cfg = Load-Config
$MyIP = $null

# ---- UI ----
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Skill Issue Launcher'
$form.Size = New-Object System.Drawing.Size(500, 400)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(24, 26, 32)

$title = New-Object System.Windows.Forms.Label
$title.Text = "It's a Skill issue Mikey"
$title.ForeColor = [System.Drawing.Color]::Gainsboro
$title.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(24, 18)
$form.Controls.Add($title)

$ipLabel = New-Object System.Windows.Forms.Label
$ipLabel.Text = "Server: $ServerIP    Your Tailscale IP: (not connected yet)"
$ipLabel.ForeColor = [System.Drawing.Color]::FromArgb(150,160,175)
$ipLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$ipLabel.AutoSize = $false
$ipLabel.Size = New-Object System.Drawing.Size(450, 20)
$ipLabel.Location = New-Object System.Drawing.Point(24, 54)
$form.Controls.Add($ipLabel)

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Location = New-Object System.Drawing.Point(24, 82)
$bar.Size = New-Object System.Drawing.Size(450, 16)
$bar.Style = 'Continuous'
$form.Controls.Add($bar)

$status = New-Object System.Windows.Forms.Label
$status.Text = 'Starting...'
$status.ForeColor = [System.Drawing.Color]::LightGray
$status.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$status.AutoSize = $false
$status.Size = New-Object System.Drawing.Size(450, 60)
$status.Location = New-Object System.Drawing.Point(24, 106)
$form.Controls.Add($status)

$link = New-Object System.Windows.Forms.LinkLabel
$link.Text = 'Click here to sign in to Tailscale'
$link.LinkColor = [System.Drawing.Color]::FromArgb(120,180,255)
$link.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$link.AutoSize = $true
$link.Location = New-Object System.Drawing.Point(24, 172)
$link.Visible = $false
$form.Controls.Add($link)

$playBtn = New-Object System.Windows.Forms.Button
$playBtn.Text = 'PLAY'
$playBtn.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$playBtn.Size = New-Object System.Drawing.Size(450, 54)
$playBtn.Location = New-Object System.Drawing.Point(24, 210)
$playBtn.BackColor = [System.Drawing.Color]::FromArgb(64, 130, 82)
$playBtn.ForeColor = [System.Drawing.Color]::White
$playBtn.FlatStyle = 'Flat'
$playBtn.Enabled = $false
$form.Controls.Add($playBtn)

$hdLink = New-Object System.Windows.Forms.LinkLabel
$hdLink.Text = 'Install HD graphics patch (+3.2 GB)'
$hdLink.LinkColor = [System.Drawing.Color]::FromArgb(120,180,255)
$hdLink.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$hdLink.AutoSize = $true
$hdLink.Location = New-Object System.Drawing.Point(24, 274)
$hdLink.Visible = $false
$form.Controls.Add($hdLink)

$green = [System.Drawing.Color]::FromArgb(120, 220, 130)
$amber = [System.Drawing.Color]::Khaki
$red   = [System.Drawing.Color]::IndianRed
function Set-Status($msg, $color) {
  $status.Text = $msg
  if ($color) { $status.ForeColor = $color } else { $status.ForeColor = [System.Drawing.Color]::LightGray }
  [System.Windows.Forms.Application]::DoEvents()
}
function Set-MyIP($ip) {
  $script:MyIP = $ip
  if ($ip) { $ipLabel.Text = "Server: $ServerIP    Your Tailscale IP: $ip" }
  [System.Windows.Forms.Application]::DoEvents()
}

# ---- Tailscale: install if missing, sign in, get IP ----
function Ensure-Tailscale {
  $ts = Get-TailscaleExe
  if (-not $ts) {
    $bar.Value = 5; Set-Status 'Tailscale not found - installing it (approve the admin prompt if one appears)...' $amber
    $wg = Get-Command winget -ErrorAction SilentlyContinue
    if ($wg) {
      try {
        Start-Process winget -ArgumentList @('install','--id','Tailscale.Tailscale','-e','--accept-source-agreements','--accept-package-agreements') -Wait
      } catch {}
      for ($i=0; $i -lt 20 -and -not $ts; $i++) { Sleep-Pump 750; $ts = Get-TailscaleExe }
    }
    if (-not $ts) {
      Set-Status 'Please install Tailscale from tailscale.com/download, then re-open this launcher.' $red
      Start-Process 'https://tailscale.com/download/windows'
      return $false
    }
  }

  Set-MyIP (Get-TailscaleIP $ts)
  if (-not $script:MyIP) {
    $bar.Value = 12; Set-Status 'Opening Tailscale sign-in in your browser...'
    $o = Join-Path $env:TEMP ('tsup_o_' + [guid]::NewGuid().ToString('N') + '.txt')
    $e = Join-Path $env:TEMP ('tsup_e_' + [guid]::NewGuid().ToString('N') + '.txt')
    try { Start-Process $ts -ArgumentList 'up' -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError $e | Out-Null } catch {}
    # find the sign-in URL it prints
    $url = $null
    for ($i=0; $i -lt 40 -and -not $url; $i++) {
      Sleep-Pump 500
      $txt = ''
      foreach ($f in @($e,$o)) { if (Test-Path $f) { $txt += (Get-Content $f -Raw -ErrorAction SilentlyContinue) } }
      $m = [regex]::Match($txt, 'https://login\.tailscale\.com/\S+')
      if ($m.Success) { $url = $m.Value.TrimEnd([char]0) }
      if (Get-TailscaleIP $ts) { break }   # already came up (was just logged out briefly)
    }
    if ($url) {
      $link.Tag = $url; $link.Visible = $true
      try { Start-Process $url } catch {}
      Set-Status "Sign in (or create a FREE account) in the browser that opened, then come back here. If it didn't open, click the blue link below. Waiting for you to finish..." $amber
    } else {
      Set-Status 'Waiting for Tailscale to connect... finish sign-in in Tailscale if prompted.' $amber
    }
    # wait until connected
    for ($i=0; $i -lt 600; $i++) {
      $ip = Get-TailscaleIP $ts
      if ($ip) { Set-MyIP $ip; break }
      Sleep-Pump 500
    }
    $link.Visible = $false
  }

  if (-not $script:MyIP) {
    Set-Status 'Not connected to Tailscale yet. Finish the sign-in, then re-open the launcher.' $amber
    return $false
  }
  return $true
}

# ---- Reachability ----
function Test-Server { try { return (Test-Connection -ComputerName $ServerIP -Count 1 -Quiet -ErrorAction SilentlyContinue) } catch { return $false } }

# ---- Add-ons + custom patch update ----
function Update-Content {
  if (-not (Test-WowFolder $cfg.WowPath)) {
    $choice = Show-SetupChoice
    if ($choice.Action -eq 'have') {
      Set-Status 'Choose your WoW 3.3.5a folder (the one with Wow.exe)...' $amber
      $p = Pick-WowFolder
      if (-not (Test-WowFolder $p)) { Set-Status 'That folder has no Wow.exe. Close and re-open to try again.' $red; return $false }
      $cfg.WowPath = $p; Save-Config $cfg
      if ($choice.Hd) { Install-HdPatch $cfg.WowPath | Out-Null }
    } elseif ($choice.Action -eq 'download') {
      Set-Status 'Choose where to install the game...' $amber
      $parent = Pick-InstallParent
      if (-not $parent) { Set-Status 'Install cancelled. Re-open the launcher when you are ready.' $amber; return $false }
      $wp = Install-Client $parent $choice.Hd
      if (-not (Test-WowFolder $wp)) { Set-Status 'The client install did not finish. Re-open the launcher to resume the download.' $red; return $false }
      $cfg.WowPath = $wp; Save-Config $cfg
    } else {
      Set-Status 'Setup cancelled.' $amber; return $false
    }
  }

  $bar.Value = 60; Set-Status 'Checking for add-on / patch updates...'
  $latest = $null
  try { $latest = (Invoke-RestMethod -Uri $ApiUrl -Headers @{ 'User-Agent' = 'SkillIssueLauncher' } -TimeoutSec 15).sha } catch {}

  if ($latest -and $latest -eq $cfg.LastSha) {
    $bar.Value = 85; Set-Status 'Add-ons and patch already up to date.' $green
  } else {
    $bar.Value = 68; Set-Status 'Downloading latest add-ons + patch...'
    $tmp = Join-Path $env:TEMP ('sil_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $zip = Join-Path $tmp 'client.zip'
    try {
      Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -TimeoutSec 120 -UseBasicParsing
      $bar.Value = 78; Set-Status 'Installing...'
      Expand-Archive -Path $zip -DestinationPath $tmp -Force
      $pkg = Get-ChildItem -Path $tmp -Directory | Where-Object { (Test-Path (Join-Path $_.FullName 'AddOns')) -or (Test-Path (Join-Path $_.FullName 'Patches')) } | Select-Object -First 1
      if ($pkg) {
        $srcA = Join-Path $pkg.FullName 'AddOns'
        if (Test-Path $srcA) {
          $dstA = Join-Path $cfg.WowPath 'Interface\AddOns'
          if (-not (Test-Path $dstA)) { New-Item -ItemType Directory -Path $dstA -Force | Out-Null }
          Get-ChildItem -Path $srcA -Directory | ForEach-Object { Copy-Item -Path $_.FullName -Destination $dstA -Recurse -Force }
        }
        $srcP = Join-Path $pkg.FullName 'Patches'
        if (Test-Path $srcP) {
          $dstD = Join-Path $cfg.WowPath 'Data'
          if (Test-Path $dstD) { Get-ChildItem -Path $srcP -File | ForEach-Object { Copy-Item -Path $_.FullName -Destination $dstD -Force } }
        }
        if ($latest) { $cfg.LastSha = $latest; Save-Config $cfg }
        $bar.Value = 85; Set-Status 'Add-ons + patch updated.' $green
      } else { $bar.Value = 85; Set-Status 'Update package looked empty - kept existing files.' $amber }
    } catch {
      $bar.Value = 85; Set-Status ('Update skipped (' + $_.Exception.Message + '). Using existing files.') $amber
    }
  }

  $rl = "set realmlist $ServerIP"
  foreach ($p in @((Join-Path $cfg.WowPath 'realmlist.wtf'),
                   (Join-Path $cfg.WowPath 'Data\enUS\realmlist.wtf'),
                   (Join-Path $cfg.WowPath 'Data\enGB\realmlist.wtf'))) {
    if (Test-Path (Split-Path $p)) { try { Set-Content -Path $p -Value $rl -Encoding ASCII } catch {} }
  }
  return $true
}

$link.Add_LinkClicked({ if ($link.Tag) { try { Start-Process ([string]$link.Tag) } catch {} } })
$hdLink.Add_LinkClicked({
  if (-not (Test-WowFolder $cfg.WowPath)) { Set-Status 'Set up your game folder first (hit PLAY once).' $amber; return }
  $playBtn.Enabled = $false; $hdLink.Enabled = $false
  try { Install-HdPatch $cfg.WowPath | Out-Null } catch { Set-Status ('HD patch error: ' + $_.Exception.Message) $red }
  $bar.Value = 100; $playBtn.Enabled = $true; $hdLink.Enabled = $true
})
$playBtn.Add_Click({
  $wow = Join-Path $cfg.WowPath 'Wow.exe'
  if (Test-Path $wow) { Start-Process -FilePath $wow -WorkingDirectory $cfg.WowPath; $form.Close() }
  else { Set-Status 'Wow.exe not found - re-open the launcher to re-pick your folder.' $red }
})

$form.Add_Shown({
  $form.Activate()
  try {
    if (Ensure-Tailscale) {
      $bar.Value = 50; Set-Status 'Checking connection to the server...'
      $reach = Test-Server
      Update-Content | Out-Null
      if (Test-WowFolder $cfg.WowPath) { $hdLink.Visible = $true }
      $bar.Value = 100
      if ($reach) {
        Set-Status "Ready. Realm: $RealmName - hit PLAY." $green
      } else {
        Set-Status "You're on Tailscale (your IP is shown above) but can't reach the server yet. Ask Josh to add you to his Tailscale network, then re-open. You can still try PLAY." $amber
      }
    }
  } catch { Set-Status ('Error: ' + $_.Exception.Message) $red }
  $playBtn.Enabled = $true
  $playBtn.Focus()
})

[void]$form.ShowDialog()
