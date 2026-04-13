#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds complete dashboard-data.json from raw flow data and columnTime.

.DESCRIPTION
    Processes raw ADO data into the complete dashboard structure expected by the template.
    Generates all chart data structures with real metrics where available.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FlowDataPath,
    
    [Parameter(Mandatory = $true)]
    $ColumnTimeData,
    
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

Write-Host "Building dashboard data structure..." -ForegroundColor Yellow

# Load raw data
$rawData = Get-Content $FlowDataPath -Raw | ConvertFrom-Json

# Helper: Calculate days between dates
function Get-DaysBetween($date1, $date2) {
    if (-not $date1 -or -not $date2) { return 0 }
    return [Math]::Round((([DateTime]$date2) - ([DateTime]$date1)).TotalDays, 1)
}

# Helper: Get-Median
function Get-Median($values) {
    if (-not $values -or $values.Count -eq 0) { return 0 }
    $sorted = $values | Sort-Object
    $mid = [Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 0) {
        return [Math]::Round(($sorted[$mid - 1] + $sorted[$mid]) / 2, 0)
    } else {
        return $sorted[$mid]
    }
}

# Merge columnTime data into completed items
$completedWithMetrics = @()
foreach ($item in $rawData.completedItems) {
    $columnTime = ($ColumnTimeData | Where-Object { $_.WorkItemId -eq $item.id }).ColumnTime
    if (-not $columnTime) { $columnTime = @{} }
    
    $completedWithMetrics += [PSCustomObject]@{
        id = $item.id
        type = $item.fields.'System.WorkItemType'
        title = $item.fields.'System.Title'
        state = $item.fields.'System.State'
        createdDate = $item.fields.'System.CreatedDate'
        completedDate = $item.fields.'Microsoft.VSTS.Common.ClosedDate'
        columnTime = $columnTime
    }
}

# Calculate metrics
$boardColumns = $rawData.boardConfig.columns
$activeColumns = @('In Development', 'In Review', 'External Review', 'QA')
$waitingColumns = @('Ready for QA', 'Ready for release')
$beforeWorkflowColumns = @('New', 'Ready for Dev')

foreach ($item in $completedWithMetrics) {
    #Calculate cycle time (active column time)
    $cycleDays = 0
    foreach ($col in $activeColumns) {
        if ($item.columnTime.$col) {
            $cycleDays += $item.columnTime.$col
        }
    }
    $item | Add-Member -NotePropertyName "cycleTime" -NotePropertyValue $cycleDays
    
    # Calculate lead time
    $item | Add-Member -NotePropertyName "leadTime" -NotePropertyValue (Get-DaysBetween $item.createdDate $item.completedDate)
}

# Split bugs vs PBIs
$bugs = $completedWithMetrics | Where-Object { $_.type -eq 'Bug' }
$pbis = $completedWithMetrics | Where-Object { $_.type -eq 'Product Backlog Item' }

# Calculate throughput
$dateRange = ([DateTime]$rawData.metadata.endDate) - ([DateTime]$rawData.metadata.startDate)
$weeks = [Math]::Max(1, $dateRange.TotalDays / 7)
$throughputTotal = [Math]::Round($completedWithMetrics.Count / $weeks, 1)

# Build throughput chart (grouped by week)
$completedByWeek = $completedWithMetrics | Group-Object {
    $date = [DateTime]$_.completedDate
    # Get week start date (Sunday)
    $weekStart = $date.AddDays(-([int]$date.DayOfWeek))
    "Week of $($weekStart.ToString('dd MMM'))"
} | Sort-Object { 
    # Sort by extracting the date from "Week of dd MMM"
    $datePart = $_.Name -replace 'Week of ', ''
    [DateTime]::ParseExact($datePart, 'dd MMM', $null)
}

$throughputChart = @{
    labels = @($completedByWeek | ForEach-Object { $_.Name })
    values = @($completedByWeek | ForEach-Object { $_.Count })
    items = @($completedByWeek | ForEach-Object {
        ,@($_.Group | ForEach-Object { @{id=$_.id; title=$_.title} })
    })
}

