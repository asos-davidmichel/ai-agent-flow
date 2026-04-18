<#
.SYNOPSIS
    Extracts real columnTime data from Azure DevOps work items by analyzing state change history.

.DESCRIPTION
    For each completed work item, this script:
    1. Fetches all revisions/updates from ADO API
    2. Calculates time spent in each state (column)
    3. Returns a columnTime object mapping column names to days spent

    This is called automatically by the ado-flow prompt to get REAL data.
    NO ESTIMATES - only actual state transition history.

.PARAMETER Organization
    ADO organization name (e.g., "asos")

.PARAMETER Project
    ADO project name (e.g., "Customer")

.PARAMETER WorkItemIds
    Array of work item IDs to process

.PARAMETER PersonalAccessToken
    ADO PAT with work item read permissions. If not provided, attempts to use cached credentials.

.EXAMPLE
    $columnData = .\Get-WorkItemColumnTime.ps1 -Organization "asos" -Project "Customer" -WorkItemIds @(1170800, 1191895)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Organization,
    
    [Parameter(Mandatory = $true)]
    [string]$Project,
    
    [Parameter(Mandatory = $true)]
    [int[]]$WorkItemIds,
    
    [Parameter(Mandatory = $false)]
    [string]$PersonalAccessToken
)

# Initialize authentication
if ([string]::IsNullOrWhiteSpace($PersonalAccessToken)) {
    # Try to get from environment variables (check both common names)
    $PersonalAccessToken = $env:AZURE_DEVOPS_EXT_PAT
    if ([string]::IsNullOrWhiteSpace($PersonalAccessToken)) {
        $PersonalAccessToken = $env:ADO_PAT
    }
    if ([string]::IsNullOrWhiteSpace($PersonalAccessToken)) {
        # Try loading from user environment variables
        $PersonalAccessToken = [System.Environment]::GetEnvironmentVariable('ADO_PAT', 'User')
        if (-not [string]::IsNullOrWhiteSpace($PersonalAccessToken)) {
            $env:ADO_PAT = $PersonalAccessToken
            Write-Verbose "Auto-loaded ADO_PAT from user environment"
        }
    }
    if ([string]::IsNullOrWhiteSpace($PersonalAccessToken)) {
        Write-Error "No PAT provided. Set AZURE_DEVOPS_EXT_PAT or ADO_PAT environment variable, or pass -PersonalAccessToken parameter."
        return $null
    }
}

$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PersonalAccessToken"))
$headers = @{
    Authorization = "Basic $base64AuthInfo"
    "Content-Type" = "application/json"
}

$results = @()

