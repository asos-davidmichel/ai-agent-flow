#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Fetches flow metrics data from Azure DevOps for a team over a specified time period.

.DESCRIPTION
    Queries ADO REST API to retrieve:
    - All work items completed in the time period
    - All current active work items
    - State transition history for completed items
    - Board configuration (columns)

.PARAMETER Organization
    ADO organization name (e.g., "asos")

.PARAMETER Project
    ADO project name (e.g., "Customer")

.PARAMETER Team
    Team name (e.g., "Analytics and Experimentation")

.PARAMETER Months
    Number of months to look back (default: 3)

.PARAMETER OutputPath
    Path to save the output JSON file

.PARAMETER ConfigFile
    Path to board configuration JSON file (optional)

.EXAMPLE
    .\Fetch-TeamFlowData.ps1 -Organization "asos" -Project "Customer" -Team "Analytics and Experimentation" -Months 3

.EXAMPLE
    .\Fetch-TeamFlowData.ps1 -Organization "asos" -Project "Customer" -Team "Analytics and Experimentation" -ConfigFile ".\src\config\board-config.json" -Months 3
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Organization,
    
    [Parameter(Mandatory = $true)]
    [string]$Project,
    
    [Parameter(Mandatory = $true)]
    [string]$Team,
    
    [Parameter(Mandatory = $false)]
    [int]$Months = 3,
    
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = $null,
    
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = $null,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeActiveHistory
)

# Set up output directory and path
$dateStamp = Get-Date -Format 'yyyy-MM-dd'
$workspaceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$outputDir = Join-Path $workspaceRoot "output\analysis-$dateStamp"

if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $outputDir "flow-data.json"
}

# Load configuration (required)
$config = $null
if (-not $ConfigFile -or -not (Test-Path $ConfigFile)) {
    Write-Error "Configuration file is required but not found: $ConfigFile"
    Write-Host "" -ForegroundColor Yellow
    Write-Host "Board configuration is required to determine which states represent completed/active work." -ForegroundColor Yellow
    Write-Host "Run the board configuration workflow first to generate this file." -ForegroundColor Yellow
    exit 1
}

Write-Host "Loading board configuration from: $ConfigFile" -ForegroundColor Cyan
$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
Write-Host "  [OK] Configuration loaded" -ForegroundColor Green

# Check for PAT
$pat = $env:ADO_PAT
if ([string]::IsNullOrWhiteSpace($pat)) {
    $pat = $env:AZURE_DEVOPS_EXT_PAT
}

if ([string]::IsNullOrWhiteSpace($pat)) {
    Write-Error "No PAT found. Set ADO_PAT or AZURE_DEVOPS_EXT_PAT environment variable."
    exit 1
}

$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$headers = @{
    Authorization = "Basic $base64AuthInfo"
    "Content-Type" = "application/json"
}

$baseUrl = "https://dev.azure.com/$Organization/$Project"

# Calculate date range
$endDate = Get-Date
$startDate = $endDate.AddMonths(-$Months)

Write-Host "=== Azure DevOps Flow Data Analysis ===" -ForegroundColor Cyan
Write-Host "Organization: $Organization" -ForegroundColor White
Write-Host "Project: $Project" -ForegroundColor White
Write-Host "Team: $Team" -ForegroundColor White
Write-Host "Period: $($startDate.ToString('yyyy-MM-dd')) to $($endDate.ToString('yyyy-MM-dd')) ($Months months)" -ForegroundColor White
Write-Host ""

# Step 1: Construct team area path (skip API lookup, use convention)
Write-Host "Step 1: Setting up team area path..." -ForegroundColor Yellow
$teamAreaPath = "$Project\$Team"
Write-Host "  [OK] Team area path: $teamAreaPath" -ForegroundColor Green

# Step 2: Query for completed work items in the time period
Write-Host "`nStep 2: Querying completed work items..." -ForegroundColor Yellow

$startDateStr = $startDate.ToString('yyyy-MM-dd')
$endDateStr = $endDate.ToString('yyyy-MM-dd')

# Get completed states from config
if (-not $config.states.completed.includeStates) {
    Write-Error "Configuration file is missing 'states.completed.includeStates'"
    exit 1
}
$completedStates = $config.states.completed.includeStates
Write-Host "  Using configured completed states: $($completedStates -join ', ')" -ForegroundColor Gray

