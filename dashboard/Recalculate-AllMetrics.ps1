#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Recalculates ALL summary metrics from real data (NO ESTIMATES).

.DESCRIPTION
    Updates all metric values in dashboard-data-example.json to be calculated
    from the REAL cycle time and lead time data (which comes from columnTime).
    
.EXAMPLE
    .\Recalculate-AllMetrics.ps1
#>

[CmdletBinding()]
param(
    [string]$DataFilePath = (Join-Path $PSScriptRoot 'dashboard-data-example.json')
)

try {
    Write-Host "Loading dashboard data from: $DataFilePath" -ForegroundColor Cyan
    $data = Get-Content $DataFilePath -Encoding UTF8 | ConvertFrom-Json
    
    # Get bugs and PBIs datasets
    $bugs = $data.charts.cycleTime.datasets | Where-Object { $_.label -eq 'Bugs' }
    $pbis = $data.charts.cycleTime.datasets | Where-Object { $_.label -eq 'PBIs' }
    
    # Extract values
    $bugCycleTimes = $bugs.data | ForEach-Object { $_.y }
    $pbiCycleTimes = $pbis.data | ForEach-Object { $_.y }
    $allCycleTimes = $bugCycleTimes + $pbiCycleTimes
    
    $bugLeadTimes = $bugs.data | ForEach-Object { $_.leadTime }
    $pbiLeadTimes = $pbis.data | ForEach-Object { $_.leadTime }
    $allLeadTimes = $bugLeadTimes + $pbiLeadTimes
    
    Write-Host "`nRecalculating metrics from REAL data..." -ForegroundColor Cyan
    
    # Cycle Time metrics
    $data.metrics.cycleTime.bugs = [math]::Round(($bugCycleTimes | Measure-Object -Average).Average, 1)
    $data.metrics.cycleTime.pbis = [math]::Round(($pbiCycleTimes | Measure-Object -Average).Average, 1)
    $cycleTimeSorted = $allCycleTimes | Sort-Object
    $data.metrics.cycleTime.median = $cycleTimeSorted[[math]::Floor($cycleTimeSorted.Count / 2)]
    $p85Index = [math]::Floor($cycleTimeSorted.Count * 0.85)
    $data.metrics.cycleTime.p85 = [math]::Round($cycleTimeSorted[$p85Index], 1)
    
    Write-Host "  Cycle Time - Bugs: $($data.metrics.cycleTime.bugs), PBIs: $($data.metrics.cycleTime.pbis)" -ForegroundColor Green
    
    # Lead Time metrics
    $data.metrics.leadTime.bugs = [math]::Round(($bugLeadTimes | Measure-Object -Average).Average, 1)
    $data.metrics.leadTime.pbis = [math]::Round(($pbiLeadTimes | Measure-Object -Average).Average, 1)
    $data.metrics.leadTime.avg = [math]::Round(($allLeadTimes | Measure-Object -Average).Average, 1)
    $leadTimeSorted = $allLeadTimes | Sort-Object
    $data.metrics.leadTime.median = $leadTimeSorted[[math]::Floor($leadTimeSorted.Count / 2)]
    $p85IndexLead = [math]::Floor($leadTimeSorted.Count * 0.85)
    $data.metrics.leadTime.p85 = [math]::Round($leadTimeSorted[$p85IndexLead], 1)
    
    Write-Host "  Lead Time - Bugs: $($data.metrics.leadTime.bugs), PBIs: $($data.metrics.leadTime.pbis), Avg: $($data.metrics.leadTime.avg)" -ForegroundColor Green
    
    # Efficiency metrics - these will be recalculated by the dashboard from columnTime, so just note them
    Write-Host "  Efficiency metrics will be calculated by dashboard from columnTime data" -ForegroundColor Cyan
    
    Write-Host "`nSaving updated metrics..." -ForegroundColor Cyan
    $jsonOutput = $data | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($DataFilePath, $jsonOutput, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Metrics updated successfully!" -ForegroundColor Green
    Write-Host "`nAll metrics now calculated from REAL data (NO ESTIMATES)" -ForegroundColor Green
    
} catch {
    Write-Error "Failed to recalculate metrics: $($_.Exception.Message)"
    exit 1
}
