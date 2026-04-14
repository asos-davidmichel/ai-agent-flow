# Flow Metrics Dashboard

Interactive HTML dashboard for Azure DevOps agile flow metrics with **automated real data extraction**.

## 🚀 Quick Start

**The dashboard is fully automated** - just run the `ado-flow` prompt!

```
@ado-flow https://dev.azure.com/asos/Customer/_boards/board/t/Analytics%20%26%20Experimentation%20(Customer)/Backlog%20items
```

The prompt will automatically:
- ✅ Extract all metrics from your ADO board
- ✅ Call background scripts to get real `columnTime` data
- ✅ Generate interactive HTML dashboard
- ✅ Display efficiency metrics with real data (no estimates)

---

## 📁 Files

- **dashboard-template.html** - Reusable template with `/* DATA_PLACEHOLDER */` injection point
- **dashboard-data.json** - Generated dashboard data with real metrics
- **dashboard.html** - Generated dashboard (template + data)
- **Get-WorkItemColumnTime.ps1** - Extracts real column time from ADO Work Items API
- **Build-DashboardData.ps1** - Processes raw data and builds complete dashboard structure

---

## ⚙️ Setup (One-Time)

### Configure ADO Authentication

The automated scripts need an ADO Personal Access Token (PAT) to fetch work item history:

**1. Create PAT:**
- Go to: https://dev.azure.com/asos/_usersSettings/tokens
- Click "New Token"
- Name: "Flow Metrics Dashboard"
- Scope: **Work Items (Read)**
- Copy the generated token

**2. Set environment variable:**

```powershell
# Set permanently (recommended)
[System.Environment]::SetEnvironmentVariable('AZURE_DEVOPS_EXT_PAT', 'your-pat-here', 'User')

# Verify
$env:AZURE_DEVOPS_EXT_PAT
```

**That's it!** Next time you run `ado-flow`, it will automatically extract real columnTime data.

---

## 📊 What Gets Automated

### Efficiency Metrics (Now 100% Real Data)

The dashboard calculates three efficiency metrics using **real state change history** from ADO:

1. **Work Start Efficiency** - (Cycle Time / Lead Time) × 100%
   - Shows % of total time spent in workflow vs backlog

2. **Cycle Time Flow Efficiency** - (Active Time / Cycle Time) × 100%
   - Shows % of workflow time actively working vs waiting between stages

3. **Lead Time Flow Efficiency** - (Active Time / Lead Time) × 100%
   - Shows % of total time actively working

**All calculated from real columnTime data - NO ESTIMATES.**

---

## 🔧 How Automation Works

When you run the `ado-flow` prompt:

**Step 1:** Prompt collects metrics from your ADO board
```
- Throughput, Cycle Time, Lead Time
- WIP, Blocked Items, Bug Rate
- All completed work item IDs
```

**Step 2:** Background script extracts columnTime (automatic)
```powershell
Get-WorkItemColumnTime.ps1
  ├─ Fetch work item revisions from ADO API
  ├─ Calculate time spent in each state
  └─ Return columnTime objects
```

**Step 3:** Build complete dashboard data structure (automatic)
```powershell
Build-DashboardData.ps1
  ├─ Process raw ADO data
  ├─ Calculate all flow metrics
  ├─ Integrate columnTime data
  ├─ Build chart data structures
  └─ Save dashboard-data.json
```

**Step 4:** Dashboard generates with real data
```
Template + dashboard-data.json = HTML Dashboard with accurate metrics
```

---

## 🎯 Efficiency Metrics Status

**Before PAT setup:**
- Efficiency metrics show **"N/A - No columnTime data"**
- All other metrics work normally

**After PAT setup:**
- Efficiency metrics show **real percentages** calculated from actual state transitions
- Example: "82.6% - Items spend 82.6% of workflow time actively working"

---

## 📖 Manual Usage (Optional)

If you want to run the scripts manually:

```powershell
# Run the full dashboard generation
cd src\scripts
.\Generate-FlowDashboard.ps1 `
    -Organization "asos" `
    -Project "Customer" `
    -Team "Analytics and Experimentation" `
    -Months 3
```

But the easiest way is to just use the `@ado-flow` prompt!

---

## ✅ Verification

After running the prompt, check:

**1. Efficiency metrics populated:**
- Open dashboard.html
- Go to "Efficiency" tab
- Should show percentages (not "N/A")

**2. Per-column tooltips:**
- Hover over any bar in efficiency charts
- Should see: "New: 22 days, Ready for Dev: 2 days, In Development: 8 days..." etc.

