$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dataDir = Join-Path $root '.firecrawl'
$pages = @(Get-Content -Raw -LiteralPath (Join-Path $dataDir 'all-pages.json') | ConvertFrom-Json)
$createViews = @(Get-Content -Raw -LiteralPath (Join-Path $dataDir 'create-views.json') | ConvertFrom-Json)

$textDir = Join-Path $dataDir 'text'
$createTextDir = Join-Path $dataDir 'create-text'
New-Item -ItemType Directory -Path $textDir,$createTextDir -Force | Out-Null

function Get-Slug([string]$url) {
  $uri = [uri]$url
  $slug = $uri.AbsolutePath.Trim('/') -replace '[^A-Za-z0-9._-]+','-'
  if (-not $slug) { $slug = 'root' }
  return $slug
}

$pageIndex = @()
$fieldRows = @()
$tableRows = @()
$dropdownRows = @()
$dropdownIndex = @()

foreach ($page in $pages) {
  $module = ([uri]$page.requestedUrl).AbsolutePath.Trim('/').Split('/')[0]
  if (-not $module) { $module = 'home' }
  $rowCount = (@($page.tables | ForEach-Object { @($_.rows).Count }) | Measure-Object -Sum).Sum
  $pageIndex += [pscustomobject]@{
    Module = $module; URL = $page.requestedUrl; Title = $page.title
    BodyCharacters = $page.bodyText.Length; Controls = @($page.controls).Count
    Tables = @($page.tables).Count; TableRows = $rowCount
    Comboboxes = @($page.comboOptions).Count; TabStates = @($page.tabStates).Count
    CaptureStatus = if ($page.bodyText.Length -eq 0) { 'blank-after-retries' } else { 'captured' }
  }
  $header = "# $($page.title)`r`n`r`nSource: $($page.requestedUrl)`r`n`r`n"
  Set-Content -LiteralPath (Join-Path $textDir ((Get-Slug $page.requestedUrl) + '.md')) -Value ($header + $page.bodyText) -Encoding utf8

  foreach ($control in @($page.controls)) {
    $fieldRows += [pscustomobject]@{URL=$page.requestedUrl;Context='base';Tag=$control.tag;Type=$control.type;Role=$control.role;Text=$control.text;Value=$control.value;Placeholder=$control.placeholder;Name=$control.name;Id=$control.id;Label=$control.label;Disabled=$control.disabled;Required=$control.required;Checked=$control.checked}
  }
  foreach ($tab in @($page.tabStates)) {
    foreach ($control in @($tab.controls)) {
      $fieldRows += [pscustomobject]@{URL=$page.requestedUrl;Context=('tab:'+$tab.tab);Tag=$control.tag;Type=$control.type;Role=$null;Text=$control.text;Value=$control.value;Placeholder=$control.placeholder;Name=$null;Id=$null;Label=$null;Disabled=$control.disabled;Required=$null;Checked=$null}
    }
  }
  foreach ($combo in @($page.comboOptions)) {
    $options = @($combo.options)
    $dropdownIndex += [pscustomobject]@{URL=$page.requestedUrl;Context='base';Id=$combo.id;Name=$combo.name;Placeholder=$combo.placeholder;CurrentValue=$combo.value;OptionCount=$options.Count;Error=$combo.error}
    foreach ($option in $options) { $dropdownRows += [pscustomobject]@{URL=$page.requestedUrl;Context='base';Id=$combo.id;Name=$combo.name;Placeholder=$combo.placeholder;Option=$option} }
  }
  for ($i=0; $i -lt @($page.tables).Count; $i++) {
    $table = @($page.tables)[$i]
    $rows = @($table.rows)
    $tableRows += [pscustomobject]@{URL=$page.requestedUrl;Context='base';TableIndex=$i;Rows=$rows.Count;Columns=if($rows.Count){@($rows[0]).Count}else{0};FirstRow=if($rows.Count){(@($rows[0]) -join ' | ')}else{''}}
  }
}