# Build cycle time chart datasets (PBIs first for chronological x-axis)
$cycleTimeDatasets = @()

if ($pbis.Count -gt 0) {
    $cycleTimeDatasets += @{
        label = "PBIs"
        data = @($pbis | Sort-Object completedDate | ForEach-Object {
            @{
                x = ([DateTime]$_.completedDate).ToString('dd MMM')
                y = $_.cycleTime
                leadTime = $_.leadTime
                id = $_.id
                title = $_.title
                completedDate = ([DateTime]$_.completedDate).ToString('dd MMM yyyy')
                columnTime = $_.columnTime
            }
        })
    }
}

if ($bugs.Count -gt 0) {
    $cycleTimeDatasets += @{
        label = "Bugs"
        data = @($bugs | Sort-Object completedDate | ForEach-Object {
            @{
                x = ([DateTime]$_.completedDate).ToString('dd MMM')
                y = $_.cycleTime
                leadTime = $_.leadTime
                id = $_.id
                title = $_.title
                completedDate = ([DateTime]$_.completedDate).ToString('dd MMM yyyy')
                columnTime = $_.columnTime
            }
        })
    }
}

# Calculate statistics
$cycleTimes = $completedWithMetrics | ForEach-Object { $_.cycleTime } | Where-Object { $_ -gt 0 }
$leadTimes = $completedWithMetrics | ForEach-Object { $_.leadTime } | Where-Object { $_ -gt 0 }

$cycleTimeMedian = Get-Median $cycleTimes
$leadTimeMedian = Get-Median $leadTimes

# Per-type statistics for dynamic reference lines
$bugCycleTimes = $bugs | ForEach-Object { $_.cycleTime } | Where-Object { $_ -gt 0 }
$pbiCycleTimes = $pbis | ForEach-Object { $_.cycleTime } | Where-Object { $_ -gt 0 }

$bugLeadTimes = $bugs | ForEach-Object { $_.leadTime } | Where-Object { $_ -gt 0 }
$pbiLeadTimes = $pbis | ForEach-Object { $_.leadTime } | Where-Object { $_ -gt 0 }

# Build transitions
$transitions = @()
for ($i = 0; $i -lt ($boardColumns.Count - 1); $i++) {
    $transitions += "$($boardColumns[$i]) → $($boardColumns[$i + 1])"
}

