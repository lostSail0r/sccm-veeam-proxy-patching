# sccm-veeam-proxy-patching
This PowerShell script automates safe maintenance windows for Veeam Backup &amp; Replication VMware proxies in SCCM/ConfigMgr-driven patching workflows via two-stage process—**Pre** (quiesce) and **Post** (recovery)—that ensures no backup tasks are interrupted during service stops or reboots.
