# SkillIssueLauncher.ps1
# One-click launcher for the "It's a Skill issue Mikey" server.
# Zero dependencies: Windows PowerShell + WinForms. No install, no Node, no git needed.
# It: (1) installs Tailscale if missing + walks you through sign-in and shows your IP,
#     (2) updates add-ons + the custom patch, (3) sets realmlist, (4) PLAY launches WoW.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ScriptPath = $PSCommandPath                          # full path of THIS script (for self-update)

# ---- CONFIG (edit these if they ever change) ----
$LauncherVersion = 7                                  # BUMP THIS every time you change this script,
                                                      # so everyone's launcher self-updates on next open.
$RepoOwner = 'AlfredGoldfish'
$RepoName  = 'azerothcore-skilllevel-client'
$Branch    = 'main'
$ServerIP  = '100.109.250.55'                       # Josh's PC on Tailscale = where the server lives
$RealmName = "It's a Skill issue Mikey"
$RawBase   = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"

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

# Preferred download = BitTorrent (pulls from many seeders, ~5-6x faster than the single
# HTTP mirror, and dodges the mirror's per-IP throttle). aria2c handles it headlessly so
# the player never touches a torrent client; HTTP mirrors above remain the fallback.
$ClientMagnet = 'magnet:?xt=urn:btih:2ba2833baf733ce0a16040d43ed09491f2bf2ab2&dn=ChromieCraft_3.3.5a.zip&tr=udp%3A%2F%2Ftracker.openbittorrent.com%3A80%2Fannounce&tr=http%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2Ftracker.uw0.xyz%3A6969%2Fannounce&tr=udp%3A%2F%2Ftracker.zerobytes.xyz%3A1337%2Fannounce'
$Aria2Url     = "$RawBase/aria2c.exe"               # standalone downloader, fetched + cached on first use
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
  $c = $null
  if (Test-Path $CfgFile) { try { $c = (Get-Content $CfgFile -Raw | ConvertFrom-Json) } catch {} }
  if (-not $c) { $c = [pscustomobject]@{} }
  # Guarantee every field exists so later `$cfg.Field = x` never throws on old configs.
  if (-not $c.PSObject.Properties['WowPath'])           { $c | Add-Member -NotePropertyName WowPath -NotePropertyValue '' -Force }
  if (-not $c.PSObject.Properties['LastSha'])           { $c | Add-Member -NotePropertyName LastSha -NotePropertyValue '' -Force }
  if (-not $c.PSObject.Properties['HideDownloadOffer'])  { $c | Add-Member -NotePropertyName HideDownloadOffer -NotePropertyValue $false -Force }
  return $c
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

# ---- Self-update: pull the latest launcher script from the repo; apply on NEXT launch ----
# Pull, not push: every open, the launcher compares its own $LauncherVersion to the repo's.
# If the repo is newer, it overwrites this file on disk and the new version runs next open.
# (We deliberately do NOT relaunch mid-session - spawning a fresh powershell was intermittently
# failing to start with 0xc0000142 under desktop-heap pressure. Apply-on-next-launch is robust.)
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
    $script:UpdatePending = $true      # new version is on disk; it runs the next time the launcher opens
  } catch { return }                   # couldn't write (locked/perms): just run the current version
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

# Fetch + cache aria2c.exe (the headless torrent/multi-connection downloader). One-time ~5 MB.
function Ensure-Aria2 {
  $toolDir = Join-Path $CfgDir 'tools'
  $exe = Join-Path $toolDir 'aria2c.exe'
  if (Test-Path $exe) { return $exe }
  Set-Status 'Getting the fast downloader (one-time, ~5 MB)...' $amber
  if (-not (Test-Path $toolDir)) { New-Item -ItemType Directory -Path $toolDir -Force | Out-Null }
  $tmp = Join-Path $toolDir 'aria2c.exe.part'
  if (Download-File @($Aria2Url) $tmp 0 'downloader') {
    try { Move-Item $tmp $exe -Force; return $exe } catch { return $null }
  }
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  return $null
}

