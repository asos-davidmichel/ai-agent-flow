#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Discovers which ADO work item states exist in each board column.

.DESCRIPTION
    Samples recent work items to determine the mapping between board columns and work item states.
    This is used to configure the Fetch-TeamFlowData.ps1 script without hardcoded state names.

.PARAMETER Organization
    ADO organization name (e.g., "asos")

.PARAMETER Project
    ADO project name (e.g., "Customer")

.PARAMETER Team
    Team name (e.g., "Analytics and Experimentation")

.PARAMETER SampleMonths
    Number of months to sample (default: 3)

.EXAMPLE
    .\Discover-BoardStates.ps1 -Organization "asos" -Project "Customer" -Team "Analytics and Experimentation"
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
    [int]$SampleMonths = 3
)

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
$teamAreaPath = "$Project\$Team"

Write-Host "=== Discovering Board States ===" -ForegroundColor Cyan
Write-Host "Organization: $Organization" -ForegroundColor White
Write-Host "Project: $Project" -ForegroundColor White
Write-Host "Team: $Team" -ForegroundColor White
Write-Host "Sample period: Last $SampleMonths months" -ForegroundColor White
Write-Host ""

# Step 1: Get board configuration
Write-Host "Step 1: Fetching board columns..." -ForegroundColor Yellow

$boardUrl = "$baseUrl/$($Team -replace ' ', '%20')/_apis/work/boards/Backlog%20items?api-version=7.0"

try {
    $boardConfig = Invoke-RestMethod -Uri $boardUrl -Headers $headers -Method Get
    $columns = $boardConfig.columns | Select-Object -ExpandProperty name
    Write-Host "  [OK] Found $($columns.Count) columns" -ForegroundColor Green
} catch {
    Write-Error "Could not fetch board configuration: $_"
    exit 1
}

# Step 2: Sample work items
Write-Host "`nStep 2: Sampling work items from last $SampleMonths months..." -ForegroundColor Yellow

$startDate = (Get-Date).AddMonths(-$SampleMonths).ToString('yyyy-MM-dd')
$endDate = (Get-Date).ToString('yyyy-MM-dd')

# Query for all work items (both active and completed) in the sample period
$wiqlQuery = "SELECT [System.Id], [System.State], [System.BoardColumn] FROM WorkItems WHERE [System.TeamProject] = '$Project' AND [System.AreaPath] UNDER '$teamAreaPath' AND [System.WorkItemType] NOT IN ('Task', 'Epic') AND [System.ChangedDate] >= '$startDate' ORDER BY [System.ChangedDate] DESC"

$wiqlUrl = "$baseUrl/_apis/wit/wiql?api-version=7.0"
$wiqlBody = @{ query = $wiqlQuery } | ConvertTo-Json

try {
    $queryResult = Invoke-RestMethod -Uri $wiqlUrl -Headers $headers -Method Post -Body $wiqlBody
    $itemIds = $queryResult.workItems | ForEach-Object { $_.id }
    Write-Host "  [OK] Found $($itemIds.Count) work items to analyze" -ForegroundColor Green
} catch {
    Write-Error "Failed to query work items: $_"
    exit 1
}

# Step 3: Get detailed work item data
Write-Host "`nStep 3: Fetching work item details..." -ForegroundColor Yellow

$batchSize = 200
$allItems = @()

for ($i = 0; $i -lt $itemIds.Count; $i += $batchSize) {
    $batch = $itemIds[$i..[Math]::Min($i + $batchSize - 1, $itemIds.Count - 1)]
    $idsParam = ($batch -join ',')
    
    $workItemsUrl = "$baseUrl/_apis/wit/workitems?ids=$idsParam&fields=System.State,System.BoardColumn&api-version=7.0"
    
    try {
        $batchResult = Invoke-RestMethod -Uri $workItemsUrl -Headers $headers -Method Get
        $allItems += $batchResult.value
        
        if ($allItems.Count % 200 -eq 0) {
            Write-Host "  Progress: $($allItems.Count) / $($itemIds.Count) items retrieved" -ForegroundColor Gray
        }
    } catch {
        Write-Warning "Failed to fetch batch starting at index ${i}: $($_.Exception.Message)"
    }
}

Write-Host "  [OK] Retrieved $($allItems.Count) work items" -ForegroundColor Green

# Step 4: Analyze column-to-state mappings
Write-Host "`nStep 4: Analyzing column-to-state mappings..." -ForegroundColor Yellow

$columnStateMap = @{}

foreach ($item in $allItems) {
    $column = $item.fields.'System.BoardColumn'
    $state = $item.fields.'System.State'
    
    if ($column -and $state) {
        if (-not $columnStateMap.ContainsKey($column)) {
            $columnStateMap[$column] = @{}
        }
        
        if (-not $columnStateMap[$column].ContainsKey($state)) {
            $columnStateMap[$column][$state] = 0
        }
        
        $columnStateMap[$column][$state]++
    }
}

# Display findings
Write-Host ""
Write-Host "=== Column-to-State Mappings ===" -ForegroundColor Cyan

foreach ($column in $columns) {
    Write-Host "`n  Column: $column" -ForegroundColor Yellow
    
    if ($columnStateMap.ContainsKey($column)) {
        $states = $columnStateMap[$column]
        $sortedStates = $states.GetEnumerator() | Sort-Object -Property Value -Descending
        
        foreach ($state in $sortedStates) {
            Write-Host "    - $($state.Key): $($state.Value) items" -ForegroundColor Gray
        }
    } else {
        Write-Host "    (No items found in this column)" -ForegroundColor Gray
    }
}

# Step 5: Output summary
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Total work items analyzed: $($allItems.Count)" -ForegroundColor White
Write-Host "Columns found: $($columns.Count)" -ForegroundColor White
Write-Host "Unique states discovered: $(($allItems | ForEach-Object { $_.fields.'System.State' } | Select-Object -Unique).Count)" -ForegroundColor White
Write-Host ""
Write-Host "Next step: Use this information to configure which states represent 'completed' and 'active' work." -ForegroundColor Yellow
Write-Host ""

# Return the mapping for programmatic use
return @{
    columns = $columns
    columnStateMap = $columnStateMap
    allStates = ($allItems | ForEach-Object { $_.fields.'System.State' } | Select-Object -Unique | Sort-Object)
}
