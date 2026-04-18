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
    [string]$ConfigFile = $null,

    [Parameter(Mandatory = $false)]
    [ValidateSet('creation','boardEntry','column')]
    [string]$LeadTimeStartType,

    [Parameter(Mandatory = $false)]
    [string]$LeadTimeStartColumn
)

Write-Host "Building dashboard data structure..." -ForegroundColor Yellow

# Load raw data
$rawData = Get-Content $FlowDataPath -Raw | ConvertFrom-Json

# Load configuration if provided
$config = $null
$configFileLeaf = $null
if ($ConfigFile -and (Test-Path $ConfigFile)) {
    $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $configFileLeaf = Split-Path $ConfigFile -Leaf
    Write-Host "  Using configuration: $ConfigFile" -ForegroundColor Gray
}

# Limit analysis to tracked work item types (PBI/Story/Bug level)
$trackedWorkItemTypes = if ($config -and $config.workItemTypes -and $config.workItemTypes.tracked) {
    @($config.workItemTypes.tracked)
} else {
    @('Product Backlog Item', 'User Story', 'Story', 'Bug')
}

function Test-IsTrackedWorkItemType {
    param([string]$WorkItemType)

    if ([string]::IsNullOrWhiteSpace($WorkItemType)) { return $false }
    return ($trackedWorkItemTypes -contains $WorkItemType)
}

$activeItems = @($rawData.activeItems | Where-Object { Test-IsTrackedWorkItemType $_.fields.'System.WorkItemType' })
$completedItems = @($rawData.completedItems | Where-Object { Test-IsTrackedWorkItemType $_.fields.'System.WorkItemType' })

# Analysis scope (for the dashboard "Configuration" tab)
$allTypesInRaw = @()
$allTypesInRaw += @($rawData.activeItems | ForEach-Object { $_.fields.'System.WorkItemType' })
$allTypesInRaw += @($rawData.completedItems | ForEach-Object { $_.fields.'System.WorkItemType' })
$allTypesInRaw = @(
    $allTypesInRaw |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
)

$ignoredObservedWorkItemTypes = @(
    $allTypesInRaw |
        Where-Object { $trackedWorkItemTypes -notcontains $_ } |
        Sort-Object -Unique
)

$excludedConfiguredWorkItemTypes = if ($config -and $config.workItemTypes -and $config.workItemTypes.excluded) {
    @($config.workItemTypes.excluded)
} else {
    @()
}
$excludedConfiguredWorkItemTypes = @(
    $excludedConfiguredWorkItemTypes |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
)

# Helper: Calculate days between dates
function Get-DaysBetween($date1, $date2) {
    if (-not $date1 -or -not $date2) { return 0 }
    return [Math]::Round((([DateTime]$date2) - ([DateTime]$date1)).TotalDays, 1)
}

function Get-EffectiveLeadTimeConfig {
    param(
        $Config,
        [string]$StartTypeOverride,
        [string]$StartColumnOverride
    )

    $cfgStartType = if ($Config -and $Config.metrics -and $Config.metrics.leadTime -and $Config.metrics.leadTime.startType) {
        [string]$Config.metrics.leadTime.startType
    } else {
        'boardEntry'
    }

    # Backwards compat: older configs used backlogExit for "specific column"
    if ($cfgStartType -eq 'backlogExit') { $cfgStartType = 'column' }

    $startType = if (-not [string]::IsNullOrWhiteSpace($StartTypeOverride)) {
        $StartTypeOverride
    } else {
        $cfgStartType
    }

    $cfgStartColumn = if ($Config -and $Config.metrics -and $Config.metrics.leadTime) {
        if ($Config.metrics.leadTime.startColumn) { [string]$Config.metrics.leadTime.startColumn }
        elseif ($Config.metrics.leadTime.column) { [string]$Config.metrics.leadTime.column }
        else { $null }
    } else {
        $null
    }

    $startColumn = if (-not [string]::IsNullOrWhiteSpace($StartColumnOverride)) {
        $StartColumnOverride
    } else {
        $cfgStartColumn
    }

    if ($startType -eq 'column' -and [string]::IsNullOrWhiteSpace($startColumn)) {
        $startColumn = 'In Development'
    }

    return @{ startType = $startType; startColumn = $startColumn }
}

function Get-ItemStartDateStrict {
    param(
        $Item,
        [string]$StartType,
        [string]$StartColumn
    )

    switch ($StartType) {
        'creation' {
            $raw = $Item.fields.'System.CreatedDate'
            if (-not $raw) { return $null }
            try { return [DateTime]$raw } catch { return $null }
        }
        'boardEntry' {
            if (-not $Item.updates -or $Item.updates.Count -eq 0) { return $null }

            $first = $Item.updates |
                Where-Object { $_.fields.'System.BoardColumn' -and $_.fields.'System.BoardColumn'.newValue } |
                Sort-Object {
                    $d = [DateTime]$_.revisedDate
                    if ($d.Year -ge 9999) { [DateTime]::MaxValue } else { $d }
                } |
                Select-Object -First 1

            if (-not $first) { return $null }
            try { return [DateTime]$first.revisedDate } catch { return $null }
        }
        'column' {
            if (-not $Item.updates -or $Item.updates.Count -eq 0) { return $null }
            if ([string]::IsNullOrWhiteSpace($StartColumn)) { return $null }

            $first = $Item.updates |
                Where-Object {
                    $_.fields.'System.BoardColumn' -and
                    $_.fields.'System.BoardColumn'.newValue -eq $StartColumn
                } |
                Sort-Object {
                    $d = [DateTime]$_.revisedDate
                    if ($d.Year -ge 9999) { [DateTime]::MaxValue } else { $d }
                } |
                Select-Object -First 1

            if (-not $first) { return $null }
            try { return [DateTime]$first.revisedDate } catch { return $null }
        }
        default {
            return $null
        }
    }
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

    $effective = Get-EffectiveLeadTimeConfig -Config $config -StartTypeOverride $LeadTimeStartType -StartColumnOverride $LeadTimeStartColumn
    $startType = [string]$effective.startType
    $startColumn = [string]$effective.startColumn

    $startDateObj = Get-ItemStartDateStrict -Item $item -StartType $startType -StartColumn $startColumn

    # Backwards-compatible fallback for lead time only
    if (-not $startDateObj) {
        $createdRaw = $item.fields.'System.CreatedDate'
        if ($createdRaw) {
            try { $startDateObj = [DateTime]$createdRaw } catch { $startDateObj = $null }
        }
    }

    if (-not $startDateObj) { return 0 }
    return (Get-DaysBetween $startDateObj $closedDate)
}