# Download a magnet/torrent with aria2c into $destDir\$destName. The file is sparse-preallocated
# so we can't poll its size - we parse aria2's console progress instead, and treat "the .aria2
# control file is gone" (which aria2 deletes only on full completion) as the success signal.
function Download-Torrent($magnet, $destDir, $destName, $total, $label) {
  $aria = Ensure-Aria2
  if (-not $aria) { return $false }
  if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
  $destFile = Join-Path $destDir $destName
  $log = Join-Path $env:TEMP ('sil_aria_' + [guid]::NewGuid().ToString('N') + '.log')
  '' | Set-Content $log -Encoding ASCII; '' | Set-Content ($log + '.err') -Encoding ASCII
  $argStr = ('--dir="{0}" -o "{1}" ' -f $destDir, $destName) +
            '--seed-time=0 --file-allocation=none --continue=true --allow-overwrite=true --auto-file-renaming=false ' +
            '--summary-interval=1 --console-log-level=warn --enable-color=false --bt-stop-timeout=120 ' +
            ('"{0}"' -f $magnet)
  $p = Start-Process -FilePath $aria -ArgumentList $argStr -PassThru -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError ($log + '.err')
  $rx = '\[#\w+\s+([0-9.]+[KMGTP]?i?B)/([0-9.]+[KMGTP]?i?B)\((\d+)%\)[^\]]*\]'
  while (-not $p.HasExited) {
    Sleep-Pump 1000
    $tail = ''
    try { $tail = ((Get-Content $log -Tail 6 -ErrorAction SilentlyContinue) + (Get-Content ($log + '.err') -Tail 6 -ErrorAction SilentlyContinue)) -join "`n" } catch {}
    $mm = [regex]::Matches($tail, $rx)
    if ($mm.Count -gt 0) {
      $tok  = $mm[$mm.Count - 1]
      $done = $tok.Groups[1].Value; $tot = $tok.Groups[2].Value; $pct = [int]$tok.Groups[3].Value
      $dlm  = [regex]::Match($tok.Value, 'DL:([0-9.]+[KMGTP]?i?B)')
      $spd  = if ($dlm.Success) { $dlm.Groups[1].Value + '/s' } else { '' }
      $bar.Value = [Math]::Max(1, [Math]::Min(100, $pct))
      Set-Status ("Downloading $label via torrent - $done / $tot ($pct%)   $spd`r`nPulling from multiple peers - much faster. You can leave this running; it resumes if interrupted.") $amber
    } else {
      Set-Status ("Finding download peers for $label (a few seconds)...") $amber
    }
  }
  try { $p.WaitForExit() } catch {}
  Remove-Item $log, ($log + '.err') -Force -ErrorAction SilentlyContinue
  # aria2 removes the .aria2 control file only when the download is 100% complete.
  return ((Test-Path $destFile) -and (-not (Test-Path ($destFile + '.aria2'))))
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
  $dlDir = Join-Path $parent '_sil_download'
  $zip   = Join-Path $dlDir 'ChromieCraft_3.3.5a.zip'

  Set-Status 'Starting the game download (~16.5 GB)...' $amber
  # Prefer the torrent (many seeders = much faster, and dodges the mirror's per-IP throttle).
  $got = Download-Torrent $ClientMagnet $dlDir 'ChromieCraft_3.3.5a.zip' $ClientBytes 'game client'
  if (-not $got) {
    # Torrent didn't pan out - clear its (sparse/incomplete) file so the HTTP "already
    # complete" size check can't be fooled by the full-size sparse allocation, then fall back.
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item ($zip + '.aria2') -Force -ErrorAction SilentlyContinue
    Set-Status 'Torrent unavailable - switching to the direct download...' $amber
    $got = Download-File $ClientUrls $zip $ClientBytes 'game client'
  }
  if (-not $got) {
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
  $d.Size = New-Object System.Drawing.Size(460, 336)
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

  $chkNoOffer = New-Object System.Windows.Forms.CheckBox
  $chkNoOffer.Text = "Don't offer to download the game again (I'll use my own client)"
  $chkNoOffer.ForeColor = [System.Drawing.Color]::FromArgb(150,160,175)
  $chkNoOffer.Font = New-Object System.Drawing.Font('Segoe UI', 9)
  $chkNoOffer.Location = New-Object System.Drawing.Point(22, 212)
  $chkNoOffer.Size = New-Object System.Drawing.Size(410, 24)
  $d.Controls.Add($chkNoOffer)

  $bCancel = New-Object System.Windows.Forms.Button
  $bCancel.Text = 'Cancel'
  $bCancel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
  $bCancel.Size = New-Object System.Drawing.Size(120, 30)
  $bCancel.Location = New-Object System.Drawing.Point(20, 248)
  $bCancel.BackColor = [System.Drawing.Color]::FromArgb(48, 52, 62)
  $bCancel.ForeColor = [System.Drawing.Color]::Gainsboro; $bCancel.FlatStyle = 'Flat'
  $d.Controls.Add($bCancel)

  $result = @{ Action = 'cancel'; Hd = $false }
  $bDl.Add_Click({ $script:__silChoice = 'download'; $d.Close() })
  $bHave.Add_Click({ $script:__silChoice = 'have'; $d.Close() })
  $bCancel.Add_Click({ $script:__silChoice = 'cancel'; $d.Close() })
  $script:__silChoice = 'cancel'
  [void]$d.ShowDialog()
  return @{ Action = $script:__silChoice; Hd = $chk.Checked; NoOffer = $chkNoOffer.Checked }
}

# Make a freshly-downloaded client launch windowed 1920x1080. The ChromieCraft client ships
# with a partial Config.wtf (hwDetect/realm/TOS but NO gxWindow/gxResolution -> fullscreen), so
# we MERGE our three display keys into whatever's there, replacing them if present and appending
# if missing, and leaving every other line untouched. hwDetect "0" is essential - without it WoW
# re-detects the GPU on first launch and resets the window/resolution back to fullscreen-native.
# Only called on a fresh DOWNLOAD (not "I already have it"), so a player's own client is untouched.
function Seed-ClientConfig($wowPath) {
  if (-not (Test-WowFolder $wowPath)) { return }
  $wtfDir = Join-Path $wowPath 'WTF'
  $cfgWtf = Join-Path $wtfDir 'Config.wtf'
  if (-not (Test-Path $wtfDir)) { New-Item -ItemType Directory -Path $wtfDir -Force | Out-Null }
  $want = [ordered]@{ 'gxWindow' = '1'; 'gxResolution' = '1920x1080'; 'hwDetect' = '0' }
  $existing = @()
  if (Test-Path $cfgWtf) { $existing = @(Get-Content $cfgWtf -ErrorAction SilentlyContinue) }
  $applied = @{}
  $out = @(foreach ($line in $existing) {
    $m = [regex]::Match($line, '^\s*SET\s+(\w+)\s')
    if ($m.Success -and $want.Contains($m.Groups[1].Value)) {
      $k = $m.Groups[1].Value; $applied[$k] = $true
      'SET ' + $k + ' "' + $want[$k] + '"'
    } else { $line }
  })
  foreach ($k in $want.Keys) { if (-not $applied[$k]) { $out += ('SET ' + $k + ' "' + $want[$k] + '"') } }
  try { Set-Content -Path $cfgWtf -Value $out -Encoding ASCII } catch {}
}

# Act on a Show-SetupChoice result: records the "don't offer" flag, then downloads or picks a
# client folder. Returns $true if a client got configured (so callers know to continue to add-ons).
function Apply-SetupChoice($choice) {
  if ($choice.NoOffer) { $cfg.HideDownloadOffer = $true; Save-Config $cfg }
  if ($choice.Action -eq 'have') {
    Set-Status 'Choose your WoW 3.3.5a folder (the one with Wow.exe)...' $amber
    $p = Pick-WowFolder
    if (-not (Test-WowFolder $p)) { Set-Status 'That folder has no Wow.exe. Close and re-open to try again.' $red; return $false }
    $cfg.WowPath = $p; Save-Config $cfg
    if ($choice.Hd) { Install-HdPatch $cfg.WowPath | Out-Null }
    return $true
  } elseif ($choice.Action -eq 'download') {
    Set-Status 'Choose where to install the game...' $amber
    $parent = Pick-InstallParent
    if (-not $parent) { Set-Status 'Install cancelled. Re-open the launcher when you are ready.' $amber; return $false }
    $wp = Install-Client $parent $choice.Hd
    if (-not (Test-WowFolder $wp)) { Set-Status 'The client install did not finish. Re-open to resume the download.' $red; return $false }
    $cfg.WowPath = $wp; Save-Config $cfg
    Seed-ClientConfig $cfg.WowPath
    return $true
  }
  return $false
}

# Single-instance guard: if a launcher is already open, don't stack up another (piled-up hidden
# instances exhaust desktop heap and make new powershell launches fail with 0xc0000142).
$script:__silMutex = New-Object System.Threading.Mutex($false, 'SkillIssueLauncher_SingleInstance')
$gotMutex = $false
try { $gotMutex = $script:__silMutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $gotMutex = $true }  # prior instance crashed; we own it now
catch { $gotMutex = $true }                                             # never let mutex trouble block startup
if (-not $gotMutex) {
  [void][System.Windows.Forms.MessageBox]::Show('The Skill Issue Launcher is already open - check your taskbar.', 'Skill Issue Launcher', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
  exit
}

# Check for a newer launcher on disk before building the UI (silent, ~1s; applied next open).
$script:UpdatePending = $false
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

$dlLink = New-Object System.Windows.Forms.LinkLabel
$dlLink.Text = 'Get / reinstall the game'
$dlLink.LinkColor = [System.Drawing.Color]::FromArgb(120,180,255)
$dlLink.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$dlLink.AutoSize = $true
$dlLink.Location = New-Object System.Drawing.Point(24, 274)
$dlLink.Visible = $true
$form.Controls.Add($dlLink)

$hdLink = New-Object System.Windows.Forms.LinkLabel
$hdLink.Text = 'Install HD graphics patch (+3.2 GB)'
$hdLink.LinkColor = [System.Drawing.Color]::FromArgb(120,180,255)
$hdLink.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$hdLink.AutoSize = $true
$hdLink.Location = New-Object System.Drawing.Point(24, 300)
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
    if ($cfg.HideDownloadOffer) {
      # User opted out of the download offer - don't nag. They can use the main-window link.
      Set-Status "No game folder set. Click 'Get / reinstall the game' below to (re)install." $amber
      return $true
    }
    $choice = Show-SetupChoice
    if (-not (Apply-SetupChoice $choice)) {
      if ($choice.Action -eq 'cancel') { Set-Status 'Setup cancelled.' $amber }
      return $false
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
$dlLink.Add_LinkClicked({
  # Escape hatch: (re)install the game on demand, and clear the "don't offer" flag.
  $cfg.HideDownloadOffer = $false; Save-Config $cfg
  $playBtn.Enabled = $false; $dlLink.Enabled = $false; $hdLink.Enabled = $false
  try {
    $choice = Show-SetupChoice
    if (Apply-SetupChoice $choice) {
      Update-Content | Out-Null          # install add-ons + set realmlist for the now-configured client
      if (Test-WowFolder $cfg.WowPath) { $hdLink.Visible = $true; Set-Status "Ready. Realm: $RealmName - hit PLAY." $green }
    }
  } catch { Set-Status ('Error: ' + $_.Exception.Message) $red }
  $bar.Value = 100; $playBtn.Enabled = $true; $dlLink.Enabled = $true; $hdLink.Enabled = $true
})
$playBtn.Add_Click({
  $wow = Join-Path $cfg.WowPath 'Wow.exe'
  if (Test-Path $wow) { Start-Process -FilePath $wow -WorkingDirectory $cfg.WowPath; $form.Close() }
  else { Set-Status "No game folder set - click 'Get / reinstall the game' below to install it." $red }
})

$form.Add_Shown({
  $form.Activate()
  if ($script:UpdatePending) { $form.Text = 'Skill Issue Launcher - update ready (restart to apply)' }
  try {
    if (Ensure-Tailscale) {
      $bar.Value = 50; Set-Status 'Checking connection to the server...'
      $reach = Test-Server
      Update-Content | Out-Null
      $haveClient = Test-WowFolder $cfg.WowPath
      if ($haveClient) { $hdLink.Visible = $true }
      $bar.Value = 100
      if (-not $haveClient) {
        Set-Status "No game set up yet. Click 'Get / reinstall the game' below to install it." $amber
      } elseif ($reach) {
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
