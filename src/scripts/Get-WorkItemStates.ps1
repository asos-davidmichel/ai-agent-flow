#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Analyzes work item states on an Azure DevOps board.

.DESCRIPTION
    Retrieves work items from a board and their type definitions to determine
    the workflow states used by each work item type.

.PARAMETER Organization
    ADO organization name (e.g., "asos")

.PARAMETER Project
    ADO project name (e.g., "Customer")

.PARAMETER Team
    Team name (e.g., "Analytics and Experimentation")

.PARAMETER BoardLevel
    Board level to query (default: "Backlog items")

.EXAMPLE
    .\Get-WorkItemStates.ps1 -Organization "asos" -Project "Customer" -Team "Analytics and Experimentation"
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
    [string]$BoardLevel = "Backlog items"
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

Write-Host "=== Analyzing Work Item States ===" -ForegroundColor Cyan
Write-Host "Organization: $Organization" -ForegroundColor White
Write-Host "Project: $Project" -ForegroundColor White
Write-Host "Team: $Team" -ForegroundColor White
Write-Host "Board Level: $BoardLevel" -ForegroundColor White
Write-Host ""

# Step 1: Query work items to identify types
Write-Host "Step 1: Retrieving work items..." -ForegroundColor Yellow

$wiqlQuery = @"
SELECT [System.Id], [System.WorkItemType], [System.State]
FROM WorkItems
WHERE [System.TeamProject] = '$Project'
AND [System.AreaPath] UNDER '$teamAreaPath'
AND [System.WorkItemType] NOT IN ('Task', 'Epic')
ORDER BY [System.ChangedDate] DESC
"@

$wiqlUrl = "$baseUrl/_apis/wit/wiql?api-version=7.0"
$wiqlBody = @{ query = $wiqlQuery } | ConvertTo-Json

try {
    $queryResult = Invoke-RestMethod -Uri $wiqlUrl -Headers $headers -Method Post -Body $wiqlBody
    $itemIds = $queryResult.workItems | ForEach-Object { $_.id }
    Write-Host "  [OK] Found $($itemIds.Count) work items" -ForegroundColor Green
} catch {
    Write-Error "Failed to query work items: $_"
    exit 1
}

if ($itemIds.Count -eq 0) {
    Write-Host "  [WARN] No work items found" -ForegroundColor Yellow
    $result = @{
        organization = $Organization
        project = $Project
        team = $Team
        boardLevel = $BoardLevel
        retrievalTimestamp = (Get-Date -Format 'o')
        workItems = @()
        workItemTypes = @()
        totalCount = 0
    }
    $result | ConvertTo-Json -Depth 10
    exit 0
}

# Step 2: Get work item details to identify types
Write-Host "`nStep 2: Fetching work item details..." -ForegroundColor Yellow

$batchSize = 200
$allWorkItems = @()

for ($i = 0; $i -lt $itemIds.Count; $i += $batchSize) {
    $batch = $itemIds[$i..[Math]::Min($i + $batchSize - 1, $itemIds.Count - 1)]
    $idsParam = $batch -join ','
    
    $workItemsUrl = "$baseUrl/_apis/wit/workitems?ids=$idsParam&`$expand=all&api-version=7.0"
    
    try {
        $batchResult = Invoke-RestMethod -Uri $workItemsUrl -Headers $headers -Method Get
        $allWorkItems += $batchResult.value
    } catch {
        Write-Error "Failed to fetch work item details: $_"
        exit 1
    }
}

Write-Host "  [OK] Retrieved $($allWorkItems.Count) work items" -ForegroundColor Green

# Identify unique work item types
$uniqueTypes = $allWorkItems | ForEach-Object { $_.fields.'System.WorkItemType' } | Select-Object -Unique
Write-Host "  [OK] Found $($uniqueTypes.Count) work item types: $($uniqueTypes -join ', ')" -ForegroundColor Green

# Step 3: Get state definitions for each work item type
Write-Host "`nStep 3: Fetching state definitions..." -ForegroundColor Yellow

$workItemTypeDetails = @()

foreach ($typeName in $uniqueTypes) {
    $typeUrl = "$baseUrl/_apis/wit/workitemtypes/$([Uri]::EscapeDataString($typeName))?api-version=7.0"
    
    try {
        $typeDefinition = Invoke-RestMethod -Uri $typeUrl -Headers $headers -Method Get
        
        $states = $typeDefinition.states | ForEach-Object { $_.name }
        
        $workItemTypeDetails += @{
            name = $typeName
            states = $states
        }
        
        Write-Host "  [OK] Retrieved states for: $typeName ($($states.Count) states)" -ForegroundColor Green
    } catch {
        Write-Warning "Could not fetch state definitions for $typeName : $_"
    }
}

# Step 4: Output structured result
Write-Host "`nStep 4: Generating output..." -ForegroundColor Yellow

$result = @{
    organization = $Organization
    project = $Project
    team = $Team
    boardLevel = $BoardLevel
    retrievalTimestamp = (Get-Date -Format 'o')
    workItems = $allWorkItems
    workItemTypes = $workItemTypeDetails
    totalCount = $allWorkItems.Count
}

# Output as JSON
$jsonOutput = $result | ConvertTo-Json -Depth 10
Write-Output $jsonOutput

Write-Host "`n[OK] Analysis complete" -ForegroundColor Green