# Helper: Calculate weekly WIP snapshots from state transitions
function Get-WeeklyWIPSnapshot($completedItems, $activeItems, $startDate, $endDate) {
    # Define active states (items being worked on)
    $activeStates = @('Active', 'In Progress')
    
    # Helper function to get week start (Monday) - matches main chart logic
    function Get-WeekStartMonday([DateTime]$date) {
        $d = $date.Date
        $daysSinceMonday = (([int]$d.DayOfWeek + 6) % 7)
        return $d.AddDays(-$daysSinceMonday).Date
    }
    
    # Round start and end dates to Monday to align with other charts
    $firstWeekStart = Get-WeekStartMonday $startDate
    $lastWeekStart = Get-WeekStartMonday $endDate
    
    # Create weekly buckets starting from Monday
    $weeks = @()
    $currentWeekStart = $firstWeekStart
    while ($currentWeekStart -le $lastWeekStart) {
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
foreach ($item in $completedItems) {
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

# Helper function to get week start (Monday)
function Get-WeekStartMonday([DateTime]$date) {
    $d = $date.Date
    $daysSinceMonday = (([int]$d.DayOfWeek + 6) % 7)
    return $d.AddDays(-$daysSinceMonday).Date
}

$firstWeekStart = Get-WeekStartMonday $analysisStart
$lastWeekStart = Get-WeekStartMonday $analysisEnd

$weekStarts = @()
for ($d = $firstWeekStart; $d -le $lastWeekStart; $d = $d.AddDays(7)) {
    $weekStarts += $d
}

$completedByWeekMap = @{}
foreach ($item in $completedWithMetrics) {
    if (-not $item.completedDate) { continue }
    $weekStart = Get-WeekStartMonday ([DateTime]$item.completedDate)
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

    # Build items list for this week first
    $weekItemsList = @($weekItems | ForEach-Object { @{ id = $_.id; title = $_.title } })
    
    # Count based on the built list to ensure consistency
    $count = $weekItemsList.Count
    $throughputValues += $count
    $throughputItems += ,@($weekItemsList)
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

# Calculate weekly WIP snapshots for historical bug rate (tracked types only)
$wipSnapshots = Get-WeeklyWIPSnapshot -completedItems $completedItems -activeItems $activeItems -startDate $analysisStart -endDate $analysisEnd

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
        $bugItem = $completedItems | Where-Object { $_.id -eq $bugId } | Select-Object -First 1
        if (-not $bugItem) {
            $bugItem = $activeItems | Where-Object { $_.id -eq $bugId } | Select-Object -First 1
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
        $featureItem = $completedItems | Where-Object { $_.id -eq $featureId } | Select-Object -First 1
        if (-not $featureItem) {
            $featureItem = $activeItems | Where-Object { $_.id -eq $featureId } | Select-Object -First 1
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
$activeBugs = @($activeItems | Where-Object { $_.fields.'System.WorkItemType' -eq 'Bug' })
$activeFeatures = @($activeItems | Where-Object { $_.fields.'System.WorkItemType' -eq 'Product Backlog Item' })
$currentActiveBugRate = if ($activeItems.Count -gt 0) { 
    [Math]::Round(($activeBugs.Count / $activeItems.Count) * 100, 1) 
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
$staleWorkItems = @()
$now = Get-Date
foreach ($item in $activeItems) {
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
    $typeLabel = if ($item.workItemType -eq 'Bug') { 'Bug' } elseif ($item.workItemType -eq 'Product Backlog Item') { 'PBI' } else { $item.workItemType }
    $staleWorkLabels += "$typeLabel #$($item.id)"
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
foreach ($item in $activeItems) {
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

# Always show the full analysis timeline for time-based charts
# (Get-WeekStartMonday function defined earlier in the file)
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
            # All weeks and categories are pre-initialized, so we can directly increment
            if ($weeklyBuckets.ContainsKey($weekKey)) {
                if ($null -ne $weeklyBuckets[$weekKey][$detail.category]) {
                    $weeklyBuckets[$weekKey][$detail.category]++
                }
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
foreach ($wi in $completedItems) {
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

# Align daily charts to start on Monday for consistency with weekly charts
$analysisStartDate = (Get-WeekStartMonday $analysisStart).Date
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
foreach ($wi in $completedItems) {
    $fields = $wi.fields
    $activated = $fields.'Microsoft.VSTS.Common.ActivatedDate'
    $closed = $fields.'Microsoft.VSTS.Common.ClosedDate'

    if ($activated -and $closed) {
        Add-WipPeriod -Start ([DateTime]$activated) -End ([DateTime]$closed)
    }
}

# Current active items contribute WIP only if currently in an active state
foreach ($wi in $activeItems) {
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

# Peak and biggest single-day change (anomaly signals)
$dailyWipPeakIdx = -1
for ($i = 0; $i -lt $dailyWipValues.Count; $i++) {
    if ([int]$dailyWipValues[$i] -eq [int]$dailyWipMax) { $dailyWipPeakIdx = $i; break }
}
$dailyWipPeakLabel = if ($dailyWipPeakIdx -ge 0 -and $dailyWipPeakIdx -lt $dailyWipLabels.Count) { $dailyWipLabels[$dailyWipPeakIdx] } else { 'N/A' }

$maxDelta = 0
$maxDeltaIdx = -1
for ($i = 1; $i -lt $dailyWipValues.Count; $i++) {
    $delta = [int]$dailyWipValues[$i] - [int]$dailyWipValues[$i - 1]
    if ([Math]::Abs($delta) -gt [Math]::Abs($maxDelta)) {
        $maxDelta = $delta
        $maxDeltaIdx = $i
    }
}
$maxDeltaLabel = if ($maxDeltaIdx -ge 0 -and $maxDeltaIdx -lt $dailyWipLabels.Count) { $dailyWipLabels[$maxDeltaIdx] } else { 'N/A' }
$maxDeltaText = if ($maxDeltaIdx -ge 0) { "$(if ($maxDelta -ge 0) { '+' } else { '' })$maxDelta on $maxDeltaLabel" } else { 'N/A' }

$dailyWipStdDev = if ($dailyWipValues.Count -gt 0) {
    $mean = [double]$dailyWipAvg
    [Math]::Sqrt((($dailyWipValues | ForEach-Object { [Math]::Pow(([double]$_ - $mean), 2) } | Measure-Object -Sum).Sum) / $dailyWipValues.Count)
} else { 0 }
$dailyWipCV = if ($dailyWipAvg -gt 0) { [Math]::Round(($dailyWipStdDev / [double]$dailyWipAvg), 2) } else { 0 }
$dailyWipVolatility = if ($dailyWipCV -gt 0.5) { 'high' } elseif ($dailyWipCV -gt 0.25) { 'moderate' } else { 'low' }

$spikeThreshold = [Math]::Round(($dailyWipAvg + $dailyWipStdDev), 1)
$spikeDays = if ($dailyWipValues.Count -gt 0) { @($dailyWipValues | Where-Object { $_ -gt $spikeThreshold }).Count } else { 0 }

$dailyWipInsightText = "Avg $dailyWipAvg (range $dailyWipMin-$dailyWipMax; volatility $dailyWipVolatility; $spikeDays spike day$(if ($spikeDays -ne 1) { 's' } else { '' }) >$spikeThreshold). Peak $dailyWipMax on $dailyWipPeakLabel; biggest 1-day change $maxDeltaText. Trend is $dailyWipTrendText (start $dailyWipStartValue -> end $dailyWipEndValue)."

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

    # Longest consecutive streak where there is at least one >14-day item
    $longestStreak = 0
    $currentStreak = 0
    $currentStart = 0
    $bestStart = -1
    $bestEnd = -1

    for ($i = 0; $i -lt $wipAge14Plus.Count; $i++) {
        if ([int]$wipAge14Plus[$i] -gt 0) {
            if ($currentStreak -eq 0) { $currentStart = $i }
            $currentStreak++
            if ($currentStreak -gt $longestStreak) {
                $longestStreak = $currentStreak
                $bestStart = $currentStart
                $bestEnd = $i
            }
        } else {
            $currentStreak = 0
        }
    }

    $streakText = if ($longestStreak -gt 0 -and $bestStart -ge 0 -and $bestEnd -ge 0) {
        $startLabel = if ($bestStart -lt $dailyWipLabels.Count) { $dailyWipLabels[$bestStart] } else { 'N/A' }
        $endLabel = if ($bestEnd -lt $dailyWipLabels.Count) { $dailyWipLabels[$bestEnd] } else { 'N/A' }
        "Longest stretch with >=1 item aged >14d: $longestStreak days ($startLabel -> $endLabel)."
    } else {
        'No days with items aged >14d.'
    }

    $tailText = if ($lastPct14Plus -ge 50) {
        'Old work dominates WIP.'
    } elseif ($lastPct14Plus -ge 25) {
        'A material tail of old work is present.'
    } else {
        'Old-work tail is small.'
    }

    $wipAgeInsightText = "Latest day WIP $lastTotal with $last14Plus ($lastPct14Plus%) aged >14d. Peak >14d was $peak14Plus on $peak14PlusLabel; the >14d segment is $age14TrendText. $streakText $tailText"
}

# Build Aging WIP (current) and Work Item Age (current)
$wipAgingItems = @()
foreach ($wi in $activeItems) {
    $fields = $wi.fields
    $state = $fields.'System.State'
    if ($wipActiveStates -notcontains $state) { continue }

    $activated = $fields.'Microsoft.VSTS.Common.ActivatedDate'
    $created = $fields.'System.CreatedDate'

    $start = if ($activated) { [DateTime]$activated } elseif ($created) { [DateTime]$created } else { $analysisStartDate }
    $ageDays = [int][Math]::Floor(($analysisEndDate - $start.Date).TotalDays)
    if ($ageDays -lt 0) { $ageDays = 0 }

    $column = $fields.'System.BoardColumn'
    if ([string]::IsNullOrWhiteSpace($column)) { $column = $state }
    if ([string]::IsNullOrWhiteSpace($column)) { $column = 'Unknown' }

    $wipAgingItems += [PSCustomObject]@{
        id = $wi.id
        title = $fields.'System.Title'
        workItemType = $fields.'System.WorkItemType'
        column = $column
        age = $ageDays
    }
}

$wipAgingItemsSorted = @($wipAgingItems | Sort-Object -Property age -Descending | Select-Object -First 20)

$wipAgingLabels = @()
$wipAgingValues = @()
$wipAgingIds = @()
$wipAgingTitles = @()
$wipAgingColors = @()

foreach ($item in $wipAgingItemsSorted) {
    $typeLabel = if ($item.workItemType -eq 'Bug') { 'Bug' } elseif ($item.workItemType -eq 'Product Backlog Item') { 'PBI' } else { $item.workItemType }
    $wipAgingLabels += "$typeLabel #$($item.id)"
    $wipAgingValues += [int]$item.age
    $wipAgingIds += $item.id
    $wipAgingTitles += $item.title

    $wipAgingColors += if ($item.age -gt 14) {
        '#ef4444'
    } elseif ($item.age -gt 7) {
        '#f59e0b'
    } else {
        '#22c55e'
    }
}

$wipAgingChart = @{
    labels = $wipAgingLabels
    values = $wipAgingValues
    ids = $wipAgingIds
    titles = $wipAgingTitles
    colors = $wipAgingColors
}

$wipInsightText = if ($wipAgingItems.Count -eq 0) {
    'No items currently in an active WIP state.'
} else {
    $total = $wipAgingItems.Count

    $over14Items = @($wipAgingItems | Where-Object { $_.age -gt 14 })
    $over14 = $over14Items.Count
    $over30 = @($wipAgingItems | Where-Object { $_.age -gt 30 }).Count

    $oldest = @($wipAgingItems | Sort-Object -Property age -Descending | Select-Object -First 1)

    $columnText = ''
    if ($over14 -gt 0) {
        $byColumn = @($over14Items | Group-Object -Property column | Sort-Object -Property Count -Descending)
        if ($byColumn.Count -gt 0) {
            $top = $byColumn[0]
            $pct = [Math]::Round(($top.Count / $over14) * 100, 0)
            if ($pct -ge 60) {
                $columnText = "Most >14d items are in '$($top.Name)' ($($top.Count) of $over14, $pct%). "
            } else {
                $columnText = "Old items are spread across columns (largest: '$($top.Name)' at $pct%). "
            }
        }
    }

    if ($oldest) {
        "$total active WIP items; $over14 aged >14 days ($over30 aged >30 days). $columnText Oldest is #$($oldest.id) at $($oldest.age) days."
    } else {
        "$total active WIP items; $over14 aged >14 days ($over30 aged >30 days). $columnText"
    }
}

# Work Item Age: only show in-progress board columns (active work), in board order
$workItemAgeAllowedColumns = @()

if ($config -and $config.columns -and $config.columns.inProgress) {
    $workItemAgeAllowedColumns = @(
        @($config.columns.inProgress) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
} elseif ($rawData.boardConfig -and $rawData.boardConfig.columns) {
    # Fallback: use board order, excluding first+last columns
    $workflowColumnsAll = @(
        @($rawData.boardConfig.columns) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $workItemAgeAllowedColumns = if ($workflowColumnsAll.Count -ge 3) {
        @($workflowColumnsAll[1..($workflowColumnsAll.Count - 2)])
    } else {
        @()
    }
}

$workItemAgeItems = @()
foreach ($wi in $activeItems) {
    $fields = $wi.fields
    $activated = $fields.'Microsoft.VSTS.Common.ActivatedDate'
    if (-not $activated) { continue }

    $ageDays = [int][Math]::Floor(($analysisEndDate - ([DateTime]$activated).Date).TotalDays)
    if ($ageDays -lt 0) { $ageDays = 0 }

    $column = $fields.'System.BoardColumn'
    if ([string]::IsNullOrWhiteSpace($column)) { continue }
    if ($workItemAgeAllowedColumns -notcontains $column) { continue }

    $workItemAgeItems += [PSCustomObject]@{
        id = $wi.id
        title = $fields.'System.Title'
        column = $column
        age = $ageDays
    }
}

# Build chart series in board column order, including empty columns
$workItemAgeStates = @()
foreach ($col in $workItemAgeAllowedColumns) {
    $columnItems = @()
    $itemsInCol = @($workItemAgeItems | Where-Object { $_.column -eq $col } | Sort-Object -Property age -Descending)

    foreach ($it in $itemsInCol) {
        $columnItems += @{ id = $it.id; title = $it.title; age = [int]$it.age }
    }

    $workItemAgeStates += @{
        name = $col
        items = $columnItems
    }
}

$workItemAgeAges = @($workItemAgeItems | ForEach-Object { [int]$_.age })
$workItemAgeAvg = if ($workItemAgeAges.Count -gt 0) { [Math]::Round((($workItemAgeAges | Measure-Object -Average).Average), 1) } else { 0 }
$workItemAgeMedian = if ($workItemAgeAges.Count -gt 0) { Get-Median $workItemAgeAges } else { 0 }
$workItemAgeP85 = if ($workItemAgeAges.Count -gt 0) {
    $sorted = @($workItemAgeAges | Sort-Object)
    $idx = [Math]::Ceiling($sorted.Count * 0.85) - 1
    if ($idx -lt 0) { $idx = 0 }
    $sorted[$idx]
} else { 0 }

$workItemAgeChart = @{
    labels = @($workItemAgeAllowedColumns)
    states = $workItemAgeStates
    average = $workItemAgeAvg
    median = $workItemAgeMedian
    p85 = $workItemAgeP85
}

$workItemAgeInsightText = if ($workItemAgeItems.Count -eq 0) {
    'No started (activated) work items found in the current backlog.'
} else {
    $count = $workItemAgeItems.Count

    $columnGroups = @($workItemAgeItems | Group-Object -Property column)
    $columnStats = @()
    foreach ($g in $columnGroups) {
        $ages = @($g.Group | ForEach-Object { [int]$_.age })
        $columnStats += [PSCustomObject]@{
            column = $g.Name
            count = $g.Count
            avg = if ($ages.Count -gt 0) { [Math]::Round((($ages | Measure-Object -Average).Average), 1) } else { 0 }
            median = if ($ages.Count -gt 0) { Get-Median $ages } else { 0 }
            over14 = @($ages | Where-Object { $_ -gt 14 }).Count
        }
    }

    $worstColumn = $columnStats | Sort-Object -Property median -Descending | Select-Object -First 1
    $oldest = $workItemAgeItems | Sort-Object -Property age -Descending | Select-Object -First 1

    $hotspotText = if ($worstColumn) {
        $over14Text = if ($worstColumn.over14 -gt 0) { "$($worstColumn.over14) >14d" } else { 'no >14d items' }
        "Hotspot: '$($worstColumn.column)' has the oldest started work (median $($worstColumn.median)d across $($worstColumn.count) items; $over14Text)."
    } else {
        'No clear aging hotspot by column.'
    }

    $oldestText = if ($oldest) {
        "Oldest is #$($oldest.id) at $($oldest.age)d in '$($oldest.column)'."
    } else {
        ''
    }

    "$count started items: avg $workItemAgeAvg days (median $workItemAgeMedian, 85th $workItemAgeP85). $hotspotText $oldestText"
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
foreach ($item in $completedItems) {
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

# Build cycle time chart datasets (one dataset per tracked work item type)
function Get-TypeDatasetLabel {
    param([Parameter(Mandatory = $true)][string]$WorkItemType)

    switch ($WorkItemType) {
        'Product Backlog Item' { return 'PBIs' }
        'Bug' { return 'Bugs' }
        'Spike' { return 'Spikes' }
        'User Story' { return 'User Stories' }
        'Story' { return 'Stories' }
        default { return $WorkItemType }
    }
}

$typePriority = @('Product Backlog Item', 'User Story', 'Story', 'Bug', 'Spike')
$completedTypeGroups = @($completedWithMetrics | Group-Object -Property type)
$completedTypeGroupsOrdered = @(
    $completedTypeGroups | Sort-Object -Property @(
        @{ Expression = {
            $idx = $typePriority.IndexOf($_.Name)
            if ($idx -ge 0) { $idx } else { 999 }
        } },
        @{ Expression = { $_.Name } }
    )
)

$cycleTimeDatasets = @()
$cycleTimeByTypeStats = [ordered]@{}
$throughputByType = [ordered]@{}
$cycleTimeAvgByType = [ordered]@{}
$leadTimeAvgByType = [ordered]@{}

foreach ($g in $completedTypeGroupsOrdered) {
    $workItemType = [string]$g.Name
    if ([string]::IsNullOrWhiteSpace($workItemType)) { continue }

    $label = Get-TypeDatasetLabel -WorkItemType $workItemType
    $items = @($g.Group | Sort-Object completedDate)

    if ($items.Count -gt 0) {
        $cycleTimeDatasets += @{
            label = $label
            workItemType = $workItemType
            data = @($items | ForEach-Object {
                # Use Monday of the week for x-axis to align with other charts
                $completedDate = [DateTime]$_.completedDate
                $weekStart = Get-WeekStartMonday $completedDate
                @{
                    x = $weekStart.ToString('dd MMM')
                    y = $_.cycleTime
                    leadTime = $_.leadTime
                    id = $_.id
                    title = $_.title
                    completedDate = $completedDate.ToString('dd MMM yyyy')
                    columnTime = $_.columnTime
                }
            })
        }
    }

    $typeCycleTimes = @($items | ForEach-Object { $_.cycleTime } | Where-Object { $_ -gt 0 })
    $typeLeadTimes = @($items | ForEach-Object { $_.leadTime } | Where-Object { $_ -gt 0 })

    $typeCycleMedian = Get-Median $typeCycleTimes
    $typeLeadMedian = Get-Median $typeLeadTimes

    $typeCycleAvg = if ($typeCycleTimes.Count -gt 0) { [Math]::Round(($typeCycleTimes | Measure-Object -Average).Average, 1) } else { 0 }
    $typeLeadAvg = if ($typeLeadTimes.Count -gt 0) { [Math]::Round(($typeLeadTimes | Measure-Object -Average).Average, 1) } else { 0 }

    $typeCycleP85 = if ($typeCycleTimes) { ($typeCycleTimes | Sort-Object)[([Math]::Ceiling($typeCycleTimes.Count * 0.85) - 1)] } else { 0 }
    $typeLeadP85 = if ($typeLeadTimes) { ($typeLeadTimes | Sort-Object)[([Math]::Ceiling($typeLeadTimes.Count * 0.85) - 1)] } else { 0 }

    $cycleTimeByTypeStats[$label] = @{
        average = $typeCycleAvg
        median = $typeCycleMedian
        percentile85 = $typeCycleP85
        leadTimeAverage = $typeLeadAvg
        leadTimeMedian = $typeLeadMedian
        leadTimePercentile85 = $typeLeadP85
    }

    $throughputByType[$label] = [Math]::Round(($items.Count / $weeks), 1)
    $cycleTimeAvgByType[$label] = $typeCycleAvg
    $leadTimeAvgByType[$label] = $typeLeadAvg
}

# Calculate overall statistics
$cycleTimes = $completedWithMetrics | ForEach-Object { $_.cycleTime } | Where-Object { $_ -gt 0 }
$leadTimes = $completedWithMetrics | ForEach-Object { $_.leadTime } | Where-Object { $_ -gt 0 }

$cycleTimeMedian = Get-Median $cycleTimes
$leadTimeMedian = Get-Median $leadTimes

# Backwards-compat per-type arrays (used by a few existing metrics)
$bugCycleTimes = $bugs | ForEach-Object { $_.cycleTime } | Where-Object { $_ -gt 0 }
$pbiCycleTimes = $pbis | ForEach-Object { $_.cycleTime } | Where-Object { $_ -gt 0 }

$bugLeadTimes = $bugs | ForEach-Object { $_.leadTime } | Where-Object { $_ -gt 0 }
$pbiLeadTimes = $pbis | ForEach-Object { $_.leadTime } | Where-Object { $_ -gt 0 }

# Net Flow chart (weekly started vs finished) - full analysis timeline
$startedByWeekMap = @{}
foreach ($item in @($activeItems + $completedItems)) {
    $createdDateRaw = $item.fields.'System.CreatedDate'
    if (-not $createdDateRaw) { continue }

    $weekStart = Get-WeekStartMonday ([DateTime]$createdDateRaw)
    if ($weekStart -lt $firstWeekStart -or $weekStart -gt $lastWeekStart) { continue }

    $key = $weekStart.ToString('yyyy-MM-dd')
    if (-not $startedByWeekMap.ContainsKey($key)) {
        $startedByWeekMap[$key] = 0
    }
    $startedByWeekMap[$key] += 1
}

$netFlowStarted = @()
$netFlowFinished = @()
$netFlowValues = @()

foreach ($ws in $weekStarts) {
    $key = $ws.ToString('yyyy-MM-dd')

    $startedCount = if ($startedByWeekMap.ContainsKey($key)) { [int]$startedByWeekMap[$key] } else { 0 }
    $finishedCount = if ($completedByWeekMap.ContainsKey($key)) { @($completedByWeekMap[$key]).Count } else { 0 }

    $netFlowStarted += $startedCount
    $netFlowFinished += $finishedCount
    $netFlowValues += ($finishedCount - $startedCount)
}

$netFlowChart = @{
    labels = $throughputLabels
    values = $netFlowValues
    started = $netFlowStarted
    finished = $netFlowFinished
}

$netTotalStarted = ($netFlowStarted | Measure-Object -Sum).Sum
$netTotalFinished = ($netFlowFinished | Measure-Object -Sum).Sum
$netDelta = ($netFlowValues | Measure-Object -Sum).Sum

$netWorstValue = if ($netFlowValues.Count -gt 0) { [int](($netFlowValues | Measure-Object -Minimum).Minimum) } else { 0 }
$netBestValue = if ($netFlowValues.Count -gt 0) { [int](($netFlowValues | Measure-Object -Maximum).Maximum) } else { 0 }
$worstIdx = if ($netFlowValues.Count -gt 0) { $netFlowValues.IndexOf($netWorstValue) } else { -1 }
$bestIdx = if ($netFlowValues.Count -gt 0) { $netFlowValues.IndexOf($netBestValue) } else { -1 }

$worstWeekLabel = if ($worstIdx -ge 0) { $throughputLabels[$worstIdx] } else { 'N/A' }
$bestWeekLabel = if ($bestIdx -ge 0) { $throughputLabels[$bestIdx] } else { 'N/A' }

$netFlowInsightText = "Across $($weekStarts.Count) weeks: started $netTotalStarted, finished $netTotalFinished. Net flow (finished - started): $netDelta. Best week: $bestWeekLabel ($netBestValue). Worst week: $worstWeekLabel ($netWorstValue)."

# Time in column chart (completed items only)
$columnTotals = @{}
$columnCounts = @{}
foreach ($item in $completedWithMetrics) {
    if (-not $item.columnTime -or $item.columnTime.Count -eq 0) { continue }

    foreach ($prop in $item.columnTime.PSObject.Properties) {
        $col = $prop.Name
        $days = [double]$prop.Value
        if ($days -le 0) { continue }

        if (-not $columnTotals.ContainsKey($col)) {
            $columnTotals[$col] = 0.0
            $columnCounts[$col] = 0
        }

        $columnTotals[$col] += $days
        $columnCounts[$col] += 1
    }
}

# Only include board columns (not states), and exclude the first + last column in the workflow
$workflowColumnsAll = @()
if ($config -and $config.columns) {
    $workflowColumnsAll += @($config.columns.backlog)
    $workflowColumnsAll += @($config.columns.inProgress)
    $workflowColumnsAll += @($config.columns.done)
} elseif ($rawData.boardConfig -and $rawData.boardConfig.columns) {
    $workflowColumnsAll += @($rawData.boardConfig.columns)
}

$workflowColumnsAll = @(
    $workflowColumnsAll |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
)

$allowedColumns = if ($workflowColumnsAll.Count -ge 3) {
    @($workflowColumnsAll[1..($workflowColumnsAll.Count - 2)])
} else {
    @()
}

$orderedColumns = @(
    $allowedColumns |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
)

$timeInColumnLabels = @()
$timeInColumnValues = @()
$timeInColumnTotals = @()
$timeInColumnCounts = @()

foreach ($col in $orderedColumns) {
    $total = if ($columnTotals.ContainsKey($col)) { [Math]::Round([double]$columnTotals[$col], 1) } else { 0 }
    $count = if ($columnCounts.ContainsKey($col)) { [int]$columnCounts[$col] } else { 0 }
    $avg = if ($count -gt 0) { [Math]::Round(($total / $count), 1) } else { 0 }

    $timeInColumnLabels += $col
    $timeInColumnValues += $avg
    $timeInColumnTotals += $total
    $timeInColumnCounts += $count
}

$timeInColumnChart = @{
    labels = $timeInColumnLabels
    values = $timeInColumnValues
    totals = $timeInColumnTotals
    counts = $timeInColumnCounts
}

$timeInColumnInsightText = if ($timeInColumnLabels.Count -eq 0) {
    "No columnTime data available to compute time in column."
} else {
    $rows = @()
    for ($i = 0; $i -lt $timeInColumnLabels.Count; $i++) {
        $rows += [PSCustomObject]@{
            Column = $timeInColumnLabels[$i]
            Avg = [double]$timeInColumnValues[$i]
            Total = [double]$timeInColumnTotals[$i]
            Count = [int]$timeInColumnCounts[$i]
        }
    }

    $rowsWithData = @($rows | Where-Object { $_.Count -gt 0 })
    if ($rowsWithData.Count -eq 0) {
        "No columnTime data available to compute time in column."
    } else {
        $top = @($rowsWithData | Sort-Object -Property Avg -Descending | Select-Object -First 3)
        $topText = ($top | ForEach-Object { "$($_.Column): $($_.Avg)d avg (across $($_.Count) items)" }) -join "; "
        "Longest average time is in: $topText."
    }
}

# Build transitions
$transitions = @()
for ($i = 0; $i -lt ($boardColumns.Count - 1); $i++) {
    $transitions += "$($boardColumns[$i]) -> $($boardColumns[$i + 1])"
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
$backlogSize = $activeItems.Count
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

# Cumulative Flow Diagram (whole board): arrivals vs departures over time
# Arrivals uses the same start-point choice as lead time (creation / board entry / specific column)
# Departures = ClosedDate
$effectiveLt = Get-EffectiveLeadTimeConfig -Config $config -StartTypeOverride $LeadTimeStartType -StartColumnOverride $LeadTimeStartColumn
$cfdArrivalStartType = [string]$effectiveLt.startType
$cfdArrivalStartColumn = [string]$effectiveLt.startColumn

$cfdLabels = @($blockedTimelineLabels)
$cfdWeekCount = $timelineWeekKeys.Count
$cfdWeeklyArrivals = @(0) * $cfdWeekCount
$cfdWeeklyDepartures = @(0) * $cfdWeekCount

$cfdCandidates = [int]($activeItems.Count + $completedItems.Count)
$cfdExcludedCount = 0
$cfdExclusionReasons = @{}
$cfdExclusionIds = @{}

function Add-CfdExclusion {
    param(
        [string]$Reason,
        [int]$Id
    )

    if (-not $cfdExclusionReasons.ContainsKey($Reason)) { $cfdExclusionReasons[$Reason] = 0 }
    $cfdExclusionReasons[$Reason]++
    $cfdExcludedCount++

    if (-not $cfdExclusionIds.ContainsKey($Reason)) { $cfdExclusionIds[$Reason] = @() }
    if ($cfdExclusionIds[$Reason].Count -lt 50) {
        $cfdExclusionIds[$Reason] += $Id
    }
}

$allCfdItems = @($activeItems + $completedItems)
foreach ($item in $allCfdItems) {
    $startDate = Get-ItemStartDateStrict -Item $item -StartType $cfdArrivalStartType -StartColumn $cfdArrivalStartColumn
    if (-not $startDate) {
        $reason = if ($cfdArrivalStartType -eq 'creation') {
            'missingCreatedDate'
        } elseif ($cfdArrivalStartType -eq 'boardEntry') {
            'missingBoardEntryDate'
        } else {
            'missingColumnEntryDate'
        }

        Add-CfdExclusion -Reason $reason -Id ([int]$item.id)
        continue
    }

    if ($startDate -ge $analysisStart -and $startDate -le $analysisEnd) {
        $wkKey = (Get-WeekStartMonday $startDate).ToString('yyyy-MM-dd')
        if ($weekKeyToIndex.ContainsKey($wkKey)) {
            $idx = [int]$weekKeyToIndex[$wkKey]
            if ($idx -ge 0 -and $idx -lt $cfdWeekCount) {
                $cfdWeeklyArrivals[$idx] = [int]$cfdWeeklyArrivals[$idx] + 1
            }
        }
    }
}

foreach ($item in $completedItems) {
    $closedRaw = $item.fields.'Microsoft.VSTS.Common.ClosedDate'
    if (-not $closedRaw) {
        Add-CfdExclusion -Reason 'missingClosedDate' -Id ([int]$item.id)
        continue
    }

    try {
        $closed = [DateTime]$closedRaw
    } catch {
        Add-CfdExclusion -Reason 'invalidClosedDate' -Id ([int]$item.id)
        continue
    }

    if ($closed -ge $analysisStart -and $closed -le $analysisEnd) {
        $wkKey = (Get-WeekStartMonday $closed).ToString('yyyy-MM-dd')
        if ($weekKeyToIndex.ContainsKey($wkKey)) {
            $idx = [int]$weekKeyToIndex[$wkKey]
            if ($idx -ge 0 -and $idx -lt $cfdWeekCount) {
                $cfdWeeklyDepartures[$idx] = [int]$cfdWeeklyDepartures[$idx] + 1
            }
        }
    }
}

$cfdCumulativeArrivals = @()
$cfdCumulativeDepartures = @()
$runA = 0
$runD = 0
for ($i = 0; $i -lt $cfdWeekCount; $i++) {
    $runA += [int]$cfdWeeklyArrivals[$i]
    $runD += [int]$cfdWeeklyDepartures[$i]
    $cfdCumulativeArrivals += $runA
    $cfdCumulativeDepartures += $runD
}

$cfdExcludedPercent = if ($cfdCandidates -gt 0) { [Math]::Round(($cfdExcludedCount / $cfdCandidates) * 100, 1) } else { 0 }

$cfdExcludedObject = @{
    candidates = $cfdCandidates
    count = $cfdExcludedCount
    excludedPercent = $cfdExcludedPercent
    reasons = $cfdExclusionReasons
    ids = $cfdExclusionIds
}

$cfdChart = @{
    labels = $cfdLabels
    arrivals = $cfdCumulativeArrivals
    departures = $cfdCumulativeDepartures
    excluded = $cfdExcludedObject
}

# Backlog Growth (system stability) derived from CFD arrival/departure rates
$systemStabilityMetric = @{
    ratio = '+0.0'
    text = 'STABLE'
    class = 'trend-neutral'
    trend = @{ direction = 'stable'; isGood = $true }
}

if ($cfdWeekCount -ge 2) {
    $arrivalStart = [double]($cfdCumulativeArrivals[0])
    $arrivalEnd = [double]($cfdCumulativeArrivals[$cfdWeekCount - 1])
    $departureStart = [double]($cfdCumulativeDepartures[0])
    $departureEnd = [double]($cfdCumulativeDepartures[$cfdWeekCount - 1])

    $arrivalRate = ($arrivalEnd - $arrivalStart) / ($cfdWeekCount - 1)
    $departureRate = ($departureEnd - $departureStart) / ($cfdWeekCount - 1)
    $netRate = $arrivalRate - $departureRate

    $ratioStr = if ($netRate -ge 0) { "+$([Math]::Round($netRate, 1))" } else { "$([Math]::Round($netRate, 1))" }

    $trendObj = if ($arrivalRate -gt ($departureRate * 1.1)) {
        @{ direction = 'up'; isGood = $false }
    } elseif ($departureRate -gt ($arrivalRate * 1.1)) {
        @{ direction = 'down'; isGood = $true }
    } else {
        @{ direction = 'stable'; isGood = $true }
    }

    $text = if ($trendObj.direction -eq 'up') {
        '[!] GROWING'
    } elseif ($trendObj.direction -eq 'down') {
        'SHRINKING'
    } else {
        'STABLE'
    }

    $class = if ($trendObj.direction -eq 'up') {
        'trend-warning'
    } elseif ($trendObj.direction -eq 'down') {
        'trend-good'
    } else {
        'trend-neutral'
    }

    $systemStabilityMetric = @{
        ratio = $ratioStr
        text = $text
        class = $class
        trend = $trendObj
    }
}

# Data quality: Time In Column coverage
$timeInColumnCandidates = [int]$completedWithMetrics.Count
$timeInColumnExcluded = [int](@($completedWithMetrics | Where-Object { -not $_.columnTime -or $_.columnTime.Count -eq 0 }).Count)
$timeInColumnExcludedPercent = if ($timeInColumnCandidates -gt 0) { [Math]::Round(($timeInColumnExcluded / $timeInColumnCandidates) * 100, 1) } else { 0 }

# Build final data structure matching template expectations
$dashboardData = @{ 
    teamName = "$($rawData.metadata.team) ($($rawData.metadata.project))"
    period = "$([DateTime]::Parse($rawData.metadata.startDate).ToString('dd MMM yyyy')) - $([DateTime]::Parse($rawData.metadata.endDate).ToString('dd MMM yyyy')) ($($rawData.metadata.months) months)"
    adoOrg = $rawData.metadata.organization
    adoProject = $rawData.metadata.project
    hasTypeSplit = ($completedTypeGroups.Count -gt 1)
    hasBugPbiSplit = ($bugs.Count -gt 0 -and $pbis.Count -gt 0)
    
    # Metadata about metric calculations
    metricDefinitions = @{
        leadTimeMethod = $effectiveLt.startType
        leadTimeStartColumn = if ($effectiveLt.startType -eq 'column') { $effectiveLt.startColumn } else { 'New' }
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

    analysisScope = @{
        workItemTypes = @{
            included = $trackedWorkItemTypes
            excludedConfigured = $excludedConfiguredWorkItemTypes
            ignoredObserved = $ignoredObservedWorkItemTypes
        }
    }

    configuration = @{
        board = @{
            boardName = if ($config -and $config.boardName) { $config.boardName } else { $null }
            organization = if ($config -and $config.organization) { $config.organization } else { $rawData.metadata.organization }
            project = if ($config -and $config.project) { $config.project } else { $rawData.metadata.project }
            team = if ($config -and $config.team) { $config.team } else { $rawData.metadata.team }
            configuredDate = if ($config -and $config.configuredDate) { $config.configuredDate } else { $null }
            configFile = $configFileLeaf
        }
        columns = if ($config -and $config.columns) { $config.columns } else { $null }
        states = if ($config -and $config.states) { $config.states } else { $null }
        dataQuality = @{
            warningThresholdPercent = 10
            policy = 'No guessing. If required data is missing, the item is excluded and counted here.'
            charts = [ordered]@{
                cfd = @{
                    name = 'CFD (Arrivals vs Departures)'
                    candidates = $cfdCandidates
                    excluded = $cfdExcludedCount
                    excludedPercent = $cfdExcludedPercent
                }
                timeInColumn = @{
                    name = 'Time In Column'
                    candidates = $timeInColumnCandidates
                    excluded = $timeInColumnExcluded
                    excludedPercent = $timeInColumnExcludedPercent
                }
            }
        }
        blockers = @{
            tags = if ($config -and $config.blockers -and $config.blockers.tags) { @($config.blockers.tags) } else { @() }
            columns = if ($config -and $config.blockers -and $config.blockers.columns) { @($config.blockers.columns) } else { @() }
            categories = $blockerCategories
        }
    }
    
    metrics = @{
        throughput = @{
            avg = $throughputTotal
            byType = $throughputByType
            bugs = if ($throughputByType.Contains('Bugs')) { $throughputByType['Bugs'] } else { 0 }
            pbis = if ($throughputByType.Contains('PBIs')) { $throughputByType['PBIs'] } else { 0 }
            median = $throughputTotal
            min = 0
            max = ($throughputChart.values | Measure-Object -Maximum).Maximum
            trend = Calculate-Trend -values $throughputValues -higherIsBetter $true
        }
        cycleTime = @{
            avg = [Math]::Round(($cycleTimes | Measure-Object -Average).Average, 1)
            byType = $cycleTimeAvgByType
            bugs = if ($cycleTimeAvgByType.Contains('Bugs')) { $cycleTimeAvgByType['Bugs'] } else { 0 }
            pbis = if ($cycleTimeAvgByType.Contains('PBIs')) { $cycleTimeAvgByType['PBIs'] } else { 0 }
            median = $cycleTimeMedian
            p85 = if ($cycleTimes) { ($cycleTimes | Sort-Object)[([Math]::Ceiling($cycleTimes.Count * 0.85) - 1)] } else { 0 }
            trend = Calculate-Trend -values @($cycleTimeTrendChart.values) -higherIsBetter $false
        }
        leadTime = @{
            avg = [Math]::Round(($leadTimes | Measure-Object -Average).Average, 1)
            byType = $leadTimeAvgByType
            bugs = if ($leadTimeAvgByType.Contains('Bugs')) { $leadTimeAvgByType['Bugs'] } else { 0 }
            pbis = if ($leadTimeAvgByType.Contains('PBIs')) { $leadTimeAvgByType['PBIs'] } else { 0 }
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
        systemStability = $systemStabilityMetric
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
            byType = $cycleTimeByTypeStats
        }
        cfd = $cfdChart
        wip = $wipAgingChart
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
        workItemAge = $workItemAgeChart
        timeInColumn = $timeInColumnChart
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
        netFlow = $netFlowChart
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
        cfd = "$($completedWithMetrics.Count) items completed, $($activeItems.Count) in progress"
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
        workItemAge = $workItemAgeInsightText
        dailyWip = $dailyWipInsightText
        timeInColumn = $timeInColumnInsightText
        wipAgeBreakdown = $wipAgeInsightText
        wip = $wipInsightText
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
        netFlow = $netFlowInsightText
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