**3. Data file updated:**
- Open dashboard-data-example.json (or flow_metrics_data.json)
- Find completed items in cycleTimeTrend.datasets[].data
- Each should have `columnTime` object with days per column

---

## 🐛 Troubleshooting

**Efficiency metrics show "N/A":**
- ✅ Check PAT is set: `$env:AZURE_DEVOPS_EXT_PAT`
- ✅ Verify PAT has "Work Items (Read)" scope
- ✅ Check PAT hasn't expired

**Scripts fail silently:**
- Run manually with `-Verbose` flag to see errors:
  ```powershell
  .\Get-WorkItemColumnTime.ps1 -Organization "asos" -Project "Customer" -WorkItemIds @(123) -Verbose
  ```

**columnTime doesn't sum to lead time:**
- Some items may skip states or have data gaps
- Scripts calculate from actual revisions - gaps mean no time logged in that state

---

## 📚 Documentation

- **[HOW-TO-GET-REAL-DATA.md](HOW-TO-GET-REAL-DATA.md)** - Technical details on automated extraction
- **[prompts/ado-flow.prompt.md](../prompts/ado-flow.prompt.md)** - Full prompt documentation including automation workflow

---

## 🎉 Benefits

- ✅ **No manual data entry** - Everything automated
- ✅ **No estimates** - Only real ADO data
- ✅ **Transparent** - See exactly where time was spent
- ✅ **Actionable** - Identify real bottlenecks and waiting patterns
- ✅ **Reproducible** - Re-run anytime for updated metrics

---

## 🎨 Dashboard Features

### Interactive Work Item Links

All charts with work items are clickable - click any ID to open the item in ADO

### Persistent Tooltips

Tooltips stay visible when you hover over them, letting you click the ID links

### 6 Tab Structure

1. **Time Metrics** - Throughput, Cycle Time, Lead Time
2. **Efficiency** - Work Start, Cycle Time Flow, Lead Time Flow (with real columnTime data)
3. **Flow & System** - CFD, Net Flow, Stale Work, State Distribution
4. **WIP Tracking** - Daily WIP, Age Breakdown, Time in Column
5. **Aging Analysis** - Work Item Age by State
6. **Blocked Items** - Blocked work analysis

### Column Categorization

The Efficiency tab shows how workflow columns are classified:
- ✓ **ACTIVE** - Work is actively happening (In Development, In Review, QA, etc.)
- ⏸ **WAITING** - Queued, waiting to be picked up (Ready for Dev, Ready for QA, etc.)
- ⊗ **NOT IN WORKFLOW** - Backlog (New) or Complete (Closed)

### Trend Indicators

All metric cards show trend arrows (↑ ↓ →) comparing recent performance to moving average
# Flow Metrics Dashboard Template

This directory contains a reusable template system for generating interactive flow metrics dashboards from Azure DevOps data.

## Files

- **dashboard-template.html** - Reusable HTML template with Chart.js visualizations
- **dashboard-data-example.json** - Sample data structure for testing
- **README.md** - This documentation file

**Related files:**
- **../prompts/ado-flow.prompt.md** - Agent prompt that uses the template
- **../flow_metrics_dashboard.html** - Generated dashboard (created by prompt, in workspace root)

## How It Works

### Template System

The template uses a data injection approach:

1. **Template Structure**: `dashboard-template.html` contains all HTML, CSS, and JavaScript for rendering the dashboard
2. **Data Placeholder**: Template has a `/* DATA_PLACEHOLDER */` marker where data is injected
3. **Data Object**: A JSON object containing all metrics, chart data, and insights
4. **Generation**: The prompt reads the template, prepares the data, and replaces the placeholder

### Dashboard Features

✅ **Interactive Work Item Links:**

All charts displaying work item data include clickable links to Azure DevOps:
- **Throughput Chart**: Hover over points to see tooltip with all completed items and clickable ID links
- **Cycle Time Chart**: Hover points to see persistent tooltip with clickable ID link (shows active work duration)
- **Lead Time Chart**: Hover points to see persistent tooltip with clickable ID link (shows total time in system)
- **Flow Efficiency Chart**: Hover points to see persistent tooltip with clickable ID link (shows efficiency ratio)
- **Work Item Age Chart**: Hover dots to see persistent tooltip with clickable ID link (shows item age by state)
- **Stale Work Chart**: Hover bars to see persistent tooltip with clickable ID link (shows days since update)
- **Aging Work In Progress**: Hover bars to see persistent tooltip with clickable ID link

✅ **Trend Lines:**

