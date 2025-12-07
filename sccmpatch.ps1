<#
Author: Chris Grady (cgfixit.com & cgfixit.com/code)
Internal Use initially but any native PS functions can be used to re-purpose this script for Veeam or any SCCM patching
Validated against Veeam Backup & Replication 12.3.2 on 2025-09-24

Purpose  :  Gracefully drain selected VMware proxies, stop Veeam services for patching/reboot, then return them to production.
Description: Graceful Veeam VMware proxy maintenance helper for patching/reboots.
Pre stage: disable selected proxies, wait for backup tasks to drain, then stop Veeam services safely for patching/reboot.
Post stage: start services, re-enable proxies, and return 3010 if a Windows reboot is pending so SCCM/ConfigMgr can handle it.
ExitCodes: 0  = Success
           10 = Proxy objects not found
           20 = Disable failed          (Pre)
           30 = Task-drain timeout      (Pre)
           40 = Stop-service failure    (Pre)
           50 = Start-service failure   (Post)
           60 = Re-enable failure       (Post)
           90 = Invalid Stage argument
           99 = Unhandled error
           3010 = Reboot pending (Post, for SCCM)
           
NOTED Requirements:
Proxies must exist in VBR configuration (modify -Proxies param as needed)
WinRM enabled on both proxy servers
Account has Backup Administrator role in VBR
Account has local administrator rights on proxy servers
PowerShell execution policy allows script execution 
MFA: Disabled for the account launching PowerShell
Network connectivity between script host and proxies and VBR
--
Troubleshooting:

Task Drain Delay:
Use Suspend-VBRJob to pause jobs feeding these proxies.
Check Instant Recovery sessions — they may hold proxy resources.
Service Stop Failures

Misc:
Run Get-Service Veeam* manually to confirm service names.
Ensure no orphaned TCP connections (Get-NetTCPConnection).
#>


[CmdletBinding()]
param(
    [ValidateSet('Pre','Post')]
    [string]$Stage = 'Pre',
    [string[]]$Proxies = @('F-1', 'M-1'),  # Default batch; override via param/host names of proxy in your env
    [int]$PollDelay = 30,                  # Seconds between task-drain checks
    [int]$DrainTimeoutMinutes = 30         # Max wait time for drain (keep in mind 30 min may need more time if jobs running)
)

$LogPath = "$env:TEMP\ProxyMaintenance_$(Get-Date -f 'yyyyMMdd-HHmmss').log"
function Write-ProxyLog { param([string]$Msg, [string]$Level='INFO', [switch]$ToConsole) 
    Add-Content $LogPath "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') [$Level] $Msg"
    if ($ToConsole) { Write-Host $Msg -ForegroundColor Cyan }
}

Write-ProxyLog "Process begins (Stage: $Stage, Proxies: $($Proxies -join ', '))" -ToConsole

Import-Module Veeam.Backup.PowerShell -ErrorAction Stop

try {
    #------------------------------------------------------------
    # Common: get proxy objects
    #------------------------------------------------------------
    $ProxyObjs = Get-VBRViProxy -Name $Proxies
    if (-not $ProxyObjs) {
        Write-ProxyLog "No matching proxies found!" 'ERROR' -ToConsole; exit 10
    }

    #------------------------------------------------------------
    if ($Stage -eq 'Pre') {
    #------------------------------------------------------------
        # Disable proxies
        try { $ProxyObjs | Disable-VBRViProxy }
        catch { Write-ProxyLog "Failed to disable proxies: $_" 'ERROR' -ToConsole; exit 20 }

        # Drain running tasks (fixed filtering)
        Write-ProxyLog ">>> Waiting for active tasks to drain…" -ToConsole
        $StartTime = Get-Date
        do {
            $runningSessions = Get-VBRBackupSession | Where-Object { $_.State -eq "Working" }
            $runningTasks = $runningSessions | Get-VBRTaskSession | Where-Object { $_.Status -eq "InProgress" }
            $Busy = $false
            foreach ($task in $runningTasks) {
                $proxyId = $task.Info.WorkDetails.SourceProxyId
                $proxy = Get-VBRViProxy | Where-Object { $_.Id -eq $proxyId }
                if ($Proxies -contains $proxy.Name) {
                    $Busy = $true
                    Write-ProxyLog "Task still active on proxy $($proxy.Name): $($task.Name)" 'WARN' -ToConsole
                    break
                }
            }
            if ($Busy) {
                if (((Get-Date) - $StartTime).TotalMinutes -gt $DrainTimeoutMinutes) {
                    Write-ProxyLog "Task drain timeout after $DrainTimeoutMinutes minutes" 'ERROR' -ToConsole; exit 30
                }
                Write-ProxyLog (" {0} task(s) still running – sleeping {1}s" -f $runningTasks.Count, $PollDelay) -ToConsole
                Start-Sleep -Seconds $PollDelay
            }
        } until (-not $Busy)
            Write-ProxyLog ">>> No active tasks – stopping services." 'INFO' -ToConsole

        # Stop services on each proxy
        foreach ($Node in $Proxies) {
            try {
                Write-ProxyLog " Stopping Veeam services on $Node …" -ToConsole
                Invoke-Command -ComputerName $Node -ScriptBlock {
                    Get-Service Veeam* | Stop-Service -Force
                }
            } catch {
                Write-ProxyLog "Failed to stop Veeam services on $Node: $_" 'ERROR' -ToConsole; exit 40
            }
        }

        Write-ProxyLog "Stage Pre completed successfully" -ToConsole; exit 0
    }

    #------------------------------------------------------------
    elseif ($Stage -eq 'Post') {
    #------------------------------------------------------------
        # Start services on each proxy
        foreach ($Node in $Proxies) {
            try {
                Write-ProxyLog " Starting Veeam services on $Node …" -ToConsole
                Invoke-Command -ComputerName $Node -ScriptBlock {
                    Get-Service Veeam* | Start-Service
                }
            } catch {
                Write-ProxyLog "Failed to start Veeam services on $Node: $_" 'ERROR' -ToConsole; exit 50
            }
        }

        # Re-enable proxies
        try { $ProxyObjs | Enable-VBRViProxy }
        catch { Write-ProxyLog "Failed to re-enable proxies: $_" 'ERROR' -ToConsole; exit 60 }

        # Check for reboot pending (for SCCM)
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { 
            Write-ProxyLog "Reboot pending detected" 'WARN' -ToConsole; exit 3010 
        }

        Write-ProxyLog "Stage Post completed successfully" -ToConsole; exit 0
    }

    #------------------------------------------------------------
    else {
        Write-ProxyLog "Invalid -Stage argument. Use Pre or Post." 'ERROR' -ToConsole; exit 90
    }
}
catch {
    Write-ProxyLog "Unhandled error: $_" 'ERROR' -ToConsole; exit 99
}