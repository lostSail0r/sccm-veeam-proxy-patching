# Veeam Proxy Maintenance for SCCM Patching
**Gracefully drain selected VMware proxies, stop Veeam services for patching/reboot, and return them to production without disrupting active backup jobs.**

---

## Overview
This PowerShell script automates safe maintenance windows for Veeam Backup & Replication VMware proxies in SCCM/ConfigMgr-driven patching workflows. It is intended to run on the **Veeam Backup & Replication server** or a **management/jump host** with the Veeam Console installed, and it remotely orchestrates VMware proxies via Veeam PowerShell and WinRM.

The script implements a two-stage process—**Pre** (quiesce) and **Post** (recovery)—that ensures no backup tasks using the selected proxies are interrupted while their Veeam services are stopped and restarted during maintenance of the VBR server or management host.

## Why This Matters
Abruptly stopping Veeam services for Windows patching can:
*   Interrupt active backup jobs mid-stream
*   Corrupt backup repositories
*   Trigger customer SLA violations
*   Leave infrastructure in inconsistent states

This script prevents those issues by polling active backup sessions, gracefully disabling selected proxies in VBR, draining in-flight tasks that are using those proxies, and only then stopping Veeam services on the proxies via WinRM for safe maintenance of the central VBR/management server.

## Features
*   **Parameterized proxy targeting**: Run against any proxy or batch of proxies without editing code
*   **Intelligent task draining**: Polls active Veeam backup sessions and waits for tasks using the targeted proxies to complete (with configurable timeout)
*   **Persistent logging**: All actions logged to a timestamped file for SCCM integration and audit trails
*   **SCCM-aware exit codes**: Returns standard ConfigMgr codes (0, 3010) plus detailed diagnostics (10–99) for troubleshooting
*   **Reboot signaling**: Detects Windows pending reboots **on the machine running the script** (VBR server or management host) and returns exit code 3010 so SCCM handles restart orchestration
*   **Two-stage orchestration**: Designed for SCCM task sequences (Pre → Windows Updates → Post) that run on the VBR server or management/jump host, while coordinating remote proxies

## Requirements

### Veeam Environment
*   **Veeam Backup & Replication 12.3.2+** (Server & Console) on the system where the script runs
*   VMware proxies must be registered and functional in VBR
*   Account running the script must have the **Backup Administrator** role (or equivalent) in VBR

### Target Proxies
*   **WinRM enabled** (for remote service management from the script host)
*   **Local Administrator access** on the proxies for the account running the script
*   Network connectivity from the script host to the VBR server (if separate) and to all target proxies

### PowerShell & Account
*   PowerShell 5.1+ on the VBR server or jump host where the script executes
*   Execution Policy: `RemoteSigned` or `Bypass` for script execution
*   MFA disabled for the service account (Veeam PowerShell sessions do not support MFA per KB4535)

