# Server Migration Assistant

An interactive Windows Server migration checklist and evidence-collection toolkit. It exports the old server, validates the replacement, applies selected settings, performs post-cutover checks, and creates a conservative decommission plan.

## Requirements

- Windows Server with Windows PowerShell 5.1 or later
- An Administrator session
- Role-management modules for any roles being migrated (DHCP, DNS, SMB, and Server Manager)
- A tested backup and rollback plan

## Run

Right-click `Launchers\Start-MigrationToolkit.bat` and choose **Run as administrator**, or run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Launchers\Start-MigrationToolkit.ps1
```

Keep the complete repository together. Reports, exports, logs, and generated copy commands are written under `Output`.

Choose **Start or Resume Migration** for normal use. The wizard stores progress in `Output\Migration-State.json`, detects whether it is running on the old or new server, and presents one safe checkpoint at a time. Rerun it after every restart or completed checkpoint. Individual phases are kept under **Troubleshooting Tools** and should normally be used only when the wizard directs you there.

When the replacement is missing Windows roles or features, the toolkit creates a plain-language role installation plan. It can install low-risk prerequisites after typed confirmation, lists optional management tools separately, and routes AD DS, DNS, DHCP, Hyper-V, IIS, clustering, DFS, remote access, and similar workloads through guided or product-specific migration paths.

For a domain-controller replacement, the wizard checks whether the existing domain can be discovered through internal DNS. After the technician types `JOIN DOMAIN` and supplies authorized credentials, it joins the replacement to the existing domain and restarts. Domain-controller promotion remains a separate checkpoint after the restart.

Before domain join, the network checkpoint shows the new server's current IPv4 address, whether it came from DHCP, its prefix, gateway, and DNS servers. The technician may keep DHCP, convert the current lease to static after confirming it is reserved/excluded, or enter a planned static address. The old server's exported IPv4 address can be applied as internal DNS after typed confirmation. Network changes remain skippable.

Each migration is bound to the exact DNS domain—and, when available, its immutable domain GUID—from the old-server export. The technician must type that domain name exactly before the join. A mismatch between the export, saved flash-drive state, current membership, or typed domain stops the workflow; the toolkit never selects a nearby domain automatically.

After successful post-cutover validation, the rollback monitoring period, and a fully passed decommission checklist, the wizard offers **Archive and Reset**. It requires the exact phrase `ARCHIVE AND RESET TOOLKIT`, creates a timestamped ZIP and SHA-256 checksum under `MigrationArchives`, verifies the archive, clears only the active `Output` contents, and recreates clean output folders for the next migration.

## Workflow

1. Run Step 1 on the old server. Review the generated migration manifest to confirm what the server does, then copy the complete toolkit folder to the new server.
2. Build the replacement with a different computer name. Run Step 2 and resolve every package-integrity, identity, storage, role, and network failure.
3. Run Step 3 only after reviewing each prompt. It can prepare roles/settings, create destination folders and shares, apply exported share access, and generate two Robocopy jobs:
   - **Initial copy:** repeat while users still access the old server.
   - **Final delta:** stop writes to the old shares, review the `/MIR` commands, then run once during cutover.
4. Run Step 4 after cutover. It compares the target name, installed roles, share names/paths, services, networking, and recent errors with the Step 1 manifest.
5. Monitor the replacement through the agreed rollback period. Run Step 5 to generate an audit-only decommission plan only after Step 4 has no unresolved failures.

## Safety notes

- Step 3 can change DHCP, DNS, and SMB configuration. Each change requires an interactive confirmation.
- Generated Robocopy commands must be reviewed before execution. They use `/COPYALL` and can transfer security metadata.
- Step 5 is deliberately non-destructive. Decommissioning must follow the environment's approved change, retention, and rollback procedures.
- A different server name can break hard-coded UNC paths, SPNs, certificates, scheduled tasks, service accounts, application licenses, and integrations. The inventory identifies these areas, but they still require owner review.
- Domain controllers, Exchange, SQL Server, failover clusters, Hyper-V, DFS namespaces/replication, certificate authorities, and third-party line-of-business applications require their product-specific migration procedures. Do not treat a file copy as a supported migration for those workloads.
- Test the toolkit in a lab before using it on production servers.
