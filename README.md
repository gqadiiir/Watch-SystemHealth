# Watch-SystemHealth.ps1

A lightweight PowerShell system monitoring script for Windows that checks **disk space**, **CPU usage**, and **critical service status** — then sends a formatted HTML email alert if anything falls outside your defined thresholds.

Built for small businesses and IT teams who need reliable monitoring without the cost of enterprise tools like SolarWinds or Datadog.

---

## What it does

| Check | What it monitors | Alert trigger |
|---|---|---|
| **Disk space** | Free % on all local drives | Below warning or critical % |
| **CPU usage** | Averaged across multiple samples | Above warning or critical % |
| **Windows services** | Any services you specify | Service is not in Running state |

When an issue is detected, it emails a clean HTML report showing every check, its current value, threshold, and status (OK / WARN / CRIT).

---

## Sample alert email

```
Subject: [ALERT] System Health Warning on DESKTOP-ABC123

┌─────────────────────────────────────────────────┐
│  System Health Report                           │
│  WARNING — DESKTOP-ABC123 — 2025-03-14 08:00   │
├───────────┬───────────────────┬────────┬────────┤
│ CATEGORY  │ CHECK             │ VALUE  │ STATUS │
├───────────┼───────────────────┼────────┼────────┤
│ Disk      │ C:\ Drive         │ 8% free│  CRIT  │
│ CPU       │ CPU Usage (avg)   │ 62%    │  OK    │
│ Service   │ Print Spooler     │ Running│  OK    │
│ Service   │ Windows Update    │ Stopped│  CRIT  │
└───────────┴───────────────────┴────────┴────────┘
```

---

## Requirements

- Windows PowerShell 5.1 or later
- Network access to your SMTP server
- Sufficient permissions to query services and drives (standard user is usually enough; admin required for some WMI queries)

---

## Quick start

**1. Download the script**
```powershell
# Clone the repo or download Watch-SystemHealth.ps1 directly
git clone https://github.com/yourusername/Watch-SystemHealth.git
cd Watch-SystemHealth
```

**2. Edit the configuration block** at the top of `Watch-SystemHealth.ps1`

```powershell
Email = @{
    SmtpServer = 'smtp.yourdomain.com'
    SmtpPort   = 587
    UseSsl     = $true
    From       = 'monitoring@yourdomain.com'
    To         = @('admin@yourdomain.com')
    Username   = ''        # leave blank for anonymous relay
    Password   = ''
}

Disk = @{
    FreeSpaceWarningPct  = 20   # alert at 20% free
    FreeSpaceCriticalPct = 10   # critical at 10% free
    ExcludeDriveLetters  = @('D', 'E')
}

CPU = @{
    WarningPct  = 85
    CriticalPct = 95
    SampleCount = 3
}

Services = @(
    'Spooler'     # Print Spooler
    'W32Time'     # Windows Time
    'wuauserv'    # Windows Update
    # Add your own service names here
)
```

**3. Run it manually to test**
```powershell
.\Watch-SystemHealth.ps1 -Verbose
```

**4. Schedule it via Task Scheduler**

Open Task Scheduler → Create Basic Task, or run this one-liner to register it:
```powershell
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument '-NonInteractive -File "C:\Monitoring\Watch-SystemHealth.ps1"'
$trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 30) `
             -Once -At (Get-Date)
Register-ScheduledTask -TaskName 'SystemHealthMonitor' `
  -Action $action -Trigger $trigger -RunLevel Highest -Force
```

---

## Using an external config file

Instead of editing the script directly, you can pass a JSON config file:

```powershell
.\Watch-SystemHealth.ps1 -ConfigPath "C:\Monitoring\config.json"
```

Example `config.json`:
```json
{
  "Email": {
    "SmtpServer": "smtp.office365.com",
    "SmtpPort": 587,
    "From": "monitoring@company.com",
    "To": ["admin@company.com", "helpdesk@company.com"]
  },
  "Disk": {
    "FreeSpaceWarningPct": 15,
    "FreeSpaceCriticalPct": 5
  }
}
```

---

## Log files

Logs are written to `.\Logs\SystemHealth_YYYY-MM-DD.log` by default. Log files older than 30 days are automatically deleted.

```
[2025-03-14 08:00:01] [INFO]  Watch-SystemHealth started on DESKTOP-ABC123
[2025-03-14 08:00:02] [INFO]  Disk C:\ — 8% free (14/180 GB) [CRIT]
[2025-03-14 08:00:04] [INFO]  CPU average: 62% [OK]
[2025-03-14 08:00:04] [CRIT]  Service 'Windows Update' (wuauserv) — Stopped [CRIT]
[2025-03-14 08:00:05] [WARN]  2 issue(s) found. Sending alert email...
[2025-03-14 08:00:06] [INFO]  Alert email sent to: admin@company.com
```

---

## Configuration reference

| Setting | Default | Description |
|---|---|---|
| `Email.SmtpServer` | *(required)* | SMTP hostname |
| `Email.SmtpPort` | `587` | Port — 587 TLS, 465 SSL, 25 plain |
| `Email.UseSsl` | `$true` | Enable SSL/TLS |
| `Email.From` | *(required)* | Sender address |
| `Email.To` | *(required)* | Array of recipient addresses |
| `Disk.FreeSpaceWarningPct` | `20` | Warn when free % falls below this |
| `Disk.FreeSpaceCriticalPct` | `10` | Critical when free % falls below this |
| `Disk.ExcludeDriveLetters` | `D, E` | Drive letters to skip |
| `CPU.WarningPct` | `85` | Warn when avg CPU exceeds this |
| `CPU.CriticalPct` | `95` | Critical when avg CPU exceeds this |
| `CPU.SampleCount` | `3` | Samples to average |
| `CPU.SampleSeconds` | `2` | Seconds between samples |
| `Services` | *(list)* | Service short names to check |
| `Log.RetainDays` | `30` | Days before old logs are deleted |

---

## Common SMTP setups

**Office 365**
```powershell
SmtpServer = 'smtp.office365.com'
SmtpPort   = 587
UseSsl     = $true
Username   = 'monitoring@yourdomain.com'
Password   = 'your-app-password'
```

**Gmail**
```powershell
SmtpServer = 'smtp.gmail.com'
SmtpPort   = 587
UseSsl     = $true
Username   = 'youraddress@gmail.com'
Password   = 'your-app-password'   # use an App Password, not your login password
```

**Internal relay (no auth)**
```powershell
SmtpServer = '192.168.1.10'
SmtpPort   = 25
UseSsl     = $false
Username   = ''
Password   = ''
```

---

## Project structure

```
Watch-SystemHealth/
├── Watch-SystemHealth.ps1   # Main script
├── config.json              # Optional external config (copy and edit)
├── README.md
└── Logs/                    # Auto-created on first run
    └── SystemHealth_2025-03-14.log
```

---

## License

MIT — free to use, modify, and distribute.

---

*Built as part of my IT automation portfolio. I build custom PowerShell and Python automation scripts for IT teams and small businesses. [View my Upwork profile →]https://www.upwork.com/freelancers/~01336a3cfe17b7eae6*
