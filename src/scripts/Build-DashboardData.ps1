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
    [string]$OutputPath,
    
    [Parameter(Mandatory = $false)]
    [string]$WorkflowStartColumn,
    
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = $null
)

Write-Host "Building dashboard data structure..." -ForegroundColor Yellow

# Load raw data
$rawData = Get-Content $FlowDataPath -Raw | ConvertFrom-Json

# Load configuration if provided
$config = $null
if ($ConfigFile -and (Test-Path $ConfigFile)) {
    $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    Write-Host "  Using configuration: $ConfigFile" -ForegroundColor Gray
}

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

# Helper: Calculate-Trend using linear regression
function Calculate-Trend($values, $higherIsBetter = $true) {
    if (-not $values -or $values.Count -lt 3) { 
        return @{ direction = "stable"; isGood = $true }
    }
    
    # Linear regression: y = mx + b
    $n = $values.Count
    $x = 0..($n - 1)
    $sumX = ($x | Measure-Object -Sum).Sum
    $sumY = ($values | Measure-Object -Sum).Sum
    $sumXY = 0
    $sumX2 = 0
    
    for ($i = 0; $i -lt $n; $i++) {
        $sumXY += $x[$i] * $values[$i]
        $sumX2 += $x[$i] * $x[$i]
    }
    
    # Slope (m)
    $slope = ($n * $sumXY - $sumX * $sumY) / ($n * $sumX2 - $sumX * $sumX)
    
    # Determine direction and significance
    $mean = $sumY / $n
    $threshold = $mean * 0.05  # 5% change threshold for significance
    
    if ([Math]::Abs($slope) -lt $threshold) {
        return @{ direction = "stable"; isGood = $true }
    } elseif ($slope > 0) {
        return @{ 
            direction = "up"
            isGood = $higherIsBetter
        }
    } else {
        return @{ 
            direction = "down"
            isGood = -not $higherIsBetter
        }
    }
}

# Helper: Calculate lead time based on configuration
function Get-LeadTime($item, $config) {
    $closedDate = $item.fields.'Microsoft.VSTS.Common.ClosedDate'
    if (-not $closedDate) { return 0 }
    
    # Determine lead time start type from config (default: boardEntry)
    $startType = if ($config -and $config.metrics.leadTime.startType) {
        $config.metrics.leadTime.startType
    } else {
        'boardEntry'
    }
    
    $startDate = $null
    
    switch ($startType) {
        'creation' {
            # Use System.CreatedDate
            $startDate = $item.fields.'System.CreatedDate'
        }
        'boardEntry' {
            # Find first board column entry from updates
            if ($item.updates -and $item.updates.Count -gt 0) {
                $firstBoardEntry = $item.updates | Where-Object { 
                    $_.fields.'System.BoardColumn' -and $_.fields.'System.BoardColumn'.newValue 
                } | Select-Object -First 1
                
                if ($firstBoardEntry) {
                    $startDate = $firstBoardEntry.revisedDate
                } else {
                    # Fallback: use CreatedDate if no board column entry found
                    $startDate = $item.fields.'System.CreatedDate'
                }
            } else {
                # Fallback: no updates available, use CreatedDate
                $startDate = $item.fields.'System.CreatedDate'
            }
        }
        'backlogExit' {
            # Find when item left last backlog column (enters first in-progress column)
            $targetColumn = if ($config -and $config.metrics.leadTime.column) {
                $config.metrics.leadTime.column
            } else {
                'In Development'  # Default
            }
            
            if ($item.updates -and $item.updates.Count -gt 0) {
                $entryToInProgress = $item.updates | Where-Object { 
                    $_.fields.'System.BoardColumn' -and 
                    $_.fields.'System.BoardColumn'.newValue -eq $targetColumn
                } | Select-Object -First 1
                
                if ($entryToInProgress) {
                    $startDate = $entryToInProgress.revisedDate
                } else {
                    # Fallback: use CreatedDate
                    $startDate = $item.fields.'System.CreatedDate'
                }
            } else {
                # Fallback: use CreatedDate
                $startDate = $item.fields.'System.CreatedDate'
            }
        }
        default {
            # Default to creation date
            $startDate = $item.fields.'System.CreatedDate'
        }
    }
    
    return (Get-DaysBetween $startDate $closedDate)
}

