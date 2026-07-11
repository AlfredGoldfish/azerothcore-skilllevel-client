# SkillIssueLauncher.ps1
# One-click launcher for the "It's a Skill issue Mikey" server.
# Zero dependencies: Windows PowerShell + WinForms. No install, no Node, no git needed.
# It: (1) installs Tailscale if missing + walks you through sign-in and shows your IP,
#     (2) updates add-ons + the custom patch, (3) sets realmlist, (4) PLAY launches WoW.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---- CONFIG (edit these if they ever change) ----
$RepoOwner = 'AlfredGoldfish'
$RepoName  = 'azerothcore-skilllevel-client'
$Branch    = 'main'
$ServerIP  = '100.109.250.55'                       # Josh's PC on Tailscale = where the server lives
$RealmName = "It's a Skill issue Mikey"
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

$cfg = Load-Config
$MyIP = $null

# ---- UI ----
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Skill Issue Launcher'
$form.Size = New-Object System.Drawing.Size(500, 360)
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
    Set-Status 'Choose your WoW 3.3.5a folder (the one with Wow.exe)...' $amber
    $p = Pick-WowFolder
    if (-not (Test-WowFolder $p)) { Set-Status 'That folder has no Wow.exe. Close and re-open to try again.' $red; return $false }
    $cfg.WowPath = $p; Save-Config $cfg
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
