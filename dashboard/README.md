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

✅ **Refined based on feedback:**

- **Top Metrics Cards**:
  - Throughput: Shows median + range, splits bugs/PBIs if both exist
  - Cycle Time: Shows median + 85th percentile, splits bugs/PBIs if both exist
  - System Stability: Arrival/Departure ratio with status
  - Bug Rate: Percentage with count details
  - WIP: Count with avg age + min/max range
  - Blocked Items: Count with percentage of backlog

- **Throughput Chart**: 
  - Interactive - click any point to see list of completed items for that week
  - Shows weekly completion trend

- **Cycle Time Chart**:
  - Scatter plot organized by completion date
  - X-axis labels showing dates
  - Horizontal reference lines for average, 50th, and 85th percentile
  - Different colors for bugs vs PBIs
  - Hover shows ID, title, cycle time, completion date

- **Cumulative Flow Diagram**:
  - Shows arrival vs departure as cumulative lines
  - Trend lines drawn from first to last point
  - Clear visualization of backlog growth/shrinkage

- **WIP Aging Chart**:
  - Ordered by age (worst/oldest first)
  - Only shows concerning items (age >7 days)
  - Color-coded: red >14 days, yellow 7-14 days
  - Horizontal bar chart for easy comparison

- **Bug Rate Chart**:
  - Time-based line chart showing bug rate % by week
  - Tooltip shows bug count vs feature count
  - Title: "Bug Rate by Week" (accurate, not "over time")

- **State Distribution**: 
  - Doughnut chart showing backlog state breakdown

### Data Structure

See `dashboard-data-example.json` for the complete data structure. Key sections:

```javascript
{
  "teamName": "...",
  "period": "...",
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