# Helper: Calculate weekly WIP snapshots from state transitions
function Get-WeeklyWIPSnapshot($completedItems, $activeItems, $startDate, $endDate) {
    # Define active states (items being worked on)
    $activeStates = @('Active', 'In Progress')
    
    # Create weekly buckets
    $weeks = @()
    $currentWeekStart = $startDate
    while ($currentWeekStart -lt $endDate) {
        $weekEnd = $currentWeekStart.AddDays(7)
        $weeks += @{
            start = $currentWeekStart
            end = $weekEnd
            label = $currentWeekStart.ToString('dd MMM')
            bugIds = @()
            featureIds = @()
        }
        $currentWeekStart = $weekEnd
    }
    
    # Process all items (completed + active) to reconstruct historical WIP
    $allItems = @($completedItems) + @($activeItems)
    
    foreach ($item in $allItems) {
        $itemId = $item.id
        $itemType = $item.fields.'System.WorkItemType'
        
        # Build timeline of state periods from updates
        $statePeriods = @()
        $currentState = $null
        $currentStateStart = $null
        
        # Sort updates by date
        $sortedUpdates = $item.updates | Sort-Object { 
            $date = [DateTime]$_.revisedDate
            if ($date.Year -ge 9999) { [DateTime]::MaxValue } else { $date }
        }
        
        foreach ($update in $sortedUpdates) {
            # Skip placeholder dates
            $updateDate = [DateTime]$update.revisedDate
            if ($updateDate.Year -ge 9999) { continue }
            
            # Check for state change
            if ($update.fields.'System.State') {
                $newState = $update.fields.'System.State'.newValue
                
                # Record previous state period
                if ($currentState -and $activeStates -contains $currentState) {
                    $statePeriods += @{
                        start = $currentStateStart
                        end = $updateDate
                        state = $currentState
                    }
                }
                
                # Start new period
                $currentState = $newState
                $currentStateStart = $updateDate
            }
        }
        
        # Add final period - use closed date if completed, or endDate if still active
        $closedDate = $item.fields.'Microsoft.VSTS.Common.ClosedDate'
        if ($currentState -and $activeStates -contains $currentState) {
            $periodEnd = if ($closedDate) { [DateTime]$closedDate } else { $endDate }
            $statePeriods += @{
                start = $currentStateStart
                end = $periodEnd
                state = $currentState
            }
        }
        
        # SPECIAL CASE: For active items without update history, use current state
        # This handles items that were fetched without their state transition history
        if ($statePeriods.Count -eq 0 -and -not $closedDate) {
            $currentItemState = $item.fields.'System.State'
            if ($activeStates -contains $currentItemState) {
                # Assume item has been in this state for at least some recent time
                # Use creation date or start of period as a reasonable start point
                $createdDate = $item.fields.'System.CreatedDate'
                $periodStart = if ($createdDate) { 
                    $created = [DateTime]$createdDate
                    # Use the later of creation date or analysis start date
                    if ($created -gt $startDate) { $created } else { $startDate }
                } else { 
                    $startDate 
                }
                
                $statePeriods += @{
                    start = $periodStart
                    end = $endDate
                    state = $currentItemState
                }
            }
        }
        
        # Check which weeks this item was in active state
        foreach ($week in $weeks) {
            $wasActiveThisWeek = $false
            
            foreach ($period in $statePeriods) {
                # Check if state period overlaps with this week
                $periodStart = $period.start
                $periodEnd = $period.end
                
                if ($periodStart -lt $week.end -and $periodEnd -gt $week.start) {
                    $wasActiveThisWeek = $true
                    break
                }
            }
            
            if ($wasActiveThisWeek) {
                if ($itemType -eq 'Bug') {
                    $week.bugIds += $itemId
                } else {
                    $week.featureIds += $itemId
                }
            }
        }
    }
    
    return $weeks
}