$completedStatesClause = ($completedStates | ForEach-Object { "'$_'" }) -join ', '
$wiqlQuery = "SELECT [System.Id], [System.WorkItemType], [System.Title], [System.State], [System.CreatedDate], [Microsoft.VSTS.Common.ClosedDate], [Microsoft.VSTS.Common.ActivatedDate], [System.BoardColumn], [System.Tags] FROM WorkItems WHERE [System.TeamProject] = '$Project' AND [System.AreaPath] UNDER '$teamAreaPath' AND [System.State] IN ($completedStatesClause) AND [System.WorkItemType] NOT IN ('Task', 'Epic') AND [Microsoft.VSTS.Common.ClosedDate] >= '$startDateStr' AND [Microsoft.VSTS.Common.ClosedDate] <= '$endDateStr' ORDER BY [Microsoft.VSTS.Common.ClosedDate] DESC"

$wiqlUrl = "$baseUrl/_apis/wit/wiql?api-version=7.0"
$wiqlBody = @{ query = $wiqlQuery } | ConvertTo-Json

try {
    $completedQueryResult = Invoke-RestMethod -Uri $wiqlUrl -Headers $headers -Method Post -Body $wiqlBody
    $completedItemIds = $completedQueryResult.workItems | ForEach-Object { $_.id }
    Write-Host "  [OK] Found $($completedItemIds.Count) completed items" -ForegroundColor Green
} catch {
    Write-Error "Failed to query completed items: $_"
    exit 1
}

# Step 3: Query for current active work items
Write-Host "`nStep 3: Querying active work items..." -ForegroundColor Yellow

# Get excluded states from config
if (-not $config.states.active.excludeStates) {
    Write-Error "Configuration file is missing 'states.active.excludeStates'"
    exit 1
}
$excludedStates = $config.states.active.excludeStates
Write-Host "  Using configured excluded states: $($excludedStates -join ', ')" -ForegroundColor Gray

$excludedStatesClause = ($excludedStates | ForEach-Object { "'$_'" }) -join ', '
$activeWiqlQuery = "SELECT [System.Id], [System.WorkItemType], [System.Title], [System.State], [System.CreatedDate], [System.ChangedDate], [Microsoft.VSTS.Common.ActivatedDate], [System.BoardColumn], [System.Tags] FROM WorkItems WHERE [System.TeamProject] = '$Project' AND [System.AreaPath] UNDER '$teamAreaPath' AND [System.State] NOT IN ($excludedStatesClause) AND [System.WorkItemType] NOT IN ('Task', 'Epic') ORDER BY [System.CreatedDate] ASC"

$activeWiqlBody = @{ query = $activeWiqlQuery } | ConvertTo-Json

try {
    $activeQueryResult = Invoke-RestMethod -Uri $wiqlUrl -Headers $headers -Method Post -Body $activeWiqlBody
    $activeItemIds = $activeQueryResult.workItems | ForEach-Object { $_.id }
    Write-Host "  [OK] Found $($activeItemIds.Count) active items" -ForegroundColor Green
} catch {
    Write-Error "Failed to query active items: $_"
    exit 1
}

# Step 4: Get detailed work item data in batches
Write-Host "`nStep 4: Fetching detailed work item data..." -ForegroundColor Yellow

$allItemIds = $completedItemIds + $activeItemIds
$batchSize = 200
$allItems = @()

for ($i = 0; $i -lt $allItemIds.Count; $i += $batchSize) {
    $batch = $allItemIds[$i..[Math]::Min($i + $batchSize - 1, $allItemIds.Count - 1)]
    $idsParam = ($batch -join ',')
    
    $workItemsUrl = "$baseUrl/_apis/wit/workitems?ids=$idsParam&`$expand=All&api-version=7.0"
    
    try {
        $batchResult = Invoke-RestMethod -Uri $workItemsUrl -Headers $headers -Method Get
        $allItems += $batchResult.value
        Write-Host "  Progress: $($allItems.Count) / $($allItemIds.Count) items retrieved" -ForegroundColor Gray
    } catch {
        Write-Warning "Failed to fetch batch starting at index ${i}: $($_.Exception.Message)"
    }
}

Write-Host "  [OK] Retrieved $($allItems.Count) work items" -ForegroundColor Green

# Step 5: Get board configuration (columns)
Write-Host "`nStep 5: Fetching board configuration..." -ForegroundColor Yellow

$boardUrl = "$baseUrl/$($Team -replace ' ', '%20')/_apis/work/boards/Backlog%20items?api-version=7.0"

try {
    $boardConfig = Invoke-RestMethod -Uri $boardUrl -Headers $headers -Method Get
    $columns = $boardConfig.columns | Select-Object -ExpandProperty name
    Write-Host "  [OK] Board columns: $($columns -join ' > ')" -ForegroundColor Green
} catch {
    Write-Warning "Could not fetch board configuration: $_"
    $columns = @()
}