The Cumulative Flow Diagram includes trend lines:
- **Pre-calculated linear trends** overlay on arrivals and departures
- Red dashed line perfectly aligns with the arrivals curve
- Green dashed line perfectly aligns with the departures curve
- Helps visualize if actual flow is accelerating or decelerating vs linear trend
- Trend lines calculated from first to last data point

**Smart Tooltips:**
- Tooltips stay visible when you move your mouse over them
- This lets you click the work item ID links without the tooltip disappearing
- Click anywhere outside the tooltip to close it
- Throughput chart tooltips show all items completed in that week (can be multiple)
- Hint appears in tooltip: "Hover to keep open • Click elsewhere to close"

---

✅ **Refined based on feedback:**

- **Top Metrics Cards**:
  - Throughput: Shows median + range, splits bugs/PBIs if both exist
  - Cycle Time: Shows median + 85th percentile, splits bugs/PBIs if both exist
  - System Stability: Arrival/Departure ratio with status
  - Bug Rate: Percentage with count details
  - WIP: Count with avg age + min/max range
  - Blocked Items: Count with percentage of backlog

- **Throughput Chart**: 
  - Interactive - hover over any point to see tooltip with all items completed that week
  - Tooltip shows work item IDs as clickable links to ADO plus titles
  - Supports multiple items per week (e.g., 4 items completed)
  - Shows weekly completion trend

- **Cycle Time Chart**:
  - Scatter plot showing active work duration (In Progress → Done)
  - X-axis labels showing completion dates
  - Horizontal reference lines for average, median, and 85th percentile
  - Different colors for bugs vs PBIs
  - **Hover to see popup with clickable ADO link**
  - Tooltip shows ID (clickable), title, cycle time, completion date

- **Lead Time Chart**:
  - Scatter plot showing total time in system (Created → Done)
  - Same layout as Cycle Time chart but showing lead time values
  - Separate reference lines for lead time average, median, 85th percentile
  - **Hover to see popup with clickable ADO link**
  - Tooltip shows ID (clickable), title, lead time, completion date

- **Flow Efficiency Chart**:
  - Scatter plot showing efficiency ratio (cycle time / lead time * 100)
  - Y-axis displays percentage (0-100%)
  - Shows what percentage of total time was spent in active work
  - Higher is better - indicates less non-active time
  - **Hover to see popup with clickable ADO link**
  - Tooltip shows ID (clickable), title, efficiency percentage, cycle time, and lead time
  - Avoids "wait time" terminology as non-active time could include other work types

- **Cumulative Flow Diagram**:
  - Shows cumulative arrivals vs cumulative departures over time
  - **Trend lines**: Dashed lines show linear trends from start to end
    - Red dashed line: Arrival trend (aligns with arrivals curve)
    - Green dashed line: Departure trend (aligns with departures curve)
  - Gap between arrivals and departures indicates backlog growth
  - Widening gap = system unstable (backlog growing)
  - Narrowing gap = backlog shrinking
  - Parallel lines = stable system

- **Work Item Age**:
  - Scatter plot showing how long individual items have been in each state
  - Each dot represents one work item
  - Organized by workflow state on x-axis, age in days on y-axis
  - **Hover to see persistent tooltip with clickable ADO link**
  - Tooltip shows ID (clickable), title, state, and age
  - Quickly identifies aging work that needs attention

- **Daily Work In Progress (WIP)**:
  - Line chart showing WIP count over time
  - Includes trend line to show if WIP is growing or shrinking
  - Red dots indicate WIP limit breaches (when implemented)
  - Goal: Keep WIP stable and under control

- **Stale Work**:
  - Horizontal bar chart showing items without recent updates
  - Shows days since last update for each item
  - **Hover to see persistent tooltip with clickable ADO link**
  - Tooltip shows ID (clickable), title, and days since updated
  - Helps identify work that may be blocked or abandoned
  - Orange bars indicate items needing attention

- **Daily WIP x Work Item Age**:
  - Stacked bar chart breaking down WIP by age categories
  - Age categories: ≤1 day, ≤7 days, ≤14 days, >14 days
  - Shows if work is flowing or aging in the system
  - Goal: Most WIP should be fresh (≤7 days)

- **Aging Work In Progress**:
  - Horizontal bar chart showing current WIP items
  - Ordered by age (worst/oldest first)
  - Only shows concerning items (age >7 days)
  - Color-coded: red >14 days, yellow 7-14 days
  - **Hover to see popup with clickable ADO link**
  - Tooltip shows ID (clickable), title, age in days