# Helper: Calculate cycle time from state transitions (time in active states)
function Get-CycleTimeFromUpdates($item) {
    $activeStates = @('Active', 'In Progress')
    $totalActiveDays = 0
    
    if (-not $item.updates -or $item.updates.Count -eq 0) {
        return 0
    }
    
    # Track state periods
    $currentState = $null
    $currentStateStart = $null
    
    # Sort updates by date
    $sortedUpdates = $item.updates | Sort-Object { 
        $date = [DateTime]$_.revisedDate
        if ($date.Year -ge 9999) { [DateTime]::MaxValue } else { $date }
    }
    
    foreach ($update in $sortedUpdates) {
        # Skip placeholder dates
        $updateDate = [DateTime]$update.revisedDate
        if ($updateDate.Year -ge 9999) { continue }
        
        # Check for state change
        if ($update.fields.'System.State') {
            $newState = $update.fields.'System.State'.newValue
            
            # If leaving an active state, add the time spent
            if ($currentState -and $activeStates -contains $currentState) {
                $daysInState = ($updateDate - $currentStateStart).TotalDays
                $totalActiveDays += $daysInState
            }
            
            # Start new period
            $currentState = $newState
            $currentStateStart = $updateDate
        }
    }
    
    # Add final period if item closed in active state
    $closedDate = $item.fields.'Microsoft.VSTS.Common.ClosedDate'
    if ($currentState -and $activeStates -contains $currentState -and $closedDate) {
        $daysInState = ([DateTime]$closedDate - $currentStateStart).TotalDays
        $totalActiveDays += $daysInState
    }
    
    return [Math]::Round($totalActiveDays, 1)
}

# Build completed items with metrics calculated from state transitions
$completedWithMetrics = @()
foreach ($item in $rawData.completedItems) {
    # Try to use provided columnTime data if available
    $columnTime = ($ColumnTimeData | Where-Object { $_.WorkItemId -eq $item.id }).ColumnTime
    if (-not $columnTime) { $columnTime = @{} }
    
    # Calculate cycle time from state transitions if columnTime is empty
    $cycleTime = 0
    if ($columnTime.Count -gt 0) {
        # Use columnTime if available
        $activeColumns = @('In Development', 'In Review', 'External Review', 'QA')
        foreach ($col in $activeColumns) {
            if ($columnTime.$col) {
                $cycleTime += $columnTime.$col
            }
        }
    } else {
        # Calculate from state transitions
        $cycleTime = Get-CycleTimeFromUpdates -item $item
    }
    
    $completedWithMetrics += [PSCustomObject]@{
        id = $item.id
        type = $item.fields.'System.WorkItemType'
        title = $item.fields.'System.Title'
        state = $item.fields.'System.State'
        createdDate = $item.fields.'System.CreatedDate'
        completedDate = $item.fields.'Microsoft.VSTS.Common.ClosedDate'
        columnTime = $columnTime
        cycleTime = $cycleTime
        leadTime = (Get-LeadTime -item $item -config $config)
    }
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
    $weekStart.ToString('dd MMM')
} | Sort-Object { 
    # Sort by parsing the date
    [DateTime]::ParseExact($_.Name, 'dd MMM', $null)
}

$throughputChart = @{
    labels = @($completedByWeek | ForEach-Object { $_.Name })
    values = @($completedByWeek | ForEach-Object { $_.Count })
    items = @($completedByWeek | ForEach-Object {
        ,@($_.Group | ForEach-Object { @{id=$_.id; title=$_.title} })
    })
}

# Cycle time trend chart (weekly averages)
$cycleTimeTrendChart = @{
    labels = @($completedByWeek | ForEach-Object { $_.Name })
    values = @($completedByWeek | ForEach-Object { 
        $weekItems = $_.Group
        $weekCycleTimes = $weekItems | ForEach-Object { $_.cycleTime } | Where-Object { $_ -gt 0 }
        if ($weekCycleTimes.Count -gt 0) { 
            [Math]::Round(($weekCycleTimes | Measure-Object -Average).Average, 1) 
        } else { 0 }
    })
}

# Lead time trend chart (weekly averages)
$leadTimeTrendChart = @{
    labels = @($completedByWeek | ForEach-Object { $_.Name })
    values = @($completedByWeek | ForEach-Object { 
        $weekItems = $_.Group
        $weekLeadTimes = $weekItems | ForEach-Object { $_.leadTime } | Where-Object { $_ -gt 0 }
        if ($weekLeadTimes.Count -gt 0) { 
            [Math]::Round(($weekLeadTimes | Measure-Object -Average).Average, 1) 
        } else { 0 }
    })
}

# Calculate coefficient of variation for batch detection
$throughputValues = @($completedByWeek | ForEach-Object { $_.Count })
$throughputMean = ($throughputValues | Measure-Object -Average).Average
$throughputStdDev = [Math]::Sqrt(($throughputValues | ForEach-Object { [Math]::Pow($_ - $throughputMean, 2) } | Measure-Object -Sum).Sum / $throughputValues.Count)
$throughputCV = if ($throughputMean -gt 0) { $throughputStdDev / $throughputMean } else { 0 }

