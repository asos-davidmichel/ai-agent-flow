# Board Configuration Files

This directory contains board-specific configuration files that define workflow semantics for flow metrics calculations.

## Purpose

Different teams have different board structures, column names, and state definitions. Configuration files allow the flow metrics tools to adapt to each team's workflow without hard-coded assumptions.

## File Format

Configurations are stored as JSON files following the `board-config.schema.json` schema.

### File Naming Convention

```
{organization}-{project}-{team-slug}.json
```

Example:
```
asos-customer-analytics-experimentation.json
```

## Configuration Structure

### 1. Board Identity
```json
{
  "organization": "asos",
  "project": "Customer",
  "team": "Analytics and Experimentation",
  "boardName": "Analytics and Experimentation"
}
```

### 2. Column Categorization

Categorize board columns into workflow stages:

```json
{
  "columns": {
    "backlog": ["New", "Ready for Dev"],
    "inProgress": ["In Development", "In Review", "QA"],
    "done": ["Closed"]
  }
}
```

- **backlog**: Work not yet started (waiting, planned, queued)
- **inProgress**: Active development work
- **done**: Completed work

### 3. State Definitions

Define which work item states represent active vs completed work:

```json
{
  "states": {
    "active": {
      "excludeStates": ["Closed", "Done", "Removed"]
    },
    "completed": {
      "includeStates": ["Closed", "Done"]
    },
    "notes": {
      "Resolved": "Included in active - awaiting QA verification"
    }
  }
}
```

**Key Insight:** "Resolved" often means "fixed but not verified" - it should be **active** (not completed).

### 4. Metric Boundaries

Define how metrics are calculated:

```json
{
  "metrics": {
    "cycleTime": {
      "startColumn": "In Development",
      "startDescription": "When work enters active development",
      "endState": "Closed",
      "endDescription": "When work is fully completed"
    },
    "leadTime": {
      "startType": "boardEntry",
      "startColumn": "New",
      "endState": "Closed"
    }
  }
}
```

**Cycle Time** - Active work duration:
- **Start**: First entry into an "inProgress" column
- **End**: Reaches a "done" state

**Lead Time** - Total time to delivery:
- **startType** options:
  - `creation`: From System.CreatedDate
  - `boardEntry`: From entering first board column
  - `backlogExit`: From leaving last backlog column

## Usage

### Generate Configuration with Prompt

Use the `/ado-board-config` prompt to interactively create a configuration:

1. Provide your board URL
2. Answer categorization questions
3. Save the generated configuration

### Use Configuration with Scripts

Pass configuration file to scripts:

```powershell
.\Generate-FlowDashboard.ps1 `
  -Organization "asos" `
  -Project "Customer" `
  -Team "Analytics and Experimentation" `
  -ConfigFile ".\config\asos-customer-analytics-experimentation.json" `
  -Months 3
```

Without a config file, scripts use sensible defaults:
- Active states: NOT IN ('Closed', 'Done', 'Removed')
- Completed states: IN ('Closed', 'Done')
- Cycle time: From first column change to closed

## Common Patterns

### Pattern 1: Scrum Board
```json
{
  "columns": {
    "backlog": ["New", "To Do", "Ready"],
    "inProgress": ["In Progress", "In Review"],
    "done": ["Done"]
  },
  "states": {
    "active": { "excludeStates": ["Done", "Removed"] },
    "completed": { "includeStates": ["Done"] }
  }
}
```

### Pattern 2: Kanban with QA
```json
{
  "columns": {
    "backlog": ["New", "Backlog", "Ready for Dev"],
    "inProgress": ["Development", "Code Review", "QA", "Ready for Deploy"],
    "done": ["Deployed", "Closed"]
  },
  "states": {
    "active": { "excludeStates": ["Closed", "Removed"] },
    "completed": { "includeStates": ["Closed"] }
  }
}
```

### Pattern 3: Resolved ≠ Done
```json
{
  "states": {
    "active": { 
      "excludeStates": ["Closed", "Done", "Removed"]
    },
    "completed": { 
      "includeStates": ["Closed", "Done"]
    },
    "notes": {
      "Resolved": "Bugs marked Resolved are still in QA/verification - counted as active"
    }
  }
}
```

## Validation

The schema includes validation for:
- Required fields (organization, project, team, states, metrics)
- Valid startType values for lead time
- Array types for states and columns

Use VS Code's JSON schema validation to catch errors while editing.

## Example: Analytics and Experimentation Team

See [board-config.example.json](./board-config.example.json) for a complete example based on the Analytics and Experimentation team's workflow.

## Creating Your First Config

1. Run `/ado-board-config` with your board URL
2. Answer the categorization questions
3. Review the generated configuration
4. Save to `config/{org}-{project}-{team}.json`
5. Use with dashboard generation scripts

## Updating Configurations

When your board structure changes:
1. Re-run `/ado-board-config` to fetch current columns/states
2. Update categorizations as needed
3. Document changes in git commit message
4. Regenerate dashboards with updated config
