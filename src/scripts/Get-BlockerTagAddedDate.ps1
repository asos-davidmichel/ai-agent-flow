#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Gets the date when a blocker tag was added to work items.

.DESCRIPTION
    Queries work item revision history to find when blocker-related tags were added.
    Returns the earliest date a blocker tag was detected for each item.

.PARAMETER Organization
    Azure DevOps organization name

.PARAMETER Project
    Azure DevOps project name

.PARAMETER WorkItemIds
    Array of work item IDs to check

.PARAMETER BlockerTags
    Array of tag patterns to search for (e.g., 'blocked', 'hold')

.EXAMPLE
    .\Get-BlockerTagAddedDate.ps1 -Organization "asos" -Project "Customer" -WorkItemIds @(12345, 67890) -BlockerTags @('blocked', 'hold')
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Organization,
    
    [Parameter(Mandatory = $true)]
    [string]$Project,
    
    [Parameter(Mandatory = $true)]
    [int[]]$WorkItemIds,
    
    [Parameter(Mandatory = $true)]
    [string[]]$BlockerTags
)

# Get PAT from environment
$pat = [Environment]::GetEnvironmentVariable('ADO_PAT', 'User')
if (-not $pat) {
    Write-Error "ADO_PAT environment variable not set"
    return @()
}

$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$headers = @{
    Authorization = "Basic $base64AuthInfo"
    'Content-Type' = 'application/json'
}

$results = @()

foreach ($id in $WorkItemIds) {
    try {
        # Get all revisions for this work item
        $url = "https://dev.azure.com/$Organization/$Project/_apis/wit/workItems/$($id)/revisions?api-version=7.1"
        $response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers
        
        $blockerAddedDate = $null
        $previousTags = ""
        
        # Go through revisions chronologically to find when blocker tag was first added
        foreach ($revision in $response.value) {
            $currentTags = $revision.fields.'System.Tags'
            
            if ($currentTags) {
                # Check if any blocker tag is present in current revision but not in previous
                $hasBlockerNow = $false
                foreach ($blockerTag in $BlockerTags) {
                    if ($currentTags -like "*$blockerTag*") {
                        $hasBlockerNow = $true
                        break
                    }
                }
                
                # Check if blocker tag was in previous revision
                $hadBlockerBefore = $false
                if ($previousTags) {
                    foreach ($blockerTag in $BlockerTags) {
                        if ($previousTags -like "*$blockerTag*") {
                            $hadBlockerBefore = $true
                            break
                        }
                    }
                }
                
                # If has blocker now but didn't before, this is when it was added
                if ($hasBlockerNow -and -not $hadBlockerBefore) {
                    $blockerAddedDate = $revision.fields.'System.ChangedDate'
                    break
                }
            }
            
            $previousTags = $currentTags
        }
        
        # Calculate days blocked if we found the date
        $daysBlocked = if ($blockerAddedDate) {
            [Math]::Floor(((Get-Date) - [DateTime]$blockerAddedDate).TotalDays)
        } else {
            $null
        }
        
        $results += [PSCustomObject]@{
            id = $id
            blockerAddedDate = $blockerAddedDate
            daysBlocked = $daysBlocked
        }
        
    } catch {
        Write-Warning "Failed to get revisions for work item $($id): $_"
        $results += [PSCustomObject]@{
            id = $id
            blockerAddedDate = $null
            daysBlocked = $null
        }
    }
}

# Return as JSON
$results | ConvertTo-Json -Depth 10