# Calculate weekly WIP snapshots for historical bug rate (FIXED: now includes active items)
$startDate = [DateTime]$rawData.metadata.startDate
$endDate = [DateTime]$rawData.metadata.endDate
$wipSnapshots = Get-WeeklyWIPSnapshot -completedItems $rawData.completedItems -activeItems $rawData.activeItems -startDate $startDate -endDate $endDate

# Build bug rate chart (weekly WIP bug percentage) with full tooltip data
$bugRateLabels = @()
$bugRateWIP = @()
$bugRateWIPBugCount = @()
$bugRateWIPFeatureCount = @()
$bugRateWIPBugs = @()
$bugRateWIPFeatures = @()

foreach ($week in $wipSnapshots) {
    $wipBugsCount = $week.bugIds.Count
    $wipFeaturesCount = $week.featureIds.Count
    $wipTotal = $wipBugsCount + $wipFeaturesCount
    $bugPercentage = if ($wipTotal -gt 0) { [Math]::Round(($wipBugsCount / $wipTotal) * 100, 1) } else { 0 }
    
    # Get bug and feature details for tooltip (search in both completed and active items)
    $wipBugItems = @()
    $wipFeatureItems = @()
    
    foreach ($bugId in $week.bugIds) {
        # First try completed items, then active items
        $bugItem = $rawData.completedItems | Where-Object { $_.id -eq $bugId } | Select-Object -First 1
        if (-not $bugItem) {
            $bugItem = $rawData.activeItems | Where-Object { $_.id -eq $bugId } | Select-Object -First 1
        }
        if ($bugItem) {
            $wipBugItems += @{
                id = $bugItem.id
                title = $bugItem.fields.'System.Title'
            }
        }
    }
    
    foreach ($featureId in $week.featureIds) {
        # First try completed items, then active items
        $featureItem = $rawData.completedItems | Where-Object { $_.id -eq $featureId } | Select-Object -First 1
        if (-not $featureItem) {
            $featureItem = $rawData.activeItems | Where-Object { $_.id -eq $featureId } | Select-Object -First 1
        }
        if ($featureItem) {
            $wipFeatureItems += @{
                id = $featureItem.id
                title = $featureItem.fields.'System.Title'
            }
        }
    }
    
    $bugRateLabels += $week.label
    $bugRateWIP += $bugPercentage
    $bugRateWIPBugCount += $wipBugsCount
    $bugRateWIPFeatureCount += $wipFeaturesCount
    $bugRateWIPBugs += ,@($wipBugItems)
    $bugRateWIPFeatures += ,@($wipFeatureItems)
}

# Calculate current active items for bug rate display
$activeBugs = @($rawData.activeItems | Where-Object { $_.fields.'System.WorkItemType' -eq 'Bug' })
$activeFeatures = @($rawData.activeItems | Where-Object { $_.fields.'System.WorkItemType' -eq 'Product Backlog Item' })
$currentActiveBugRate = if ($rawData.activeItems.Count -gt 0) { 
    [Math]::Round(($activeBugs.Count / $rawData.activeItems.Count) * 100, 1) 
} else { 0 }

# Current bug breakdown by board column (for pie chart)
$bugColumnBreakdown = @{}
foreach ($bug in $activeBugs) {
    $column = $bug.fields.'System.BoardColumn'
    if ([string]::IsNullOrWhiteSpace($column)) {
        $column = $bug.fields.'System.State'
    }
    if ([string]::IsNullOrWhiteSpace($column)) {
        $column = "Unknown"
    }
    
    if (-not $bugColumnBreakdown.ContainsKey($column)) {
        $bugColumnBreakdown[$column] = 0
    }
    $bugColumnBreakdown[$column]++
}

# Current bug breakdown by state (for pie chart)
$bugStateBreakdown = @{}
foreach ($bug in $activeBugs) {
    $state = $bug.fields.'System.State'
    if ([string]::IsNullOrWhiteSpace($state)) {
        $state = "Unknown"
    }
    
    if (-not $bugStateBreakdown.ContainsKey($state)) {
        $bugStateBreakdown[$state] = 0
    }
    $bugStateBreakdown[$state]++
}

# Get board columns order for sorting
$boardColumns = $rawData.boardConfig.columns
if (-not $boardColumns) {
    $boardColumns = @()
}

