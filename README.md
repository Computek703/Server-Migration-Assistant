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
