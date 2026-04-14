#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Complete automated workflow to generate flow metrics dashboard from ADO data.

.DESCRIPTION
    This is the MASTER SCRIPT that orchestrates the entire workflow:
    1. Fetches raw data from Azure DevOps (or uses existing)
    2. Processes it into dashboard format with all charts
    3. Extracts columnTime from state transitions
    4. Generates final dashboard HTML
    
    This script is designed to be called by the ado-flow prompt for a fully automated workflow.

.PARAMETER Organization
    ADO organization name (e.g., "asos")

.PARAMETER Project
    ADO project name (e.g., "Customer")

.PARAMETER Team
    Team name (e.g., "Analytics and Experimentation")

.PARAMETER Months
    Number of months to analyze (default: 3)

.PARAMETER SkipFetch
    Skip fetching new data from ADO and use existing flow-data file

.EXAMPLE
    .\Generate-FlowDashboard.ps1 -Organization "asos" -Project "Customer" -Team "Analytics and Experimentation" -Months 3
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Organization,
    
    [Parameter(Mandatory = $true)]
    [string]$Project,
    
    [Parameter(Mandatory = $true)]
    [string]$Team,
    
    [Parameter(Mandatory = $false)]
    [int]$Months = 3,
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipFetch
)

$ErrorActionPreference = "Stop"

# Create dated output folder
$dateStamp = Get-Date -Format 'yyyy-MM-dd'
$projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$outputFolder = Join-Path $projectRoot "output\analysis-$dateStamp"

if (-not (Test-Path $outputFolder)) {
    New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null
    Write-Host "Created output folder: analysis-$dateStamp" -ForegroundColor Green
}

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Flow Metrics Dashboard Generator" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Output: analysis-$dateStamp/" -ForegroundColor White
Write-Host ""

# Step 1: Fetch data or use existing
$flowDataPath = Join-Path $outputFolder "flow-data-$dateStamp.json"

if (-not $SkipFetch) {
    Write-Host "[1/4] Fetching data from Azure DevOps..." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot "Fetch-TeamFlowData.ps1") `
        -Organization $Organization `
        -Project $Project `
        -Team $Team `
        -Months $Months `
        -OutputPath $flowDataPath
        
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to fetch data from ADO"
        exit 1
    }
} else {
    Write-Host "[1/4] Using existing data: $flowDataPath" -ForegroundColor Yellow
    if (-not (Test-Path $flowDataPath)) {
        Write-Error "Flow data file not found: $flowDataPath"
        exit 1
    }
}

# Step 2: Process into dashboard format with Get-WorkItemColumnTime
Write-Host "`n[2/4] Processing data and calculating columnTime..." -ForegroundColor Yellow

$rawData = Get-Content $flowDataPath -Raw | ConvertFrom-Json

# Extract completed item IDs
$completedIds = $rawData.completedItems | ForEach-Object { $_.id }

if ($completedIds.Count -eq 0) {
    Write-Warning "No completed items found in the data"
}

# Call the Get-WorkItemColumnTime.ps1 script
$columnTimeJson = & (Join-Path $PSScriptRoot "Get-WorkItemColumnTime.ps1") `
    -Organization $Organization `
    -Project $Project `
    -WorkItemIds $completedIds

# Parse JSON result
$columnTimeData = $columnTimeJson | ConvertFrom-Json

Write-Host "  [OK] Calculated columnTime for $($columnTimeData.Count) items" -ForegroundColor Green

# Step 3: Build dashboard data structure
Write-Host "`n[3/4] Building dashboard data structure..." -ForegroundColor Yellow

# Import the comprehensive dashboard builder
& (Join-Path $PSScriptRoot "Build-DashboardData.ps1") `
    -FlowDataPath $flowDataPath `
    -ColumnTimeData $columnTimeData `
    -OutputPath (Join-Path $outputFolder "dashboard-data.json")

# Step 4: Generate HTML
Write-Host "`n[4/4] Generating dashboard HTML..." -ForegroundColor Yellow

# Read template from src/templates/ folder
$templatesPath = Join-Path (Split-Path $PSScriptRoot -Parent) "templates"
$templateSource = Join-Path $templatesPath "dashboard-template.html"
$dataPath = Join-Path $outputFolder "dashboard-data.json"
$dashboardPath = Join-Path $outputFolder "dashboard.html"

# Generate HTML in output folder
Write-Verbose "Reading template from: $templateSource"
$template = Get-Content $templateSource -Raw -Encoding UTF8

Write-Verbose "Reading data from: $dataPath"
$data = Get-Content $dataPath -Raw -Encoding UTF8

Write-Verbose "Injecting data into template..."
$dashboard = $template -replace '/\* DATA_PLACEHOLDER \*/', $data

Write-Verbose "Writing dashboard to: $dashboardPath"
[System.IO.File]::WriteAllText($dashboardPath, $dashboard, [System.Text.UTF8Encoding]::new($false))

$size = (Get-Item $dashboardPath).Length
Write-Host "  [OK] Dashboard generated: $dashboardPath ($size bytes)" -ForegroundColor Green

Write-Host "`n=====================================" -ForegroundColor Green
Write-Host "  Dashboard generated successfully!" -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Green
Write-Host "  Dashboard: $dashboardPath" -ForegroundColor White
Write-Host ""