# Format bug breakdown for output, ordered by board column sequence
$currentBugsByColumn = @()
foreach ($col in $boardColumns) {
    if ($bugColumnBreakdown.ContainsKey($col) -and $bugColumnBreakdown[$col] -gt 0) {
        $currentBugsByColumn += @{
            column = $col
            count = $bugColumnBreakdown[$col]
        }
    }
}
# Add any columns not in board config
foreach ($col in ($bugColumnBreakdown.Keys | Sort-Object)) {
    if ($boardColumns -notcontains $col -and $bugColumnBreakdown[$col] -gt 0) {
        $currentBugsByColumn += @{
            column = $col
            count = $bugColumnBreakdown[$col]
        }
    }
}

# Format bug breakdown by state for output
$currentBugsByState = @()
foreach ($state in ($bugStateBreakdown.Keys | Sort-Object)) {
    if ($bugStateBreakdown[$state] -gt 0) {
        $currentBugsByState += @{
            state = $state
            count = $bugStateBreakdown[$state]
        }
    }
}

# Calculate stale work (items not updated recently)
# Tasks and Epics are already excluded from data fetch
$staleWorkItems = @()
$now = Get-Date
foreach ($item in $rawData.activeItems) {
    $changedDateStr = $item.fields.'System.ChangedDate'
    if ($changedDateStr) {
        $changedDate = [DateTime]$changedDateStr
        $daysSinceChanged = [Math]::Floor(($now - $changedDate).TotalDays)
        
        # Check if item is blocked (has "blocked" tag - case insensitive)
        $tags = $item.fields.'System.Tags'
        $isBlocked = $tags -and ($tags -like '*blocked*')
        
        $staleWorkItems += [PSCustomObject]@{
            id = $item.id
            title = $item.fields.'System.Title'
            workItemType = $item.fields.'System.WorkItemType'
            state = $item.fields.'System.State'
            column = $item.fields.'System.BoardColumn'
            daysSinceChanged = $daysSinceChanged
            isBlocked = $isBlocked
        }
    }
}

# Sort by days since changed (worst first) and take top 20
$staleWorkItems = @($staleWorkItems | Sort-Object -Property daysSinceChanged -Descending | Select-Object -First 20)

# Format for chart display
$staleWorkLabels = @()
$staleWorkValues = @()
$staleWorkIds = @()
$staleWorkTitles = @()
$staleWorkBlocked = @()

foreach ($item in $staleWorkItems) {
    $typeIcon = if ($item.workItemType -eq 'Bug') { '🐛' } else { '📋' }
    $staleWorkLabels += "$typeIcon #$($item.id)"
    $staleWorkValues += $item.daysSinceChanged
    $staleWorkIds += $item.id
    $staleWorkTitles += $item.title
    $staleWorkBlocked += $item.isBlocked
}

# Calculate bug rate statistics for insight (using WIP percentages)
$avgWIPBugRate = if ($bugRateWIP.Count -gt 0) { 
    [Math]::Round(($bugRateWIP | Measure-Object -Average).Average, 1) 
} else { 0 }
$maxBugRateWeek = if ($bugRateWIP.Count -gt 0) {
    $maxIndex = 0
    $maxValue = $bugRateWIP[0]
    for ($i = 1; $i -lt $bugRateWIP.Count; $i++) {
        if ($bugRateWIP[$i] -gt $maxValue) {
            $maxValue = $bugRateWIP[$i]
            $maxIndex = $i
        }
    }
    $bugRateLabels[$maxIndex]
} else { "N/A" }
$maxBugRate = ($bugRateWIP | Measure-Object -Maximum).Maximum

# Calculate COMPLETION bug rate (bugs completed vs total completed per week)
$completionRateLabels = @()
$completionRateBugs = @()
$completionRateBugCount = @()
$completionRateFeatureCount = @()
$completionRateBugDetails = @()
$completionRateFeatureDetails = @()