$openedViews = @($createViews | Where-Object status -eq 'opened')
for ($i=0; $i -lt $createViews.Count; $i++) {
  $item = $createViews[$i]
  if ($item.status -ne 'opened') { continue }
  $context = 'create:' + $item.task.button + $(if($item.task.tab){' / tab:'+$item.task.tab}else{''})
  $header = "# $($item.view.title)`r`n`r`nOpened from: $($item.task.route)`r`nControl: $($item.task.button)`r`nTab: $($item.task.tab)`r`nResult URL: $($item.view.url)`r`n`r`n"
  Set-Content -LiteralPath (Join-Path $createTextDir ("{0:D3}-{1}.md" -f ($i+1),(Get-Slug $item.view.url))) -Value ($header + $item.view.bodyText) -Encoding utf8
  foreach ($control in @($item.view.controls)) {
    $fieldRows += [pscustomobject]@{URL=$item.view.url;Context=$context;Tag=$control.tag;Type=$control.type;Role=$control.role;Text=$control.text;Value=$control.value;Placeholder=$control.placeholder;Name=$control.name;Id=$control.id;Label=$null;Disabled=$control.disabled;Required=$control.required;Checked=$control.checked}
  }
  foreach ($combo in @($item.comboOptions)) {
    $options = @($combo.options)
    $dropdownIndex += [pscustomobject]@{URL=$item.view.url;Context=$context;Id=$combo.id;Name=$combo.name;Placeholder=$combo.placeholder;CurrentValue=$combo.value;OptionCount=$options.Count;Error=$combo.error}
    foreach ($option in $options) { $dropdownRows += [pscustomobject]@{URL=$item.view.url;Context=$context;Id=$combo.id;Name=$combo.name;Placeholder=$combo.placeholder;Option=$option} }
  }
  for ($j=0; $j -lt @($item.view.tables).Count; $j++) {
    $table = @($item.view.tables)[$j]
    $rows = @($table)
    $tableRows += [pscustomobject]@{URL=$item.view.url;Context=$context;TableIndex=$j;Rows=$rows.Count;Columns=if($rows.Count){@($rows[0]).Count}else{0};FirstRow=if($rows.Count){(@($rows[0]) -join ' | ')}else{''}}
  }
}

$pageIndex | Export-Csv -LiteralPath (Join-Path $dataDir 'page-index.csv') -NoTypeInformation -Encoding utf8
$fieldRows | Export-Csv -LiteralPath (Join-Path $dataDir 'field-inventory.csv') -NoTypeInformation -Encoding utf8
$tableRows | Export-Csv -LiteralPath (Join-Path $dataDir 'table-index.csv') -NoTypeInformation -Encoding utf8
$dropdownIndex | Export-Csv -LiteralPath (Join-Path $dataDir 'dropdown-index.csv') -NoTypeInformation -Encoding utf8
$dropdownRows | Export-Csv -LiteralPath (Join-Path $dataDir 'dropdown-options.csv') -NoTypeInformation -Encoding utf8

$mapLines = @('# Managerium site map','')
foreach ($group in $pageIndex | Group-Object Module | Sort-Object Name) {
  $mapLines += "## $($group.Name) ($($group.Count))"
  $mapLines += ''
  foreach ($entry in $group.Group | Sort-Object URL) { $mapLines += "- $($entry.Title): $($entry.URL)" }
  $mapLines += ''
}
Set-Content -LiteralPath (Join-Path $dataDir 'site-map.md') -Value $mapLines -Encoding utf8

# Replace per-batch files with the authoritative, retry-merged records.
for ($offset=0; $offset -lt $pages.Count; $offset+=10) {
  $end=[Math]::Min($offset+9,$pages.Count-1)
  @($pages[$offset..$end]) | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $dataDir ("pages\batch-{0:D3}.json" -f ([int]($offset/10)+1))) -Encoding utf8
}

# Remove live browser connection details from transient diagnostic envelopes.
$transient = Get-ChildItem -LiteralPath $dataDir -File | Where-Object { $_.Name -match 'envelope|^probe-|session-\d+-(login|snapshot)' }
foreach ($file in $transient) { Set-Content -LiteralPath $file.FullName -Value '{"discarded":true,"reason":"transient browser connection details removed"}' -Encoding utf8 }

[pscustomobject]@{
  Routes = $pageIndex.Count
  CapturedRoutes = @($pageIndex | Where-Object CaptureStatus -eq 'captured').Count
  BlankRoutes = @($pageIndex | Where-Object CaptureStatus -ne 'captured').Count
  BaseControls = (@($pages | ForEach-Object { @($_.controls).Count }) | Measure-Object -Sum).Sum
  TotalFieldRows = $fieldRows.Count
  Tables = $tableRows.Count
  Dropdowns = $dropdownIndex.Count
  DropdownOptions = $dropdownRows.Count
  TabStates = (@($pages | ForEach-Object { @($_.tabStates).Count }) | Measure-Object -Sum).Sum
  CreateTasks = $createViews.Count
  OpenedCreateViews = $openedViews.Count
  DistinctCreateUrls = @($openedViews | ForEach-Object { $_.view.url } | Sort-Object -Unique).Count
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dataDir 'coverage.json') -Encoding utf8
