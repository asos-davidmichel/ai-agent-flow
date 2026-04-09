# MCP Servers Setup Guide

## What are MCP Servers?

Model Context Protocol (MCP) servers provide external tool capabilities to AI agents. This repository uses:

- **Azure DevOps MCP**: Access to work items, boards, repos, pipelines
- **Atlassian MCP**: Access to Jira and Confluence

## Automatic Installation

The `install-prompts.ps1` script automatically installs the MCP configuration to:
```
%APPDATA%\Code\User\globalStorage\github.copilot-chat\mcp.json
```

## How MCP Servers Start

MCP servers are **automatically started** by VS Code when:
1. VS Code reads the `mcp.json` configuration file
2. You reload the VS Code window after installation
3. A prompt or agent tries to use an MCP tool

**You don't need to manually start them.**

## Verifying MCP Servers are Running

After installation and VS Code reload:

### Method 1: Ask Copilot
1. Open Copilot Chat (Ctrl+Shift+I)
2. Ask: "list available MCP tools"
3. You should see tools like:
   - `mcp_ado_wit_get_work_item`
   - `mcp_ado_wit_list_backlog_work_items`
   - `mcp_com_atlassian_getJiraIssue`
   - etc.

### Method 2: Check VS Code Output
1. Go to: **View → Output**
2. Select: **GitHub Copilot Chat** from the dropdown
3. Look for lines like:
   ```
   [MCP] Starting server: ado
   [MCP] Server started successfully: ado
   ```

### Method 3: Use a Prompt
Simply use one of the flow metrics prompts (e.g., `@ado-flow`). If the MCP server isn't running, you'll see an error and can troubleshoot.

## First-Time Setup

When you first use ADO-related prompts, you'll be prompted for:
- **Azure DevOps Organization**: Your organization name (e.g., `contoso` from `https://dev.azure.com/contoso`)

This is stored for subsequent uses.

## Troubleshooting

### MCP Servers Don't Start

**Check Prerequisites:**
- Ensure **Node.js** and **npm** are installed
- Run: `node --version` and `npm --version`

**Check Configuration:**
- Verify `mcp.json` exists at: `%APPDATA%\Code\User\globalStorage\github.copilot-chat\mcp.json`
- Ensure the JSON is valid (no syntax errors)

**Check VS Code Output:**
- View → Output → GitHub Copilot Chat
- Look for error messages related to MCP servers

**Reload VS Code:**
```
Ctrl+R or View → Command Palette → Developer: Reload Window
```

### Authentication Issues

**Azure DevOps:**
- Ensure you're logged into Azure DevOps in your browser
- The MCP server uses your VS Code authentication
- If prompted, authorize the MCP server to access your ADO organization

**Atlassian:**
- Similar browser-based authentication
- You may need to authorize access to your Jira/Confluence instance

## Manual MCP Configuration

If you prefer to manually configure MCP servers, edit:
```
%APPDATA%\Code\User\globalStorage\github.copilot-chat\mcp.json
```

Example:
```json
{
  "servers": {
    "ado": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@azure-devops/mcp@latest", "YOUR_ORG_NAME"]
    }
  }
}
```

## How Prompts Check for MCP Tools

The prompts include `tools: ["mcp_ado_*"]` in their YAML frontmatter:

```yaml
---
name: "ado-flow"
tools: ["mcp_ado_*"]
---
```

This tells VS Code Copilot that:
1. This prompt requires MCP tools matching `mcp_ado_*`
2. If tools aren't available, Copilot will attempt to start the server
3. If the server can't start, you'll see an error message

## Advanced: Domain-Specific Configuration

The Azure DevOps MCP server supports domain filtering to limit which capabilities are loaded:

```json
"args": [
  "-y",
  "@azure-devops/mcp@latest",
  "YOUR_ORG",
  "-d", "work-items",
  "-d", "pipelines"
]
```

Available domains:
- `core`
- `work`
- `work-items`
- `repositories`
- `pipelines`
- `wiki`
- `test-plans`
- `search`
- `advanced-security`

By default (no `-d` flags), all domains are enabled.

## Uninstalling

Run `uninstall-prompts.ps1` and choose to remove the MCP configuration when prompted.
