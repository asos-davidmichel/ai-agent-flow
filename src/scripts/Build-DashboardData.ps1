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
    [string]$LeadTimeStartColumn,

    [Parameter(Mandatory = $false)]
    [string[]]$EfficiencyActiveColumns,

    [Parameter(Mandatory = $false)]
    [string[]]$EfficiencyWaitingColumns,

    [Parameter(Mandatory = $false)]
    [string[]]$EfficiencyBeforeWorkflowColumns,

    [Parameter(Mandatory = $false)]
    [string[]]$EfficiencyAfterWorkflowColumns
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

# Optional colour configuration (keeps defaults if not provided)
$ageBandGreen = '#22c55e'
$ageBandAmber = '#f59e0b'
$ageBandRed = '#ef4444'
if ($config -and $config.colors -and $config.colors.ageBands) {
    if ($config.colors.ageBands.green) { $ageBandGreen = [string]$config.colors.ageBands.green }
    if ($config.colors.ageBands.amber) { $ageBandAmber = [string]$config.colors.ageBands.amber }
    if ($config.colors.ageBands.red) { $ageBandRed = [string]$config.colors.ageBands.red }
}

# Canonical board column ordering (used for ordering + detecting unknown/old columns)
$configuredBoardColumns = @()
if ($config -and $config.columns) {
    if ($config.columns.backlog) { $configuredBoardColumns += @($config.columns.backlog) }
    if ($config.columns.inProgress) { $configuredBoardColumns += @($config.columns.inProgress) }
    if ($config.columns.done) { $configuredBoardColumns += @($config.columns.done) }
} elseif ($rawData.boardConfig -and $rawData.boardConfig.columns) {
    $configuredBoardColumns += @($rawData.boardConfig.columns)
}
$configuredBoardColumns = @(
    $configuredBoardColumns |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
)

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

# Only fetch ADO type styles for work item types that actually appear in this dataset
$observedTrackedTypes = @(
    @($activeItems + $completedItems) |
        ForEach-Object { $_.fields.'System.WorkItemType' } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
)

function Get-AdoPatFromEnv {
    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_DEVOPS_EXT_PAT)) { return $env:AZURE_DEVOPS_EXT_PAT }
    if (-not [string]::IsNullOrWhiteSpace($env:ADO_PAT)) { return $env:ADO_PAT }
    $userPat = [System.Environment]::GetEnvironmentVariable('ADO_PAT', 'User')
    if (-not [string]::IsNullOrWhiteSpace($userPat)) { return $userPat }
    return $null
}

function Normalize-HexColor {
    param([string]$Color)
    if ([string]::IsNullOrWhiteSpace($Color)) { return $null }
    $c = $Color.Trim()
    if ($c -match '^#?[0-9a-fA-F]{6}$') {
        if ($c.StartsWith('#')) { return $c }
        return "#$c"
    }
    return $c
}

function Get-SafeFileNameFragment {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'unknown' }
    $safe = ($Text -replace '[^a-zA-Z0-9._-]+', '-')
    $safe = $safe.Trim('-')
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'unknown' }
    return $safe
}