# Group completed items by week
$completedByWeek = @{}
foreach ($item in $rawData.completedItems) {
    $closedDate = [DateTime]$item.fields.'Microsoft.VSTS.Common.ClosedDate'
    # Find which week this item was completed in
    $weekLabel = $null
    foreach ($week in $wipSnapshots) {
        if ($closedDate -ge $week.start -and $closedDate -lt $week.end) {
            $weekLabel = $week.label
            break
        }
    }
    
    if ($weekLabel) {
        if (-not $completedByWeek.ContainsKey($weekLabel)) {
            $completedByWeek[$weekLabel] = @{
                bugs = @()
                features = @()
            }
        }
        
        $itemType = $item.fields.'System.WorkItemType'
        if ($itemType -eq 'Bug') {
            $completedByWeek[$weekLabel].bugs += @{
                id = $item.id
                title = $item.fields.'System.Title'
            }
        } else {
            $completedByWeek[$weekLabel].features += @{
                id = $item.id
                title = $item.fields.'System.Title'
            }
        }
    }
}

# Build completion rate arrays (aligned with WIP weeks)
foreach ($week in $wipSnapshots) {
    $weekLabel = $week.label
    $completionRateLabels += $weekLabel
    
    if ($completedByWeek.ContainsKey($weekLabel)) {
        $bugsCompleted = $completedByWeek[$weekLabel].bugs.Count
        $featuresCompleted = $completedByWeek[$weekLabel].features.Count
        $totalCompleted = $bugsCompleted + $featuresCompleted
        $bugPercentage = if ($totalCompleted -gt 0) { [Math]::Round(($bugsCompleted / $totalCompleted) * 100, 1) } else { 0 }
        
        $completionRateBugs += $bugPercentage
        $completionRateBugCount += $bugsCompleted
        $completionRateFeatureCount += $featuresCompleted
        $completionRateBugDetails += ,@($completedByWeek[$weekLabel].bugs)
        $completionRateFeatureDetails += ,@($completedByWeek[$weekLabel].features)
    } else {
        # No completions this week
        $completionRateBugs += 0
        $completionRateBugCount += 0
        $completionRateFeatureCount += 0
        $completionRateBugDetails += ,@()
        $completionRateFeatureDetails += ,@()
    }
}

