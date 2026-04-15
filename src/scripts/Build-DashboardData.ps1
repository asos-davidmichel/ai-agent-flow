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

# Build throughput chart (grouped by week) - ALWAYS show full analysis timeline
$analysisStart = [DateTime]$rawData.metadata.startDate
$analysisEnd = [DateTime]$rawData.metadata.endDate

function Get-WeekStartSunday([DateTime]$date) {
    $d = $date.Date
    return $d.AddDays(-[int]$d.DayOfWeek)
}

$firstWeekStart = Get-WeekStartSunday $analysisStart
$lastWeekStart = Get-WeekStartSunday $analysisEnd

$weekStarts = @()
for ($d = $firstWeekStart; $d -le $lastWeekStart; $d = $d.AddDays(7)) {
    $weekStarts += $d
}

$completedByWeekMap = @{}
foreach ($item in $completedWithMetrics) {
    if (-not $item.completedDate) { continue }
    $weekStart = Get-WeekStartSunday ([DateTime]$item.completedDate)
    $key = $weekStart.ToString('yyyy-MM-dd')
    if (-not $completedByWeekMap.ContainsKey($key)) {
        $completedByWeekMap[$key] = @()
    }
    $completedByWeekMap[$key] += $item
}

$throughputLabels = @($weekStarts | ForEach-Object { $_.ToString('dd MMM') })
$throughputValues = @()
$throughputItems = @()

foreach ($ws in $weekStarts) {
    $key = $ws.ToString('yyyy-MM-dd')
    $weekItems = if ($completedByWeekMap.ContainsKey($key)) { @($completedByWeekMap[$key]) } else { @() }

    $throughputValues += $weekItems.Count
    $throughputItems += ,@($weekItems | ForEach-Object { @{ id = $_.id; title = $_.title } })
}

$throughputChart = @{
    labels = $throughputLabels
    values = $throughputValues
    items = $throughputItems
}

# Cycle time trend chart (weekly averages) - full analysis timeline
$cycleTimeTrendValues = @()
foreach ($ws in $weekStarts) {
    $key = $ws.ToString('yyyy-MM-dd')
    $weekItems = if ($completedByWeekMap.ContainsKey($key)) { @($completedByWeekMap[$key]) } else { @() }
    $weekCycleTimes = @($weekItems | ForEach-Object { $_.cycleTime } | Where-Object { $_ -gt 0 })

    $cycleTimeTrendValues += if ($weekCycleTimes.Count -gt 0) {
        [Math]::Round(($weekCycleTimes | Measure-Object -Average).Average, 1)
    } else {
        0
    }
}

$cycleTimeTrendChart = @{
    labels = $throughputLabels
    values = $cycleTimeTrendValues
}

# Lead time trend chart (weekly averages) - full analysis timeline
$leadTimeTrendValues = @()
foreach ($ws in $weekStarts) {
    $key = $ws.ToString('yyyy-MM-dd')
    $weekItems = if ($completedByWeekMap.ContainsKey($key)) { @($completedByWeekMap[$key]) } else { @() }
    $weekLeadTimes = @($weekItems | ForEach-Object { $_.leadTime } | Where-Object { $_ -gt 0 })

    $leadTimeTrendValues += if ($weekLeadTimes.Count -gt 0) {
        [Math]::Round(($weekLeadTimes | Measure-Object -Average).Average, 1)
    } else {
        0
    }
}

$leadTimeTrendChart = @{
    labels = $throughputLabels
    values = $leadTimeTrendValues
}

# Calculate coefficient of variation for batch detection
$throughputMean = if ($throughputValues.Count -gt 0) { ($throughputValues | Measure-Object -Average).Average } else { 0 }
$throughputStdDev = if ($throughputValues.Count -gt 0) {
    [Math]::Sqrt((($throughputValues | ForEach-Object { [Math]::Pow($_ - $throughputMean, 2) } | Measure-Object -Sum).Sum) / $throughputValues.Count)
} else { 0 }
$throughputCV = if ($throughputMean -gt 0) { $throughputStdDev / $throughputMean } else { 0 }

# Calculate weekly WIP snapshots for historical bug rate (FIXED: now includes active items)
$wipSnapshots = Get-WeeklyWIPSnapshot -completedItems $rawData.completedItems -activeItems $rawData.activeItems -startDate $analysisStart -endDate $analysisEnd

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

# Configure blocker detection (used for both blocked items and stale work)
$blockerConfig = $config.blockers
$blockerTags = if ($blockerConfig -and $blockerConfig.tags) {
    $blockerConfig.tags
} else {
    @('blocked')  # Fallback to default
}

$blockerCategories = if ($blockerConfig -and $blockerConfig.categories) {
    $blockerConfig.categories
} else {
    @{
        blocked = @{
            tags = @('blocked')
            color = '#ef4444'
            label = 'Blocked'
        }
    }
}

