#Requires -Version 5.1
<#
.SYNOPSIS
    Watch-SystemHealth.ps1 — Lightweight Windows system monitoring with email alerting.

.DESCRIPTION
    Checks disk space, CPU usage, and the status of critical Windows services.
    Sends a formatted HTML email alert if any threshold is breached.
    Designed to run on a schedule via Windows Task Scheduler.

.PARAMETER ConfigPath
    Optional path to an external JSON config file. Defaults to config embedded below.

.EXAMPLE
    .\Watch-SystemHealth.ps1
    Runs all checks using the built-in configuration.

.EXAMPLE
    .\Watch-SystemHealth.ps1 -ConfigPath "C:\Monitoring\config.json"
    Runs checks using settings from an external JSON file.

.NOTES
    Author      : [Your Name]
    Version     : 1.0.0
    Requires    : PowerShell 5.1+, network access to SMTP server
    License     : MIT
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1 — CONFIGURATION
# Edit these values to match your environment.
# You can also point -ConfigPath to a JSON file with the same keys.
# ─────────────────────────────────────────────────────────────────────────────

$DefaultConfig = @{

    # ── Email settings ────────────────────────────────────────────────────────
    Email = @{
        SmtpServer  = 'smtp.yourdomain.com'       # SMTP server hostname
        SmtpPort    = 587                          # 587 = TLS, 465 = SSL, 25 = plain
        UseSsl      = $true                        # $true recommended for TLS/SSL
        From        = 'monitoring@yourdomain.com'  # Sender address
        To          = @('admin@yourdomain.com')    # One or more recipient addresses
        Subject     = '[ALERT] System Health Warning on {HOSTNAME}'
        # Leave Username/Password empty to use anonymous SMTP (internal relay)
        Username    = ''
        Password    = ''
    }

    # ── Disk space thresholds ─────────────────────────────────────────────────
    Disk = @{
        # Alert when free space on any drive falls below this percentage
        FreeSpaceWarningPct  = 20   # Warning level  — yellow alert
        FreeSpaceCriticalPct = 10   # Critical level — red alert
        # Drives to EXCLUDE from checks (e.g. optical drives, USB sticks)
        ExcludeDriveLetters  = @('D', 'E')
    }

    # ── CPU usage thresholds ──────────────────────────────────────────────────
    CPU = @{
        # Samples averaged over SampleSeconds to smooth out short spikes
        WarningPct   = 85    # Warning  — sustained high CPU
        CriticalPct  = 95    # Critical — near-maxed CPU
        SampleCount  = 3     # Number of samples to average
        SampleSeconds = 2    # Seconds between samples
    }

    # ── Services to monitor ───────────────────────────────────────────────────
    # Add any service short name here. Alert fires if the service is not Running.
    Services = @(
        'Spooler'         # Print Spooler
        'W32Time'         # Windows Time
        'wuauserv'        # Windows Update
        'Winmgmt'         # WMI
        'EventLog'        # Windows Event Log
        # Add your own:
        # 'MSSQLSERVER'   # SQL Server
        # 'W3SVC'         # IIS
        # 'TeamViewer'    # TeamViewer
    )

    # ── Log settings ──────────────────────────────────────────────────────────
    Log = @{
        Enabled  = $true
        Path     = "$PSScriptRoot\Logs\SystemHealth_{DATE}.log"
        # Logs older than this many days are auto-deleted
        RetainDays = 30
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2 — LOAD EXTERNAL CONFIG (optional)
# ─────────────────────────────────────────────────────────────────────────────

function Merge-Config {
    param($Base, $Override)
    foreach ($key in $Override.Keys) {
        if ($Base.ContainsKey($key) -and $Base[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            Merge-Config -Base $Base[$key] -Override $Override[$key]
        } else {
            $Base[$key] = $Override[$key]
        }
    }
}

$Config = $DefaultConfig

if ($ConfigPath -and (Test-Path $ConfigPath)) {
    try {
        $json = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        $jsonHash = @{}
        $json.PSObject.Properties | ForEach-Object { $jsonHash[$_.Name] = $_.Value }
        Merge-Config -Base $Config -Override $jsonHash
        Write-Verbose "Loaded external config from: $ConfigPath"
    } catch {
        Write-Warning "Could not load config from '$ConfigPath'. Using defaults. Error: $_"
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3 — LOGGING
# ─────────────────────────────────────────────────────────────────────────────

$LogPath = $null

function Initialize-Log {
    if (-not $Config.Log.Enabled) { return }

    $datestamp  = Get-Date -Format 'yyyy-MM-dd'
    $script:LogPath = $Config.Log.Path -replace '\{DATE\}', $datestamp
    $logDir = Split-Path $script:LogPath -Parent

    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    # Rotate old logs
    Get-ChildItem $logDir -Filter '*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$Config.Log.RetainDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','CRIT')]
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    Write-Verbose $line
    if ($Config.Log.Enabled -and $script:LogPath) {
        Add-Content -Path $script:LogPath -Value $line -ErrorAction SilentlyContinue
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4 — CHECK FUNCTIONS
# Each function returns a [PSCustomObject] with:
#   Category, Name, Status ('OK'|'WARN'|'CRIT'), Value, Threshold, Message
# ─────────────────────────────────────────────────────────────────────────────

function Get-DiskChecks {
    $results = @()
    $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
              Where-Object {
                  $_.Used -ne $null -and
                  $_.Root -match '^[A-Z]:\\' -and
                  ($Config.Disk.ExcludeDriveLetters -notcontains ($_.Name))
              }

    foreach ($drive in $drives) {
        $totalGB = [math]::Round(($drive.Used + $drive.Free) / 1GB, 1)
        $freeGB  = [math]::Round($drive.Free / 1GB, 1)
        $freePct = if (($drive.Used + $drive.Free) -gt 0) {
                       [math]::Round(($drive.Free / ($drive.Used + $drive.Free)) * 100, 1)
                   } else { 100 }

        $status = 'OK'
        if ($freePct -le $Config.Disk.FreeSpaceCriticalPct) { $status = 'CRIT' }
        elseif ($freePct -le $Config.Disk.FreeSpaceWarningPct) { $status = 'WARN' }

        $results += [PSCustomObject]@{
            Category  = 'Disk'
            Name      = "$($drive.Name):\ Drive"
            Status    = $status
            Value     = "$freePct% free ($freeGB GB of $totalGB GB)"
            Threshold = "Warn < $($Config.Disk.FreeSpaceWarningPct)%  |  Crit < $($Config.Disk.FreeSpaceCriticalPct)%"
            Message   = if ($status -eq 'OK') { "Disk space is healthy." }
                        elseif ($status -eq 'WARN') { "Low disk space on $($drive.Name):\. Only $freePct% free." }
                        else { "CRITICAL: Disk $($drive.Name):\ has only $freePct% free ($freeGB GB). Immediate action required." }
        }

        Write-Log "Disk $($drive.Name):\ — $freePct% free ($freeGB/$totalGB GB) [$status]" -Level $(if ($status -eq 'OK') {'INFO'} elseif ($status -eq 'WARN') {'WARN'} else {'CRIT'})
    }
    return $results
}


function Get-CpuCheck {
    Write-Log "Sampling CPU over $($Config.CPU.SampleCount) x $($Config.CPU.SampleSeconds)s intervals..." -Level INFO
    $samples = @()
    for ($i = 0; $i -lt $Config.CPU.SampleCount; $i++) {
        $samples += (Get-CimInstance -ClassName Win32_Processor |
                     Measure-Object -Property LoadPercentage -Average).Average
        if ($i -lt ($Config.CPU.SampleCount - 1)) {
            Start-Sleep -Seconds $Config.CPU.SampleSeconds
        }
    }
    $avgCpu = [math]::Round(($samples | Measure-Object -Average).Average, 1)

    $status = 'OK'
    if ($avgCpu -ge $Config.CPU.CriticalPct) { $status = 'CRIT' }
    elseif ($avgCpu -ge $Config.CPU.WarningPct) { $status = 'WARN' }

    Write-Log "CPU average: $avgCpu% [$status]" -Level $(if ($status -eq 'OK') {'INFO'} elseif ($status -eq 'WARN') {'WARN'} else {'CRIT'})

    return [PSCustomObject]@{
        Category  = 'CPU'
        Name      = 'CPU Usage (avg)'
        Status    = $status
        Value     = "$avgCpu% (avg of $($Config.CPU.SampleCount) samples)"
        Threshold = "Warn >= $($Config.CPU.WarningPct)%  |  Crit >= $($Config.CPU.CriticalPct)%"
        Message   = if ($status -eq 'OK') { "CPU usage is normal." }
                    elseif ($status -eq 'WARN') { "Elevated CPU usage: $avgCpu%. Monitor for sustained load." }
                    else { "CRITICAL: CPU at $avgCpu%. System may be overloaded." }
    }
}


function Get-ServiceChecks {
    $results = @()
    foreach ($svcName in $Config.Services) {
        try {
            $svc = Get-Service -Name $svcName -ErrorAction Stop
            $status = if ($svc.Status -eq 'Running') { 'OK' } else { 'CRIT' }
            $displayName = $svc.DisplayName

            Write-Log "Service '$displayName' ($svcName) — $($svc.Status) [$status]" -Level $(if ($status -eq 'OK') {'INFO'} else {'CRIT'})

            $results += [PSCustomObject]@{
                Category  = 'Service'
                Name      = "$displayName ($svcName)"
                Status    = $status
                Value     = $svc.Status.ToString()
                Threshold = 'Must be: Running'
                Message   = if ($status -eq 'OK') { "Service is running normally." }
                            else { "CRITICAL: '$displayName' is $($svc.Status). It should be Running." }
            }
        } catch {
            Write-Log "Service '$svcName' not found on this system." -Level WARN
            $results += [PSCustomObject]@{
                Category  = 'Service'
                Name      = "$svcName"
                Status    = 'WARN'
                Value     = 'Not found'
                Threshold = 'Must be: Running'
                Message   = "Service '$svcName' was not found on this machine."
            }
        }
    }
    return $results
}


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5 — HTML EMAIL BUILDER
# ─────────────────────────────────────────────────────────────────────────────

function Build-HtmlReport {
    param([array]$Checks, [string]$Hostname, [string]$Timestamp)

    $statusColor = @{
        OK   = '#1D9E75'   # teal
        WARN = '#BA7517'   # amber
        CRIT = '#A32D2D'   # red
    }
    $statusBg = @{
        OK   = '#E1F5EE'
        WARN = '#FAEEDA'
        CRIT = '#FCEBEB'
    }
    $statusEmoji = @{ OK = '&#10003;'; WARN = '&#9888;'; CRIT = '&#10005;' }

    $rowsHtml = ($Checks | ForEach-Object {
        $c = $statusColor[$_.Status]
        $bg = $statusBg[$_.Status]
        $icon = $statusEmoji[$_.Status]
        @"
        <tr>
          <td style="padding:10px 14px;border-bottom:1px solid #eee;">$($_.Category)</td>
          <td style="padding:10px 14px;border-bottom:1px solid #eee;font-weight:500;">$($_.Name)</td>
          <td style="padding:10px 14px;border-bottom:1px solid #eee;">$($_.Value)</td>
          <td style="padding:10px 14px;border-bottom:1px solid #eee;font-size:12px;color:#666;">$($_.Threshold)</td>
          <td style="padding:10px 14px;border-bottom:1px solid #eee;text-align:center;">
            <span style="background:$bg;color:$c;font-weight:600;font-size:12px;padding:3px 10px;border-radius:4px;">$icon $($_.Status)</span>
          </td>
        </tr>
        <tr>
          <td colspan="5" style="padding:6px 14px 12px;border-bottom:1px solid #f0f0f0;font-size:13px;color:#555;background:#fafafa;">
            $($_.Message)
          </td>
        </tr>
"@
    }) -join "`n"

    $overallStatus = if ($Checks.Status -contains 'CRIT') { 'CRITICAL' }
                     elseif ($Checks.Status -contains 'WARN') { 'WARNING' }
                     else { 'ALL CLEAR' }

    $headerColor = if ($overallStatus -eq 'CRITICAL') { '#A32D2D' }
                   elseif ($overallStatus -eq 'WARNING') { '#BA7517' }
                   else { '#1D9E75' }

    return @"
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"></head>
<body style="margin:0;padding:0;font-family:Arial,sans-serif;background:#f5f5f5;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#f5f5f5;padding:24px 0;">
    <tr><td align="center">
      <table width="620" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:8px;overflow:hidden;border:1px solid #e0e0e0;">

        <!-- Header -->
        <tr><td style="background:$headerColor;padding:20px 28px;">
          <div style="color:#fff;font-size:20px;font-weight:700;">System Health Report</div>
          <div style="color:rgba(255,255,255,0.85);font-size:13px;margin-top:4px;">$overallStatus &mdash; $Hostname &mdash; $Timestamp</div>
        </td></tr>

        <!-- Summary pills -->
        <tr><td style="padding:16px 28px;border-bottom:1px solid #eee;">
          <span style="font-size:13px;color:#666;margin-right:12px;">Summary:</span>
          <span style="background:#E1F5EE;color:#085041;padding:4px 12px;border-radius:4px;font-size:12px;font-weight:600;margin-right:6px;">
            &#10003; OK: $(($Checks | Where-Object Status -eq 'OK').Count)
          </span>
          <span style="background:#FAEEDA;color:#633806;padding:4px 12px;border-radius:4px;font-size:12px;font-weight:600;margin-right:6px;">
            &#9888; WARN: $(($Checks | Where-Object Status -eq 'WARN').Count)
          </span>
          <span style="background:#FCEBEB;color:#791F1F;padding:4px 12px;border-radius:4px;font-size:12px;font-weight:600;">
            &#10005; CRIT: $(($Checks | Where-Object Status -eq 'CRIT').Count)
          </span>
        </td></tr>

        <!-- Results table -->
        <tr><td style="padding:0 28px 8px;">
          <table width="100%" cellpadding="0" cellspacing="0" style="margin-top:16px;font-size:14px;">
            <tr style="background:#f9f9f9;">
              <th style="padding:10px 14px;text-align:left;font-size:12px;color:#888;font-weight:600;border-bottom:2px solid #eee;">CATEGORY</th>
              <th style="padding:10px 14px;text-align:left;font-size:12px;color:#888;font-weight:600;border-bottom:2px solid #eee;">CHECK</th>
              <th style="padding:10px 14px;text-align:left;font-size:12px;color:#888;font-weight:600;border-bottom:2px solid #eee;">CURRENT VALUE</th>
              <th style="padding:10px 14px;text-align:left;font-size:12px;color:#888;font-weight:600;border-bottom:2px solid #eee;">THRESHOLD</th>
              <th style="padding:10px 14px;text-align:center;font-size:12px;color:#888;font-weight:600;border-bottom:2px solid #eee;">STATUS</th>
            </tr>
            $rowsHtml
          </table>
        </td></tr>

        <!-- Footer -->
        <tr><td style="padding:16px 28px;background:#f9f9f9;border-top:1px solid #eee;">
          <div style="font-size:12px;color:#aaa;">
            Generated by Watch-SystemHealth.ps1 &bull; $Hostname &bull; $Timestamp<br>
            To adjust thresholds or the services list, edit the Config section at the top of the script.
          </div>
        </td></tr>

      </table>
    </td></tr>
  </table>
</body>
</html>
"@
}


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6 — EMAIL SENDER
# ─────────────────────────────────────────────────────────────────────────────

function Send-AlertEmail {
    param([string]$HtmlBody, [string]$Hostname)

    $subject = $Config.Email.Subject -replace '\{HOSTNAME\}', $Hostname
    $mailParams = @{
        SmtpServer  = $Config.Email.SmtpServer
        Port        = $Config.Email.SmtpPort
        From        = $Config.Email.From
        To          = $Config.Email.To
        Subject     = $subject
        Body        = $HtmlBody
        BodyAsHtml  = $true
        UseSsl      = $Config.Email.UseSsl
    }

    if ($Config.Email.Username -and $Config.Email.Password) {
        $securePass = ConvertTo-SecureString $Config.Email.Password -AsPlainText -Force
        $mailParams.Credential = New-Object System.Management.Automation.PSCredential(
            $Config.Email.Username, $securePass
        )
    }

    try {
        Send-MailMessage @mailParams
        Write-Log "Alert email sent to: $($Config.Email.To -join ', ')" -Level INFO
    } catch {
        Write-Log "Failed to send email: $_" -Level ERROR
        Write-Warning "Email send failed: $_"
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 7 — MAIN EXECUTION
# ─────────────────────────────────────────────────────────────────────────────

function Main {
    $hostname  = $env:COMPUTERNAME
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    Initialize-Log
    Write-Log "═══════════════════════════════════════════" -Level INFO
    Write-Log "Watch-SystemHealth started on $hostname" -Level INFO
    Write-Log "═══════════════════════════════════════════" -Level INFO

    # Run all checks
    $allChecks = @()
    $allChecks += Get-DiskChecks
    $allChecks += Get-CpuCheck
    $allChecks += Get-ServiceChecks

    # Summary to console
    Write-Host "`n=== SYSTEM HEALTH RESULTS — $hostname ===" -ForegroundColor Cyan
    $allChecks | Format-Table Category, Name, Value, Status -AutoSize

    # Count issues
    $issues = $allChecks | Where-Object { $_.Status -ne 'OK' }

    if ($issues.Count -gt 0) {
        Write-Log "$($issues.Count) issue(s) found. Sending alert email..." -Level WARN
        Write-Host "`n$($issues.Count) issue(s) detected. Sending alert email..." -ForegroundColor Yellow

        $html = Build-HtmlReport -Checks $allChecks -Hostname $hostname -Timestamp $timestamp
        Send-AlertEmail -HtmlBody $html -Hostname $hostname
    } else {
        Write-Log "All checks passed. No alert sent." -Level INFO
        Write-Host "`nAll checks passed. No alert needed." -ForegroundColor Green
    }

    Write-Log "Watch-SystemHealth completed." -Level INFO
}

# Entry point
Main
