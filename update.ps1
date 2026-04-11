# Update Prompts Script
# Copies prompt files from workspace to VS Code User prompts directory

Write-Host "=== Updating VS Code Prompts ===" -ForegroundColor Cyan
Write-Host ""

$promptsSourceDir = Join-Path $PSScriptRoot "prompts"
$promptsDestDir = Join-Path $env:APPDATA "Code\User\prompts"

if (-not (Test-Path $promptsDestDir)) {
    New-Item -ItemType Directory -Path $promptsDestDir -Force | Out-Null
    Write-Host "Created prompts directory: $promptsDestDir" -ForegroundColor Green
}

if (Test-Path $promptsSourceDir) {
    $promptFiles = Get-ChildItem -Path $promptsSourceDir -Filter "*.prompt.md"
    
    if ($promptFiles.Count -gt 0) {
        $copiedCount = 0
        foreach ($file in $promptFiles) {
            Copy-Item -Path $file.FullName -Destination $promptsDestDir -Force
            Write-Host "  Updated: $($file.Name)" -ForegroundColor Gray
            $copiedCount++
        }
        Write-Host ""
        Write-Host "Updated $copiedCount prompt file(s)" -ForegroundColor Green
    } else {
        Write-Host "No .prompt.md files found in prompts folder" -ForegroundColor Yellow
    }
} else {
    Write-Host "Prompts folder not found: $promptsSourceDir" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== Update Complete ===" -ForegroundColor Cyan
Write-Host "Prompts are now available in Copilot Chat" -ForegroundColor Green
