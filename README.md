# Veeam Proxy Maintenance for SCCM Patching

Gracefully drain selected VMware proxies, stop Veeam services for patching/reboot, and return them to production without disrupting active backup jobs.

## Overview

This PowerShell script automates safe maintenance windows for Veeam Backup & Replication VMware proxies in SCCM/ConfigMgr-driven patching workflows. It implements a two-stage process—**Pre** (quiesce) and **Post** (recovery)—that ensures no backup tasks are interrupted during service stops or reboots.

### Why This Matters

Abruptly stopping Veeam services for Windows patching can:
- Interrupt active backup jobs mid-stream
- Corrupt backup repositories
- Trigger customer SLA violations
- Leave infrastructure in inconsistent states

This script prevents those issues by polling active backup sessions, gracefully disabling proxies, draining in-flight tasks, and only then stopping services for safe maintenance.

## Features

- **Parameterized proxy targeting:** Run against any proxy or batch of proxies without editing code
- **Intelligent task draining:** Polls active Veeam backup sessions and waits for task completion (with configurable timeout)
- **Persistent logging:** All actions logged to timestamped file for SCCM integration and audit trails
- **SCCM-aware exit codes:** Returns standard ConfigMgr codes (0, 3010) plus detailed diagnostics (10–99) for troubleshooting
- **Reboot signaling:** Detects Windows pending reboots and returns exit code 3010 so SCCM handles restart orchestration
- **Two-stage orchestration:** Designed for SCCM task sequences (Pre → Windows Updates → Post)

## Requirements

### Veeam Environment
- **Veeam Backup & Replication 12.3.2+** (Server & Console)
- **VMware proxies** must be registered and functional in VBR
- Account running script must have **Backup Administrator role** in VBR

### Target Proxies
- **WinRM enabled** (for remote service management)
- **Local Administrator access** for the account running the script
- **Network connectivity** to VBR server and target proxies

