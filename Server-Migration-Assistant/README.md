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

1. Run Step 1 on the old server and copy the complete toolkit folder to the new server.
2. Run Step 2 on the new server; resolve important warnings and failures.
3. Run Step 3 only after reviewing each prompt and the exported inputs.
4. Run Step 4 after cutover and review its CSV report.
5. Run Step 5 to generate an audit-only decommission plan. It intentionally does not automate domain demotion, role removal, or data deletion.

## Safety notes

- Step 3 can change DHCP, DNS, and SMB configuration. Each change requires an interactive confirmation.
- Generated Robocopy commands must be reviewed before execution. They use `/COPYALL` and can transfer security metadata.
- Step 5 is deliberately non-destructive. Decommissioning must follow the environment's approved change, retention, and rollback procedures.
- Test the toolkit in a lab before using it on production servers.