foreach ($workItemId in $WorkItemIds) {
    try {
        Write-Verbose "Processing Work Item #$workItemId..."

        # Derive ClosedDate from the updates payload (avoids extra API calls and works even when work item GET is blocked)
        $closedDate = $null
        $closedDateFromStateChange = $null
        
        # Fetch all revisions for this work item
        $updatesUri = "https://dev.azure.com/$Organization/$Project/_apis/wit/workitems/$workItemId/updates?api-version=7.0"
        $updates = Invoke-RestMethod -Uri $updatesUri -Headers $headers -Method Get -ErrorAction Stop
        
        # Track board column changes with timestamps (prioritize BoardColumn over State)
        $columnHistory = @()
        
        foreach ($update in $updates.value) {
            # Skip placeholder dates (9999-01-01 means "no date" in ADO)
            $revisedDate = [DateTime]$update.revisedDate
            if ($revisedDate.Year -ge 9999) {
                Write-Verbose "  Skipping placeholder date: $($update.revisedDate)"
                continue
            }

            # Capture explicit ClosedDate if present in this revision
            if ($update.fields.PSObject.Properties.Name -contains 'Microsoft.VSTS.Common.ClosedDate') {
                $cd = $update.fields.'Microsoft.VSTS.Common.ClosedDate'.newValue
                if ($cd) {
                    try {
                        $parsed = [DateTime]$cd
                        if ($parsed.Year -lt 9999) { $closedDate = $parsed }
                    } catch {
                        # ignore parse failures
                    }
                }
            }

            # Fallback: if we see a state transition into a done/closed state, use that revision timestamp
            if (-not $closedDate -and ($update.fields.PSObject.Properties.Name -contains 'System.State')) {
                $newState = $update.fields.'System.State'.newValue
                if ($newState -in @('Closed','Done','Removed')) {
                    $closedDateFromStateChange = $revisedDate
                }
            }
            
            $fieldToUse = $null
            $newValue = $null
            
            # Check for board column field first (most accurate for Kanban boards)
            if ($update.fields.PSObject.Properties.Name -contains 'System.BoardColumn') {
                $fieldToUse = 'System.BoardColumn'
                $newValue = $update.fields.'System.BoardColumn'.newValue
            }
            # Fall back to State if no BoardColumn
            elseif ($update.fields.PSObject.Properties.Name -contains 'System.State') {
                $fieldToUse = 'System.State'
                $newValue = $update.fields.'System.State'.newValue
            }
            
            if ($fieldToUse) {
                $columnChange = @{
                    Column = $newValue
                    Field = $fieldToUse
                    Timestamp = $revisedDate  # Use pre-parsed date
                    RevisionNumber = $update.rev
                }
                $columnHistory += $columnChange
            }
        }

        if (-not $closedDate -and $closedDateFromStateChange) {
            $closedDate = $closedDateFromStateChange
        }
        
        # If no column changes found, work item might have been created in final state
        if ($columnHistory.Count -eq 0) {
            Write-Warning "No column or state changes found for work item #$workItemId. Skipping."
            continue
        }
        
        Write-Verbose "  Found $($columnHistory.Count) transitions (using field: $($columnHistory[0].Field))"

        # Ensure transitions are in chronological order (updates API order is not guaranteed)
        $columnHistory = @(
            $columnHistory |
                Sort-Object -Property @(
                    @{ Expression = { $_.Timestamp } },
                    @{ Expression = { $_.RevisionNumber } }
                )
        )

        # Remove consecutive duplicates (can happen with mixed BoardColumn/State or repeated values)
        $deduped = @()
        $lastCol = $null
        foreach ($c in $columnHistory) {
            if ([string]::IsNullOrWhiteSpace($c.Column)) { continue }
            if ($lastCol -ne $null -and $c.Column -eq $lastCol) { continue }
            $deduped += $c
            $lastCol = $c.Column
        }
        $columnHistory = $deduped
        
        # Calculate time spent in each column/state
        $columnTime = @{}
        
        for ($i = 0; $i -lt $columnHistory.Count; $i++) {
            $currentColumn = $columnHistory[$i].Column
            
            # Skip if column value is null or empty
            if ([string]::IsNullOrWhiteSpace($currentColumn)) {
                Write-Verbose "  Skipping null/empty column value at revision $($columnHistory[$i].RevisionNumber)"
                continue
            }
            
            $startTime = $columnHistory[$i].Timestamp
            
            # Determine end time (next state change, ClosedDate for completed items, or now if still active)
            if ($i -lt ($columnHistory.Count - 1)) {
                $endTime = $columnHistory[$i + 1].Timestamp
            } else {
                # This is the last recorded state - cap at ClosedDate if available, otherwise use current time
                $endTime = if ($closedDate) { $closedDate } else { Get-Date }
            }

            # Defensive: cap endTime to ClosedDate if we have one
            if ($closedDate -and $endTime -gt $closedDate) {
                $endTime = $closedDate
            }

            # Defensive: ignore invalid/negative spans
            if ($endTime -lt $startTime) {
                Write-Verbose "  Skipping negative span for '$currentColumn' (start $startTime, end $endTime)"
                continue
            }
            
            # Calculate days in this column/state
            $timeSpan = $endTime - $startTime
            $days = [Math]::Round($timeSpan.TotalDays, 1)
            
            # Accumulate time if same column/state appears multiple times
            if ($columnTime.ContainsKey($currentColumn)) {
                $columnTime[$currentColumn] += $days
            } else {
                $columnTime[$currentColumn] = $days
            }
        }
        
        # Keep 1-decimal precision (matches the dashboard's other day-based metrics)
        $roundedColumnTime = @{}
        foreach ($key in $columnTime.Keys) {
            $roundedColumnTime[$key] = [Math]::Round([double]$columnTime[$key], 1)
        }
        
        $results += @{
            WorkItemId = $workItemId
            ColumnTime = $roundedColumnTime
            TotalDays = ($roundedColumnTime.Values | Measure-Object -Sum).Sum
            StateCount = $roundedColumnTime.Count
        }
        
        $totalDays = ($roundedColumnTime.Values | Measure-Object -Sum).Sum
        Write-Verbose "  Processed work item #$workItemId - $($roundedColumnTime.Count) columns/states, $totalDays total days"
        
    } catch {
        Write-Warning "Failed to process work item #${workItemId}: $($_.Exception.Message)"
    }
}

# Return results as JSON for easy consumption
return $results | ConvertTo-Json -Depth 10
