#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Analyzes work item types on an Azure DevOps board.

.DESCRIPTION
    Retrieves work items from a board to determine which types are currently present,
    and queries board configuration to identify which types are configured for the board level.

.PARAMETER Organization
    ADO organization name (e.g., "asos")

.PARAMETER Project
    ADO project name (e.g., "Customer")

.PARAMETER Team
    Team name (e.g., "Analytics and Experimentation")

.PARAMETER BoardLevel
    Board level to query (default: "Backlog items")

.EXAMPLE
    .\Get-WorkItemTypes.ps1 -Organization "asos" -Project "Customer" -Team "Analytics and Experimentation"
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

Write-Host "=== Analyzing Work Item Types ===" -ForegroundColor Cyan
Write-Host "Organization: $Organization" -ForegroundColor White
Write-Host "Project: $Project" -ForegroundColor White
Write-Host "Team: $Team" -ForegroundColor White
Write-Host "Board Level: $BoardLevel" -ForegroundColor White
Write-Host ""

# Step 1: Query work items to identify currently present types
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

$allWorkItems = @()
$currentTypes = @()

if ($itemIds.Count -gt 0) {
    # Step 2: Get work item details
    Write-Host "`nStep 2: Fetching work item details..." -ForegroundColor Yellow

    $batchSize = 200

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

    # Count work items by type
    $typeCounts = $allWorkItems | Group-Object { $_.fields.'System.WorkItemType' } | ForEach-Object {
        @{
            name = $_.Name
            count = $_.Count
        }
    } | Sort-Object -Property count -Descending

    $currentTypes = $typeCounts
    Write-Host "  [OK] Found $($currentTypes.Count) work item types currently present" -ForegroundColor Green
} else {
    Write-Host "  [WARN] No work items found" -ForegroundColor Yellow
}

# Step 3: Get board configuration to identify configured types
Write-Host "`nStep 3: Fetching board configuration..." -ForegroundColor Yellow

$boardUrl = "$baseUrl/$($Team -replace ' ', '%20')/_apis/work/boards/$([Uri]::EscapeDataString($BoardLevel))?api-version=7.0"

$configuredTypes = @()
$defaultType = $null

try {
    $boardConfig = Invoke-RestMethod -Uri $boardUrl -Headers $headers -Method Get
    
    if ($boardConfig.allowedMappings) {
        $configuredTypes = $boardConfig.allowedMappings | ForEach-Object {
            @{
                name = $_.workItemType
                isDefault = ($_.isDefault -eq $true)
            }
        }
        
        $defaultTypeEntry = $configuredTypes | Where-Object { $_.isDefault -eq $true } | Select-Object -First 1
        if ($defaultTypeEntry) {
            $defaultType = $defaultTypeEntry.name
        }
        
        Write-Host "  [OK] Found $($configuredTypes.Count) configured work item types" -ForegroundColor Green
        if ($defaultType) {
            Write-Host "  [OK] Default type: $defaultType" -ForegroundColor Green
        }
    } else {
        Write-Host "  [WARN] Could not determine configured types from board configuration" -ForegroundColor Yellow
    }
} catch {
    Write-Warning "Could not fetch board configuration: $_"
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
    currentTypes = $currentTypes
    configuredTypes = $configuredTypes
    defaultType = $defaultType
    totalCount = $allWorkItems.Count
}

# Output as JSON
$jsonOutput = $result | ConvertTo-Json -Depth 10
Write-Output $jsonOutput

Write-Host "`n[OK] Analysis complete" -ForegroundColor Green