# Step 6: Get state transition history for completed items
Write-Host "`nStep 6: Fetching state transition history for completed items..." -ForegroundColor Yellow
Write-Host "  (This may take a while...)" -ForegroundColor Gray

$completedItemsWithHistory = @()

foreach ($item in ($allItems | Where-Object { $completedItemIds -contains $_.id })) {
    $itemId = $item.id
    $updatesUrl = "$baseUrl/_apis/wit/workitems/$itemId/updates?api-version=7.0"
    
    try {
        $updates = Invoke-RestMethod -Uri $updatesUrl -Headers $headers -Method Get
        
        $itemWithHistory = @{
            id = $item.id
            fields = $item.fields
            updates = $updates.value
        }
        
        $completedItemsWithHistory += $itemWithHistory
        
        if ($completedItemsWithHistory.Count % 10 -eq 0) {
            Write-Host "  Progress: $($completedItemsWithHistory.Count) / $($completedItemIds.Count) histories retrieved" -ForegroundColor Gray
        }
    } catch {
        Write-Warning "Failed to get history for item ${itemId}: $($_.Exception.Message)"
    }
}

Write-Host "  [OK] Retrieved history for $($completedItemsWithHistory.Count) completed items" -ForegroundColor Green

# Step 6b: Optionally fetch state/column transition history for active items
$activeItemsWithHistory = $null
if ($IncludeActiveHistory) {
    Write-Host "`nStep 6b: Fetching state transition history for active items..." -ForegroundColor Yellow
    Write-Host "  (This may take a while; active items: $($activeItemIds.Count))" -ForegroundColor Gray

    $activeItemsWithHistory = @()
    $activeItemsRaw = @($allItems | Where-Object { $activeItemIds -contains $_.id })

    foreach ($item in $activeItemsRaw) {
        $itemId = $item.id
        $updatesUrl = "$baseUrl/_apis/wit/workitems/$itemId/updates?api-version=7.0"

        try {
            $updates = Invoke-RestMethod -Uri $updatesUrl -Headers $headers -Method Get

            $itemWithHistory = @{
                id = $item.id
                fields = $item.fields
                updates = $updates.value
            }

            $activeItemsWithHistory += $itemWithHistory

            if ($activeItemsWithHistory.Count % 20 -eq 0) {
                Write-Host "  Progress: $($activeItemsWithHistory.Count) / $($activeItemIds.Count) histories retrieved" -ForegroundColor Gray
            }
        } catch {
            Write-Warning "Failed to get history for active item ${itemId}: $($_.Exception.Message)"
        }
    }

    Write-Host "  [OK] Retrieved history for $($activeItemsWithHistory.Count) active items" -ForegroundColor Green
}

# Step 7: Structure the output data
Write-Host "`nStep 7: Structuring output data..." -ForegroundColor Yellow

$outputData = @{
    metadata = @{
        organization = $Organization
        project = $Project
        team = $Team
        teamAreaPath = $teamAreaPath
        startDate = $startDate.ToString('yyyy-MM-dd')
        endDate = $endDate.ToString('yyyy-MM-dd')
        months = $Months
        generatedAt = (Get-Date).ToString('o')
    }
    boardConfig = @{
        columns = $columns
    }
    summary = @{
        totalItems = $allItems.Count
        completedItems = $completedItemsWithHistory.Count
        activeItems = $activeItemIds.Count
    }
    completedItems = $completedItemsWithHistory
    activeItems = if ($IncludeActiveHistory -and $activeItemsWithHistory) { $activeItemsWithHistory } else { ($allItems | Where-Object { $activeItemIds -contains $_.id }) }
}

# Step 8: Save to JSON file
Write-Host "`nStep 8: Saving data to file..." -ForegroundColor Yellow

try {
    $json = $outputData | ConvertTo-Json -Depth 10 -Compress:$false
    [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))
    
    $fileSize = (Get-Item $OutputPath).Length
    Write-Host "  [OK] Saved to: $OutputPath" -ForegroundColor Green
    Write-Host "  File size: $([Math]::Round($fileSize / 1KB, 2)) KB" -ForegroundColor Green
} catch {
    Write-Error "Failed to save output file: $_"
    exit 1
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Total work items: $($allItems.Count)" -ForegroundColor White
Write-Host "Completed: $($completedItemsWithHistory.Count)" -ForegroundColor White
Write-Host "Active: $($activeItemIds.Count)" -ForegroundColor White
Write-Host "Output: $OutputPath" -ForegroundColor White
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Process this data to calculate flow metrics" -ForegroundColor Gray
Write-Host "  2. Extract columnTime from state transitions" -ForegroundColor Gray
Write-Host "  3. Generate dashboard JSON" -ForegroundColor Gray
Write-Host ""

# Exit successfully
exit 0