function Get-AdoWorkItemTypeStyles {
    param(
        [Parameter(Mandatory = $true)][string]$Organization,
        [Parameter(Mandatory = $true)][string]$Project,
        [string[]]$WorkItemTypes
    )

    $pat = Get-AdoPatFromEnv
    if ([string]::IsNullOrWhiteSpace($pat)) { return @{} }

    $requested = @(
        @($WorkItemTypes) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    if (-not $requested -or $requested.Count -eq 0) {
        return @{
            styles = @{}
            typeUrlCount = 0
            errorCount = 0
            sampleErrors = @{}
            cache = @{ enabled = $true; used = $false; hitCount = 0; missCount = 0 }
        }
    }

    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $cacheDir = Join-Path (Join-Path $repoRoot 'output') '_cache'
    if (-not (Test-Path $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir | Out-Null
    }
    $cacheFile = Join-Path $cacheDir ("ado-workitemtype-styles-{0}-{1}.json" -f (Get-SafeFileNameFragment -Text $Organization), (Get-SafeFileNameFragment -Text $Project))

    $cachedStyles = @{}
    $cacheMeta = $null
    if (Test-Path $cacheFile) {
        try {
            $cacheObj = Get-Content $cacheFile -Raw | ConvertFrom-Json
            if ($cacheObj -and $cacheObj.styles) {
                $cachedStyles = @{}
                foreach ($p in $cacheObj.styles.PSObject.Properties) {
                    $cachedStyles[$p.Name] = $p.Value
                }
            }
            $cacheMeta = $cacheObj.meta
        } catch {
            $cachedStyles = @{}
            $cacheMeta = $null
        }
    }

    try {
        $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
        $headers = @{ Authorization = "Basic $base64AuthInfo"; Accept = "application/json" }

        $styles = @{}
        $cacheHitCount = 0
        foreach ($name in $requested) {
            if ($cachedStyles -and $cachedStyles.ContainsKey($name)) {
                $styles[$name] = $cachedStyles[$name]
                $cacheHitCount++
            }
        }

        $missing = @(
            $requested |
                Where-Object { -not $styles.ContainsKey($_) }
        )

        if ($missing.Count -eq 0) {
            return @{
                styles = $styles
                typeUrlCount = 0
                errorCount = 0
                sampleErrors = @{}
                cache = @{ enabled = $true; used = $true; file = $cacheFile; hitCount = $cacheHitCount; missCount = 0 }
            }
        }

        # List type categories first (reliable in this org), then fetch each requested type definition URL.
        $catUri = "https://dev.azure.com/$Organization/$Project/_apis/wit/workitemtypecategories?api-version=7.1-preview.2"
        $cats = Invoke-RestMethod -Uri $catUri -Headers $headers -Method Get -ErrorAction Stop
        if ($cats -is [string]) { $cats = $cats | ConvertFrom-Json }
        $catValues = if ($cats -and $cats.value) { @($cats.value) } else { @() }

        $typeUrlByName = @{}
        foreach ($cat in $catValues) {
            foreach ($t in @($cat.workItemTypes)) {
                $n = if ($t.name) { [string]$t.name } else { $null }
                $u = if ($t.url) { [string]$t.url } else { $null }
                if ([string]::IsNullOrWhiteSpace($n) -or [string]::IsNullOrWhiteSpace($u)) { continue }
                if (-not $typeUrlByName.ContainsKey($n)) {
                    $typeUrlByName[$n] = $u
                }
            }
        }

        $errors = @{}
        foreach ($name in $missing) {
            if (-not $typeUrlByName.ContainsKey($name)) { continue }

            $defUrl = $typeUrlByName[$name]
            if ($defUrl -notmatch 'api-version=') {
                $defUrl = "${defUrl}?api-version=7.1-preview.2"
            }

            try {
                $wr = Invoke-WebRequest -Uri $defUrl -Headers $headers -Method Get -UseBasicParsing -ErrorAction Stop
                $defJson = if ($wr -and $wr.Content) { [string]$wr.Content } else { '' }

                $color = $null
                $iconUrl = $null

                # Extract only what we need (payload contains large xmlForm)
                $mColor = [regex]::Match($defJson, '"color"\s*:\s*"(?<c>[^"]+)"')
                if ($mColor.Success) { $color = Normalize-HexColor -Color ($mColor.Groups['c'].Value) }

                $mIcon = [regex]::Match($defJson, '"icon"\s*:\s*\{[^\}]*"url"\s*:\s*"(?<u>[^"]+)"')
                if ($mIcon.Success) { $iconUrl = [string]$mIcon.Groups['u'].Value }

                $styles[$name] = @{
                    color = $color
                    iconUrl = $iconUrl
                }
            } catch {
                if ($errors.Count -lt 5 -and -not $errors.ContainsKey($name)) {
                    $errors[$name] = $_.Exception.Message
                }
            }
        }

        # Update cache (best-effort, no secrets)
        try {
            $cachePayload = @{
                meta = @{
                    organization = $Organization
                    project = $Project
                    apiVersion = '7.1-preview.2'
                    fetchedAtUtc = ([DateTime]::UtcNow.ToString('o'))
                    types = @($styles.Keys | Sort-Object)
                }
                styles = $styles
            }
            $cachePayload | ConvertTo-Json -Depth 8 | Set-Content -Path $cacheFile -Encoding UTF8
        } catch {
            # ignore cache write failures
        }

        return @{
            styles = $styles
            typeUrlCount = [int]$typeUrlByName.Keys.Count
            errorCount = [int]$errors.Keys.Count
            sampleErrors = $errors
            cache = @{ enabled = $true; used = $true; file = $cacheFile; hitCount = $cacheHitCount; missCount = [int]$missing.Count }
        }
    } catch {
        return @{
            styles = @{}
            typeUrlCount = 0
            errorCount = 1
            sampleErrors = @{ _fatal = $_.Exception.Message }
            cache = @{ enabled = $true; used = $false; file = $cacheFile; hitCount = 0; missCount = [int]$requested.Count }
        }
    }
}

function Get-AdoBoardColumnWipLimits {
    param(
        [Parameter(Mandatory = $true)][string]$Organization,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$Team,
        [string]$BoardName = 'Backlog items',
        [int]$CacheMaxAgeHours = 24
    )

    $pat = Get-AdoPatFromEnv
    if ([string]::IsNullOrWhiteSpace($pat)) { return @{} }

    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $cacheDir = Join-Path (Join-Path $repoRoot 'output') '_cache'
    if (-not (Test-Path $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir | Out-Null
    }
    $cacheFile = Join-Path $cacheDir (
        "ado-board-wiplimits-{0}-{1}-{2}.json" -f (Get-SafeFileNameFragment -Text $Organization), (Get-SafeFileNameFragment -Text $Project), (Get-SafeFileNameFragment -Text $Team)
    )

    if (Test-Path $cacheFile) {
        try {
            $cacheObj = Get-Content $cacheFile -Raw | ConvertFrom-Json
            $fetchedAt = $null
            if ($cacheObj -and $cacheObj.meta -and $cacheObj.meta.fetchedAt) {
                try { $fetchedAt = [DateTime]$cacheObj.meta.fetchedAt } catch { $fetchedAt = $null }
            }

            $isFresh = $false
            if ($fetchedAt) {
                $ageHours = (New-TimeSpan -Start $fetchedAt -End (Get-Date)).TotalHours
                $isFresh = ($ageHours -ge 0 -and $ageHours -le [double]$CacheMaxAgeHours)
            }

            if ($isFresh -and $cacheObj -and $cacheObj.wipLimits) {
                $limits = @{}
                foreach ($p in $cacheObj.wipLimits.PSObject.Properties) {
                    try { $limits[$p.Name] = [int]$p.Value } catch { }
                }
                return $limits
            }
        } catch { }
    }

    try {
        $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
        $headers = @{ Authorization = "Basic $base64AuthInfo"; Accept = "application/json" }

        $teamEsc = [uri]::EscapeDataString($Team)
        $boardsUri = "https://dev.azure.com/$Organization/$Project/$teamEsc/_apis/work/boards?api-version=7.1-preview.1"
        $boards = Invoke-RestMethod -Uri $boardsUri -Headers $headers -Method Get -ErrorAction Stop
        if ($boards -is [string]) { $boards = $boards | ConvertFrom-Json }
        $boardValues = if ($boards -and $boards.value) { @($boards.value) } else { @() }
        if (-not $boardValues -or $boardValues.Count -eq 0) { return @{} }

        $board = $null
        if (-not [string]::IsNullOrWhiteSpace($BoardName)) {
            $board = @($boardValues | Where-Object { $_.name -eq $BoardName } | Select-Object -First 1)
        }
        if (-not $board) { $board = $boardValues[0] }

        $boardUrl = [string]$board.url
        if ([string]::IsNullOrWhiteSpace($boardUrl)) { return @{} }

        $colsUri = "$boardUrl/columns?api-version=7.1-preview.1"
        $cols = Invoke-RestMethod -Uri $colsUri -Headers $headers -Method Get -ErrorAction Stop
        if ($cols -is [string]) { $cols = $cols | ConvertFrom-Json }
        $colValues = if ($cols -and $cols.value) { @($cols.value) } else { @() }

        $limits = @{}
        foreach ($c in $colValues) {
            $name = if ($c.name) { [string]$c.name } else { $null }
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            $limit = 0
            try { $limit = [int]$c.itemLimit } catch { $limit = 0 }
            if ($limit -gt 0) {
                $limits[$name] = $limit
            }
        }

        $cacheObj = [PSCustomObject]@{
            meta = @{
                organization = $Organization
                project = $Project
                team = $Team
                boardName = $board.name
                fetchedAt = (Get-Date).ToString('o')
            }
            wipLimits = $limits
        }
        $cacheObj | ConvertTo-Json -Depth 8 | Set-Content -Path $cacheFile -Encoding utf8

        return $limits
    } catch {
        return @{}
    }
}

$adoTypeStyleResult = Get-AdoWorkItemTypeStyles -Organization $rawData.metadata.organization -Project $rawData.metadata.project -WorkItemTypes @($observedTrackedTypes)
$adoWorkItemTypeStyles = if ($adoTypeStyleResult -and $adoTypeStyleResult.styles) { $adoTypeStyleResult.styles } else { @{} }
$adoWorkItemTypeStylesDebug = @{
    patPresent = -not [string]::IsNullOrWhiteSpace((Get-AdoPatFromEnv))
    observedTypes = @($observedTrackedTypes)
    fetchedTypeCount = if ($adoWorkItemTypeStyles) { [int]$adoWorkItemTypeStyles.Keys.Count } else { 0 }
    fetchedTypes = if ($adoWorkItemTypeStyles) { @($adoWorkItemTypeStyles.Keys | Sort-Object) } else { @() }
    typeUrlCount = if ($adoTypeStyleResult -and $adoTypeStyleResult.typeUrlCount) { [int]$adoTypeStyleResult.typeUrlCount } else { 0 }
    errorCount = if ($adoTypeStyleResult -and $adoTypeStyleResult.errorCount -ne $null) { [int]$adoTypeStyleResult.errorCount } else { 0 }
    sampleErrors = if ($adoTypeStyleResult -and $adoTypeStyleResult.sampleErrors) { $adoTypeStyleResult.sampleErrors } else { @{} }
    cache = if ($adoTypeStyleResult -and $adoTypeStyleResult.cache) { $adoTypeStyleResult.cache } else { @{} }
}

function Get-WorkItemTypeStyle {
    param([string]$WorkItemType)
    if ([string]::IsNullOrWhiteSpace($WorkItemType)) { return $null }
    if ($adoWorkItemTypeStyles -and $adoWorkItemTypeStyles.ContainsKey($WorkItemType)) {
        return $adoWorkItemTypeStyles[$WorkItemType]
    }
    return $null
}

function Get-EfficiencyColumnMapping {
    param(
        $Config,
        [string[]]$ActiveOverride,
        [string[]]$WaitingOverride,
        [string[]]$BeforeOverride,
        [string[]]$AfterOverride
    )

    $effSource = 'heuristic'

    $cfgBefore = if ($Config -and $Config.columns -and $Config.columns.backlog) { @($Config.columns.backlog) } else { @() }
    $cfgInProgress = if ($Config -and $Config.columns -and $Config.columns.inProgress) { @($Config.columns.inProgress) } else { @() }
    $cfgAfter = if ($Config -and $Config.columns -and $Config.columns.done) { @($Config.columns.done) } else { @('Closed', 'Done') }

    $effBefore = if ($BeforeOverride -and $BeforeOverride.Count -gt 0) {
        $effSource = 'override'
        @($BeforeOverride)
    } elseif ($Config -and $Config.metrics -and $Config.metrics.efficiency -and $Config.metrics.efficiency.beforeWorkflowColumns) {
        $effSource = 'config'
        @($Config.metrics.efficiency.beforeWorkflowColumns)
    } elseif ($cfgBefore.Count -gt 0) {
        @($cfgBefore)
    } else {
        @()
    }

    $effAfter = if ($AfterOverride -and $AfterOverride.Count -gt 0) {
        $effSource = 'override'
        @($AfterOverride)
    } elseif ($Config -and $Config.metrics -and $Config.metrics.efficiency -and $Config.metrics.efficiency.afterWorkflowColumns) {
        $effSource = 'config'
        @($Config.metrics.efficiency.afterWorkflowColumns)
    } elseif ($cfgAfter.Count -gt 0) {
        @($cfgAfter)
    } else {
        @('Closed', 'Done', 'Removed')
    }

    $effActive = @()
    $effWaiting = @()

    if ($ActiveOverride -and $ActiveOverride.Count -gt 0) {
        $effSource = 'override'
        $effActive = @($ActiveOverride)
    }
    if ($WaitingOverride -and $WaitingOverride.Count -gt 0) {
        $effSource = 'override'
        $effWaiting = @($WaitingOverride)
    }

    if ($effActive.Count -eq 0 -and $Config -and $Config.metrics -and $Config.metrics.efficiency -and $Config.metrics.efficiency.activeColumns) {
        $effSource = 'config'
        $effActive = @($Config.metrics.efficiency.activeColumns)
    }
    if ($effWaiting.Count -eq 0 -and $Config -and $Config.metrics -and $Config.metrics.efficiency -and $Config.metrics.efficiency.waitingColumns) {
        $effSource = 'config'
        $effWaiting = @($Config.metrics.efficiency.waitingColumns)
    }

    if ($effActive.Count -eq 0 -and $effWaiting.Count -eq 0) {
        $waitingRegex = '(?i)\bready\b|\bwaiting\b|\bqueue\b|\bon hold\b|\bblocked\b'
        foreach ($col in $cfgInProgress) {
            if ([string]::IsNullOrWhiteSpace($col)) { continue }
            if ($col -match $waitingRegex) {
                $effWaiting += $col
            } else {
                $effActive += $col
            }
        }
    }

    $effActive = @($effActive | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $effWaiting = @($effWaiting | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $effBefore = @($effBefore | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $effAfter = @($effAfter | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

    return @{
        source = $effSource
        activeColumns = $effActive
        waitingColumns = $effWaiting
        beforeWorkflowColumns = $effBefore
        afterWorkflowColumns = $effAfter
    }
}

function Get-ColumnTimeDays {
    param(
        $ColumnTime,
        [Parameter(Mandatory = $true)][string]$ColumnName
    )

    if (-not $ColumnTime) { return 0 }

    # Hashtable / dictionary
    if ($ColumnTime -is [System.Collections.IDictionary]) {
        if ($ColumnTime.Contains($ColumnName)) {
            $v = $ColumnTime[$ColumnName]
            try { return [Math]::Max(0, [double]$v) } catch { return 0 }
        }

        foreach ($k in $ColumnTime.Keys) {
            if ([string]$k -ieq $ColumnName) {
                $v = $ColumnTime[$k]
                try { return [Math]::Max(0, [double]$v) } catch { return 0 }
            }
        }

        return 0
    }

    # PSCustomObject
    $prop = $ColumnTime.PSObject.Properties | Where-Object { $_.Name -ieq $ColumnName } | Select-Object -First 1
    if (-not $prop) { return 0 }
    try { return [Math]::Max(0, [double]$prop.Value) } catch { return 0 }
}

function Sum-ColumnTimeDays {
    param(
        $ColumnTime,
        [string[]]$Columns
    )

    if (-not $Columns -or $Columns.Count -eq 0) { return 0 }
    $sum = 0.0
    foreach ($c in $Columns) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $sum += (Get-ColumnTimeDays -ColumnTime $ColumnTime -ColumnName $c)
    }
    # Keep more precision so short spans don't round to 0.0 days.
    return [Math]::Round($sum, 3)
}

$efficiencyMapping = Get-EfficiencyColumnMapping -Config $config -ActiveOverride $EfficiencyActiveColumns -WaitingOverride $EfficiencyWaitingColumns -BeforeOverride $EfficiencyBeforeWorkflowColumns -AfterOverride $EfficiencyAfterWorkflowColumns

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
    try {
        $d1 = [DateTime]$date1
        $d2 = [DateTime]$date2
    } catch {
        return 0
    }

    $days = ($d2 - $d1).TotalDays
    if ([double]::IsNaN($days) -or [double]::IsInfinity($days)) { return 0 }
    if ($days -lt 0) { return 0 }
    return [Math]::Round($days, 3)
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

# Helper: Calculate per-column WIP level distribution over time (board columns)
function Get-ColumnWIPDistribution {
    param(
        $CompletedItems,
        $ActiveItems,
        [DateTime]$StartDate,
        [DateTime]$EndDate,
        [string[]]$ColumnNames,
        $WIPLimits
    )

    $allItems = @($CompletedItems) + @($ActiveItems)
    $colSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($c in @($ColumnNames)) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        [void]$colSet.Add([string]$c)
    }

    $itemInfoById = @{}
    foreach ($it in $allItems) {
        $itemInfoById[[int]$it.id] = @{
            id = [int]$it.id
            title = [string]$it.fields.'System.Title'
            workItemType = [string]$it.fields.'System.WorkItemType'
        }
    }

    $eventsByColumn = @{}
    foreach ($c in $colSet) {
        $eventsByColumn[$c] = New-Object System.Collections.ArrayList
    }

    $parseDate = {
        param($raw)
        if (-not $raw) { return $null }
        try {
            $dt = [DateTime]$raw
            if ($dt.Year -ge 9999) { return $null }
            return $dt
        } catch {
            return $null
        }
    }

    foreach ($item in $allItems) {
        $itemId = [int]$item.id

        $createdDt = & $parseDate $item.fields.'System.CreatedDate'
        $closedDt = & $parseDate $item.fields.'Microsoft.VSTS.Common.ClosedDate'

        $itemStart = if ($createdDt -and $createdDt -gt $StartDate) { $createdDt } else { $StartDate }
        $itemEnd = if ($closedDt -and $closedDt -lt $EndDate) { $closedDt } else { $EndDate }
        if ($itemEnd -le $StartDate) { continue }
        if ($itemStart -ge $EndDate) { continue }

        $boardColTransitions = @()
        $stateTransitions = @()

        if ($item.updates -and $item.updates.Count -gt 0) {
            $sortedUpdates = $item.updates | Sort-Object {
                $d = & $parseDate $_.revisedDate
                if ($d) { $d } else { [DateTime]::MaxValue }
            }

            foreach ($u in $sortedUpdates) {
                $t = & $parseDate $u.revisedDate
                if (-not $t) { continue }

                if ($u.fields.'System.BoardColumn') {
                    $f = $u.fields.'System.BoardColumn'
                    $newVal = if ($f.newValue) { [string]$f.newValue } else { $null }
                    $oldVal = if ($f.oldValue) { [string]$f.oldValue } else { $null }
                    if (-not [string]::IsNullOrWhiteSpace($newVal)) {
                        $boardColTransitions += [PSCustomObject]@{ time = $t; old = $oldVal; new = $newVal }
                    }
                } elseif ($u.fields.'System.State') {
                    $f = $u.fields.'System.State'
                    $newVal = if ($f.newValue) { [string]$f.newValue } else { $null }
                    $oldVal = if ($f.oldValue) { [string]$f.oldValue } else { $null }
                    if (-not [string]::IsNullOrWhiteSpace($newVal)) {
                        $stateTransitions += [PSCustomObject]@{ time = $t; old = $oldVal; new = $newVal }
                    }
                }
            }
        }

        $transitions = if ($boardColTransitions.Count -gt 0) { $boardColTransitions } else { $stateTransitions }
        $transitions = @($transitions | Sort-Object time)

        # Determine column at itemStart
        $currentCol = $null
        if ($transitions.Count -gt 0) {
            $lastBefore = @($transitions | Where-Object { $_.time -le $itemStart } | Sort-Object time -Descending | Select-Object -First 1)
            if ($lastBefore) {
                $currentCol = [string]$lastBefore.new
            } else {
                $first = $transitions[0]
                if ($first.old -and -not [string]::IsNullOrWhiteSpace($first.old)) {
                    $currentCol = [string]$first.old
                } else {
                    $currentCol = [string]$first.new
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($currentCol)) {
            $currentCol = [string]$item.fields.'System.BoardColumn'
        }
        if ([string]::IsNullOrWhiteSpace($currentCol)) {
            $currentCol = [string]$item.fields.'System.State'
        }
        if ([string]::IsNullOrWhiteSpace($currentCol)) { continue }

        $curStart = $itemStart
        $forward = @($transitions | Where-Object { $_.time -gt $itemStart -and $_.time -lt $itemEnd } | Sort-Object time)
        foreach ($tr in $forward) {
            $t = [DateTime]$tr.time
            if ($t -le $curStart) { continue }

            $segStart = $curStart
            $segEnd = $t
            if ($segStart -lt $StartDate) { $segStart = $StartDate }
            if ($segEnd -gt $EndDate) { $segEnd = $EndDate }
            if ($segEnd -gt $segStart -and $colSet.Contains([string]$currentCol)) {
                [void]$eventsByColumn[[string]$currentCol].Add([PSCustomObject]@{ time = $segStart; action = 'enter'; id = $itemId })
                [void]$eventsByColumn[[string]$currentCol].Add([PSCustomObject]@{ time = $segEnd; action = 'exit'; id = $itemId })
            }

            $currentCol = [string]$tr.new
            $curStart = $t
        }

        # Final segment
        $segStart = $curStart
        $segEnd = $itemEnd
        if ($segStart -lt $StartDate) { $segStart = $StartDate }
        if ($segEnd -gt $EndDate) { $segEnd = $EndDate }
        if ($segEnd -gt $segStart -and $colSet.Contains([string]$currentCol)) {
            [void]$eventsByColumn[[string]$currentCol].Add([PSCustomObject]@{ time = $segStart; action = 'enter'; id = $itemId })
            [void]$eventsByColumn[[string]$currentCol].Add([PSCustomObject]@{ time = $segEnd; action = 'exit'; id = $itemId })
        }
    }

    $totalSeconds = ($EndDate - $StartDate).TotalSeconds
    if ($totalSeconds -le 0) { $totalSeconds = 1 }

    $byColumn = @{}
    foreach ($col in @($ColumnNames)) {
        if ([string]::IsNullOrWhiteSpace($col)) { continue }

        $events = if ($eventsByColumn.ContainsKey($col)) { @($eventsByColumn[$col]) } else { @() }
        $events = @($events | Where-Object { $_.time -ge $StartDate -and $_.time -le $EndDate } | Sort-Object time)

        $activeSet = New-Object 'System.Collections.Generic.HashSet[int]'
        $levelSeconds = @{}
        $levelItems = @{}

        $addSlice = {
            param([DateTime]$from, [DateTime]$to, [int]$level)
            $sec = ($to - $from).TotalSeconds
            if ($sec -le 0) { return }

            if (-not $levelSeconds.ContainsKey($level)) { $levelSeconds[$level] = 0.0 }
            $levelSeconds[$level] = [double]$levelSeconds[$level] + [double]$sec

            if (-not $levelItems.ContainsKey($level)) {
                $levelItems[$level] = New-Object 'System.Collections.Generic.HashSet[int]'
            }
            foreach ($id in $activeSet) {
                [void]$levelItems[$level].Add([int]$id)
            }
        }

        $prev = $StartDate
        $i = 0
        while ($i -lt $events.Count) {
            $t = [DateTime]$events[$i].time
            if ($t -gt $EndDate) { break }

            & $addSlice $prev $t ([int]$activeSet.Count)

            # Apply all events at time t (exit first, then enter)
            $sameTime = @()
            while ($i -lt $events.Count -and ([DateTime]$events[$i].time) -eq $t) {
                $sameTime += $events[$i]
                $i++
            }

            foreach ($e in @($sameTime | Where-Object { $_.action -eq 'exit' })) {
                [void]$activeSet.Remove([int]$e.id)
            }
            foreach ($e in @($sameTime | Where-Object { $_.action -eq 'enter' })) {
                [void]$activeSet.Add([int]$e.id)
            }

            $prev = $t
        }

        & $addSlice $prev $EndDate ([int]$activeSet.Count)

        if (-not $levelSeconds.ContainsKey(0)) {
            $levelSeconds[0] = 0.0
        }

        # Ensure time sums to total (float drift): assign remainder to level 0
        $sumSec = 0.0
        foreach ($k in $levelSeconds.Keys) { $sumSec += [double]$levelSeconds[$k] }
        $rem = [double]$totalSeconds - [double]$sumSec
        if ($rem -gt 0.0001) {
            $levelSeconds[0] = [double]$levelSeconds[0] + $rem
        }

        $levels = @($levelSeconds.Keys | ForEach-Object { [int]$_ } | Sort-Object)
        $pcts = @()
        $itemsByLevelOut = @{}

        foreach ($lvl in $levels) {
            $pct = ([double]$levelSeconds[$lvl] / [double]$totalSeconds) * 100
            $pcts += [Math]::Round($pct, 1)

            $ids = if ($levelItems.ContainsKey($lvl)) { @($levelItems[$lvl]) } else { @() }
            $items = @(
                $ids |
                    Select-Object -Unique |
                    Select-Object -First 40 |
                    ForEach-Object {
                        $id = [int]$_
                        if ($itemInfoById.ContainsKey($id)) { $itemInfoById[$id] }
                    } |
                    Where-Object { $_ }
            )

            $itemsByLevelOut["$lvl"] = $items
        }

        # Recommended WIP = most common non-zero level
        $rec = 0
        $bestPct = -1
        for ($idx = 0; $idx -lt $levels.Count; $idx++) {
            $lvl = [int]$levels[$idx]
            if ($lvl -lt 1) { continue }
            $pct = [double]$pcts[$idx]
            if ($pct -gt $bestPct) {
                $bestPct = $pct
                $rec = $lvl
            }
        }

        $maxLimit = $null
        if ($WIPLimits -and $WIPLimits.ContainsKey($col)) {
            try { $maxLimit = [int]$WIPLimits[$col] } catch { $maxLimit = $null }
        }
        if (-not $maxLimit -or $maxLimit -le 0) { $maxLimit = $null }

        $currentWip = @(
            $ActiveItems | Where-Object {
                ([string]$_.fields.'System.BoardColumn' -eq $col) -or ([string]$_.fields.'System.State' -eq $col)
            }
        ).Count

        $byColumn[$col] = @{
            wipLevels = $levels
            timePercentages = $pcts
            recommendedWip = $rec
            maxWip = $maxLimit
            currentWip = $currentWip
            itemsByLevel = $itemsByLevelOut
        }
    }

    return @{
        columns = @($ColumnNames)
        byColumn = $byColumn
    }
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
    
    if ([double]::IsNaN($totalActiveDays) -or [double]::IsInfinity($totalActiveDays)) { return 0 }
    if ($totalActiveDays -lt 0) { return 0 }
    return [Math]::Round($totalActiveDays, 3)
}

# Build completed items with metrics calculated from state transitions
$completedWithMetrics = @()
foreach ($item in $completedItems) {
    # Try to use provided columnTime data if available
    $columnTimeEntry = ($ColumnTimeData | Where-Object { $_.WorkItemId -eq $item.id } | Select-Object -First 1)
    $columnTime = if ($columnTimeEntry) { $columnTimeEntry.ColumnTime } else { $null }
    $columnTimeField = if ($columnTimeEntry -and $columnTimeEntry.FieldUsed) { [string]$columnTimeEntry.FieldUsed } else { $null }
    if (-not $columnTime) { $columnTime = @{} }
    
    # Calculate cycle time from real columnTime when available.
    # Definition used by the Efficiency tab: cycle time = time in ACTIVE + WAITING workflow columns (from the first ACTIVE column onwards).
    $cycleTime = 0
    $activeTimeDays = 0
    $waitingTimeDays = 0
    $hasColumnTime = $false
    if ($columnTime -is [System.Collections.IDictionary]) {
        $hasColumnTime = ($columnTime.Count -gt 0)
    } elseif ($columnTime -and $columnTime.PSObject -and $columnTime.PSObject.Properties) {
        $hasColumnTime = ($columnTime.PSObject.Properties.Count -gt 0)
    }

    if ($hasColumnTime) {
        $activeTimeDays = Sum-ColumnTimeDays -ColumnTime $columnTime -Columns $efficiencyMapping.activeColumns
        $waitingTimeDays = Sum-ColumnTimeDays -ColumnTime $columnTime -Columns $efficiencyMapping.waitingColumns

        $cycleTime = [Math]::Round(($activeTimeDays + $waitingTimeDays), 3)

        # If mapping didn't match any workflow columns but the item was clearly worked and completed,
        # fall back to ActivatedDate -> ClosedDate to avoid impossible 0.0d cycle times.
        if ($cycleTime -le 0) {
            $activatedRaw = $item.fields.'Microsoft.VSTS.Common.ActivatedDate'
            $closedRaw = $item.fields.'Microsoft.VSTS.Common.ClosedDate'
            if ($activatedRaw -and $closedRaw) {
                $fallback = Get-DaysBetween $activatedRaw $closedRaw
                if ($fallback -gt 0) {
                    $cycleTime = $fallback
                }
            }
        }
    } else {
        # No real board column history available => no workflow cycle time.
        $cycleTime = 0
        $activeTimeDays = 0
        $waitingTimeDays = 0
    }
    
    $completedWithMetrics += [PSCustomObject]@{
        id = $item.id
        type = $item.fields.'System.WorkItemType'
        title = $item.fields.'System.Title'
        state = $item.fields.'System.State'
        createdDate = $item.fields.'System.CreatedDate'
        completedDate = $item.fields.'Microsoft.VSTS.Common.ClosedDate'
        columnTime = $columnTime
        columnTimeField = $columnTimeField
        cycleTime = $cycleTime
        activeTime = $activeTimeDays
        waitingTime = $waitingTimeDays
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
    $weekItemsList = @(
        $weekItems |
            ForEach-Object {
                @{
                    id = $_.id
                    title = $_.title
                    workItemType = $_.type
                }
            }
    )
    
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
                workItemType = $bugItem.fields.'System.WorkItemType'
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
                workItemType = $featureItem.fields.'System.WorkItemType'
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

# Current board columns (source of truth for column-based charts)
$boardColumns = $rawData.boardConfig.columns
if (-not $boardColumns) { $boardColumns = @() }
$boardColumns = @(
    @($boardColumns) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
)

# WIP level distribution (per column)
$wipLevelDistributionChart = $null
$wipLevelDistributionDebug = $null
try {
    $configuredWipColumns = @()
    if ($config -and $config.columns) {
        if ($config.columns.backlog) { $configuredWipColumns += @($config.columns.backlog) }
        if ($config.columns.inProgress) { $configuredWipColumns += @($config.columns.inProgress) }
    }

    $wipColumns = if ($configuredWipColumns.Count -gt 0) {
        @(
            $configuredWipColumns |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique |
                Where-Object { $boardColumns -contains $_ }
        )
    } else {
        @($boardColumns)
    }

    # Exclude the initial intake column from this visualization
    $wipColumns = @(
        $wipColumns |
            Where-Object { $_ -and ([string]$_).Trim().ToLowerInvariant() -ne 'new' }
    )

    $wipLimits = @{}
    $wipOrg = if ($config -and $config.organization) { [string]$config.organization } else { [string]$rawData.metadata.organization }
    $wipProject = if ($config -and $config.project) { [string]$config.project } else { [string]$rawData.metadata.project }
    $wipTeam = if ($config -and $config.team) { [string]$config.team } else { [string]$rawData.metadata.team }
    if (-not [string]::IsNullOrWhiteSpace($wipOrg) -and -not [string]::IsNullOrWhiteSpace($wipProject) -and -not [string]::IsNullOrWhiteSpace($wipTeam)) {
        $wipLimits = Get-AdoBoardColumnWipLimits -Organization $wipOrg -Project $wipProject -Team $wipTeam -BoardName 'Backlog items'
    }

    if ($wipColumns.Count -gt 0) {
        $wipLevelDistributionChart = Get-ColumnWIPDistribution `
            -CompletedItems $completedItems `
            -ActiveItems $activeItems `
            -StartDate $analysisStart `
            -EndDate $analysisEnd `
            -ColumnNames $wipColumns `
            -WIPLimits $wipLimits
    }
} catch {
    $wipLevelDistributionChart = $null
    $wipLevelDistributionDebug = $_.Exception.Message
}

# Current bug breakdown by board column (for pie chart)
$bugColumnBreakdown = @{}
$bugColumnItems = @{}

$bugsByColumnCandidates = [int]$activeBugs.Count
$bugsByColumnExcludedMissingBoardColumn = 0
$bugsByColumnExcludedUnknownColumns = 0
$bugsByColumnOldColumnsCounts = @{}
$bugsByColumnExcludedItemsSample = @()

foreach ($bug in $activeBugs) {
    $column = [string]$bug.fields.'System.BoardColumn'

    if ([string]::IsNullOrWhiteSpace($column)) {
        $bugsByColumnExcludedMissingBoardColumn++
        if ($bugsByColumnExcludedItemsSample.Count -lt 10) {
            $bugsByColumnExcludedItemsSample += @{
                id = $bug.id
                workItemType = $bug.fields.'System.WorkItemType'
                columns = @('missingBoardColumn')
            }
        }
        continue
    }

    # Ignore bugs in old/unknown board columns
    if ($boardColumns -notcontains $column) {
        $bugsByColumnExcludedUnknownColumns++
        if (-not $bugsByColumnOldColumnsCounts.ContainsKey($column)) { $bugsByColumnOldColumnsCounts[$column] = 0 }
        $bugsByColumnOldColumnsCounts[$column] += 1

        if ($bugsByColumnExcludedItemsSample.Count -lt 10) {
            $bugsByColumnExcludedItemsSample += @{
                id = $bug.id
                workItemType = $bug.fields.'System.WorkItemType'
                columns = @($column)
            }
        }
        continue
    }
    
    if (-not $bugColumnBreakdown.ContainsKey($column)) {
        $bugColumnBreakdown[$column] = 0
    }
    $bugColumnBreakdown[$column]++

    if (-not $bugColumnItems.ContainsKey($column)) {
        $bugColumnItems[$column] = @()
    }

    $existing = @($bugColumnItems[$column])
    $bugColumnItems[$column] = $existing + @(
        @{
            id = $bug.id
            title = $bug.fields.'System.Title'
            workItemType = $bug.fields.'System.WorkItemType'
        }
    )
}

# Normalise: ensure every bucket is an array (avoid single-item buckets becoming objects)
foreach ($k in @($bugColumnItems.Keys)) {
    $v = $bugColumnItems[$k]
    if ($null -eq $v) {
        $bugColumnItems[$k] = @()
        continue
    }
    if ($v -is [System.Array]) { continue }
    $bugColumnItems[$k] = @() + ,$v
}

# Current bug breakdown by state (for pie chart)
$bugStateBreakdown = @{}
$bugStateItems = @{}
foreach ($bug in $activeBugs) {
    $state = $bug.fields.'System.State'
    if ([string]::IsNullOrWhiteSpace($state)) {
        $state = "Unknown"
    }
    
    if (-not $bugStateBreakdown.ContainsKey($state)) {
        $bugStateBreakdown[$state] = 0
    }
    $bugStateBreakdown[$state]++

    if (-not $bugStateItems.ContainsKey($state)) {
        $bugStateItems[$state] = @()
    }

    $existing = @($bugStateItems[$state])
    $bugStateItems[$state] = $existing + @(
        @{
            id = $bug.id
            title = $bug.fields.'System.Title'
            workItemType = $bug.fields.'System.WorkItemType'
        }
    )
}

# Normalise: ensure every bucket is an array (avoid single-item buckets becoming objects)
foreach ($k in @($bugStateItems.Keys)) {
    $v = $bugStateItems[$k]
    if ($null -eq $v) {
        $bugStateItems[$k] = @()
        continue
    }
    if ($v -is [System.Array]) { continue }
    $bugStateItems[$k] = @() + ,$v
}

# Format bug breakdown for output, ordered by board column sequence
$currentBugsByColumn = @()
foreach ($col in $boardColumns) {
    if ($bugColumnBreakdown.ContainsKey($col) -and $bugColumnBreakdown[$col] -gt 0) {
        $bucket = if ($bugColumnItems.ContainsKey($col)) { $bugColumnItems[$col] } else { $null }
        $bucketItems = if ($bucket -is [System.Array]) {
            @($bucket)
        } elseif ($null -ne $bucket) {
            @() + ,$bucket
        } else {
            @()
        }

        $currentBugsByColumn += @{
            column = $col
            count = $bugColumnBreakdown[$col]
            items = $bucketItems
        }
    }
}

# Format bug breakdown by state for output
$currentBugsByState = @()
foreach ($state in ($bugStateBreakdown.Keys | Sort-Object)) {
    if ($bugStateBreakdown[$state] -gt 0) {
        $bucket = if ($bugStateItems.ContainsKey($state)) { $bugStateItems[$state] } else { $null }
        $bucketItems = if ($bucket -is [System.Array]) {
            @($bucket)
        } elseif ($null -ne $bucket) {
            @() + ,$bucket
        } else {
            @()
        }

        $currentBugsByState += @{
            state = $state
            count = $bugStateBreakdown[$state]
            items = $bucketItems
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
$staleWorkTypes = @()
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
    $staleWorkTypes += $item.workItemType
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
$blockedByColumn = [ordered]@{}
foreach ($col in $boardColumns) {
    $blockedByColumn[$col] = 0
}

$blockedByColumnCandidates = [int]$blockedItems.Count
$blockedByColumnExcludedMissingBoardColumn = 0
$blockedByColumnExcludedUnknownColumns = 0
$blockedByColumnOldColumnsCounts = @{}
$blockedByColumnExcludedItemsSample = @()

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
    
    # Count by column (ignore items in old/unknown columns)
    if ([string]::IsNullOrWhiteSpace($column)) {
        $blockedByColumnExcludedMissingBoardColumn++
        if ($blockedByColumnExcludedItemsSample.Count -lt 10) {
            $blockedByColumnExcludedItemsSample += @{
                id = $item.id
                workItemType = $workItemType
                columns = @('missingBoardColumn')
            }
        }
    } elseif ($blockedByColumn.Contains($column)) {
        $blockedByColumn[$column]++
    } else {
        $blockedByColumnExcludedUnknownColumns++
        if (-not $blockedByColumnOldColumnsCounts.ContainsKey($column)) { $blockedByColumnOldColumnsCounts[$column] = 0 }
        $blockedByColumnOldColumnsCounts[$column] += 1
        if ($blockedByColumnExcludedItemsSample.Count -lt 10) {
            $blockedByColumnExcludedItemsSample += @{
                id = $item.id
                workItemType = $workItemType
                columns = @($column)
            }
        }
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
$weeklyBucketItems = @{}
foreach ($wk in $timelineWeekKeys) {
    $weeklyBuckets[$wk] = @{}
    $weeklyBucketItems[$wk] = @{}
    foreach ($categoryKey in $categoryKeys) {
        $weeklyBuckets[$wk][$categoryKey] = 0
        $weeklyBucketItems[$wk][$categoryKey] = @()
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

                if ($weeklyBucketItems.ContainsKey($weekKey) -and $null -ne $weeklyBucketItems[$weekKey][$detail.category]) {
                    $weeklyBucketItems[$weekKey][$detail.category] += @{
                        id = $detail.id
                        title = $detail.title
                        workItemType = $detail.workItemType
                    }
                }
            }
        }

    }
}

foreach ($categoryKey in $categoryKeys) {
    $blockedTimelineSeries[$categoryKey] = @($timelineWeekKeys | ForEach-Object { [int]$weeklyBuckets[$_][$categoryKey] })
}

$blockedTimelineItemsSeries = [ordered]@{}
foreach ($categoryKey in $categoryKeys) {
    $perWeek = @()
    foreach ($wk in $timelineWeekKeys) {
        $bucket = if ($weeklyBucketItems.ContainsKey($wk)) { $weeklyBucketItems[$wk][$categoryKey] } else { $null }

        $bucketItems = if ($bucket -is [System.Array]) {
            @($bucket)
        } elseif ($null -ne $bucket) {
            @() + ,$bucket
        } else {
            @()
        }

        # Unary comma is critical: it prevents PowerShell from flattening nested arrays.
        $perWeek += ,$bucketItems
    }
    $blockedTimelineItemsSeries[$categoryKey] = $perWeek
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
            $events += [PSCustomObject]@{
                type = 'blocked'
                categoryKey = $newCategory.key
                date = $updateDate
                id = $WorkItem.id
                title = $WorkItem.fields.'System.Title'
                workItemType = $WorkItem.fields.'System.WorkItemType'
            }
        } elseif (-not $hasBlockerNow -and $hadBlockerBefore) {
            $events += [PSCustomObject]@{
                type = 'unblocked'
                categoryKey = $oldCategory.key
                date = $updateDate
                id = $WorkItem.id
                title = $WorkItem.fields.'System.Title'
                workItemType = $WorkItem.fields.'System.WorkItemType'
            }
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
        $blockerEvents += [PSCustomObject]@{
            type = 'blocked'
            categoryKey = $blockedEntry.category.key
            date = $addedDate
            id = $blockedEntry.item.id
            title = $blockedEntry.item.fields.'System.Title'
            workItemType = $blockedEntry.item.fields.'System.WorkItemType'
        }
    }
}

# Per-week tooltip item lists for blocker flow (totals)
$blockedEventsItemsByWeek = @()
$unblockedEventsItemsByWeek = @()
for ($i = 0; $i -lt $timelineWeekKeys.Count; $i++) {
    $blockedEventsItemsByWeek += ,@()
    $unblockedEventsItemsByWeek += ,@()
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

    $itemRef = $null
    if ($ev.id) {
        $itemRef = @{
            id = $ev.id
            title = $ev.title
            workItemType = $ev.workItemType
        }
    }

    if ($ev.type -eq 'blocked') {
        if ($blockedRateSeries.Contains($cat)) {
            $blockedRateSeries[$cat][$idx] = [int]$blockedRateSeries[$cat][$idx] + 1
        }

        if ($itemRef) {
            $blockedEventsItemsByWeek[$idx] += $itemRef
        }
    } elseif ($ev.type -eq 'unblocked') {
        if ($unblockedRateSeries.Contains($cat)) {
            $unblockedRateSeries[$cat][$idx] = [int]$unblockedRateSeries[$cat][$idx] + 1
        }

        if ($itemRef) {
            $unblockedEventsItemsByWeek[$idx] += $itemRef
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
$wipAgingTypes = @()

foreach ($item in $wipAgingItemsSorted) {
    $typeLabel = if ($item.workItemType -eq 'Bug') {
        'Bug'
    } elseif ($item.workItemType -eq 'Product Backlog Item') {
        'PBI'
    } elseif ($item.workItemType -eq 'Spike' -or $item.workItemType -eq 'Spikes') {
        'Spike'
    } else {
        $item.workItemType
    }
    $wipAgingLabels += "$typeLabel #$($item.id)"
    $wipAgingValues += [int]$item.age
    $wipAgingIds += $item.id
    $wipAgingTitles += $item.title
    $wipAgingTypes += $item.workItemType

    # Colour by age bands (green -> amber -> red)
    # Use a wider amber band so mid-aged items are visually distinct.
    $wipAgingColors += if ($item.age -gt 30) {
        $ageBandRed
    } elseif ($item.age -gt 14) {
        $ageBandAmber
    } else {
        $ageBandGreen
    }
}

$wipAgingChart = @{
    labels = $wipAgingLabels
    values = $wipAgingValues
    ids = $wipAgingIds
    titles = $wipAgingTitles
    colors = $wipAgingColors
    types = $wipAgingTypes
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

    # If boardConfig columns are present, filter out any configured columns that are no longer on the board
    if ($rawData.boardConfig -and $rawData.boardConfig.columns) {
        $boardCols = @(
            @($rawData.boardConfig.columns) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique
        )
        $workItemAgeAllowedColumns = @($workItemAgeAllowedColumns | Where-Object { $boardCols -contains $_ })
    }
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
        workItemType = $fields.'System.WorkItemType'
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
        $columnItems += @{ id = $it.id; title = $it.title; workItemType = $it.workItemType; age = [int]$it.age }
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
                workItemType = $itemType
            }
        } else {
            $completedByWeek[$weekLabel].features += @{
                id = $item.id
                title = $item.fields.'System.Title'
                workItemType = $itemType
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

    $style = Get-WorkItemTypeStyle -WorkItemType $workItemType
    $dsColor = if ($style -and $style.color) {
        [string]$style.color
    } elseif ($workItemType -eq 'Bug') {
        '#ef4444'
    } elseif ($workItemType -eq 'Spike') {
        '#8b5cf6'
    } else {
        # PBI/Story default
        '#3b82f6'
    }

    if ($items.Count -gt 0) {
        $cycleTimeDatasets += @{
            label = $label
            workItemType = $workItemType
            backgroundColor = $dsColor
            borderColor = $dsColor
            pointBackgroundColor = $dsColor
            pointBorderColor = '#ffffff'
            pointBorderWidth = 2
            pointRadius = 5
            pointHoverRadius = 7
            data = @($items | ForEach-Object {
                # Use Monday of the week for x-axis to align with other charts
                $completedDate = [DateTime]$_.completedDate
                $weekStart = Get-WeekStartMonday $completedDate
                @{
                    x = $weekStart.ToString('dd MMM')
                    y = $_.cycleTime
                    leadTime = $_.leadTime
                    id = $_.id
                    workItemType = $workItemType
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

function Get-PercentileValue {
    param(
        [double[]]$Values,
        [Parameter(Mandatory = $true)][double]$Percentile
    )

    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $p = [Math]::Max(0, [Math]::Min(1, $Percentile))
    $sorted = @($Values | Sort-Object)
    $idx = [Math]::Ceiling($sorted.Count * $p) - 1
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $sorted.Count) { $idx = $sorted.Count - 1 }
    return [Math]::Round([double]$sorted[$idx], 1)
}

function Get-EfficiencyClass {
    param(
        [double]$Value,
        [double]$GoodThreshold,
        [double]$WarningThreshold
    )

    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return 'trend-neutral' }
    if ($Value -ge $GoodThreshold) { return 'trend-good' }
    if ($Value -ge $WarningThreshold) { return 'trend-warning' }
    return 'trend-warning'
}

function Test-IsFiniteNumber {
    param([double]$Value)
    return (-not ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)))
}

$invariant = [System.Globalization.CultureInfo]::InvariantCulture

# --- Efficiency metrics (computed from real completed-item data) ---
$completedCount = [int]$completedWithMetrics.Count

# Work Start Efficiency: Cycle / Lead
$wseCandidates = @($completedWithMetrics | Where-Object { $_.leadTime -gt 0 -and $_.cycleTime -gt 0 })
$wseValues = @($wseCandidates | ForEach-Object {
    $lead = [double]$_.leadTime
    $cycle = [double]$_.cycleTime
    $v = ($cycle / $lead) * 100
    if (Test-IsFiniteNumber $v) { [Math]::Max(0, [Math]::Min(100, $v)) }
} | Where-Object { $_ -ne $null })

$wseAvgVal = if ($wseValues.Count -gt 0) { [Math]::Round((($wseValues | Measure-Object -Average).Average), 1) } else { $null }
$wseP50Val = Get-PercentileValue -Values $wseValues -Percentile 0.5
$wseP85Val = Get-PercentileValue -Values $wseValues -Percentile 0.85
$wseExcluded = $completedCount - [int]$wseCandidates.Count

$wsePct = if ($wseAvgVal -ne $null) { $wseAvgVal.ToString('0.0', $invariant) } else { 'N/A' }
$wseClass = if ($wseAvgVal -ne $null) { Get-EfficiencyClass -Value $wseAvgVal -GoodThreshold 70 -WarningThreshold 50 } else { 'trend-neutral' }
$wseInsight = if ($wseAvgVal -ne $null) {
    $p50 = if ($wseP50Val -ne $null) { $wseP50Val.ToString('0.0', $invariant) } else { 'N/A' }
    $p85 = if ($wseP85Val -ne $null) { $wseP85Val.ToString('0.0', $invariant) } else { 'N/A' }
    "Avg $wsePct% across $($wseCandidates.Count)/$completedCount completed items (P50 $p50%, P85 $p85%). Excluded $wseExcluded item(s) due to missing/zero lead or cycle time."
} else {
    "No eligible completed items (requires lead time > 0 and cycle time > 0)."
}

# Cycle Time Flow Efficiency: Active / Cycle (requires columnTime)
$ctfeCandidates = @($completedWithMetrics | Where-Object { $_.cycleTime -gt 0 -and $_.activeTime -ge 0 })
$ctfeValues = @($ctfeCandidates | ForEach-Object {
    $cycle = [double]$_.cycleTime
    $active = [double]$_.activeTime
    $v = ($active / $cycle) * 100
    if (Test-IsFiniteNumber $v) { [Math]::Max(0, [Math]::Min(100, $v)) }
} | Where-Object { $_ -ne $null })

$ctfeAvgVal = if ($ctfeValues.Count -gt 0) { [Math]::Round((($ctfeValues | Measure-Object -Average).Average), 1) } else { $null }
$ctfeP50Val = Get-PercentileValue -Values $ctfeValues -Percentile 0.5
$ctfeP85Val = Get-PercentileValue -Values $ctfeValues -Percentile 0.85
$ctfeExcluded = $completedCount - [int]$ctfeCandidates.Count

$ctfePct = if ($ctfeAvgVal -ne $null) { $ctfeAvgVal.ToString('0.0', $invariant) } else { 'N/A' }
$ctfeClass = if ($ctfeAvgVal -ne $null) { Get-EfficiencyClass -Value $ctfeAvgVal -GoodThreshold 70 -WarningThreshold 50 } else { 'trend-neutral' }
$ctfeInsight = if ($ctfeAvgVal -ne $null) {
    $p50 = if ($ctfeP50Val -ne $null) { $ctfeP50Val.ToString('0.0', $invariant) } else { 'N/A' }
    $p85 = if ($ctfeP85Val -ne $null) { $ctfeP85Val.ToString('0.0', $invariant) } else { 'N/A' }
    "Avg $ctfePct% across $($ctfeCandidates.Count)/$completedCount completed items (P50 $p50%, P85 $p85%). Excluded $ctfeExcluded item(s) due to missing/zero cycle time (no column-time data)."
} else {
    "No eligible completed items (requires cycle time > 0 and column-time data)."
}

# Lead Time Flow Efficiency: Active / Lead (requires columnTime + lead)
$ltfeCandidates = @($completedWithMetrics | Where-Object { $_.leadTime -gt 0 -and $_.activeTime -ge 0 -and $_.cycleTime -gt 0 })
$ltfeValues = @($ltfeCandidates | ForEach-Object {
    $lead = [double]$_.leadTime
    $active = [double]$_.activeTime
    $v = ($active / $lead) * 100
    if (Test-IsFiniteNumber $v) { [Math]::Max(0, [Math]::Min(100, $v)) }
} | Where-Object { $_ -ne $null })

$ltfeAvgVal = if ($ltfeValues.Count -gt 0) { [Math]::Round((($ltfeValues | Measure-Object -Average).Average), 1) } else { $null }
$ltfeP50Val = Get-PercentileValue -Values $ltfeValues -Percentile 0.5
$ltfeP85Val = Get-PercentileValue -Values $ltfeValues -Percentile 0.85
$ltfeExcluded = $completedCount - [int]$ltfeCandidates.Count

$ltfePct = if ($ltfeAvgVal -ne $null) { $ltfeAvgVal.ToString('0.0', $invariant) } else { 'N/A' }
$ltfeClass = if ($ltfeAvgVal -ne $null) { Get-EfficiencyClass -Value $ltfeAvgVal -GoodThreshold 40 -WarningThreshold 25 } else { 'trend-neutral' }
$ltfeInsight = if ($ltfeAvgVal -ne $null) {
    $p50 = if ($ltfeP50Val -ne $null) { $ltfeP50Val.ToString('0.0', $invariant) } else { 'N/A' }
    $p85 = if ($ltfeP85Val -ne $null) { $ltfeP85Val.ToString('0.0', $invariant) } else { 'N/A' }
    "Avg $ltfePct% across $($ltfeCandidates.Count)/$completedCount completed items (P50 $p50%, P85 $p85%). Excluded $ltfeExcluded item(s) due to missing/zero lead or cycle time (no column-time data)."
} else {
    "No eligible completed items (requires lead time > 0 and column-time data)."
}

$cycleTimeMedian = Get-Median $cycleTimes
$leadTimeMedian = Get-Median $leadTimes

# Backwards-compat per-type arrays (used by a few existing metrics)
$bugCycleTimes = $bugs | ForEach-Object { $_.cycleTime } | Where-Object { $_ -gt 0 }
$pbiCycleTimes = $pbis | ForEach-Object { $_.cycleTime } | Where-Object { $_ -gt 0 }

$bugLeadTimes = $bugs | ForEach-Object { $_.leadTime } | Where-Object { $_ -gt 0 }
$pbiLeadTimes = $pbis | ForEach-Object { $_.leadTime } | Where-Object { $_ -gt 0 }

# Net Flow chart (weekly started vs finished) - full analysis timeline
$startedByWeekItemsMap = @{}
foreach ($item in @($activeItems + $completedItems)) {
    $createdDateRaw = $item.fields.'System.CreatedDate'
    if (-not $createdDateRaw) { continue }

    $weekStart = Get-WeekStartMonday ([DateTime]$createdDateRaw)
    if ($weekStart -lt $firstWeekStart -or $weekStart -gt $lastWeekStart) { continue }

    $key = $weekStart.ToString('yyyy-MM-dd')
    if (-not $startedByWeekItemsMap.ContainsKey($key)) {
        $startedByWeekItemsMap[$key] = @()
    }
    $startedByWeekItemsMap[$key] += @{
        id = $item.id
        title = $item.fields.'System.Title'
        workItemType = $item.fields.'System.WorkItemType'
    }
}

$netFlowStarted = @()
$netFlowFinished = @()
$netFlowValues = @()
$netFlowStartedItems = @()
$netFlowFinishedItems = @()

foreach ($ws in $weekStarts) {
    $key = $ws.ToString('yyyy-MM-dd')

    $startedItems = if ($startedByWeekItemsMap.ContainsKey($key)) { @($startedByWeekItemsMap[$key]) } else { @() }
    $finishedItems = if ($completedByWeekMap.ContainsKey($key)) {
        @(
            @($completedByWeekMap[$key]) |
                ForEach-Object {
                    @{
                        id = $_.id
                        title = $_.title
                        workItemType = $_.type
                    }
                }
        )
    } else {
        @()
    }

    $startedCount = $startedItems.Count
    $finishedCount = $finishedItems.Count

    $netFlowStarted += $startedCount
    $netFlowFinished += $finishedCount
    $netFlowValues += ($finishedCount - $startedCount)

    $netFlowStartedItems += ,@($startedItems)
    $netFlowFinishedItems += ,@($finishedItems)
}

$netFlowChart = @{
    labels = $throughputLabels
    values = $netFlowValues
    started = $netFlowStarted
    finished = $netFlowFinished
    startedItems = $netFlowStartedItems
    finishedItems = $netFlowFinishedItems
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

$netFlowDirectionText = if ($netDelta -gt 0) {
    'Finished outpaced started (backlog likely shrinking).'
} elseif ($netDelta -lt 0) {
    'Started outpaced finished (backlog likely growing).'
} else {
    'Started and finished were balanced.'
}

$netFlowVolatilityText = if ([Math]::Abs($netWorstValue) -ge 2 * [Math]::Abs($netDelta) -and [Math]::Abs($netWorstValue) -ge 5) {
    'Large week-to-week swings suggest batch intake/release.'
} else {
    'Week-to-week net flow looks relatively steady.'
}

$netFlowInsightText = "Across $($weekStarts.Count) weeks: started $netTotalStarted, finished $netTotalFinished. Net flow (finished - started): $netDelta. $netFlowDirectionText Best week: $bestWeekLabel ($netBestValue). Worst week: $worstWeekLabel ($netWorstValue). $netFlowVolatilityText"

# Time in column chart (completed items only)
# Exclude items whose columnTime contains columns not present in the configured board.
$boardColumnsCurrent = if ($rawData.boardConfig -and $rawData.boardConfig.columns) { @($rawData.boardConfig.columns) } else { @() }
$boardColumnsCurrent = @(
    $boardColumnsCurrent |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
)

$workflowColumnsAll = if ($boardColumnsCurrent.Count -gt 0) { @($boardColumnsCurrent) } else { @($configuredBoardColumns) }

$timeInColumnOldColumnsCounts = @{}
$timeInColumnOldColumnExcludedItems = @()
$timeInColumnExcludedUnknownColumns = 0
$timeInColumnExcludedStateBased = 0

$columnTotals = @{}
$columnCounts = @{}
foreach ($item in $completedWithMetrics) {
    if (-not $item.columnTime -or $item.columnTime.Count -eq 0) { continue }

    # If we couldn't compute real board column history (fell back to System.State), exclude.
    if ($item.columnTimeField -and $item.columnTimeField -ne 'System.BoardColumn') {
        $timeInColumnExcludedStateBased++
        continue
    }

    $unknownCols = @()
    foreach ($prop in $item.columnTime.PSObject.Properties) {
        $col = $prop.Name
        if ($workflowColumnsAll -notcontains $col) {
            $unknownCols += $col
        }
    }

    if ($unknownCols.Count -gt 0) {
        $timeInColumnExcludedUnknownColumns++

        foreach ($uc in ($unknownCols | Select-Object -Unique)) {
            if (-not $timeInColumnOldColumnsCounts.ContainsKey($uc)) { $timeInColumnOldColumnsCounts[$uc] = 0 }
            $timeInColumnOldColumnsCounts[$uc] += 1
        }

        $timeInColumnOldColumnExcludedItems += @{
            id = $item.id
            workItemType = $item.type
            columns = @($unknownCols | Select-Object -Unique)
        }

        continue
    }

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
        $sorted = @($rowsWithData | Sort-Object -Property Avg -Descending)
        $top1 = $sorted | Select-Object -First 1
        $top2 = $sorted | Select-Object -Skip 1 -First 1
        $top3 = $sorted | Select-Object -Skip 2 -First 1

        $topText = @(
            @($top1, $top2, $top3) |
                Where-Object { $_ } |
                ForEach-Object { "$($_.Column): $($_.Avg)d avg (across $($_.Count) items)" }
        ) -join "; "

        $bottleneckText = ''
        if ($top1 -and $top2 -and $top2.Avg -gt 0) {
            $ratio = [Math]::Round(($top1.Avg / $top2.Avg), 1)
            if ($ratio -ge 1.6 -or ($top1.Avg - $top2.Avg) -ge 3) {
                $bottleneckText = " Bottleneck signal: '$($top1.Column)' is ~$ratio× slower than the next column ('$($top2.Column)')."
            } elseif ($ratio -ge 1.3 -or ($top1.Avg - $top2.Avg) -ge 2) {
                $bottleneckText = " Mild bottleneck signal: '$($top1.Column)' is ~$ratio× slower than '$($top2.Column)'."
            }
        }

        $actionText = if ($bottleneckText) {
            " Consider reducing WIP into '$($top1.Column)' and checking handoff/queue policies and capacity."
        } else {
            " No single dominant bottleneck by average time-in-column."
        }

        "Top time-in-column: $topText.$bottleneckText$actionText"
    }
}

# Build transitions
$transitions = @()
for ($i = 0; $i -lt ($boardColumns.Count - 1); $i++) {
    $transitions += "$($boardColumns[$i]) -> $($boardColumns[$i + 1])"
}

# Transition Rate Ratios (arrival/departure per workflow stage)
# For each transition A -> B, define:
# - Arrival rate: moves A -> B per week
# - Departure rate: moves B -> C per week
# This highlights where work builds up (arrivals > departures).
$transitionMoveCounts = if ($boardColumns.Count -ge 2) { @(0) * ($boardColumns.Count - 1) } else { @() }

$transitionCandidates = 0
$transitionExcluded = 0
$transitionExclusionReasons = @{}

function Add-TransitionExclusion {
    param(
        [string]$Reason
    )
    if (-not $transitionExclusionReasons.ContainsKey($Reason)) { $transitionExclusionReasons[$Reason] = 0 }
    $transitionExclusionReasons[$Reason]++
    $transitionExcluded++
}

$allTransitionItems = @($activeItems + $completedItems)
foreach ($item in $allTransitionItems) {
    if (-not $item.updates -or $item.updates.Count -eq 0) {
        Add-TransitionExclusion -Reason 'missingUpdates'
        continue
    }

    $sortedUpdates = $item.updates | Sort-Object {
        $d = [DateTime]$_.revisedDate
        if ($d.Year -ge 9999) { [DateTime]::MaxValue } else { $d }
    }

    $sawBoardColumn = $false

    foreach ($update in $sortedUpdates) {
        $updateDate = [DateTime]$update.revisedDate
        if ($updateDate.Year -ge 9999) { continue }

        if ($updateDate -lt $analysisStart -or $updateDate -gt $analysisEnd) { continue }

        $bcField = $update.fields.'System.BoardColumn'
        if (-not $bcField) { continue }

        $sawBoardColumn = $true

        $from = if ($null -ne $bcField.oldValue) { [string]$bcField.oldValue } else { $null }
        $to = if ($null -ne $bcField.newValue) { [string]$bcField.newValue } else { $null }

        if ([string]::IsNullOrWhiteSpace($from) -or [string]::IsNullOrWhiteSpace($to)) {
            Add-TransitionExclusion -Reason 'missingOldOrNewColumn'
            continue
        }

        if ($from -eq $to) { continue }

        $transitionCandidates++

        $fromIdx = [Array]::IndexOf($boardColumns, $from)
        $toIdx = [Array]::IndexOf($boardColumns, $to)

        if ($fromIdx -lt 0 -or $toIdx -lt 0) {
            Add-TransitionExclusion -Reason 'nonBoardColumnHistory'
            continue
        }

        if ($toIdx -ne ($fromIdx + 1)) {
            Add-TransitionExclusion -Reason 'nonAdjacentTransition'
            continue
        }

        if ($fromIdx -ge 0 -and $fromIdx -lt $transitionMoveCounts.Count) {
            $transitionMoveCounts[$fromIdx] = [int]$transitionMoveCounts[$fromIdx] + 1
        }
    }

    if (-not $sawBoardColumn) {
        Add-TransitionExclusion -Reason 'missingBoardColumnHistory'
    }
}

$transitionWeeks = [Math]::Max(1, $timelineWeekKeys.Count)
$transitionRateTransitions = @()
$transitionRateArrivals = @()
$transitionRateDepartures = @()
$transitionRateRatios = @()

if ($boardColumns.Count -ge 3) {
    for ($i = 0; $i -lt ($boardColumns.Count - 2); $i++) {
        # Label bars by the target column (the column being measured)
        $transitionRateTransitions += "$($boardColumns[$i + 1])"

        $arrivalRate = [Math]::Round(([double]$transitionMoveCounts[$i] / $transitionWeeks), 2)
        $departureRate = [Math]::Round(([double]$transitionMoveCounts[$i + 1] / $transitionWeeks), 2)

        $ratio = if ($departureRate -le 0) {
            if ($arrivalRate -le 0) { 1.0 } else { 999.0 }
        } else {
            [Math]::Round(($arrivalRate / $departureRate), 2)
        }

        $transitionRateArrivals += $arrivalRate
        $transitionRateDepartures += $departureRate
        $transitionRateRatios += $ratio
    }
}

$transitionRatesInsightText = if ($transitionRateTransitions.Count -eq 0) {
    'Not enough board column transition data to compute transition rate ratios.'
} else {
    $rows = @()
    for ($i = 0; $i -lt $transitionRateTransitions.Count; $i++) {
        $rows += [PSCustomObject]@{
            Transition = $transitionRateTransitions[$i]
            Ratio = [double]$transitionRateRatios[$i]
            Arrival = [double]$transitionRateArrivals[$i]
            Departure = [double]$transitionRateDepartures[$i]
        }
    }

    $building = @($rows | Where-Object { $_.Ratio -gt 1.2 } | Sort-Object -Property Ratio -Descending | Select-Object -First 2)
    $draining = @($rows | Where-Object { $_.Ratio -lt 0.8 } | Sort-Object -Property Ratio | Select-Object -First 2)

    $strongest = @($rows | Sort-Object -Property Ratio -Descending | Select-Object -First 1)
    $strongestText = if ($strongest) {
        $r = [double]$strongest.Ratio
        if ($r -ge 999) {
            "Strongest build-up: $($strongest.Transition) has arrivals but near-zero departures (ratio ~∞)."
        } elseif ($r -ge 2) {
            "Strongest build-up: $($strongest.Transition) ratio $([Math]::Round($r,2)) (arrivals $($strongest.Arrival)/wk, departures $($strongest.Departure)/wk)."
        } else {
            ''
        }
    } else { '' }

    $tailNote = ''
    if ($transitionRateTransitions.Count -gt 0) {
        $lastIdx = $transitionRateTransitions.Count - 1
        $tailNote = " $($transitionRateTransitions[$lastIdx]): $($transitionRateArrivals[$lastIdx])/wk arriving, $($transitionRateDepartures[$lastIdx])/wk leaving (ratio $($transitionRateRatios[$lastIdx]))."
    }

    if ($building.Count -eq 0 -and $draining.Count -eq 0) {
        'Most workflow steps look balanced (arrivals and departures are similar).' + $tailNote
    } else {
        $parts = @()
        if ($building.Count -gt 0) {
            $parts += ('Build-up at: ' + (($building | ForEach-Object { "$($_.Transition) (ratio $([Math]::Round($_.Ratio,2)))" }) -join '; '))
        }
        if ($draining.Count -gt 0) {
            $parts += ('Draining at: ' + (($draining | ForEach-Object { "$($_.Transition) (ratio $([Math]::Round($_.Ratio,2)))" }) -join '; '))
        }
        $action = if ($building.Count -gt 0) {
            ' Where arrivals exceed departures, queues build — consider reducing WIP into that step or increasing capacity downstream.'
        } else {
            ''
        }

        ($parts -join '. ') + $tailNote + " $strongestText" + $action
    }
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

# Efficiency column mapping (working vs waiting) is computed near the top of this script so
# per-item cycle time can use it consistently.

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
$cfdBaselineArrivals = 0

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

    # Baseline: items that started before the analysis window still exist in the system.
    # Without this, departures (items finishing now) can exceed arrivals (items starting now),
    # which breaks the cumulative meaning of the CFD.
    if ($startDate -lt $analysisStart) {
        $cfdBaselineArrivals++
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
    # Keep departures aligned to the same item population as arrivals.
    # If we can't determine the start date for an item, we can't place its arrival baseline,
    # so we also exclude it from departures to avoid departures exceeding arrivals.
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
$runA = [int]$cfdBaselineArrivals
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
    baselineArrivals = [int]$cfdBaselineArrivals
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
$timeInColumnExcludedMissingColumnTime = [int](@($completedWithMetrics | Where-Object { -not $_.columnTime -or $_.columnTime.Count -eq 0 }).Count)
$timeInColumnExcludedUnknownColumns = [int]$timeInColumnExcludedUnknownColumns
$timeInColumnExcludedStateBased = [int]$timeInColumnExcludedStateBased
$timeInColumnExcluded = [int]($timeInColumnExcludedMissingColumnTime + $timeInColumnExcludedUnknownColumns)
$timeInColumnExcluded = [int]($timeInColumnExcluded + $timeInColumnExcludedStateBased)
$timeInColumnExcludedPercent = if ($timeInColumnCandidates -gt 0) { [Math]::Round(($timeInColumnExcluded / $timeInColumnCandidates) * 100, 1) } else { 0 }

$timeInColumnUnknownColumns = @(
    $timeInColumnOldColumnsCounts.Keys |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object
)

$timeInColumnExcludedUnknownColumnItemsSample = @(
    @($timeInColumnOldColumnExcludedItems) |
        Select-Object -First 10
)

$bugsByColumnExcluded = [int]($bugsByColumnExcludedMissingBoardColumn + $bugsByColumnExcludedUnknownColumns)
$bugsByColumnExcludedPercent = if ($bugsByColumnCandidates -gt 0) { [Math]::Round(($bugsByColumnExcluded / $bugsByColumnCandidates) * 100, 1) } else { 0 }
$bugsByColumnUnknownColumns = @(
    $bugsByColumnOldColumnsCounts.Keys |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object
)

$blockedByColumnExcluded = [int]($blockedByColumnExcludedMissingBoardColumn + $blockedByColumnExcludedUnknownColumns)
$blockedByColumnExcludedPercent = if ($blockedByColumnCandidates -gt 0) { [Math]::Round(($blockedByColumnExcluded / $blockedByColumnCandidates) * 100, 1) } else { 0 }
$blockedByColumnUnknownColumns = @(
    $blockedByColumnOldColumnsCounts.Keys |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object
)

# Column mismatch summary (config vs current board)
$configuredNotOnBoard = @(
    @($configuredBoardColumns) |
        Where-Object { $boardColumnsCurrent -notcontains $_ }
)
$boardNotInConfigured = @(
    @($boardColumnsCurrent) |
        Where-Object { $configuredBoardColumns -notcontains $_ }
)

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
        efficiency = $efficiencyMapping
        workItemTypeStyles = $adoWorkItemTypeStyles
        workItemTypeStylesDebug = $adoWorkItemTypeStylesDebug
        dataQuality = @{
            warningThresholdPercent = 10
            policy = 'No guessing. If required data is missing, the item is excluded and counted here.'
            columnsMismatch = @{
                configuredNotOnBoard = @($configuredNotOnBoard)
                boardNotInConfig = @($boardNotInConfigured)
            }
            charts = [ordered]@{
                cfd = @{
                    name = 'CFD (Arrivals vs Departures)'
                    candidates = $cfdCandidates
                    excluded = $cfdExcludedCount
                    excludedPercent = $cfdExcludedPercent
                }
                bugsByColumn = @{
                    name = 'Bugs by Column'
                    candidates = $bugsByColumnCandidates
                    excluded = $bugsByColumnExcluded
                    excludedPercent = $bugsByColumnExcludedPercent
                    excludedMissingBoardColumn = $bugsByColumnExcludedMissingBoardColumn
                    excludedUnknownColumns = $bugsByColumnExcludedUnknownColumns
                    unknownColumns = $bugsByColumnUnknownColumns
                    unknownColumnItemsSample = @($bugsByColumnExcludedItemsSample | Select-Object -First 10)
                }
                blockedByColumn = @{
                    name = 'Blocked Items by Column'
                    candidates = $blockedByColumnCandidates
                    excluded = $blockedByColumnExcluded
                    excludedPercent = $blockedByColumnExcludedPercent
                    excludedMissingBoardColumn = $blockedByColumnExcludedMissingBoardColumn
                    excludedUnknownColumns = $blockedByColumnExcludedUnknownColumns
                    unknownColumns = $blockedByColumnUnknownColumns
                    unknownColumnItemsSample = @($blockedByColumnExcludedItemsSample | Select-Object -First 10)
                }
                timeInColumn = @{
                    name = 'Time In Column'
                    candidates = $timeInColumnCandidates
                    excluded = $timeInColumnExcluded
                    excludedPercent = $timeInColumnExcludedPercent
                    excludedMissingColumnTime = $timeInColumnExcludedMissingColumnTime
                    excludedUnknownColumns = $timeInColumnExcludedUnknownColumns
                    excludedStateBased = $timeInColumnExcludedStateBased
                    unknownColumns = $timeInColumnUnknownColumns
                    unknownColumnItemsSample = $timeInColumnExcludedUnknownColumnItemsSample
                }
            }
        }
        blockers = @{
            tags = if ($config -and $config.blockers -and $config.blockers.tags) { @($config.blockers.tags) } else { @() }
            columns = if ($config -and $config.blockers -and $config.blockers.columns) { @($config.blockers.columns) } else { @() }
            categories = $blockerCategories
        }
        wipLevelDistributionDebug = $wipLevelDistributionDebug
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
            percentage = $wsePct
            class = $wseClass
            insight = $wseInsight
            trend = @{ direction = "stable"; isGood = $true }
        }
        cycleTimeFlowEfficiency = @{
            percentage = $ctfePct
            class = $ctfeClass
            insight = $ctfeInsight
            trend = @{ direction = "stable"; isGood = $true }
        }
        leadTimeFlowEfficiency = @{
            percentage = $ltfePct
            class = $ltfeClass
            insight = $ltfeInsight
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
        wipLevelDistribution = $wipLevelDistributionChart
        staleWork = @{
            labels = $staleWorkLabels
            values = $staleWorkValues
            ids = $staleWorkIds
            titles = $staleWorkTitles
            types = $staleWorkTypes
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
            itemsSeries = $blockedTimelineItemsSeries
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
            blockedItems = $blockedEventsItemsByWeek
            unblockedItems = $unblockedEventsItemsByWeek
        }
        transitionRates = @{
            labels = @()
            ratios = $transitionRateRatios
            arrivals = $transitionRateArrivals
            departures = $transitionRateDepartures
            transitions = $transitionRateTransitions
        }
    }
    
    insights = @{
        cfd = (
            "$($completedWithMetrics.Count) items completed; $($activeItems.Count) currently active (tracked types). " +
            "Backlog Growth: $($systemStabilityMetric.text) ($($systemStabilityMetric.ratio) items/week). " +
            "Daily WIP trend is $dailyWipTrendText (avg $dailyWipAvg, range $dailyWipMin-$dailyWipMax). " +
            "Use this to spot sustained growth (arrivals>departures) vs a stable system."
        )
        throughput = if ($throughputCV -gt 0.5) {
            $maxWeek = ($throughputValues | Measure-Object -Maximum).Maximum
            $minWeek = ($throughputValues | Measure-Object -Minimum).Minimum
            "Throughput averages $throughputTotal items/week but shows high variability (range: $minWeek-$maxWeek). The inconsistent delivery pattern suggests batch working - consider breaking work into smaller, more frequent releases for smoother flow."
        } elseif ($throughputCV -gt 0.3) {
            "Throughput averages $throughputTotal items/week with moderate variability. Some weeks show spikes - monitor for batch release patterns."
        } else {
            "Throughput averages $throughputTotal items/week with consistent, predictable delivery."
        }
        cycleTime = if ($cycleTimes -and $cycleTimes.Count -gt 0) {
            $avg = [Math]::Round(($cycleTimes | Measure-Object -Average).Average, 1)
            $p85 = ($cycleTimes | Sort-Object)[([Math]::Ceiling($cycleTimes.Count * 0.85) - 1)]

            $tailRatio = if ($cycleTimeMedian -gt 0) { [Math]::Round(([double]$p85 / [double]$cycleTimeMedian), 1) } else { 0 }
            $tailText = if ($tailRatio -ge 2) {
                "Long tail detected (P85 is ~$tailRatio× the median)."
            } elseif ($tailRatio -ge 1.5) {
                "Moderate tail (P85 is ~$tailRatio× the median)."
            } else {
                "Low tail (P85 close to median)."
            }

            $trendObj = Calculate-Trend -values @($cycleTimeTrendChart.values) -higherIsBetter $false
            $trendText = if ($trendObj.direction -eq 'up') { 'getting slower' } elseif ($trendObj.direction -eq 'down') { 'getting faster' } else { 'stable' }

            $typeNote = ''
            if ($cycleTimeAvgByType -and $cycleTimeAvgByType.Contains('Bugs') -and $cycleTimeAvgByType.Contains('PBIs')) {
                $b = [double]$cycleTimeAvgByType['Bugs']
                $p = [double]$cycleTimeAvgByType['PBIs']
                if ($b -gt 0 -and $p -gt 0) {
                    $diffPct = [Math]::Round((([Math]::Abs($b - $p)) / [Math]::Max($b, $p)) * 100, 0)
                    if ($diffPct -ge 30) {
                        $typeNote = " By type, Bugs vs PBIs differ materially ($diffPct%)."
                    }
                }
            }

            "Avg $avg days (median $cycleTimeMedian, P85 $p85). $tailText Trend is $trendText. Consider using WIP limits and smaller batches to pull the tail down.$typeNote"
        } else {
            'No completed items with cycle time available.'
        }

        leadTime = if ($leadTimes -and $leadTimes.Count -gt 0) {
            $avg = [Math]::Round(($leadTimes | Measure-Object -Average).Average, 1)
            $p85 = ($leadTimes | Sort-Object)[([Math]::Ceiling($leadTimes.Count * 0.85) - 1)]

            $cycleAvg = if ($cycleTimes -and $cycleTimes.Count -gt 0) { [Math]::Round(($cycleTimes | Measure-Object -Average).Average, 1) } else { 0 }
            $waitAvg = [Math]::Max(0, [Math]::Round(($avg - $cycleAvg), 1))
            $waitPct = if ($avg -gt 0) { [Math]::Round(($waitAvg / $avg) * 100, 0) } else { 0 }
            $waitText = if ($waitPct -ge 50) {
                "Waiting dominates lead time (~$waitAvg days, $waitPct%)."
            } elseif ($waitPct -ge 30) {
                "Material waiting before/around workflow (~$waitAvg days, $waitPct%)."
            } else {
                "Most lead time is spent in workflow (~$cycleAvg days; waiting ~$waitAvg days)."
            }

            $trendObj = Calculate-Trend -values @($leadTimeTrendChart.values) -higherIsBetter $false
            $trendText = if ($trendObj.direction -eq 'up') { 'getting slower' } elseif ($trendObj.direction -eq 'down') { 'getting faster' } else { 'stable' }

            "Avg $avg days (median $leadTimeMedian, P85 $p85). $waitText Trend is $trendText. If waiting is high, tighten intake/WIP and improve readiness before starting work."
        } else {
            'No completed items with lead time available.'
        }
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
        transitionRates = $transitionRatesInsightText
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
