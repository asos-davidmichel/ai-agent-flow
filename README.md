# ai-agent-flow
A collection of AI agents and prompts for flow metrics analysis with Azure DevOps integration.

## Prerequisites

- **VS Code** with **GitHub Copilot Chat** extension
- **Node.js and npm** (required for MCP servers)
- **Azure DevOps** organization access
- (Optional) **Atlassian** account for Jira/Confluence integration

## What Gets Installed

1. **Custom Prompts**: Flow metrics prompts for ADO analysis (`.prompt.md`, `.agent.md`, `.instructions.md` files)
2. **MCP Servers Configuration**: 
   - Azure DevOps MCP Server (work items, pipelines, repos)
   - Atlassian MCP Server (Jira, Confluence)

## Installation

Run the installation script in PowerShell:

```powershell
.\install-prompts.ps1
```

This will:
- Copy all prompts to `%APPDATA%\Code\User\prompts`
- Install MCP configuration to `%APPDATA%\Code\User\globalStorage\github.copilot-chat\mcp.json`
- Backup any existing MCP configuration
- Reload your VS Code window

After installation, you'll be prompted for your Azure DevOps organization name when you first use ADO-related prompts.

## Verifying Installation

After VS Code reloads:
1. Open Copilot Chat (Ctrl+Shift+I)
2. Type `@` to see available prompts (look for your custom prompts)
3. Ask: "list available MCP tools"
4. You should see `mcp_ado_*` and `mcp_com_atlassian_*` tools

**For detailed MCP troubleshooting, see [MCP-SETUP.md](MCP-SETUP.md)**

## Uninstallation

```powershell
.\uninstall-prompts.ps1
```

## Usage

Access prompts via Copilot Chat:
- Type `@` to see available custom prompts
- Use Quick Chat: Ctrl+Shift+I

MCP servers will automatically start when needed.