## Installation
1.  Download `sccmpatch.ps1` to your VBR server or management/jump host, or to an SCCM distribution point used to target that host.
2.  Ensure the **Veeam PowerShell module** is available on the host running the script (installed with the Veeam Console).
3.  Store the script in a shared location accessible to the SCCM client context on the VBR/management host (e.g., `C:\Scripts\` or a network UNC path).

## Usage

### Basic Examples
**Pre-stage** for proxies "Proxy1" and "Proxy2":
```powershell  
.\Sccmpatch.ps1 -Stage Pre -Proxies 'Proxy1','Proxy2'  
Post-stage after patching:
powershell
.\Sccmpatch.ps1 -Stage Post -Proxies 'Proxy1','Proxy2'
Custom drain timeout (60 minutes):
powershell
.\Sccmpatch.ps1 -Stage Pre -Proxies 'Proxy1','Proxy2' -DrainTimeoutMinutes 60
Parameters
Table
Parameter	Type	Default	Description
-Stage	string	Pre	Execution stage: Pre (disable/drain/stop) or Post (start/re-enable/reboot signal).
-Proxies	string[]	@('Proxy1','Proxy2')	Array of proxy hostnames (as known to VBR) to target. Override with your environment names.
-PollDelay	int	30	Seconds between task-drain polls. Lower = faster detection, higher = less VBR API chatter.
-DrainTimeoutMinutes	int	30	Maximum wait time for active tasks using the targeted proxies to complete. If exceeded, exits with code 30.
Exit Codes
Table
Code	Stage	Meaning	Action in SCCM
0	Both	Success, no reboot	Continue to next step
3010	Post	Success, reboot pending on script host	Schedule/execute reboot per ConfigMgr policy for the VBR/management host
10	Both	Proxy objects not found	Failure – verify proxy names in VBR
20	Pre	Disable failed	Failure – check VBR permissions/connectivity
30	Pre	Task-drain timeout	Failure – jobs still active after timeout; increase -DrainTimeoutMinutes
40	Pre	Service stop failed	Failure – check WinRM/remote access to proxy
50	Post	Service start failed	Failure – check proxy connectivity/service status
60	Post	Re-enable failed	Failure – critical; proxy may remain disabled
90	Both	Invalid Stage argument	Usage error – use -Stage Pre or -Stage Post
99	Both	Unhandled error	Failure – check log file for details
Integration with SCCM Task Sequences
Recommended Task Sequence Structure
This example assumes the task sequence targets the VBR server or management/jump host where the Veeam Console and Sccmpatch.ps1 are installed. The script will coordinate remote proxies during the maintenance of that host.
1.	"Disable Veeam Proxies" (Run PowerShell Script step)
o	Command: powershell.exe -ExecutionPolicy Bypass -File Sccmpatch.ps1 -Stage Pre -Proxies 'Proxy1','Proxy2'
o	Success codes: 0
o	Continue on error: No (halt if Pre stage fails)
2.	"Install Software Updates" (Install Software Updates step)
o	Runs Windows Update, patches the VBR/management host, and may stage a reboot.
3.	"Re-enable Veeam Proxies" (Run PowerShell Script step)
o	Command: powershell.exe -ExecutionPolicy Bypass -File Sccmpatch.ps1 -Stage Post -Proxies 'Proxy1','Proxy2'
o	Success codes: 0 3010
o	Continue on error: No
4.	"Restart Computer" (Restart Computer step)
o	Automatically triggered if any prior step returned 3010 (reboot pending on the VBR/management host).
SCCM Deployment Type (for Applications)
If deploying as a standalone application package to the VBR server or management host:
1.	Create a new Application with deployment type "Script Installer".
2.	Set installation script: point to Sccmpatch.ps1 with -Stage Pre and appropriate -Proxies.
3.	On the Return Codes tab, add:
o	0 = Success
o	10, 20, 30, 40, 90, 99 = Failure
o	3010 = SoftReboot (if planning to use Post stage separately in another deployment or TS)
Logging
Log File Location
•	%TEMP%\ProxyMaintenance_yyyyMMdd-HHmmss.log
•	Example path (running as SYSTEM): C:\Users\SYSTEM\AppData\Local\Temp\ProxyMaintenance_20250924-143022.log
Log Format
text
2025-09-24 14:30:22 [INFO] Process begins (Stage: Pre, Proxies: Proxy1, Proxy2)
2025-09-24 14:30:23 [INFO] >>> Waiting for active tasks to drain…
2025-09-24 14:30:54 [WARN] Task still active on proxy Proxy1: Backup Job - VM-Server01
2025-09-24 14:31:24 [INFO] >>> No active tasks – stopping services.
2025-09-24 14:31:25 [INFO] Stopping Veeam services on Proxy1 …
2025-09-24 14:31:28 [INFO] Stage Pre completed successfully
Note: Log files in %TEMP% may be cleaned by Windows; for production audits, consider redirecting logs to a persistent path (e.g., a network share or central logging solution) or integrating with Event Viewer.
Troubleshooting
Task Drain Timeout (Exit Code 30)
Symptom: Script times out waiting for active backup tasks using the targeted proxies to finish.
•	Causes: Long-running backup jobs, Instant Recovery sessions, or job queue backlogs.
•	Solutions:
o	Increase -DrainTimeoutMinutes to 60+ for large job queues.
o	Manually pause/suspend jobs feeding these proxies before running Pre stage:
Get-VBRJob | Where-Object { $_.TargetProxy -like 'Proxy1*' } | Suspend-VBRJob
o	Check for Instant Recovery sessions in VBR Console that may be using proxy resources.
Service Stop Failure (Exit Code 40)
Symptom: Script fails to stop Veeam services on a proxy.
•	Causes: WinRM not enabled, Firewall blocking WinRM, or insufficient permissions.
•	Solutions:
o	Verify WinRM is enabled: Invoke-Command -ComputerName 'Proxy1' -ScriptBlock { Get-Service WinRM | Select Status }
o	Verify network connectivity and firewall rules allow WinRM (TCP 5985/5986).
o	Confirm account has local admin rights on proxy.
Re-enable Failure (Exit Code 60)
Symptom: Proxies remain disabled in VBR after Post stage.
•	Causes: VBR server connectivity lost or insufficient VBR permissions.
•	Solutions:
o	Test VBR connectivity: Get-VBRServer | Select Name, State
o	Manually re-enable proxy in VBR Console: Home → Infrastructure → Backup Infrastructure → Proxies.
Performance & Sizing
•	Drain poll interval: Default 30 seconds (adjustable via -PollDelay).
o	For environments with <10 concurrent jobs: 30s is sufficient.
o	For large job queues: consider -PollDelay 60 to reduce VBR API load.
•	Drain timeout: Default 30 minutes (adjustable via -DrainTimeoutMinutes).
o	Small deployments (1–5 proxies, <50 daily jobs): 30 min is typically adequate.
o	Large deployments (>10 proxies, >100 daily jobs): increase to 60+ min.
Contributing
Found a bug or have a feature request? Please open an issue or submit a pull request. Suggested improvements:
•	Support for Hyper-V proxies
•	Event Viewer logging integration
•	Automatic job suspension logic
•	Multi-proxy parallel draining
Disclaimer
This script interacts with critical backup infrastructure. Test thoroughly in a non-production environment first. Ensure you have backups of your Veeam configuration and a rollback plan before running in production. The author assumes no liability for data loss, service disruption, or other damages resulting from script execution.
Quick Start Checklist
•	 Download script to VBR server or management/jump host (or SCCM distribution point targeting that host)
•	 Verify Veeam PowerShell module is installed (via Veeam Console) on that host
•	 Confirm account running the script has Backup Administrator role in VBR
•	 Confirm account has local admin on all target proxies
•	 Enable WinRM on all target proxies
•	 Test Pre stage on one proxy: .\Sccmpatch.ps1 -Stage Pre -Proxies 'TestProxy'
•	 Review log file output
•	 Test Post stage: .\Sccmpatch.ps1 -Stage Post -Proxies 'TestProxy'
•	 Integrate into SCCM task sequence targeting the VBR/management host with proper success codes
•	 Deploy to production with change management approval

