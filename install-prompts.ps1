# Install Flow Metrics Prompts to VS Code
$PromptSourceDir = Join-Path $PSScriptRoot "prompts"
$VsCodePromptsDir = "$env:APPDATA\Code\User\prompts"
$McpSourceFile = Join-Path $PSScriptRoot "mcp.json"
$McpTargetFile = "$env:APPDATA\Code\User\globalStorage\github.copilot-chat\mcp.json"

Write-Host "Installing Flow Metrics prompts and MCP configuration to VS Code..." -ForegroundColor Cyan
Write-Host "Prompts Source: $PromptSourceDir" -ForegroundColor Gray
Write-Host "Prompts Target: $VsCodePromptsDir" -ForegroundColor Gray
Write-Host "MCP Config: $McpTargetFile" -ForegroundColor Gray
Write-Host ""

if (-not (Test-Path $VsCodePromptsDir)) {
    Write-Host "Creating prompts directory..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $VsCodePromptsDir -Force | Out-Null
}

# Install MCP configuration
Write-Host "Installing MCP configuration..." -ForegroundColor Yellow
if (Test-Path $McpSourceFile) {
    $McpTargetDir = Split-Path $McpTargetFile -Parent
    if (-not (Test-Path $McpTargetDir)) {
        New-Item -ItemType Directory -Path $McpTargetDir -Force | Out-Null
    }
    
    # Check if existing mcp.json exists and back it up
    if (Test-Path $McpTargetFile) {
        $BackupFile = "$McpTargetFile.backup.$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
        Copy-Item -Path $McpTargetFile -Destination $BackupFile -Force
        Write-Host "  [INFO] Backed up existing mcp.json to: $BackupFile" -ForegroundColor Gray
    }
    
    Copy-Item -Path $McpSourceFile -Destination $McpTargetFile -Force
    Write-Host "[OK] Installed MCP configuration (Azure DevOps + Atlassian)" -ForegroundColor Green
    Write-Host "  [INFO] You may be prompted for your Azure DevOps organization on first use" -ForegroundColor Gray
} else {
    Write-Host "[SKIP] No mcp.json found in repository" -ForegroundColor Yellow
}
Write-Host ""

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
Write-Host ""
Write-Host "MCP Servers Configuration:" -ForegroundColor Cyan
Write-Host "  - Azure DevOps MCP: Provides ADO work items, pipelines, repos access" -ForegroundColor Gray
Write-Host "  - Atlassian MCP: Provides Jira and Confluence access" -ForegroundColor Gray
Write-Host ""
Write-Host "To verify MCP servers are running after reload:" -ForegroundColor Yellow
Write-Host "  1. Open Copilot Chat" -ForegroundColor Gray
Write-Host "  2. Type: 'list available MCP tools'" -ForegroundColor Gray
Write-Host "  3. You should see mcp_ado_* and mcp_com_atlassian_* tools" -ForegroundColor Gray
Write-Host ""
Write-Host "If MCP servers don't start:" -ForegroundColor Yellow
Write-Host "  - Ensure Node.js and npm are installed" -ForegroundColor Gray
Write-Host "  - Check VS Code Output panel: View > Output > GitHub Copilot Chat" -ForegroundColor Gray
Write-Host "  - MCP servers will auto-start when you first use a tool that requires them" -ForegroundColor Gray
