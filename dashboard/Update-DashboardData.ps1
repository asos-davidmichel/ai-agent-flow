# Update-DashboardData.ps1
# Merges real columnTime data into dashboard data file

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DataFilePath,
    
    [Parameter(Mandatory = $true)]
    $ColumnTimeData
)

# Parse input data if it's a JSON string
if ($ColumnTimeData -is [string]) {
    $columnTimeArray = $ColumnTimeData | ConvertFrom-Json
} else {
    $columnTimeArray = $ColumnTimeData
}

# Read existing dashboard data
if (-not (Test-Path $DataFilePath)) {
    Write-Error "Data file not found: $DataFilePath"
    return
}

$dashboardData = Get-Content $DataFilePath -Raw | ConvertFrom-Json
$updatedCount = 0

# Process all charts that have datasets with data arrays
foreach ($chartProp in $dashboardData.charts.PSObject.Properties) {
    $chart = $chartProp.Value
    if ($chart.datasets) {
        foreach ($dataset in $chart.datasets) {
            if ($dataset.data) {
                foreach ($item in $dataset.data) {
                    # Find matching columnTime data
                    $columnTimeEntry = $columnTimeArray | Where-Object { $_.WorkItemId -eq $item.id }
                    
                    if ($columnTimeEntry) {
                        # Add or update the columnTime property
                        $item | Add-Member -NotePropertyName "columnTime" -NotePropertyValue $columnTimeEntry.ColumnTime -Force
                        
                        Write-Verbose "Updated work item #$($item.id) with columnTime data"
                        $updatedCount++
                    }
                }
            }
        }
    }
}

# Write updated data back to file
$dashboardData | ConvertTo-Json -Depth 20 | Set-Content $DataFilePath -Encoding UTF8

Write-Host "Updated $updatedCount work items with real columnTime data" -ForegroundColor Green