### PowerShell & Account
- **PowerShell 5.1+** on the jump host
- **Execution Policy:** RemoteSigned or Bypass for script execution
- **MFA disabled** for the service account (Veeam PowerShell sessions don't support MFA per KB4535)

## Installation

1. Download `ProxyMaintenance.ps1` to your jump host or SCCM TS distribution point
2. Ensure the Veeam PowerShell module is available on the jump host (installed with Veeam Console)
3. Store script in a shared location accessible to SCCM client context (e.g., `C:\Scripts\` or network UNC path)

## Usage

### Basic Examples

**Pre-stage for proxies "Proxy1" and "Proxy2":**
```powershell
.\ProxyMaintenance.ps1 -Stage Pre -Proxies 'Proxy1','Proxy2'
```

**Post-stage after patching:**
```powershell
.\ProxyMaintenance.ps1 -Stage Post -Proxies 'Proxy1','Proxy2'
```

**Custom drain timeout (60 minutes):**
```powershell
.\ProxyMaintenance.ps1 -Stage Pre -Proxies 'Proxy1','Proxy2' -DrainTimeoutMinutes 60
```

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Stage` | string | `Pre` | Execution stage: `Pre` (disable/drain/stop) or `Post` (start/re-enable/reboot signal) |
| `-Proxies` | string[] | `@('Proxy1','Proxy2')` | Array of proxy hostnames to target. Override with your environment names. |
| `-PollDelay` | int | `30` | Seconds between task-drain polls. Lower = faster detection, higher = less VBR API chatter. |
| `-DrainTimeoutMinutes` | int | `30` | Maximum wait time for active tasks to complete. If exceeded, exits with code 30. |

### Exit Codes

| Code | Stage | Meaning | Action in SCCM |
|------|-------|---------|----------------|
| **0** | Both | Success, no reboot | Continue to next step |
| **3010** | Post | Success, reboot pending | Schedule/execute reboot per ConfigMgr policy |
| **10** | Both | Proxy objects not found | Failure – verify proxy names in VBR |
| **20** | Pre | Disable failed | Failure – check VBR permissions/connectivity |
| **30** | Pre | Task-drain timeout | Failure – jobs still active after timeout; increase `-DrainTimeoutMinutes` |
| **40** | Pre | Service stop failed | Failure – check WinRM/remote access to proxy |
| **50** | Post | Service start failed | Failure – check proxy connectivity/service status |
| **60** | Post | Re-enable failed | Failure – critical; proxy may remain disabled |
| **90** | Both | Invalid Stage argument | Usage error – use `-Stage Pre` or `-Stage Post` |
| **99** | Both | Unhandled error | Failure – check log file for details |

## Integration with SCCM Task Sequences

### Recommended Task Sequence Structure

1. **"Disable Veeam Proxies"** (Run PowerShell Script step)
   - Command: `powershell.exe -ExecutionPolicy Bypass -File ProxyMaintenance.ps1 -Stage Pre -Proxies 'Proxy1','Proxy2'`
   - Success codes: `0`
   - Continue on error: **No** (halt if Pre stage fails)

2. **"Install Software Updates"** (Install Software Updates step)
   - Runs Windows Update, patches, and stages reboot

3. **"Re-enable Veeam Proxies"** (Run PowerShell Script step)
   - Command: `powershell.exe -ExecutionPolicy Bypass -File ProxyMaintenance.ps1 -Stage Post -Proxies 'Proxy1','Proxy2'`
   - Success codes: `0 3010`
   - Continue on error: **No**

4. **"Restart Computer"** (Restart Computer step)
   - Automatically triggered if any prior step returned 3010

### SCCM Deployment Type (for Applications)

If deploying as a standalone application package:

1. Create new Application with deployment type "Script Installer"
2. Set installation script: Point to `ProxyMaintenance.ps1` with `-Stage Pre`
3. On the **Return Codes** tab, add:
   - `0` = Success
   - `10, 20, 30, 40, 90, 99` = Failure
   - `3010` = SoftReboot (if planning to use Post stage separately)

## Logging

### Log File Location
```
%TEMP%\ProxyMaintenance_yyyyMMdd-HHmmss.log
```

Example path: `C:\Users\SYSTEM\AppData\Local\Temp\ProxyMaintenance_20250924-143022.log`

### Log Format
```
2025-09-24 14:30:22 [INFO] Process begins (Stage: Pre, Proxies: Proxy1, Proxy2)
2025-09-24 14:30:23 [INFO] >>> Waiting for active tasks to drain…
2025-09-24 14:30:54 [WARN] Task still active on proxy Proxy1: Backup Job - VM-Server01
2025-09-24 14:31:24 [INFO] >>> No active tasks – stopping services.
2025-09-24 14:31:25 [INFO] Stopping Veeam services on Proxy1 …
2025-09-24 14:31:28 [INFO] Stage Pre completed successfully
```

**Note:** Log files in `%TEMP%` may be cleaned by Windows; for production audits, consider redirecting logs to a network share or Event Viewer.

## Troubleshooting

### Task Drain Timeout (Exit Code 30)

**Symptom:** Script times out waiting for active backup tasks to finish.

**Causes:**
- Long-running backup jobs still in progress
- Instant Recovery sessions holding proxy resources
- Job queue backlog

**Solutions:**
1. Increase `-DrainTimeoutMinutes` to 60+ for large job queues
2. Manually pause/suspend jobs feeding these proxies before running Pre stage:
   ```powershell
   Get-VBRJob | Where-Object { $_.TargetProxy -like 'Proxy1*' } | Suspend-VBRJob
   ```
3. Check for Instant Recovery sessions in VBR Console that may be using proxy resources
4. Review backup job history to identify long-running/stuck jobs

### Service Stop Failure (Exit Code 40)

**Symptom:** Script fails to stop Veeam services on proxy.

**Causes:**
- WinRM not enabled on proxy
- Firewall blocking WinRM traffic
- Insufficient permissions (not local admin)
- Service already stopped or in error state

**Solutions:**
1. Verify WinRM is enabled and listening on proxy:
   ```powershell
   Invoke-Command -ComputerName 'Proxy1' -ScriptBlock { Get-Service WinRM | Select Status }
   ```
2. Manually check service names on proxy:
   ```powershell
   Invoke-Command -ComputerName 'Proxy1' -ScriptBlock { Get-Service Veeam* }
   ```
3. Verify network connectivity and firewall rules allow WinRM (TCP 5985/5986)
4. Confirm account has local admin rights on proxy

### Re-enable Failure (Exit Code 60)

**Symptom:** Proxies remain disabled after Post stage.

**Causes:**
- VBR server connectivity lost
- Insufficient VBR permissions
- Proxy in error/unhealthy state

**Solutions:**
1. Test VBR connectivity:
   ```powershell
   Get-VBRServer | Select Name, State
   ```
2. Manually re-enable proxy in VBR Console if needed
3. Check proxy health status in VBR: Home → Infrastructure → Backup Infrastructure → Proxies

## Performance & Sizing

- **Drain poll interval:** Default 30 seconds (adjustable via `-PollDelay`)
  - For environments with <10 concurrent jobs: 30s is sufficient
  - For large job queues: consider `-PollDelay 60` to reduce VBR API load
- **Drain timeout:** Default 30 minutes (adjustable via `-DrainTimeoutMinutes`)
  - Small deployments (1–5 proxies, <50 daily jobs): 30 min is adequate
  - Large deployments (>10 proxies, >100 daily jobs): increase to 60+ min

## Contributing

Found a bug or have a feature request? Please open an issue or submit a pull request. Suggested improvements:
- Support for Hyper-V proxies
- Event Viewer logging integration
- Automatic job suspension logic
- Multi-proxy parallel draining

## License

MIT License – see LICENSE file for details.

## Author

Chris Grady  
[cgfixit.com](https://cgfixit.com) | [cgfixit.com/code](https://cgfixit.com/code)

## Disclaimer

This script interacts with critical backup infrastructure. **Test thoroughly in a non-production environment first.** Ensure you have backups of your Veeam configuration and a rollback plan before running in production. The author assumes no liability for data loss, service disruption, or other damages resulting from script execution.

---

## Quick Start Checklist

- [ ] Download script to jump host or SCCM distribution point
- [ ] Verify Veeam PowerShell module is installed
- [ ] Confirm account has Backup Administrator role in VBR
- [ ] Confirm account has local admin on target proxies
- [ ] Enable WinRM on all target proxies
- [ ] Test Pre stage on one proxy: `.\ProxyMaintenance.ps1 -Stage Pre -Proxies 'TestProxy'`
- [ ] Review log file output
- [ ] Test Post stage: `.\ProxyMaintenance.ps1 -Stage Post -Proxies 'TestProxy'`
- [ ] Integrate into SCCM task sequence with proper success codes
- [ ] Deploy to production with change management approval