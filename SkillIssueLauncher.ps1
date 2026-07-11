# SkillIssueLauncher.ps1
# Tiny "update-and-play" launcher for the "It's a Skill issue Mikey" server.
# Zero dependencies: Windows PowerShell + WinForms. No install, no Node, no git needed.
# On open it: updates add-ons from the public client repo, sets the realmlist,
# checks the server is reachable, then lets you hit PLAY to launch WoW.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---- CONFIG (edit these if they ever change) ----
$RepoOwner = 'AlfredGoldfish'
$RepoName  = 'azerothcore-skilllevel-client'
$Branch    = 'main'
$ServerIP  = '100.109.250.55'
$RealmName = "It's a Skill issue Mikey"
# -------------------------------------------------

$ZipUrl  = "https://github.com/$RepoOwner/$RepoName/archive/refs/heads/$Branch.zip"
$ApiUrl  = "https://api.github.com/repos/$RepoOwner/$RepoName/commits/$Branch"
$CfgDir  = Join-Path $env:LOCALAPPDATA 'SkillIssueLauncher'
$CfgFile = Join-Path $CfgDir 'config.json'

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

$cfg = Load-Config

# ---- UI ----
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Skill Issue Launcher'
$form.Size = New-Object System.Drawing.Size(480, 300)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(24, 26, 32)

$title = New-Object System.Windows.Forms.Label
$title.Text = "It's a Skill issue Mikey"
$title.ForeColor = [System.Drawing.Color]::Gainsboro
$title.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(24, 22)
$form.Controls.Add($title)

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Location = New-Object System.Drawing.Point(24, 92)
$bar.Size = New-Object System.Drawing.Size(430, 16)
$bar.Style = 'Continuous'
$form.Controls.Add($bar)

$status = New-Object System.Windows.Forms.Label
$status.Text = 'Starting...'
$status.ForeColor = [System.Drawing.Color]::LightGray
$status.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$status.AutoSize = $false
$status.Size = New-Object System.Drawing.Size(430, 56)
$status.Location = New-Object System.Drawing.Point(24, 116)
$form.Controls.Add($status)

$playBtn = New-Object System.Windows.Forms.Button
$playBtn.Text = 'PLAY'
$playBtn.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$playBtn.Size = New-Object System.Drawing.Size(430, 50)
$playBtn.Location = New-Object System.Drawing.Point(24, 184)
$playBtn.BackColor = [System.Drawing.Color]::FromArgb(64, 130, 82)
$playBtn.ForeColor = [System.Drawing.Color]::White
$playBtn.FlatStyle = 'Flat'
$playBtn.Enabled = $false
$form.Controls.Add($playBtn)

function Set-Status($msg, $color) {
  $status.Text = $msg
  if ($color) { $status.ForeColor = $color }
  [System.Windows.Forms.Application]::DoEvents()
}
$green = [System.Drawing.Color]::FromArgb(120, 220, 130)
$amber = [System.Drawing.Color]::Khaki
$red   = [System.Drawing.Color]::IndianRed

function Update-AddOns {
  if (-not (Test-WowFolder $cfg.WowPath)) {
    Set-Status 'First run: choose your WoW 3.3.5a folder...' $amber
    $p = Pick-WowFolder
    if (-not (Test-WowFolder $p)) {
      Set-Status 'That folder has no Wow.exe. Close and re-open to try again.' $red
      return
    }
    $cfg.WowPath = $p; Save-Config $cfg
  }

  $bar.Value = 10; Set-Status 'Checking for add-on updates...'
  $latest = $null
  try {
    $r = Invoke-RestMethod -Uri $ApiUrl -Headers @{ 'User-Agent' = 'SkillIssueLauncher' } -TimeoutSec 15
    $latest = $r.sha
  } catch {}

  if ($latest -and $latest -eq $cfg.LastSha) {
    $bar.Value = 80; Set-Status 'Add-ons already up to date.' $green
  } else {
    $bar.Value = 25; Set-Status 'Downloading latest add-ons...'
    $tmp = Join-Path $env:TEMP ('sil_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $zip = Join-Path $tmp 'client.zip'
    try {
      Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -TimeoutSec 90 -UseBasicParsing
      $bar.Value = 55; Set-Status 'Installing add-ons...'
      Expand-Archive -Path $zip -DestinationPath $tmp -Force
      $pkg = Get-ChildItem -Path $tmp -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'AddOns') } | Select-Object -First 1
      if ($pkg) {
        $src = Join-Path $pkg.FullName 'AddOns'
        $dst = Join-Path $cfg.WowPath 'Interface\AddOns'
        if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
        Get-ChildItem -Path $src -Directory | ForEach-Object {
          Copy-Item -Path $_.FullName -Destination $dst -Recurse -Force
        }
        # install custom client patches (small custom MPQs) into Data\
        $patchSrc = Join-Path $pkg.FullName 'Patches'
        if (Test-Path $patchSrc) {
          $dataDst = Join-Path $cfg.WowPath 'Data'
          if (Test-Path $dataDst) {
            Get-ChildItem -Path $patchSrc -File | ForEach-Object {
              Copy-Item -Path $_.FullName -Destination $dataDst -Force
            }
          }
        }
        if ($latest) { $cfg.LastSha = $latest; Save-Config $cfg }
        $bar.Value = 80; Set-Status 'Add-ons updated.' $green
      } else {
        $bar.Value = 80; Set-Status 'Update package had no AddOns folder - kept existing.' $amber
      }
    } catch {
      $bar.Value = 80; Set-Status ('Update skipped (' + $_.Exception.Message + '). Using existing add-ons.') $amber
    } finally {
      Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  # realmlist (write to every likely location)
  $rl = "set realmlist $ServerIP"
  foreach ($p in @(
      (Join-Path $cfg.WowPath 'realmlist.wtf'),
      (Join-Path $cfg.WowPath 'Data\enUS\realmlist.wtf'),
      (Join-Path $cfg.WowPath 'Data\enGB\realmlist.wtf'))) {
    if (Test-Path (Split-Path $p)) { try { Set-Content -Path $p -Value $rl -Encoding ASCII } catch {} }
  }

  $bar.Value = 92; Set-Status 'Checking server connection...'
  $up = $false
  try { $up = Test-Connection -ComputerName $ServerIP -Count 1 -Quiet -ErrorAction SilentlyContinue } catch {}
  $bar.Value = 100
  if ($up) {
    Set-Status "Ready. Realm: $RealmName" $green
  } else {
    Set-Status "Ready - but the server did not answer. Is Tailscale connected and the host PC on? You can still try PLAY." $amber
  }
}

$playBtn.Add_Click({
  $wow = Join-Path $cfg.WowPath 'Wow.exe'
  if (Test-Path $wow) {
    Start-Process -FilePath $wow -WorkingDirectory $cfg.WowPath
    $form.Close()
  } else {
    Set-Status 'Wow.exe not found - re-open the launcher to re-pick your folder.' $red
  }
})

$form.Add_Shown({
  $form.Activate()
  try { Update-AddOns } catch { Set-Status ('Error: ' + $_.Exception.Message) $red }
  $playBtn.Enabled = $true
  $playBtn.Focus()
})

[void]$form.ShowDialog()
