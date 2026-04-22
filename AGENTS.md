# AI Agent Instructions for Flow Metrics Project

This file provides concise, actionable guidance for AI coding agents working in this codebase. It links to key documentation and highlights project-specific conventions and workflows.

---

## Key Documentation

- [Board Configuration Guide](src/config/README.md): Explains how to define board-specific workflow semantics and JSON config structure.
- [Dashboard Setup & Usage](src/docs/dashboard-README.md): Step-by-step instructions for generating and verifying the interactive flow metrics dashboard, including authentication and automation details.

---

## Project Structure & Conventions

- **Scripts:** All automation is handled via PowerShell scripts in `src/scripts/`. Key scripts:
  - `Generate-FlowDashboard.ps1`: Main entry point for dashboard generation.
  - `Discover-BoardStates.ps1`: Discovers board columns and states.
  - `Get-WorkItemColumnTime.ps1`, `Build-DashboardData.ps1`: Extract and process work item data.
- **Prompts:** The `src/prompts/` directory contains prompt files for agent workflows. The main entry point is `ado-flow.prompt.md`.
- **Configuration:** Board-specific config files must follow the schema in `src/config/board-config.schema.json` and naming conventions described in the config README.

---

## Agent Workflow (ado-flow)

- Always follow the interactive configuration workflow in `ado-flow.prompt.md`.
- Never skip user input for board structure, cycle/lead time boundaries, or done columns—even if a config file exists.
- Use the comprehensive blocked patterns provided in the prompt; do not ask the user to define them.
- Save all generated configs to a dated output folder as described in the prompt.
- Run scripts using PowerShell and check for required environment variables (e.g., `ADO_PAT`).
- Open the generated dashboard HTML file for the user and provide a summary.

---

## Common Pitfalls

- Do not assume default values for board configuration—always confirm with the user interactively.
- If authentication fails, prompt the user to run `setup.ps1` and restart VS Code.
- Use plain language and British English for all user-facing insights and summaries.

---

## Links

- [Board Config README](src/config/README.md)
- [Dashboard README](src/docs/dashboard-README.md)
- [ado-flow Prompt](src/prompts/ado-flow.prompt.md)

---

For further improvements, consider creating skills for:
- Custom insight generation rules
- Automated test/validation of dashboard output
- Onboarding new board configurations
