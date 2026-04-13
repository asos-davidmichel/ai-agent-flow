#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Regenerates the dashboard HTML from template and data with proper UTF-8 encoding.

.DESCRIPTION
    Injects data from dashboard-data-example.json into dashboard-template.html
    and outputs dashboard.html with proper UTF-8 encoding to preserve emojis.

.EXAMPLE
    .\Regenerate-Dashboard.ps1
#>

[CmdletBinding()]
param()

try {
    $templatePath = Join-Path $PSScriptRoot 'dashboard-template.html'
    $dataPath = Join-Path $PSScriptRoot 'dashboard-data.json'
    $outputPath = Join-Path $PSScriptRoot 'dashboard.html'

    if (-not (Test-Path $templatePath)) {
        throw "Template file not found: $templatePath"
    }

    if (-not (Test-Path $dataPath)) {
        throw "Data file not found: $dataPath"
    }

    Write-Verbose "Reading template from: $templatePath"
    $template = Get-Content $templatePath -Raw -Encoding UTF8

    Write-Verbose "Reading data from: $dataPath"
    $data = Get-Content $dataPath -Raw -Encoding UTF8

    Write-Verbose "Injecting data into template..."
    $dashboard = $template -replace '/\* DATA_PLACEHOLDER \*/', $data

    Write-Verbose "Writing dashboard to: $outputPath"
    # Use .NET File.WriteAllText with UTF8Encoding(false) for proper emoji support
    [System.IO.File]::WriteAllText($outputPath, $dashboard, [System.Text.UTF8Encoding]::new($false))

    $size = (Get-Item $outputPath).Length
    Write-Host "Dashboard regenerated successfully: $outputPath ($size bytes)" -ForegroundColor Green

} catch {
    Write-Error "Failed to regenerate dashboard: $($_.Exception.Message)"
    exit 1
}
