# How to Get Real columnTime Data from Azure DevOps

## ✅ AUTOMATED - Runs in Background

**Good news:** columnTime extraction is now **fully automated**! When you run the `ado-flow` prompt, it automatically:

1. ✅ Identifies all completed work items in your analysis
2. ✅ Calls `Get-WorkItemColumnTime.ps1` in the background to extract state history from ADO
3. ✅ Calculates exact time spent in each workflow column
4. ✅ Updates the dashboard data file with real `columnTime` objects
5. ✅ Generates dashboard with accurate efficiency metrics

**You don't need to do anything manually.** The scripts run silently in the background.

---

## Current Status

**Efficiency metrics show "N/A"** because background extraction requires:
- ✅ ADO Personal Access Token (PAT) with work item read permissions
- ✅ Set as environment variable: `$env:AZURE_DEVOPS_EXT_PAT`

Once the PAT is configured, the next time you run the prompt, it will automatically populate real data.

---

## Setup: Configure ADO Authentication

### One-Time Setup

**Create a Personal Access Token:**

1. Go to https://dev.azure.com/asos/_usersSettings/tokens
2. Click "New Token"
3. Give it a name: "Flow Metrics Dashboard"
4. Set expiration (recommend 90 days)
5. Scopes: Select **Work Items (Read)**
6. Click "Create"
7. **Copy the token** (you won't see it again!)

**Set as environment variable:**

```powershell
# Set for current PowerShell session
$env:AZURE_DEVOPS_EXT_PAT = "your-pat-here"

# Set permanently (user level)
[System.Environment]::SetEnvironmentVariable('AZURE_DEVOPS_EXT_PAT', 'your-pat-here', 'User')

# Verify it's set
$env:AZURE_DEVOPS_EXT_PAT
```

### Alternative: Pass PAT Directly

If you prefer not to use environment variables, you can pass the PAT directly in the scripts:

```powershell
$columnTimeData = & "dashboard\Get-WorkItemColumnTime.ps1" `
    -Organization "asos" `
    -Project "Customer" `
    -WorkItemIds @(1170800, 1191895) `
    -PersonalAccessToken "your-pat-here"
```

---

## How the Automation Works

### Script 1: Get-WorkItemColumnTime.ps1

**What it does:**
- Takes a list of work item IDs
- Calls ADO Work Items Updates API for each ID
- Analyzes state change history (revisions)
- Calculates days spent in each state
- Returns `columnTime` objects

**Example output:**
```json
[
  {
    "WorkItemId": 1170800,
    "ColumnTime": {
      "New": 22,
      "Ready for Dev": 2,
      "In Development": 8,
      "In Review": 5,
      "External Review": 3,
      "Ready for QA": 1,
      "QA": 3,
      "Ready for Release": 1
    },
    "TotalDays": 45,
    "StateCount": 8
  }
]
```

### Script 2: Update-DashboardData.ps1

**What it does:**
- Reads the dashboard data JSON file
- Finds each completed work item by ID
- Adds/updates the `columnTime` property
- Saves updated data back to file

**Result:**
```json
{
  "id": 1170800,
  "cycleTime": 23,
  "leadTime": 45,
  "columnTime": {
    "New": 22,
    "Ready for Dev": 2,
    "In Development": 8,
    ...
  }
}
```

---
