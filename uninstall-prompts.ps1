# Uninstall Flow Metrics Prompts from VS Code
# This script removes all prompt and agent files from VS Code's user prompts folder

$PromptSourceDir = Join-Path $PSScriptRoot "prompts"
$VsCodePromptsDir = "$env:APPDATA\Code\User\prompts"

Write-Host "Uninstalling Flow Metrics prompts from VS Code..." -ForegroundColor Cyan
Write-Host "Target: $VsCodePromptsDir" -ForegroundColor Gray
Write-Host ""

if (-not (Test-Path $VsCodePromptsDir)) {
    Write-Host "Prompts directory doesn't exist. Nothing to uninstall." -ForegroundColor Yellow
    exit
}

# Find all prompt and agent files in the source
$FilesToRemove = @(
    Get-ChildItem -Path $PromptSourceDir -Filter "*.prompt.md"
    Get-ChildItem -Path $PromptSourceDir -Filter "*.agent.md"
    Get-ChildItem -Path $PromptSourceDir -Filter "*.instructions.md"
)

$RemovedCount = 0
$NotFoundCount = 0

foreach ($File in $FilesToRemove) {
    $TargetPath = Join-Path $VsCodePromptsDir $File.Name
    
    if (Test-Path $TargetPath) {
        try {
            Remove-Item -Path $TargetPath -Force
            Write-Host "✓ Removed: $($File.Name)" -ForegroundColor Green
            $RemovedCount++
        }
        catch {
            Write-Host "✗ Failed to remove: $($File.Name)" -ForegroundColor Red
            Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    else {
        Write-Host "- Not found: $($File.Name)" -ForegroundColor Gray
        $NotFoundCount++
    }
}

Write-Host ""
Write-Host "Uninstallation complete!" -ForegroundColor Cyan
Write-Host "Removed: $RemovedCount file(s)" -ForegroundColor Green

if ($NotFoundCount -gt 0) {
    Write-Host "Not found: $NotFoundCount file(s)" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Restart VS Code or reload the window to complete the removal." -ForegroundColor Yellow
