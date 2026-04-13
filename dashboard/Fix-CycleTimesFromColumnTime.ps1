#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Recalculates cycle times AND lead times from real columnTime data (NO ESTIMATES).

.DESCRIPTION
    Updates the "y" (cycle time) and "leadTime" values in dashboard-data-example.json 
    to match the REAL data from columnTime extracted from ADO.
    
    Cycle Time = Time from FIRST ACTIVE COLUMN onwards (when work actually starts)
    Lead Time = Total time in ALL columns (from creation to completion)
    
    ACTIVE columns: In Development, In Review, External Review, QA
    WAITING columns (within workflow): Ready for QA, Ready for Release
    BEFORE WORKFLOW: New, Backlog, Ready for Dev
    
    NOTE: Cycle time starts from the first ACTIVE column (e.g., In Development).
    "Ready for Dev" is considered backlog/queue time BEFORE the workflow starts.
    
    TO CUSTOMIZE FOR YOUR BOARD:
    - Review the column definitions below
    - Ensure ACTIVE columns match your board's "work in progress" states
    - First ACTIVE column = when cycle time starts
    - Move any "Ready for..." columns that come BEFORE work starts to beforeWorkflowColumns
    
.EXAMPLE
    .\Fix-CycleTimesFromColumnTime.ps1
#>

[CmdletBinding()]
param(
    [string]$DataFilePath = (Join-Path $PSScriptRoot 'dashboard-data-example.json')
)

try {
    Write-Host "Loading dashboard data from: $DataFilePath" -ForegroundColor Cyan
    $data = Get-Content $DataFilePath -Encoding UTF8 | ConvertFrom-Json
    
    # Define column categories
    # IMPORTANT: Cycle time starts from the FIRST ACTIVE COLUMN
    # Customize these for your board - ensure ACTIVE columns match when work actually starts
    $activeColumns = @('In Development', 'In Review', 'External Review', 'QA')
    $waitingColumns = @('Ready for QA', 'Ready for Release', 'Ready for release')  # Waiting states WITHIN workflow
    $beforeWorkflowColumns = @('New', 'Backlog', 'Ready for Dev')  # Before cycle time starts
    $notInWorkflowColumns = @('Closed', 'Done', 'Removed')  # After workflow ends
    
    Write-Host "`nRecalculating cycle times and lead times from REAL columnTime data..." -ForegroundColor Cyan
    Write-Host "  Cycle Time = Time from FIRST ACTIVE column (In Development) onwards" -ForegroundColor Yellow
    Write-Host "  Lead Time = ALL columns (total time)" -ForegroundColor Yellow
    
    $cycleTimeUpdates = 0
    $leadTimeUpdates = 0
    $skippedCount = 0
    
    foreach ($dataset in $data.charts.cycleTime.datasets) {
        Write-Host "`nProcessing [$($dataset.label)]:" -ForegroundColor Yellow
        
        foreach ($item in $dataset.data) {
            if (-not $item.columnTime) {
                Write-Verbose "  #$($item.id): No columnTime data - skipping"
                $skippedCount++
                continue
            }
            
            # Calculate time by iterating through actual columnTime properties
            $activeTime = 0
            $waitingTime = 0
            $beforeWorkflowTime = 0
            $afterWorkflowTime = 0
            
            foreach ($prop in $item.columnTime.PSObject.Properties) {
                $columnName = $prop.Name
                $days = $prop.Value
                
                # Categorize by column name (case-insensitive matching)
                if ($activeColumns -contains $columnName) {
                    $activeTime += $days
                } 
                elseif ($waitingColumns -contains $columnName) {
                    $waitingTime += $days
                }
                elseif ($beforeWorkflowColumns -contains $columnName) {
                    $beforeWorkflowTime += $days
                }
                elseif ($notInWorkflowColumns -contains $columnName) {
                    $afterWorkflowTime += $days
                }
                else {
                    Write-Warning "  #$($item.id): Unknown column '$columnName' with $days days - treating as BEFORE WORKFLOW"
                    $beforeWorkflowTime += $days
                }
            }
            
            # Cycle Time = ACTIVE + WAITING (from first active column onwards)
            # Does NOT include "Ready for Dev" which is before workflow starts
            $cycleTime = $activeTime + $waitingTime
            
            # Lead Time = Total time in ALL columns
            $totalTime = $beforeWorkflowTime + $activeTime + $waitingTime + $afterWorkflowTime
            
            $oldCycleTime = $item.y
            $oldLeadTime = $item.leadTime
            
            # Update cycle time if needed
            if ($oldCycleTime -ne $cycleTime) {
                Write-Host "  #$($item.id): Cycle time $oldCycleTime -> $cycleTime days (Active=$activeTime + Waiting=$waitingTime)" -ForegroundColor Green
                $item.y = $cycleTime
                $cycleTimeUpdates++
            }
            
            # Update lead time if needed
            if ($oldLeadTime -ne $totalTime) {
                Write-Host "  #$($item.id): Lead time $oldLeadTime -> $totalTime days" -ForegroundColor Cyan
                $item.leadTime = $totalTime
                $leadTimeUpdates++
            }
            
            if ($oldCycleTime -eq $cycleTime -and $oldLeadTime -eq $totalTime) {
                Write-Verbose "  #$($item.id): Already correct (cycle=$cycleTime, lead=$totalTime)"
            }
        }
    }
    
    Write-Host "`n=== Summary ===" -ForegroundColor Cyan
    Write-Host "  Cycle times updated: $cycleTimeUpdates" -ForegroundColor Green
    Write-Host "  Lead times updated: $leadTimeUpdates" -ForegroundColor Cyan
    Write-Host "  Items skipped (no columnTime): $skippedCount" -ForegroundColor Yellow
    
    $totalUpdates = $cycleTimeUpdates + $leadTimeUpdates
    
    if ($totalUpdates -gt 0) {
        Write-Host "`nSaving updated data..." -ForegroundColor Cyan
        $jsonOutput = $data | ConvertTo-Json -Depth 100
        [System.IO.File]::WriteAllText($DataFilePath, $jsonOutput, [System.Text.UTF8Encoding]::new($false))
        Write-Host "Data saved successfully!" -ForegroundColor Green
        Write-Host "`nCycle Time = ACTIVE + WAITING (workflow time)" -ForegroundColor Green
        Write-Host "Lead Time = Total time (ALL columns)" -ForegroundColor Green
        Write-Host "All data uses REAL columnTime (NO ESTIMATES)" -ForegroundColor Green
    } else {
        Write-Host "`nNo updates needed - all data already correct" -ForegroundColor Green
    }
    
} catch {
    Write-Error "Failed to fix times: $($_.Exception.Message)"
    exit 1
}
