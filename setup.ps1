# Azure DevOps MCP Server Setup Script
# This script automates the installation and configuration of the ADO MCP server for VS Code

Write-Host "=== Azure DevOps MCP Server Setup ===" -ForegroundColor Cyan
Write-Host ""

# Step 1: Get ADO Organization URL
Write-Host "Step 1: Azure DevOps Organization" -ForegroundColor Yellow
Write-Host "Enter your Azure DevOps organization URL" -ForegroundColor Gray
Write-Host "Examples:" -ForegroundColor Gray
Write-Host "  - https://dev.azure.com/your-org" -ForegroundColor Gray
Write-Host "  - https://your-org.visualstudio.com" -ForegroundColor Gray
Write-Host ""

$adoUrl = Read-Host "ADO Organization URL"

# Validate URL format
if (-not ($adoUrl -match '^https://(dev\.azure\.com/[^/]+|[^/]+\.visualstudio\.com)/?$')) {
    Write-Host "Invalid URL format. Please use the format shown in the examples above." -ForegroundColor Red
    exit 1
}

# Remove trailing slash if present
$adoUrl = $adoUrl.TrimEnd('/')

Write-Host "✓ Organization URL: $adoUrl" -ForegroundColor Green
Write-Host ""

# Step 2: Get PAT Token
Write-Host "Step 2: Personal Access Token (PAT)" -ForegroundColor Yellow
Write-Host "Enter your Azure DevOps Personal Access Token" -ForegroundColor Gray
Write-Host "Note: This will be stored securely in your Windows user environment variables" -ForegroundColor Gray
Write-Host ""

$pat = Read-Host "PAT Token" -AsSecureString
$patPlainText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pat)
)

if ([string]::IsNullOrWhiteSpace($patPlainText)) {
    Write-Host "PAT token cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host "✓ PAT token received" -ForegroundColor Green
Write-Host ""

# Step 3: Set Environment Variable
Write-Host "Step 3: Setting Environment Variable" -ForegroundColor Yellow
try {
    [System.Environment]::SetEnvironmentVariable('ADO_PAT', $patPlainText, 'User')
    Write-Host "✓ Environment variable ADO_PAT has been set" -ForegroundColor Green
} catch {
    Write-Host "✗ Failed to set environment variable: $_" -ForegroundColor Red
    exit 1
}
Write-Host ""

# Step 4: Copy Prompt Files
Write-Host "Step 4: Copying Prompt Files to VS Code" -ForegroundColor Yellow

$promptsSourceDir = Join-Path $PSScriptRoot "prompts"
$promptsDestDir = Join-Path $env:APPDATA "Code\User\prompts"

if (Test-Path $promptsSourceDir) {
    # Create destination directory if it doesn't exist
    if (-not (Test-Path $promptsDestDir)) {
        New-Item -ItemType Directory -Path $promptsDestDir -Force | Out-Null
        Write-Host "✓ Created prompts directory: $promptsDestDir" -ForegroundColor Green
    }
    
    # Copy all prompt files
    $promptFiles = Get-ChildItem -Path $promptsSourceDir -Filter "*.prompt.md"
    
    if ($promptFiles.Count -gt 0) {
        $copiedCount = 0
        foreach ($file in $promptFiles) {
            Copy-Item -Path $file.FullName -Destination $promptsDestDir -Force
            Write-Host "  ✓ Copied: $($file.Name)" -ForegroundColor Gray
            $copiedCount++
        }
        Write-Host "✓ Copied $copiedCount prompt file(s) to VS Code" -ForegroundColor Green
    } else {
        Write-Host "⚠ No .prompt.md files found in prompts folder" -ForegroundColor Yellow
    }
} else {
    Write-Host "⚠ Prompts folder not found, skipping prompt installation" -ForegroundColor Yellow
}
Write-Host ""

# Step 5: Configure MCP Server
Write-H6: Restart VS Code
Write-Host "Step 6
# Determine MCP config path
$mcpConfigPath = Join-Path $PSScriptRoot "mcp.json"

# Create MCP configuration
$mcpConfig = @{
    mcpServers = @{
        "azure-devops" = @{
            command = "npx"
            args = @(
                "-y"
                "@modelcontextprotocol/server-azure-devops"
            )
            env = @{
                AZURE_DEVOPS_ORG_URL = $adoUrl
                AZURE_DEVOPS_PAT = "`${ADO_PAT}"
            }
        }
    }
} | ConvertTo-Json -Depth 10

# Write configuration file
try {
    $mcpConfig | Out-File -FilePath $mcpConfigPath -Encoding utf8 -Force
    Write-Host "✓ MCP configuration written to: $mcpConfigPath" -ForegroundColor Green
} catch {
    Write-Host "✗ Failed to write configuration file: $_" -ForegroundColor Red
    exit 1
}
Write-Host ""

# Step 5: Restart VS Code
Write-Host "Step 5: Restart VS Code" -ForegroundColor Yellow
Write-Host "VS Code needs to be restarted for the changes to take effect." -ForegroundColor Gray
Write-Host ""
$restart = Read-Host "Would you like to restart VS Code now? (Y/N)"

if ($restart -eq 'Y' -or $restart -eq 'y') {
    Write-Host "Closing all VS Code instances..." -ForegroundColor Cyan
    
    # Close all VS Code instances
    Get-Process -Name "Code" -ErrorAction SilentlyContinue | Stop-Process -Force
    
    Start-Sleep -Seconds 2
    
    # Restart VS Code in the current directory
    Write-Host "Restarting VS Code..." -ForegroundColor Cyan
    Start-Process "code" -ArgumentList $PSScriptRoot
    
    Write-Host "✓ VS Code is restarting" -ForegroundColor Green
} else {
    Write-Host "⚠ Please manually restart VS Code to apply changes" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Setup Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Summary:" -ForegroundColor White
Write-Host "  Organization: $adoUrl" -ForegroundColor Gray
Write-Host "  Environment Variable: ADO_PAT (set)" -ForegroundColor Gray
Write-Host "  Config File: $mcpConfigPath" -ForegroundColor Gray
Write-Host "  Prompts Location: $promptsDestDir" -ForegroundColor Gray
Write-Host ""
Write-Host "After VS Code restarts:" -ForegroundColor Green
Write-Host "  - Azure DevOps MCP server will be available" -ForegroundColor Green
Write-Host "  - Custom prompts will be accessible in Copilot Chat" -ForegroundColor Green