# Calculate completion rate statistics
$avgCompletionBugRate = if ($completionRateBugs.Count -gt 0) {
    [Math]::Round(($completionRateBugs | Measure-Object -Average).Average, 1)
} else { 0 }

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
    
    # Metadata about metric calculations
    metricDefinitions = @{
        leadTimeMethod = if ($config -and $config.metrics.leadTime.startType) { $config.metrics.leadTime.startType } else { 'boardEntry' }
        leadTimeStartColumn = if ($config -and $config.metrics.leadTime.startColumn) { $config.metrics.leadTime.startColumn } else { 'New' }
        leadTimeDescription = if ($config -and $config.metrics.leadTime.startDescription) { 
            $config.metrics.leadTime.startDescription 
        } else { 
            'When item first appears on the board' 
        }
        cycleTimeStartColumn = if ($config -and $config.metrics.cycleTime.startColumn) { 
            $config.metrics.cycleTime.startColumn 
        } elseif ($WorkflowStartColumn) { 
            $WorkflowStartColumn 
        } else { 
            'In Development' 
        }
    }
    
    metrics = @{
        throughput = @{
            bugs = [Math]::Round($bugs.Count / $weeks, 1)
            pbis = [Math]::Round($pbis.Count / $weeks, 1)
            median = $throughputTotal
            min = 0
            max = ($throughputChart.values | Measure-Object -Maximum).Maximum
            trend = Calculate-Trend -values $throughputValues -higherIsBetter $true
        }
        cycleTime = @{
            bugs = if ($bugCycleTimes.Count -gt 0) { [Math]::Round(($bugCycleTimes | Measure-Object -Average).Average, 1) } else { 0 }
            pbis = if ($pbiCycleTimes.Count -gt 0) { [Math]::Round(($pbiCycleTimes | Measure-Object -Average).Average, 1) } else { 0 }
            median = $cycleTimeMedian
            p85 = if ($cycleTimes) { ($cycleTimes | Sort-Object)[([Math]::Ceiling($cycleTimes.Count * 0.85) - 1)] } else { 0 }
            trend = Calculate-Trend -values @($completedByWeek | ForEach-Object { 
                $weekItems = $_.Group
                $weekCycleTimes = $weekItems | ForEach-Object { $_.cycleTime } | Where-Object { $_ -gt 0 }
                if ($weekCycleTimes.Count -gt 0) { ($weekCycleTimes | Measure-Object -Average).Average } else { 0 }
            }) -higherIsBetter $false
        }
        leadTime = @{
            bugs = if ($bugLeadTimes.Count -gt 0) { [Math]::Round(($bugLeadTimes | Measure-Object -Average).Average, 1) } else { 0 }
            pbis = if ($pbiLeadTimes.Count -gt 0) { [Math]::Round(($pbiLeadTimes | Measure-Object -Average).Average, 1) } else { 0 }
            avg = [Math]::Round(($leadTimes | Measure-Object -Average).Average, 1)
            median = $leadTimeMedian
            p85 = if ($leadTimes) { ($leadTimes | Sort-Object)[([Math]::Ceiling($leadTimes.Count * 0.85) - 1)] } else { 0 }
            trend = Calculate-Trend -values @($completedByWeek | ForEach-Object { 
                $weekItems = $_.Group
                $weekLeadTimes = $weekItems | ForEach-Object { $_.leadTime } | Where-Object { $_ -gt 0 }
                if ($weekLeadTimes.Count -gt 0) { ($weekLeadTimes | Measure-Object -Average).Average } else { 0 }
            }) -higherIsBetter $false
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
            labels = $bugRateLabels
            # WIP Bug Rate (% of items in progress that are bugs)
            wipRate = $bugRateWIP
            wipBugCount = $bugRateWIPBugCount
            wipFeatureCount = $bugRateWIPFeatureCount
            wipBugs = $bugRateWIPBugs
            wipFeatures = $bugRateWIPFeatures
            avgWIPBugRate = $avgWIPBugRate
            # Completion Bug Rate (% of items completed that are bugs)
            completionRate = $completionRateBugs
            completionBugCount = $completionRateBugCount
            completionFeatureCount = $completionRateFeatureCount
            completionBugs = $completionRateBugDetails
            completionFeatures = $completionRateFeatureDetails
            avgCompletionBugRate = $avgCompletionBugRate
            # Current active breakdown
            currentActiveBugRate = $currentActiveBugRate
            currentActiveBugs = @($activeBugs | ForEach-Object { @{id=$_.id; title=$_.fields.'System.Title'} })
        }
        currentBugsByColumn = $currentBugsByColumn
        currentBugsByState = $currentBugsByState
        cycleTimeTrend = $cycleTimeTrendChart
        leadTimeTrend = $leadTimeTrendChart
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
            labels = $staleWorkLabels
            values = $staleWorkValues
            ids = $staleWorkIds
            titles = $staleWorkTitles
            blocked = $staleWorkBlocked
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
        throughput = if ($throughputCV -gt 0.5) {
            $maxWeek = ($throughputValues | Measure-Object -Maximum).Maximum
            $minWeek = ($throughputValues | Measure-Object -Minimum).Minimum
            "Throughput averages $throughputTotal items/week but shows high variability (range: $minWeek-$maxWeek). The inconsistent delivery pattern suggests batch working - consider breaking work into smaller, more frequent releases for smoother flow."
        } elseif ($throughputCV -gt 0.3) {
            "Throughput averages $throughputTotal items/week with moderate variability. Some weeks show spikes - monitor for batch release patterns."
        } else {
            "Throughput averages $throughputTotal items/week with consistent, predictable delivery."
        }
        cycleTime = "Median cycle time: $cycleTimeMedian days"
        leadTime = "Median lead time: $leadTimeMedian days"
        workItemAge = "$($rawData.activeItems.Count) items in progress"
        dailyWip = "WIP tracking"
        timeInColumn = "Column metrics"
        wipAgeBreakdown = "Age distribution"
        wip = "$($rawData.activeItems.Count) items in WIP"
        bugRate = if ($maxBugRate -gt 50) {
            "WIP bug rate averaged $avgWIPBugRate% (peak: $maxBugRate% at $maxBugRateWeek). Completion bug rate averaged $avgCompletionBugRate%. Currently $($activeBugs.Count) bugs in WIP ($currentActiveBugRate%). High WIP bug rates may indicate quality issues - consider root cause analysis."
        } elseif ($maxBugRate -gt 30) {
            "WIP bug rate averaged $avgWIPBugRate% (peak: $maxBugRate% at $maxBugRateWeek). Completion rate: $avgCompletionBugRate%. Currently $($activeBugs.Count) bugs in WIP ($currentActiveBugRate%). Monitor trends for quality concerns."
        } else {
            "WIP bug rate averaged $avgWIPBugRate%, with $avgCompletionBugRate% of completed items being bugs. Currently $($activeBugs.Count) bugs in WIP ($currentActiveBugRate%). Healthy balance between bugs and feature work."
        }
        staleWork = if ($staleWorkItems.Count -gt 0) {
            $worstItem = $staleWorkItems[0]
            $daysSinceChangedValues = @($staleWorkItems | ForEach-Object { $_.daysSinceChanged })
            $avgStale = [Math]::Round(($daysSinceChangedValues | Measure-Object -Average).Average, 0)
            $count = $staleWorkItems.Count
            $blockedCount = @($staleWorkItems | Where-Object { $_.isBlocked }).Count
            
            # Analyze patterns in stale work
            $columnGroups = $staleWorkItems | Group-Object -Property column | Sort-Object -Property Count -Descending
            $typeGroups = $staleWorkItems | Group-Object -Property workItemType | Sort-Object -Property Count -Descending
            $stateGroups = $staleWorkItems | Group-Object -Property state | Sort-Object -Property Count -Descending
            
            # Identify dominant patterns
            $columnPattern = if ($columnGroups.Count -gt 0 -and $columnGroups[0].Count -ge ($count * 0.5)) {
                "$($columnGroups[0].Count) are in '$($columnGroups[0].Name)'"
            } elseif ($columnGroups.Count -gt 1 -and ($columnGroups[0].Count + $columnGroups[1].Count) -ge ($count * 0.7)) {
                "$($columnGroups[0].Count) in '$($columnGroups[0].Name)', $($columnGroups[1].Count) in '$($columnGroups[1].Name)'"
            } else {
                "spread across $($columnGroups.Count) columns"
            }
            
            $typePattern = if ($typeGroups.Count -gt 0 -and $typeGroups[0].Count -ge ($count * 0.7)) {
                "$($typeGroups[0].Count) are $($typeGroups[0].Name)s"
            } else {
                "$($typeGroups[0].Count) $($typeGroups[0].Name)s, $($typeGroups[1].Count) $($typeGroups[1].Name)s"
            }
            
            # Build insight with patterns
            $baseMessage = "$count stale items (not updated recently). Worst: #$($worstItem.id) at $($worstItem.daysSinceChanged) days (avg: $avgStale). "
            $patternMessage = "Pattern: $typePattern, $columnPattern. "
            $blockedMessage = if ($blockedCount -gt 0) { "⚠️ $blockedCount tagged as BLOCKED. " } else { "" }
            
            # Action message based on actual state
            $actionMessage = if ($blockedCount -gt 0 -and $worstItem.daysSinceChanged -gt 30) {
                "Review blocked items and items stale >30 days - may be abandoned work."
            } elseif ($blockedCount -gt 0) {
                "Blocked items need attention to unblock or close."
            } elseif ($worstItem.daysSinceChanged -gt 30) {
                "Items stale >30 days may be abandoned - verify if still needed."
            } elseif ($worstItem.daysSinceChanged -gt 14) {
                "Monitor items stale >14 days to ensure progress."
            } else {
                "Reasonable update frequency suggests active work."
            }
            
            $baseMessage + $patternMessage + $blockedMessage + $actionMessage
        } else {
            "No stale work data available - requires System.ChangedDate field from work items."
        }
        netFlow = "Flow analysis"
        state = "State distribution"
        blockedItems = "Blocked items tracking"
        transitionRates = "Transition analysis"
        bugDistribution = if ($activeBugs.Count -gt 0) {
            $totalBugs = $activeBugs.Count
            # Find column with most bugs
            $topColumn = $currentBugsByColumn | Sort-Object -Property count -Descending | Select-Object -First 1
            if ($topColumn) {
                $topColumnPct = [Math]::Round(($topColumn.count / $totalBugs) * 100, 0)
                if ($topColumnPct -gt 50) {
                    "$totalBugs active bugs with $topColumnPct% concentrated in '$($topColumn.column)'. This concentration suggests potential bottlenecks in $($topColumn.column) - consider investigating review capacity, testing resources, or process efficiency."
                } elseif ($topColumnPct -gt 30) {
                    "$totalBugs active bugs distributed across workflow, with $topColumnPct% in '$($topColumn.column)'. Monitor this column for potential capacity constraints."
                } else {
                    "$totalBugs active bugs well-distributed across workflow stages. Fairly balanced bug processing indicates healthy flow through the system."
                }
            } else {
                "$totalBugs active bugs in workflow."
            }
        } else {
            "No active bugs currently in workflow. Excellent quality focus!"
        }
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
