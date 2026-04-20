# API Migration Notes

## REST API Migration (2026-04-20)

Migrated three prompts from Azure DevOps MCP server to REST API using PowerShell scripts:

### Updated Prompts
- **ado-blocked**: Now uses `Get-BlockedWorkPatterns.ps1`
- **ado-states**: Now uses `Get-WorkItemStates.ps1`
- **ado-types**: Now uses `Get-WorkItemTypes.ps1`

### New Scripts Created
All scripts follow the same patterns as existing scripts:
- Authentication via `ADO_PAT` or `AZURE_DEVOPS_EXT_PAT` environment variables
- Base64 Basic auth headers
- Error handling with try/catch
- Batch processing for large result sets (200 items per batch)
- JSON output to stdout
- Color-coded console status messages

### Script Purposes
1. **Get-BlockedWorkPatterns.ps1**: Retrieves all work items with full field details to analyze blocked work reporting patterns
2. **Get-WorkItemStates.ps1**: Retrieves work items and work item type definitions with complete state lists
3. **Get-WorkItemTypes.ps1**: Retrieves work items, counts by type, and board configuration to identify configured vs present types

### Why This Migration
- Removes dependency on MCP server for these prompts
- Provides more control over data retrieval and formatting
- Consistent with other prompts (ado-flow, ado-board-config) that already use PowerShell scripts
- Easier to debug and maintain