- **Bug Rate Chart**:
  - Combined chart showing both active backlog health and completed work quality
  - Two lines: Active Bug Rate (orange) and Completed Bug Rate (red)
  - Active Bug Rate: Bugs in backlog / Total active items (tracks backlog health)
  - Completed Bug Rate: Bugs completed / Total items completed (tracks quality)
  - **Hover to see popup with clickable ADO links**
  - Tooltip shows bug count, total count, and list of bugs as clickable links
  - Gap spanning enabled for weeks with no completed items

- **Net Flow (Sustainability) Chart**:
  - Bar chart showing started vs finished work each week
  - Net Flow = Finished - Started
  - Positive values (blue) = good, finishing more than starting
  - Negative values (orange) = concerning, starting more than finishing
  - Goal: Maintain near-zero by limiting new work starts
  - Emphasized zero line for reference

- **State Distribution**: 
  - Doughnut chart showing backlog state breakdown

### Data Structure

See `dashboard-data-example.json` for the complete data structure. Key sections:

```javascript
{
  "teamName": "...",
  "period": "...",
  "adoOrg": "...",          // ADO organization for generating work item links
  "adoProject": "...",      // ADO project for generating work item links
  "hasBugPbiSplit": true/false,  // Set true only if BOTH bugs AND PBIs exist
  
  "metrics": {
    "throughput": { ... },
    "cycleTime": { ... },
    "systemStability": { ... },
    "bugRate": { ... },
    "wip": { ... },
    "blocked": { ... }
  },
  
  "charts": {
    "throughput": { labels, values, items },
    "cycleTime": { average, median, percentile85, datasets },
    "cfd": { labels, arrivals, departures, arrivalTrend, departureTrend },
    "wip": { labels, values, ids, titles, colors },
    "bugRate": { labels, values, details },
    "state": { labels, values, colors }
  },
  
  "insights": { ... },
  "footer": "..."
}
```

## Usage

### Via Copilot Chat Prompt

```
#prompt:ado-flow.prompt.md https://dev.azure.com/[org]/[project]/_boards/board/t/[team]/Backlog
```

The prompt will:
1. Ask for time window confirmation
2. Retrieve work items from ADO
3. Calculate all flow metrics
4. Read `dashboard-template.html`
5. Generate data object
6. Create `flow_metrics_dashboard.html`

### Manual Testing

To test the template with sample data:

```powershell
$template = Get-Content "dashboard\dashboard-template.html" -Raw -Encoding UTF8
$data = Get-Content "dashboard\dashboard-data-example.json" -Raw -Encoding UTF8
$output = $template -replace '/\* DATA_PLACEHOLDER \*/', $data
# Use System.IO.File to ensure UTF-8 without BOM (prevents emoji corruption)
[System.IO.File]::WriteAllText("$PWD\flow_metrics_dashboard.html", $output, [System.Text.UTF8Encoding]::new($false))
```

Then open `flow_metrics_dashboard.html` in your browser.

**Note**: Using `[System.IO.File]::WriteAllText()` with UTF-8 encoding without BOM prevents character corruption of emojis and special characters.

### Via Python Script

```python
import json

# Read template
with open('dashboard/dashboard-template.html', 'r', encoding='utf-8') as f:
    template = f.read()

# Prepare data
data = {
    "teamName": "My Team",
    # ... complete data structure
}

# Inject data
output = template.replace('/* DATA_PLACEHOLDER */', json.dumps(data))

# Save dashboard
with open('flow_metrics_dashboard.html', 'w', encoding='utf-8') as f:
    f.write(output)
```

## Customization

### Styling

Edit the `<style>` section in `dashboard-template.html`:

- **Colors**: Search for color codes (e.g., `#667eea`, `#fc8181`) and replace
- **Fonts**: Modify `font-family` declarations
- **Layout**: Adjust grid columns in `.metric-cards` and `.charts-grid`

### Charts

Edit the Chart.js configurations in the `<script>` section:

- **Chart types**: Change `type: 'line'` to `'bar'`, `'scatter'`, etc.
- **Colors**: Modify `borderColor`, `backgroundColor` in dataset configs
- **Tooltips**: Customize `callbacks` functions
- **Reference Lines**: Adjust annotation plugin settings

### Metrics

To add/remove metric cards:

1. Update data structure in prompt documentation
2. Modify the `metricCardsHTML` rendering in template
3. Update the sample data file

## Requirements

- Modern web browser (Chrome, Firefox, Edge, Safari)
- No backend server required - fully client-side
- Chart.js and annotation plugin loaded from CDN

## License

Internal ASOS tool for flow metrics analysis.
