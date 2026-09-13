param(
  [string]$ScrapeId,
  [int]$BatchSize = 10
)

$ErrorActionPreference = 'Stop'
$allPagesPath = Join-Path $PSScriptRoot '.firecrawl\all-pages.json'
$pages = @(Get-Content -Raw -LiteralPath $allPagesPath | ConvertFrom-Json)
$tasks = @()
foreach ($pageData in $pages) {
  foreach ($button in @($pageData.controls | Where-Object { $_.tag -eq 'button' -and $_.text -match '(?i)create|new|add new' -and $_.text })) {
    $tasks += [pscustomobject]@{ route = $pageData.requestedUrl; tab = $null; button = $button.text }
  }
  foreach ($tabData in @($pageData.tabStates)) {
    foreach ($button in @($tabData.controls | Where-Object { $_.tag -eq 'button' -and $_.text -match '(?i)create|new|add new' -and $_.text })) {
      $tasks += [pscustomobject]@{ route = $pageData.requestedUrl; tab = $tabData.tab; button = $button.text }
    }
  }
}
$tasks = @($tasks | Sort-Object route,tab,button -Unique)
$tasks | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PSScriptRoot '.firecrawl\create-tasks.json') -Encoding utf8

$firecrawlCli = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'npm-cache\_npx') -Recurse -Filter package.json -ErrorAction Stop |
  Where-Object { (Get-Content -Raw $_.FullName -ErrorAction SilentlyContinue) -match '"name"\s*:\s*"firecrawl-cli"' } |
  Select-Object -First 1 |
  ForEach-Object { Join-Path $_.DirectoryName 'dist\index.js' }
$viewDir = Join-Path $PSScriptRoot '.firecrawl\create-batches'
New-Item -ItemType Directory -Path $viewDir -Force | Out-Null

for ($offset = 0; $offset -lt $tasks.Count; $offset += $BatchSize) {
  $end = [Math]::Min($offset + $BatchSize - 1, $tasks.Count - 1)
  $batch = @($tasks[$offset..$end])
  $batchNumber = [int]($offset / $BatchSize) + 1
  $batchFile = Join-Path $viewDir ("batch-{0:D3}.json" -f $batchNumber)
  if (Test-Path -LiteralPath $batchFile) { Write-Host "Skipping completed create batch $batchNumber"; continue }
  $tasksJson = ConvertTo-Json -InputObject $batch -Compress -Depth 5
$js = @"
JSON.stringify(await (async () => {
  const tasks = $tasksJson;
  const out = [];
  const clean = v => v == null ? null : String(v).replace(/\s+/g, ' ').trim();
  const extract = async () => page.evaluate(() => {
    const clean = v => v == null ? null : String(v).replace(/\s+/g, ' ').trim();
    const nodes = s => Array.from(document.querySelectorAll(s));
    return {
      url: location.href,
      title: document.title,
      bodyText: document.body?.innerText || '',
      headings: nodes('h1,h2,h3,h4,h5,h6,[role="heading"]').map(h => clean(h.innerText)),
      controls: nodes('input,textarea,select,button,[role="button"],[role="combobox"],[role="tab"],[role="checkbox"]').map(el => ({
        tag: el.tagName.toLowerCase(), type: el.getAttribute('type'), role: el.getAttribute('role'),
        text: clean(el.innerText || el.textContent), value: 'value' in el ? el.value : null,
        placeholder: el.getAttribute('placeholder'), name: el.getAttribute('name'), id: el.id || null,
        disabled: !!el.disabled || el.getAttribute('aria-disabled') === 'true',
        required: !!el.required || el.getAttribute('aria-required') === 'true',
        checked: 'checked' in el ? !!el.checked : el.getAttribute('aria-checked')
      })),
      tables: nodes('table').map(table => Array.from(table.querySelectorAll('tr')).map(row => Array.from(row.querySelectorAll('th,td')).map(cell => clean(cell.innerText)))),
      dialogs: nodes('[role="dialog"],.modal').filter(el => el.offsetParent !== null).map(el => clean(el.innerText))
    };
  });

  for (const task of tasks) {
    const result = {task};
    try {
      await page.goto(task.route, {waitUntil:'domcontentloaded', timeout:45000});
      await page.waitForTimeout(1600);
      if (task.tab) {
        const tabs = page.locator('[role="tab"]');
        let clicked = false;
        for (let i = 0; i < await tabs.count(); i++) {
          const tab = tabs.nth(i);
          if (clean(await tab.innerText()) === task.tab) { await tab.evaluate(el => el.click()); clicked = true; break; }
        }
        result.tabFound = clicked;
        await page.waitForTimeout(350);
      }
      const buttons = page.locator('button,[role="button"]');
      let target = null;
      for (let i = 0; i < await buttons.count(); i++) {
        const button = buttons.nth(i);
        if (clean(await button.innerText()) === task.button && await button.isVisible()) { target = button; break; }
      }
      if (!target) { result.status = 'button-not-found'; result.before = await extract(); out.push(result); continue; }
      result.enabled = await target.isEnabled();
      result.beforeUrl = page.url();
      if (!result.enabled) { result.status = 'button-disabled'; result.before = await extract(); out.push(result); continue; }
      await target.evaluate(el => el.click());
      await page.waitForTimeout(1000);
      result.status = 'opened';
      result.view = await extract();
      const combos = page.locator('[role="combobox"]');
      result.comboOptions = [];
      for (let i = 0; i < Math.min(await combos.count(), 30); i++) {
        try {
          const combo = combos.nth(i);
          if (!(await combo.isVisible()) || !(await combo.isEnabled())) continue;
          const descriptor = await combo.evaluate(el => ({id:el.id||null,name:el.getAttribute('name'),placeholder:el.getAttribute('placeholder'),value:el.value||null}));
          await combo.evaluate(el => el.click());
          await page.waitForTimeout(100);
          const options = (await page.locator('[role="option"]:visible').allTextContents()).map(clean).filter(Boolean).slice(0,250);
          result.comboOptions.push({...descriptor,options});
          await page.keyboard.press('Escape');
        } catch (e) { result.comboOptions.push({index:i,error:String(e).slice(0,240)}); }
      }
    } catch (e) {
      result.status = 'error';
      result.error = String(e);
    }
    out.push(result);
  }
  return out;
})())
"@
$envelopePath = Join-Path $viewDir ("batch-{0:D3}-envelope.json" -f $batchNumber)
& node $firecrawlCli interact -s $ScrapeId --code $js --node --timeout 300 --json -o $envelopePath
if ($LASTEXITCODE -ne 0) { throw "Firecrawl create-view batch $batchNumber failed with exit code $LASTEXITCODE" }
$envelope = Get-Content -Raw -LiteralPath $envelopePath | ConvertFrom-Json
if (-not $envelope.success -or $envelope.exitCode -ne 0) { throw "Firecrawl create-view batch $batchNumber returned an error: $($envelope.stderr)" }
$parsed = $envelope.result | ConvertFrom-Json
$parsed | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $batchFile -Encoding utf8
Remove-Item -LiteralPath $envelopePath
Write-Host "Captured create batch $batchNumber ($($parsed.Count) states)"
}

$allViews = @(Get-ChildItem -LiteralPath $viewDir -Filter 'batch-*.json' | Sort-Object Name | ForEach-Object { @(Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json) })
$allViews | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $PSScriptRoot '.firecrawl\create-views.json') -Encoding utf8
Write-Host "Captured $($allViews.Count) create/new states in total"
