# Install Flow Metrics Prompts to VS Code
$PromptSourceDir = Join-Path $PSScriptRoot "prompts"
$VsCodePromptsDir = "$env:APPDATA\Code\User\prompts"

Write-Host "Installing Flow Metrics prompts to VS Code..." -ForegroundColor Cyan
Write-Host "Source: $PromptSourceDir" -ForegroundColor Gray
Write-Host "Target: $VsCodePromptsDir" -ForegroundColor Gray
Write-Host ""

if (-not (Test-Path $VsCodePromptsDir)) {
    Write-Host "Creating prompts directory..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $VsCodePromptsDir -Force | Out-Null
}

$FilesToCopy = @()
$FilesToCopy += Get-ChildItem -Path $PromptSourceDir -Filter "*.prompt.md" -File
$FilesToCopy += Get-ChildItem -Path $PromptSourceDir -Filter "*.agent.md" -File
$FilesToCopy += Get-ChildItem -Path $PromptSourceDir -Filter "*.instructions.md" -File

$CopiedCount = 0
$ErrorCount = 0

foreach ($File in $FilesToCopy) {
    try {
        $TargetPath = Join-Path $VsCodePromptsDir $File.Name
        Copy-Item -Path $File.FullName -Destination $TargetPath -Force
        Write-Host "[OK] Installed: $($File.Name)" -ForegroundColor Green
        $CopiedCount++
    }
    catch {
        Write-Host "[FAIL] Failed to install: $($File.Name)" -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        $ErrorCount++
    }
}

Write-Host ""
Write-Host "Installation complete!" -ForegroundColor Cyan
Write-Host "Installed: $CopiedCount file(s)" -ForegroundColor Green

if ($ErrorCount -gt 0) {
    Write-Host "Errors: $ErrorCount file(s)" -ForegroundColor Red
}

Write-Host ""
Write-Host "Reloading VS Code window..." -ForegroundColor Yellow

$VsCodeCli = "code"
try {
    & $VsCodeCli --command workbench.action.reloadWindow 2>$null
    Write-Host "[OK] VS Code window reloaded successfully!" -ForegroundColor Green
}
catch {
    Write-Host "[WARN] Could not automatically reload VS Code." -ForegroundColor Yellow
    Write-Host "  Please manually reload: Ctrl+R or run Developer: Reload Window" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Access prompts via Copilot chat by typing @ or using Quick Chat (Ctrl+Shift+I)." -ForegroundColor Gray