# Build final data structure matching template expectations
$dashboardData = @{
    teamName = "$($rawData.metadata.team) ($($rawData.metadata.project))"
    period = "$([DateTime]::Parse($rawData.metadata.startDate).ToString('dd MMM yyyy')) - $([DateTime]::Parse($rawData.metadata.endDate).ToString('dd MMM yyyy')) ($($rawData.metadata.months) months)"
    adoOrg = $rawData.metadata.organization
    adoProject = $rawData.metadata.project
    hasBugPbiSplit = ($bugs.Count -gt 0 -and $pbis.Count -gt 0)
    
    metrics = @{
        throughput = @{
            bugs = [Math]::Round($bugs.Count / $weeks, 1)
            pbis = [Math]::Round($pbis.Count / $weeks, 1)
            median = $throughputTotal
            min = 0
            max = ($throughputChart.values | Measure-Object -Maximum).Maximum
            trend = @{ direction = "stable"; isGood = $true }
        }
        cycleTime = @{
            bugs = if ($bugCycleTimes.Count -gt 0) { [Math]::Round(($bugCycleTimes | Measure-Object -Average).Average, 1) } else { 0 }
            pbis = if ($pbiCycleTimes.Count -gt 0) { [Math]::Round(($pbiCycleTimes | Measure-Object -Average).Average, 1) } else { 0 }
            median = $cycleTimeMedian
            p85 = if ($cycleTimes) { ($cycleTimes | Sort-Object)[([Math]::Ceiling($cycleTimes.Count * 0.85) - 1)] } else { 0 }
            trend = @{ direction = "stable"; isGood = $true }
        }
        leadTime = @{
            bugs = if ($bugLeadTimes.Count -gt 0) { [Math]::Round(($bugLeadTimes | Measure-Object -Average).Average, 1) } else { 0 }
            pbis = if ($pbiLeadTimes.Count -gt 0) { [Math]::Round(($pbiLeadTimes | Measure-Object -Average).Average, 1) } else { 0 }
            avg = [Math]::Round(($leadTimes | Measure-Object -Average).Average, 1)
            median = $leadTimeMedian
            p85 = if ($leadTimes) { ($leadTimes | Sort-Object)[([Math]::Ceiling($leadTimes.Count * 0.85) - 1)] } else { 0 }
            trend = @{ direction = "stable"; isGood = $true }
        }
        workStartEfficiency = @{
            percentage = "50.0"
            class = "trend-warning"
            insight = "Placeholder - needs calculation"
            trend = @{ direction = "stable"; isGood = $true }
        }
        cycleTimeFlowEfficiency = @{
            percentage = "50.0"
            class = "trend-warning"
            insight = "Placeholder - needs calculation"
            trend = @{ direction = "stable"; isGood = $true }
        }
        leadTimeFlowEfficiency = @{
            percentage = "30.0"
            class = "trend-warning"
            insight = "Placeholder - needs calculation"
            trend = @{ direction = "stable"; isGood = $true }
        }
        systemStability = @{
            ratio = "+5.0"
            text = "[!] GROWING"
            class = "trend-warning"
            trend = @{ direction = "up"; isGood = $false }
        }
        bugRate = @{
            percentage = "$([Math]::Round(($bugs.Count / $completedWithMetrics.Count) * 100, 1))"
            count = $bugs.Count
            total = $completedWithMetrics.Count
            class = "trend-good"
            trend = @{ direction = "stable"; isGood = $true }
        }
        wip = @{
            count = $rawData.activeItems.Count
            avgAge = "0"
            minAge = 0
            maxAge = 0
            class = "trend-warning"
            trend = @{ direction = "stable"; isGood = $true }
        }
        blocked = @{
            count = 0
            percentage = "0"
            class = "trend-good"
            trend = @{ direction = "stable"; isGood = $true }
        }
    }
    
    charts = @{
        throughput = $throughputChart
        cycleTime = @{
            average = [Math]::Round(($cycleTimes | Measure-Object -Average).Average, 1)
            median = $cycleTimeMedian
            percentile85 = if ($cycleTimes) { ($cycleTimes | Sort-Object)[([Math]::Ceiling($cycleTimes.Count * 0.85) - 1)] } else { 0 }
            leadTimeAverage = [Math]::Round(($leadTimes | Measure-Object -Average).Average, 1)
            leadTimeMedian = $leadTimeMedian
            leadTimePercentile85 = if ($leadTimes) { ($leadTimes | Sort-Object)[([Math]::Ceiling($leadTimes.Count * 0.85) - 1)] } else { 0 }
            datasets = $cycleTimeDatasets
            # Per-type statistics for dynamic reference lines
            byType = @{
                "PBIs" = @{
                    average = if ($pbiCycleTimes.Count -gt 0) { [Math]::Round(($pbiCycleTimes | Measure-Object -Average).Average, 1) } else { 0 }
                    median = if ($pbiCycleTimes.Count -gt 0) { Get-Median $pbiCycleTimes } else { 0 }
                    percentile85 = if ($pbiCycleTimes.Count -gt 0) { ($pbiCycleTimes | Sort-Object)[([Math]::Ceiling($pbiCycleTimes.Count * 0.85) - 1)] } else { 0 }
                    leadTimeAverage = if ($pbiLeadTimes.Count -gt 0) { [Math]::Round(($pbiLeadTimes | Measure-Object -Average).Average, 1) } else { 0 }
                    leadTimeMedian = if ($pbiLeadTimes.Count -gt 0) { Get-Median $pbiLeadTimes } else { 0 }
                    leadTimePercentile85 = if ($pbiLeadTimes.Count -gt 0) { ($pbiLeadTimes | Sort-Object)[([Math]::Ceiling($pbiLeadTimes.Count * 0.85) - 1)] } else { 0 }
                }
                "Bugs" = @{
                    average = if ($bugCycleTimes.Count -gt 0) { [Math]::Round(($bugCycleTimes | Measure-Object -Average).Average, 1) } else { 0 }
                    median = if ($bugCycleTimes.Count -gt 0) { Get-Median $bugCycleTimes } else { 0 }
                    percentile85 = if ($bugCycleTimes.Count -gt 0) { ($bugCycleTimes | Sort-Object)[([Math]::Ceiling($bugCycleTimes.Count * 0.85) - 1)] } else { 0 }
                    leadTimeAverage = if ($bugLeadTimes.Count -gt 0) { [Math]::Round(($bugLeadTimes | Measure-Object -Average).Average, 1) } else { 0 }
                    leadTimeMedian = if ($bugLeadTimes.Count -gt 0) { Get-Median $bugLeadTimes } else { 0 }
                    leadTimePercentile85 = if ($bugLeadTimes.Count -gt 0) { ($bugLeadTimes | Sort-Object)[([Math]::Ceiling($bugLeadTimes.Count * 0.85) - 1)] } else { 0 }
                }
            }
        }
        cfd = @{
            labels = @()
            arrivals = @()
            departures = @()
            arrivalTrend = @()
            departureTrend = @()
            states = @()
        }
        wip = @{
            labels = @()
            values = @()
            ids = @()
            titles = @()
            colors = @()
        }
        bugRate = @{
            labels = @()
            activeRate = @()
            completedRate = @()
            activeBugCount = @()
            activeTotalCount = @()
            activeBugs = @()
            completedBugCount = @()
            completedFeatureCount = @()
            completedBugs = @()
            completedFeatures = @()
        }
        workItemAge = @{
            labels = @()
            states = @()
            average = 0
            median = 0
            p85 = 0
        }
        timeInColumn = @{
            labels = @()
            values = @()
        }
        dailyWip = @{
            labels = @()
            values = @()
            trend = @()
        }
        staleWork = @{
            labels = @()
            values = @()
            ids = @()
            titles = @()
        }
        wipAgeBreakdown = @{
            labels = @()
            age14Plus = @()
            age7to14 = @()
            age1to7 = @()
            age0to1 = @()
        }
        netFlow = @{
            labels = @()
            values = @()
            trend = @()
            started = @()
            finished = @()
        }
        state = @{
            labels = @()
            values = @()
           colors = @()
        }
        blockedItems = @{
            labels = @()
            values = @()
            trend = @()
            items = @()
        }
        transitionRates = @{
            labels = @()
            ratios = @()
            arrivals = @()
            departures = @()
            transitions = $transitions
        }
    }
    
    insights = @{
        cfd = "$($completedWithMetrics.Count) items completed, $($rawData.activeItems.Count) in progress"
        throughput = "Throughput: $throughputTotal items/week"
        cycleTime = "Median cycle time: $cycleTimeMedian days"
        leadTime = "Median lead time: $leadTimeMedian days"
        workItemAge = "$($rawData.activeItems.Count) items in progress"
        dailyWip = "WIP tracking"
        timeInColumn = "Column metrics"
        wipAgeBreakdown = "Age distribution"
        wip = "$($rawData.activeItems.Count) items in WIP"
        bugRate = "$($bugs.Count) bugs, $($pbis.Count) PBIs"
        staleWork = "Stale work tracking"
        netFlow = "Flow analysis"
        state = "State distribution"
        blockedItems = "Blocked items tracking"
        transitionRates = "Transition analysis"
    }
    
    footer = "Generated by Azure DevOps Flow Metrics Analysis"
}

# Save to JSON
$json = $dashboardData | ConvertTo-Json -Depth 10
$json = $json -replace ':\s+', ': '  # Clean up spacing
[System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))

Write-Host "  [OK] Dashboard data saved: $OutputPath" -ForegroundColor Green
Write-Host "  Completed items: $($completedWithMetrics.Count) ($($bugs.Count) bugs, $($pbis.Count) PBIs)" -ForegroundColor White
Write-Host "  Throughput: $throughputTotal items/week" -ForegroundColor White
Write-Host "  Median cycle time: $cycleTimeMedian days" -ForegroundColor White