# Function to determine blocker category for an item
function Get-BlockerCategory {
    param($tags, $categories)
    
    if (-not $tags) { return $null }
    
    # Handle both hashtables and PSCustomObject (from JSON)
    $categoryKeys = if ($categories.Keys) {
        $categories.Keys
    } else {
        $categories.PSObject.Properties.Name
    }
    
    foreach ($categoryKey in $categoryKeys) {
        $category = if ($categories.$categoryKey) {
            $categories.$categoryKey
        } else {
            $categories[$categoryKey]
        }
        
        foreach ($tagPattern in $category.tags) {
            if ($tags -like "*$tagPattern*") {
                return @{
                    key = $categoryKey
                    label = $category.label
                    color = $category.color
                }
            }
        }
    }
    
    return $null
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
        
        # Check if item has blocker category
        $tags = $item.fields.'System.Tags'
        $blockerCategory = Get-BlockerCategory -tags $tags -categories $blockerCategories
        
        $staleWorkItems += [PSCustomObject]@{
            id = $item.id
            title = $item.fields.'System.Title'
            workItemType = $item.fields.'System.WorkItemType'
            state = $item.fields.'System.State'
            column = $item.fields.'System.BoardColumn'
            daysSinceChanged = $daysSinceChanged
            isBlocked = $null -ne $blockerCategory
            blockerCategory = if ($blockerCategory) { $blockerCategory.key } else { $null }
            blockerLabel = if ($blockerCategory) { $blockerCategory.label } else { $null }
            blockerColor = if ($blockerCategory) { $blockerCategory.color } else { $null }
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
$staleWorkBlockerCategories = @()
$staleWorkBlockerLabels = @()
$staleWorkBlockerColors = @()

foreach ($item in $staleWorkItems) {
    $typeIcon = if ($item.workItemType -eq 'Bug') { '🐛' } else { '📋' }
    $staleWorkLabels += "$typeIcon #$($item.id)"
    $staleWorkValues += $item.daysSinceChanged
    $staleWorkIds += $item.id
    $staleWorkTitles += $item.title
    $staleWorkBlocked += $item.isBlocked
    $staleWorkBlockerCategories += $item.blockerCategory
    $staleWorkBlockerLabels += $item.blockerLabel
    $staleWorkBlockerColors += $item.blockerColor
}

# Calculate blocked items using configured blocker indicators
# Read blocker configuration from board config (with fallback to legacy behavior)
$blockerConfig = $config.blockers
$blockerTags = if ($blockerConfig -and $blockerConfig.tags) {
    $blockerConfig.tags
} else {
    @('blocked')  # Fallback to default
}

$blockerCategories = if ($blockerConfig -and $blockerConfig.categories) {
    $blockerConfig.categories
} else {
    @{
        blocked = @{
            tags = @('blocked')
            color = '#ef4444'
            label = 'Blocked'
        }
    }
}

# Function to determine blocker category for an item
function Get-BlockerCategory {
    param($tags, $categories)
    
    if (-not $tags) { return $null }
    
    # Handle both hashtables and PSCustomObject (from JSON)
    $categoryKeys = if ($categories.Keys) {
        $categories.Keys
    } else {
        $categories.PSObject.Properties.Name
    }
    
    foreach ($categoryKey in $categoryKeys) {
        $category = if ($categories.$categoryKey) {
            $categories.$categoryKey
        } else {
            $categories[$categoryKey]
        }
        
        foreach ($tagPattern in $category.tags) {
            if ($tags -like "*$tagPattern*") {
                return @{
                    key = $categoryKey
                    label = $category.label
                    color = $category.color
                }
            }
        }
    }
    
    return $null
}

# Identify blocked items
$blockedItems = @()
foreach ($item in $rawData.activeItems) {
    $tags = $item.fields.'System.Tags'
    $category = Get-BlockerCategory -tags $tags -categories $blockerCategories
    
    if ($category) {
        $blockedItems += [PSCustomObject]@{
            item = $item
            category = $category
        }
    }
}

# Get actual blocker tag addition dates from revision history
Write-Host "  Querying blocker tag history for $($blockedItems.Count) blocked items..." -ForegroundColor Gray
$blockerDates = @{}
if ($blockedItems.Count -gt 0) {
    $blockedIds = @($blockedItems | ForEach-Object { $_.item.id })
    $allBlockerTags = @()
    $categoryKeys = if ($blockerCategories.Keys) { $blockerCategories.Keys } else { $blockerCategories.PSObject.Properties.Name }
    foreach ($categoryKey in $categoryKeys) {
        $category = if ($blockerCategories.$categoryKey) { $blockerCategories.$categoryKey } else { $blockerCategories[$categoryKey] }
        $allBlockerTags += $category.tags
    }
    
    try {
        $blockerDatesJson = & (Join-Path $PSScriptRoot "Get-BlockerTagAddedDate.ps1") `
            -Organization $rawData.metadata.organization `
            -Project $rawData.metadata.project `
            -WorkItemIds $blockedIds `
            -BlockerTags $allBlockerTags
        
        $blockerDatesData = $blockerDatesJson | ConvertFrom-Json
        foreach ($item in $blockerDatesData) {
            $blockerDates[$item.id] = @{
                blockerAddedDate = $item.blockerAddedDate
                daysBlocked = $item.daysBlocked
            }
        }
        Write-Host "  [OK] Retrieved blocker history for $($blockedIds.Count) items" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to get blocker tag dates: $_. Using days since changed as fallback."
    }
}

# Initialize blocked by column with ALL columns (even if count is 0)
$boardColumns = $rawData.boardConfig.columns
$blockedByColumn = [ordered]@{}
foreach ($col in $boardColumns) {
    $blockedByColumn[$col] = 0
}

# Initialize blocked by category
$blockedByCategory = @{}
$categoryKeys = if ($blockerCategories.Keys) { $blockerCategories.Keys } else { $blockerCategories.PSObject.Properties.Name }
foreach ($categoryKey in $categoryKeys) {
    $blockedByCategory[$categoryKey] = 0
}

# Group blocked items
$blockedByType = @{}
$blockedByState = @{}
$blockedItemDetails = @()

foreach ($blockedEntry in $blockedItems) {
    $item = $blockedEntry.item
    $category = $blockedEntry.category
    
    $column = $item.fields.'System.BoardColumn'
    $workItemType = $item.fields.'System.WorkItemType'
    $state = $item.fields.'System.State'
    $changedDate = $item.fields.'System.ChangedDate'
    
    # Count by category
    $blockedByCategory[$category.key]++
    
    # Count by column (increment existing)
    if ($blockedByColumn.Contains($column)) {
        $blockedByColumn[$column]++
    } else {
        # Column not in board config - add it
        $blockedByColumn[$column] = 1
    }
    
    # Count by type
    if (-not $blockedByType.ContainsKey($workItemType)) {
        $blockedByType[$workItemType] = 0
    }
    $blockedByType[$workItemType]++
    
    # Count by state  
    if (-not $blockedByState.ContainsKey($state)) {
        $blockedByState[$state] = 0
    }
    $blockedByState[$state]++
    
    # Calculate days blocked (from tag history) or days since changed as fallback
    $blockerAddedDate = $null
    $daysBlocked = 0

    if ($blockerDates.ContainsKey($item.id) -and $null -ne $blockerDates[$item.id]) {
        $blockerAddedDate = $blockerDates[$item.id].blockerAddedDate
        $daysBlocked = $blockerDates[$item.id].daysBlocked
    } elseif ($changedDate) {
        $daysBlocked = [Math]::Floor(((Get-Date) - [DateTime]$changedDate).TotalDays)
    }
    
    $blockedItemDetails += [PSCustomObject]@{
        id = $item.id
        title = $item.fields.'System.Title'
        workItemType = $workItemType
        state = $state
        column = $column
        daysSinceChanged = $daysBlocked
        blockerAddedDate = $blockerAddedDate
        category = $category.key
        categoryLabel = $category.label
        categoryColor = $category.color
    }
}

$blockedItemDetailsAll = @($blockedItemDetails)

# Sort blocked items by how long they've been stale
$blockedItemDetails = @($blockedItemDetails | Sort-Object -Property daysSinceChanged -Descending | Select-Object -First 20)

# Build blocked timeline (when items became blocked)
$blockedTimelineLabels = @()
$blockedTimelineSeries = [ordered]@{}

$categoryKeys = if ($blockerCategories.Keys) { $blockerCategories.Keys } else { $blockerCategories.PSObject.Properties.Name }
foreach ($categoryKey in $categoryKeys) {
    $blockedTimelineSeries[$categoryKey] = @()
}

function Get-WeekStartMonday([DateTime]$date) {
    $d = $date.Date
    $daysSinceMonday = (([int]$d.DayOfWeek + 6) % 7)
    return $d.AddDays(-$daysSinceMonday).Date
}

# Always show the full analysis timeline for time-based charts
$timelineFirstWeekStart = Get-WeekStartMonday $analysisStart
$timelineLastWeekStart = Get-WeekStartMonday $analysisEnd
$timelineWeekStarts = @()
for ($d = $timelineFirstWeekStart; $d -le $timelineLastWeekStart; $d = $d.AddDays(7)) {
    $timelineWeekStarts += $d
}

$timelineWeekKeys = @($timelineWeekStarts | ForEach-Object { $_.ToString('yyyy-MM-dd') })
$blockedTimelineLabels = @($timelineWeekStarts | ForEach-Object { $_.ToString('dd MMM') })

# Initialise buckets for every week in the analysis period (ensures full x-axis)
$weeklyBuckets = @{}
foreach ($wk in $timelineWeekKeys) {
    $weeklyBuckets[$wk] = @{}
    foreach ($categoryKey in $categoryKeys) {
        $weeklyBuckets[$wk][$categoryKey] = 0
    }
}

if ($blockedItemDetailsAll.Count -gt 0) {
    $now = Get-Date

    foreach ($detail in $blockedItemDetailsAll) {
        # Determine when the blocker tag was added
        $blockedStart = $null
        if ($detail.blockerAddedDate) {
            $blockedStart = [DateTime]$detail.blockerAddedDate
        } else {
            $daysBlocked = [int]$detail.daysSinceChanged
            $blockedStart = ($now).AddDays(-$daysBlocked).Date
        }

        # Only count events within the analysis period
        if ($blockedStart -ge $analysisStart -and $blockedStart -le $analysisEnd) {
            $weekStart = Get-WeekStartMonday $blockedStart
            $weekKey = $weekStart.ToString('yyyy-MM-dd')
            if ($weeklyBuckets.ContainsKey($weekKey) -and $weeklyBuckets[$weekKey].ContainsKey($detail.category)) {
                $weeklyBuckets[$weekKey][$detail.category]++
            }
        }

    }
}

foreach ($categoryKey in $categoryKeys) {
    $blockedTimelineSeries[$categoryKey] = @($timelineWeekKeys | ForEach-Object { [int]$weeklyBuckets[$_][$categoryKey] })
}

# Build blocking/unblocking rates (weekly) with category breakdown - full analysis timeline
$blockedRateSeries = [ordered]@{}
$unblockedRateSeries = [ordered]@{}
foreach ($categoryKey in $categoryKeys) {
    $blockedRateSeries[$categoryKey] = @(0) * $timelineWeekKeys.Count
    $unblockedRateSeries[$categoryKey] = @(0) * $timelineWeekKeys.Count
}

$weekKeyToIndex = @{}
for ($i = 0; $i -lt $timelineWeekKeys.Count; $i++) {
    $weekKeyToIndex[$timelineWeekKeys[$i]] = $i
}

function Get-BlockerEventsFromUpdates {
    param(
        $WorkItem,
        $Categories
    )

    $events = @()
    if (-not $WorkItem -or -not $WorkItem.updates) { return $events }

    $previousTags = $null

    $sortedUpdates = $WorkItem.updates | Sort-Object { 
        $date = [DateTime]$_.revisedDate
        if ($date.Year -ge 9999) { [DateTime]::MaxValue } else { $date }
    }

    foreach ($update in $sortedUpdates) {
        $updateDate = [DateTime]$update.revisedDate
        if ($updateDate.Year -ge 9999) { continue }

        $tagsField = $update.fields.'System.Tags'
        if (-not $tagsField) { continue }

        $oldTags = if ($null -ne $tagsField.oldValue) {
            [string]$tagsField.oldValue
        } elseif ($null -ne $previousTags) {
            [string]$previousTags
        } else {
            ''
        }

        $newTags = if ($null -ne $tagsField.newValue) {
            [string]$tagsField.newValue
        } else {
            ''
        }

        $oldCategory = Get-BlockerCategory -tags $oldTags -categories $Categories
        $newCategory = Get-BlockerCategory -tags $newTags -categories $Categories

        $hadBlockerBefore = $null -ne $oldCategory
        $hasBlockerNow = $null -ne $newCategory

        if ($hasBlockerNow -and -not $hadBlockerBefore) {
            $events += [PSCustomObject]@{ type = 'blocked'; categoryKey = $newCategory.key; date = $updateDate }
        } elseif (-not $hasBlockerNow -and $hadBlockerBefore) {
            $events += [PSCustomObject]@{ type = 'unblocked'; categoryKey = $oldCategory.key; date = $updateDate }
        }

        $previousTags = $newTags
    }

    return $events
}

$blockerEvents = @()

# Completed items: derive block/unblock events from update history
foreach ($wi in $rawData.completedItems) {
    $blockerEvents += Get-BlockerEventsFromUpdates -WorkItem $wi -Categories $blockerCategories
}

# Active currently blocked items: include their blocker-added date (unblock date is unknown unless completed)
foreach ($blockedEntry in $blockedItems) {
    $id = $blockedEntry.item.id
    if ($blockerDates.ContainsKey($id) -and $blockerDates[$id].blockerAddedDate) {
        $addedDate = [DateTime]$blockerDates[$id].blockerAddedDate
        $blockerEvents += [PSCustomObject]@{ type = 'blocked'; categoryKey = $blockedEntry.category.key; date = $addedDate }
    }
}

foreach ($ev in $blockerEvents) {
    if (-not $ev.date) { continue }
    $dt = [DateTime]$ev.date
    if ($dt -lt $analysisStart -or $dt -gt $analysisEnd) { continue }

    $weekStart = Get-WeekStartMonday $dt
    $weekKey = $weekStart.ToString('yyyy-MM-dd')
    if (-not $weekKeyToIndex.ContainsKey($weekKey)) { continue }

    $idx = [int]$weekKeyToIndex[$weekKey]
    $cat = $ev.categoryKey

    if ($ev.type -eq 'blocked') {
        if ($blockedRateSeries.Contains($cat)) {
            $blockedRateSeries[$cat][$idx] = [int]$blockedRateSeries[$cat][$idx] + 1
        }
    } elseif ($ev.type -eq 'unblocked') {
        if ($unblockedRateSeries.Contains($cat)) {
            $unblockedRateSeries[$cat][$idx] = [int]$unblockedRateSeries[$cat][$idx] + 1
        }
    }
}

$blockedRateTotals = @()
$unblockedRateTotals = @()
for ($i = 0; $i -lt $timelineWeekKeys.Count; $i++) {
    $blockedRateTotals += ($categoryKeys | ForEach-Object { [int]$blockedRateSeries[$_][$i] } | Measure-Object -Sum).Sum
    $unblockedRateTotals += ($categoryKeys | ForEach-Object { [int]$unblockedRateSeries[$_][$i] } | Measure-Object -Sum).Sum
}

# Net flow of blockers (blocked - unblocked) per week
$blockedNetValues = @()
$blockedNetCumulative = @()
$runningNet = 0
for ($i = 0; $i -lt $timelineWeekKeys.Count; $i++) {
    $net = [int]$blockedRateTotals[$i] - [int]$unblockedRateTotals[$i]
    $blockedNetValues += $net
    $runningNet += $net
    $blockedNetCumulative += $runningNet
}

# Build daily WIP and daily WIP x age breakdown across the full analysis timeline
function Get-LinearRegressionLine {
    param(
        [Parameter(Mandatory = $true)]
        [double[]]$Values
    )

    $n = $Values.Count
    if ($n -lt 2) { return @($Values) }

    $sumX = 0.0
    $sumY = 0.0
    $sumXY = 0.0
    $sumX2 = 0.0

    for ($i = 0; $i -lt $n; $i++) {
        $x = [double]$i
        $y = [double]$Values[$i]
        $sumX += $x
        $sumY += $y
        $sumXY += ($x * $y)
        $sumX2 += ($x * $x)
    }

    $den = ($n * $sumX2 - $sumX * $sumX)
    $slope = if ($den -ne 0) { ($n * $sumXY - $sumX * $sumY) / $den } else { 0.0 }
    $intercept = ($sumY / $n) - $slope * ($sumX / $n)

    $line = @()
    for ($i = 0; $i -lt $n; $i++) {
        $line += [Math]::Round(($slope * $i + $intercept), 3)
    }
    return $line
}

$analysisStartDate = $analysisStart.Date
$analysisEndDate = $analysisEnd.Date
$dayStarts = @()
for ($d = $analysisStartDate; $d -le $analysisEndDate; $d = $d.AddDays(1)) {
    $dayStarts += $d
}

$dailyWipLabels = @($dayStarts | ForEach-Object { $_.ToString('dd MMM') })
$dayCount = $dayStarts.Count

$wipDiff = New-Object int[] ($dayCount + 1)
$wipAge0to1 = New-Object int[] $dayCount
$wipAge1to7 = New-Object int[] $dayCount
$wipAge7to14 = New-Object int[] $dayCount
$wipAge14Plus = New-Object int[] $dayCount

$wipActiveStates = @('Active', 'In Progress')

function Add-WipPeriod {
    param(
        [Parameter(Mandatory = $true)]
        [DateTime]$Start,

        [Parameter(Mandatory = $true)]
        [DateTime]$End
    )

    $s = $Start.Date
    $e = $End.Date

    if ($e -lt $analysisStartDate -or $s -gt $analysisEndDate) { return }

    if ($s -lt $analysisStartDate) { $s = $analysisStartDate }
    if ($e -gt $analysisEndDate) { $e = $analysisEndDate }

    $sIdx = [int](($s - $analysisStartDate).TotalDays)
    $eIdx = [int](($e - $analysisStartDate).TotalDays)

    if ($sIdx -lt 0 -or $sIdx -ge $dayCount) { return }
    if ($eIdx -lt 0) { return }
    if ($eIdx -ge $dayCount) { $eIdx = $dayCount - 1 }

    $wipDiff[$sIdx]++
    if (($eIdx + 1) -lt $wipDiff.Length) {
        $wipDiff[$eIdx + 1]--
    }

    for ($i = $sIdx; $i -le $eIdx; $i++) {
        $currentDay = $analysisStartDate.AddDays($i)
        $ageDays = [int](($currentDay - $s).TotalDays)

        if ($ageDays -le 1) {
            $wipAge0to1[$i]++
        } elseif ($ageDays -le 7) {
            $wipAge1to7[$i]++
        } elseif ($ageDays -le 14) {
            $wipAge7to14[$i]++
        } else {
            $wipAge14Plus[$i]++
        }
    }
}

# Completed items contribute WIP between ActivatedDate and ClosedDate
foreach ($wi in $rawData.completedItems) {
    $fields = $wi.fields
    $activated = $fields.'Microsoft.VSTS.Common.ActivatedDate'
    $closed = $fields.'Microsoft.VSTS.Common.ClosedDate'

    if ($activated -and $closed) {
        Add-WipPeriod -Start ([DateTime]$activated) -End ([DateTime]$closed)
    }
}

# Current active items contribute WIP only if currently in an active state
foreach ($wi in $rawData.activeItems) {
    $fields = $wi.fields
    $state = $fields.'System.State'
    if ($wipActiveStates -notcontains $state) { continue }

    $activated = $fields.'Microsoft.VSTS.Common.ActivatedDate'
    $created = $fields.'System.CreatedDate'

    $start = if ($activated) { [DateTime]$activated } elseif ($created) { [DateTime]$created } else { $analysisStartDate }
    Add-WipPeriod -Start $start -End $analysisEndDate
}

$dailyWipValues = @()
$running = 0
for ($i = 0; $i -lt $dayCount; $i++) {
    $running += $wipDiff[$i]
    $dailyWipValues += [int]$running
}

$dailyWipTrend = Get-LinearRegressionLine -Values ([double[]]$dailyWipValues)

# Insights: Daily WIP
$dailyWipAvg = if ($dailyWipValues.Count -gt 0) { [Math]::Round((($dailyWipValues | Measure-Object -Average).Average), 1) } else { 0 }
$dailyWipMin = if ($dailyWipValues.Count -gt 0) { ($dailyWipValues | Measure-Object -Minimum).Minimum } else { 0 }
$dailyWipMax = if ($dailyWipValues.Count -gt 0) { ($dailyWipValues | Measure-Object -Maximum).Maximum } else { 0 }
$dailyWipStartValue = if ($dailyWipValues.Count -gt 0) { $dailyWipValues[0] } else { 0 }
$dailyWipEndValue = if ($dailyWipValues.Count -gt 0) { $dailyWipValues[-1] } else { 0 }
$dailyWipTrendObj = Calculate-Trend -values @($dailyWipValues) -higherIsBetter $false
$dailyWipTrendText = if ($dailyWipTrendObj.direction -eq 'up') { 'increasing' } elseif ($dailyWipTrendObj.direction -eq 'down') { 'decreasing' } else { 'stable' }
$dailyWipInsightText = "Daily WIP averaged $dailyWipAvg items/day (range: $dailyWipMin-$dailyWipMax). Trend is $dailyWipTrendText; latest day is $dailyWipEndValue (start was $dailyWipStartValue)."

# Insights: WIP age breakdown
$wipAgeInsightText = 'No WIP age breakdown available.'
if ($dayCount -gt 0) {
    $lastIdx = $dayCount - 1
    $last0to1 = [int]$wipAge0to1[$lastIdx]
    $last1to7 = [int]$wipAge1to7[$lastIdx]
    $last7to14 = [int]$wipAge7to14[$lastIdx]
    $last14Plus = [int]$wipAge14Plus[$lastIdx]
    $lastTotal = $last0to1 + $last1to7 + $last7to14 + $last14Plus
    $lastPct14Plus = if ($lastTotal -gt 0) { [Math]::Round(($last14Plus / $lastTotal) * 100, 0) } else { 0 }

    $peak14Plus = [int](($wipAge14Plus | Measure-Object -Maximum).Maximum)

    $peak14PlusIdx = -1
    for ($i = 0; $i -lt $wipAge14Plus.Count; $i++) {
        if ([int]$wipAge14Plus[$i] -eq $peak14Plus) {
            $peak14PlusIdx = $i
            break
        }
    }

    $peak14PlusLabel = if ($peak14PlusIdx -ge 0 -and $peak14PlusIdx -lt $dailyWipLabels.Count) { $dailyWipLabels[$peak14PlusIdx] } else { 'N/A' }

    $age14TrendObj = Calculate-Trend -values @($wipAge14Plus) -higherIsBetter $false
    $age14TrendText = if ($age14TrendObj.direction -eq 'up') { 'increasing' } elseif ($age14TrendObj.direction -eq 'down') { 'decreasing' } else { 'stable' }

    $wipAgeInsightText = "Latest day WIP was $lastTotal, with $last14Plus ($lastPct14Plus%) aged >14 days. Peak >14-day WIP was $peak14Plus on $peak14PlusLabel. The >14-day segment is $age14TrendText."
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

# Precompute insights for blocker charts (so they can be AI-overridden via JSON)
$blockedTimelineTotals = @()
for ($i = 0; $i -lt $timelineWeekKeys.Count; $i++) {
    $blockedTimelineTotals += ($categoryKeys | ForEach-Object { [int]$blockedTimelineSeries[$_][$i] } | Measure-Object -Sum).Sum
}

$totalBlockedStarts = ($blockedTimelineTotals | Measure-Object -Sum).Sum
$peakBlockedStarts = if ($blockedTimelineTotals.Count -gt 0) { ($blockedTimelineTotals | Measure-Object -Maximum).Maximum } else { 0 }
$peakBlockedIndex = if ($blockedTimelineTotals.Count -gt 0) { $blockedTimelineTotals.IndexOf($peakBlockedStarts) } else { -1 }
$peakBlockedWeek = if ($peakBlockedIndex -ge 0) { $blockedTimelineLabels[$peakBlockedIndex] } else { 'N/A' }

$blockedTimelineInsightText = "$totalBlockedStarts items became blocked/on-hold during the analysis period. Peak week: $peakBlockedWeek ($peakBlockedStarts)."

$totalBlockedEvents = ($blockedRateTotals | Measure-Object -Sum).Sum
$totalUnblockedEvents = ($unblockedRateTotals | Measure-Object -Sum).Sum
$weeksInAnalysis = [Math]::Max(1, $timelineWeekKeys.Count)
$avgBlockedPerWeek = [Math]::Round(($totalBlockedEvents / $weeksInAnalysis), 2)
$avgUnblockedPerWeek = [Math]::Round(($totalUnblockedEvents / $weeksInAnalysis), 2)
$netBlocked = $totalBlockedEvents - $totalUnblockedEvents
$netText = if ($netBlocked -gt 0) { "Net +$netBlocked blocked (more blocking than unblocking)." } elseif ($netBlocked -lt 0) { "Net $netBlocked blocked (more unblocking than blocking)." } else { "Net 0 (balanced)." }

$blockerRatesInsightText = "Blocked events: $totalBlockedEvents, unblocked events: $totalUnblockedEvents across $weeksInAnalysis week$($(if ($weeksInAnalysis -ne 1) { 's' } else { '' })). Average per week: $avgBlockedPerWeek blocked, $avgUnblockedPerWeek unblocked. $netText Note: The dashed line shows the trend of weekly net flow (blocked - unblocked), not the cumulative blocked count."

# Current blocked metric (card)
$backlogSize = $rawData.activeItems.Count
$blockedCount = $blockedItems.Count
$blockedPercentage = if ($backlogSize -gt 0) { [Math]::Round(($blockedCount / $backlogSize) * 100, 1) } else { 0 }
$blockedClass = if ($blockedPercentage -gt 10) {
    'trend-warning'
} elseif ($blockedPercentage -gt 5) {
    'trend-neutral'
} else {
    'trend-good'
}

# Trend for blocked count: infer direction from net blocked vs unblocked events in the analysis period
# (Net +ve means blockers accumulated; net -ve means blockers drained)
$blockedTrend = if ($netBlocked -gt 0) {
    @{ direction = 'up'; isGood = $false }
} elseif ($netBlocked -lt 0) {
    @{ direction = 'down'; isGood = $true }
} else {
    @{ direction = 'stable'; isGood = $true }
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
            trend = Calculate-Trend -values @($cycleTimeTrendChart.values) -higherIsBetter $false
        }
        leadTime = @{
            bugs = if ($bugLeadTimes.Count -gt 0) { [Math]::Round(($bugLeadTimes | Measure-Object -Average).Average, 1) } else { 0 }
            pbis = if ($pbiLeadTimes.Count -gt 0) { [Math]::Round(($pbiLeadTimes | Measure-Object -Average).Average, 1) } else { 0 }
            avg = [Math]::Round(($leadTimes | Measure-Object -Average).Average, 1)
            median = $leadTimeMedian
            p85 = if ($leadTimes) { ($leadTimes | Sort-Object)[([Math]::Ceiling($leadTimes.Count * 0.85) - 1)] } else { 0 }
            trend = Calculate-Trend -values @($leadTimeTrendChart.values) -higherIsBetter $false
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
            # Current WIP = in-progress items (matches Daily WIP chart end-of-period)
            count = $dailyWipEndValue
            avgAge = "$dailyWipAvg"
            minAge = $dailyWipMin
            maxAge = $dailyWipMax
            class = if ($dailyWipTrendObj.direction -eq 'up') { 'trend-warning' } elseif ($dailyWipTrendObj.direction -eq 'down') { 'trend-good' } else { 'trend-neutral' }
            trend = @{ 
                direction = $dailyWipTrendObj.direction
                isGood = $dailyWipTrendObj.isGood
                previousValue = $dailyWipStartValue
            }
        }
        blocked = @{
            count = $blockedCount
            percentage = "$blockedPercentage"
            class = $blockedClass
            trend = $blockedTrend
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
            labels = $dailyWipLabels
            values = $dailyWipValues
            trend = $dailyWipTrend
        }
        staleWork = @{
            labels = $staleWorkLabels
            values = $staleWorkValues
            ids = $staleWorkIds
            titles = $staleWorkTitles
            blocked = $staleWorkBlocked
            blockerCategories = $staleWorkBlockerCategories
            blockerLabels = $staleWorkBlockerLabels
            blockerColors = $staleWorkBlockerColors
        }
        wipAgeBreakdown = @{
            labels = $dailyWipLabels
            age14Plus = @($wipAge14Plus)
            age7to14 = @($wipAge7to14)
            age1to7 = @($wipAge1to7)
            age0to1 = @($wipAge0to1)
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
            current = @{
                count = $blockedItems.Count
                byColumn = $blockedByColumn
                byType = $blockedByType
                byState = $blockedByState
                byCategory = $blockedByCategory
                categories = $blockerCategories
                details = $blockedItemDetails
            }
        }
        blockedTimeline = @{
            labels = $blockedTimelineLabels
            series = $blockedTimelineSeries
            categories = $blockerCategories
        }
        blockerRates = @{
            labels = $blockedTimelineLabels
            weekKeys = $timelineWeekKeys
            blockedSeries = $blockedRateSeries
            unblockedSeries = $unblockedRateSeries
            blockedTotals = $blockedRateTotals
            unblockedTotals = $unblockedRateTotals
            netValues = $blockedNetValues
            categories = $blockerCategories
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
        dailyWip = $dailyWipInsightText
        timeInColumn = "Column metrics"
        wipAgeBreakdown = $wipAgeInsightText
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
            $blockedMessage = if ($blockedCount -gt 0) { "⚠️ $blockedCount tagged as BLOCKED. " } else { "No items currently blocked or on hold. " }
            
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
        blockedItems = if ($blockedItems.Count -gt 0) {
            $count = $blockedItems.Count
            
            # Category breakdown
            $categoryBreakdown = @()
            $categoryKeys = if ($blockedByCategory.Keys) { $blockedByCategory.Keys } else { $blockedByCategory.PSObject.Properties.Name }
            foreach ($categoryKey in $categoryKeys) {
                $catCount = $blockedByCategory[$categoryKey]
                if ($catCount -gt 0) {
                    # Handle both hashtables and PSCustomObject
                    $catLabel = if ($blockerCategories.$categoryKey) {
                        $blockerCategories.$categoryKey.label
                    } else {
                        $blockerCategories[$categoryKey].label
                    }
                    $categoryBreakdown += "$catCount $catLabel"
                }
            }
            $categoryMessage = if ($categoryBreakdown.Count -gt 0) {
                "(" + ($categoryBreakdown -join ", ") + "). "
            } else {
                ". "
            }
            
            # Find patterns in blocked items
            $topColumn = $blockedByColumn.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1
            $topType = $blockedByType.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1
            
            # Calculate average blocked duration
            $blockedDurations = @($blockedItemDetails | ForEach-Object { $_.daysSinceChanged })
            $avgBlockedDuration = if ($blockedDurations.Count -gt 0) {
                [Math]::Round(($blockedDurations | Measure-Object -Average).Average, 0)
            } else { 0 }
            $longestBlocked = ($blockedItemDetails | Select-Object -First 1)
            
            # Build insight message
            $baseMessage = "$count items currently blocked " + $categoryMessage
            
            $columnMessage = if ($topColumn -and $topColumn.Value -ge ($count * 0.5)) {
                "$($topColumn.Value) are in '$($topColumn.Key)' column. "
            } elseif ($topColumn) {
                "Distributed across columns, with $($topColumn.Value) in '$($topColumn.Key)'. "
            } else {
                ""
            }
            
            $typeMessage = if ($topType -and $topType.Value -ge ($count * 0.7)) {
                "$($topType.Value) are $($topType.Key)s. "
            } elseif ($topType) {
                "Mix of types: $($topType.Value) $($topType.Key)s. "
            } else {
                ""
            }
            
            $durationMessage = if ($longestBlocked) {
                "Longest blocked: #$($longestBlocked.id) at $($longestBlocked.daysSinceChanged) days (avg: $avgBlockedDuration days). "
            } else {
                ""
            }
            
            $actionMessage = if ($avgBlockedDuration -gt 14) {
                "Average blocked duration over 2 weeks suggests systemic blockers - review dependencies and impediments."
            } elseif ($count -gt 10) {
                "High number of blocked items may indicate process or dependency issues."
            } else {
                "Review blocked items to identify and remove impediments."
            }
            
            $baseMessage + $columnMessage + $typeMessage + $durationMessage + $actionMessage
        } else {
            "No items currently blocked. Blocked items are identified by configured blocker tags."
        }
        blockedTimeline = $blockedTimelineInsightText
        blockerRates = $blockerRatesInsightText
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
