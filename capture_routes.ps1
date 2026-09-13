param(
  [string]$ScrapeId = '01a09a01-488e-753c-b3ef-5b6846e7482c',
  [int]$BatchSize = 10
)

$ErrorActionPreference = 'Stop'
$outputDir = Join-Path $PSScriptRoot '.firecrawl\pages'
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$firecrawlCli = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'npm-cache\_npx') -Recurse -Filter package.json -ErrorAction Stop |
  Where-Object { (Get-Content -Raw $_.FullName -ErrorAction SilentlyContinue) -match '"name"\s*:\s*"firecrawl-cli"' } |
  Select-Object -First 1 |
  ForEach-Object { Join-Path $_.DirectoryName 'dist\index.js' }
if (-not $firecrawlCli -or -not (Test-Path -LiteralPath $firecrawlCli)) { throw 'Cached Firecrawl CLI was not found. Run npx -y firecrawl-cli@latest --status first.' }

$routes = Get-Content -Raw (Join-Path $PSScriptRoot '.firecrawl\routes.json') |
  ConvertFrom-Json |
  ForEach-Object { $_.url } |
  Sort-Object -Unique

for ($offset = 0; $offset -lt $routes.Count; $offset += $BatchSize) {
  $end = [Math]::Min($offset + $BatchSize - 1, $routes.Count - 1)
  $batch = @($routes[$offset..$end])
  $batchNumber = [int]($offset / $BatchSize) + 1
  $batchFile = Join-Path $outputDir ("batch-{0:D3}.json" -f $batchNumber)
  if (Test-Path -LiteralPath $batchFile) {
    $existing = @(Get-Content -Raw -LiteralPath $batchFile | ConvertFrom-Json)
    $incomplete = @($existing | Where-Object { $_.error -or -not $_.bodyText -or $_.bodyText.Length -lt 200 })
    if ($existing.Count -eq $batch.Count -and $incomplete.Count -eq 0) {
      Write-Host "Skipping completed batch $batchNumber"
      continue
    }
    Remove-Item -LiteralPath $batchFile
  }

  $urlsJson = $batch | ConvertTo-Json -Compress
  $js = @"
JSON.stringify(await (async () => {
  const urls = $urlsJson;
  const results = [];
  const clean = value => value == null ? null : String(value).replace(/\s+/g, ' ').trim();
  for (const targetUrl of urls) {
    try {
      if (page.url() !== targetUrl) {
        const targetLink = page.locator('a[href="' + targetUrl + '"]').first();
        if (await targetLink.count()) {
          await targetLink.evaluate(el => el.click());
          try { await page.waitForURL(targetUrl, {timeout: 10000}); } catch {}
        } else {
          await page.goto(targetUrl, {waitUntil: 'domcontentloaded', timeout: 45000});
        }
      }
      try {
        await page.waitForFunction(url => document.body?.innerText?.length > 500 && (url === 'https://mgm.ibos.io/' || document.title !== 'MANAGERIUM'), targetUrl, {timeout: 5000});
      } catch {}
      await page.waitForTimeout(700);
      const base = await page.evaluate(() => {
        const clean = value => value == null ? null : String(value).replace(/\s+/g, ' ').trim();
        const attr = (el, name) => el.getAttribute(name);
        const nodes = selector => Array.from(document.querySelectorAll(selector));
        const safeUrl = input => {
          if (!input) return null;
          if (input.startsWith('data:')) return '[embedded-data-url length=' + input.length + ']';
          try {
            const url = new URL(input, location.href);
            for (const key of Array.from(url.searchParams.keys())) if (/token|key|auth|signature|credential/i.test(key)) url.searchParams.set(key, '[REDACTED]');
            return url.href;
          } catch { return input; }
        };
        const controls = nodes('input, textarea, select, button, [role="button"], [role="combobox"], [role="tab"], [role="checkbox"], [contenteditable="true"]').map((el, index) => ({
          index,
          tag: el.tagName.toLowerCase(),
          type: attr(el, 'type'),
          role: attr(el, 'role'),
          text: clean(el.innerText || el.textContent),
          value: 'value' in el ? el.value : attr(el, 'aria-valuetext'),
          placeholder: attr(el, 'placeholder'),
          name: attr(el, 'name'),
          id: el.id || null,
          label: attr(el, 'aria-label'),
          describedBy: attr(el, 'aria-describedby'),
          title: attr(el, 'title'),
          disabled: !!el.disabled || attr(el, 'aria-disabled') === 'true',
          required: !!el.required || attr(el, 'aria-required') === 'true',
          checked: 'checked' in el ? !!el.checked : attr(el, 'aria-checked'),
          selected: attr(el, 'aria-selected'),
          min: attr(el, 'min'), max: attr(el, 'max'), step: attr(el, 'step'),
          href: safeUrl(el.href || null)
        }));
        const tables = nodes('table').map((table, tableIndex) => ({
          tableIndex,
          caption: clean(table.querySelector('caption')?.innerText),
          headers: nodes.call ? [] : [],
          rows: Array.from(table.querySelectorAll('tr')).map(row => Array.from(row.querySelectorAll('th,td')).map(cell => clean(cell.innerText)))
        }));
        const lists = nodes('ul,ol').map((list, listIndex) => ({listIndex, items: Array.from(list.children).map(item => clean(item.innerText)).filter(Boolean)}));
        const forms = nodes('form').map((form, formIndex) => ({formIndex, action: form.action || null, method: form.method || null, text: clean(form.innerText)}));
        return {
          requestedUrl: location.href,
          title: document.title,
          language: document.documentElement.lang || null,
          direction: document.documentElement.dir || null,
          meta: nodes('meta').map(m => ({name: attr(m,'name'), property: attr(m,'property'), content: attr(m,'content')})).filter(m => m.name || m.property),
          headings: nodes('h1,h2,h3,h4,h5,h6,[role="heading"]').map(h => ({level: h.tagName.match(/^H/) ? Number(h.tagName.slice(1)) : Number(attr(h,'aria-level')) || null, text: clean(h.innerText)})),
          bodyText: document.body?.innerText || '',
          links: nodes('a[href]').map(a => ({text: clean(a.innerText), url: safeUrl(a.href), target: a.target || null})),
          controls,
          tables,
          lists,
          forms,
          images: nodes('img').map(img => ({alt: img.alt || null, src: safeUrl(img.src), width: img.naturalWidth || img.width || null, height: img.naturalHeight || img.height || null})),
          elementCounts: nodes('*').reduce((acc, el) => { const tag = el.tagName.toLowerCase(); acc[tag] = (acc[tag] || 0) + 1; return acc; }, {})
        };
      });

      const comboOptions = [];
      const combos = page.locator('[role="combobox"]');
      const comboCount = Math.min(await combos.count(), 30);
      for (let i = 0; i < comboCount; i++) {
        try {
          const combo = combos.nth(i);
          if (!(await combo.isVisible()) || !(await combo.isEnabled())) continue;
          const descriptor = await combo.evaluate(el => ({id: el.id || null, name: el.getAttribute('name'), placeholder: el.getAttribute('placeholder'), value: el.value || null, ariaLabel: el.getAttribute('aria-label')}));
          await combo.evaluate(el => el.click());
          await page.waitForTimeout(120);
          const options = await page.locator('[role="option"]:visible').allTextContents();
          comboOptions.push({...descriptor, options: options.map(clean).filter(Boolean).slice(0, 250)});
          await page.keyboard.press('Escape');
        } catch (error) {
          comboOptions.push({index: i, error: String(error).slice(0, 300)});
          try { await page.keyboard.press('Escape'); } catch {}
        }
      }

      const tabStates = [];
      const tabs = page.locator('[role="tab"]');
      const tabCount = Math.min(await tabs.count(), 12);
      for (let i = 0; i < tabCount; i++) {
        try {
          const tab = tabs.nth(i);
          if (!(await tab.isVisible()) || !(await tab.isEnabled())) continue;
          const tabName = clean(await tab.innerText());
          await tab.evaluate(el => el.click());
          await page.waitForTimeout(300);
          tabStates.push({
            tab: tabName,
            url: page.url(),
            bodyText: await page.locator('body').innerText(),
            controls: await page.locator('input, textarea, select, button, [role="combobox"], [role="checkbox"]').evaluateAll(elements => elements.map(el => ({tag: el.tagName.toLowerCase(), type: el.getAttribute('type'), text: (el.innerText || el.textContent || '').replace(/\s+/g,' ').trim(), value: 'value' in el ? el.value : null, placeholder: el.getAttribute('placeholder'), disabled: !!el.disabled})))
          });
        } catch (error) {
          tabStates.push({index: i, error: String(error).slice(0, 300)});
        }
      }
      results.push({...base, comboOptions, tabStates, finalUrl: page.url()});
    } catch (error) {
      results.push({requestedUrl: targetUrl, error: String(error), finalUrl: page.url()});
    }
  }
  return results;
})())
"@

  $envelopePath = Join-Path $outputDir ("batch-{0:D3}-envelope.json" -f $batchNumber)
  & node $firecrawlCli interact -s $ScrapeId --code $js --node --timeout 300 --json -o $envelopePath
  if ($LASTEXITCODE -ne 0) { throw "Firecrawl batch $batchNumber failed with exit code $LASTEXITCODE" }
  $envelope = Get-Content -Raw -LiteralPath $envelopePath | ConvertFrom-Json
  if (-not $envelope.success -or $envelope.exitCode -ne 0) { throw "Firecrawl batch $batchNumber returned an error: $($envelope.stderr)" }
  $parsed = $envelope.result | ConvertFrom-Json
  $parsed | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $batchFile -Encoding utf8
  Remove-Item -LiteralPath $envelopePath
  Write-Host "Captured batch $batchNumber ($($batch.Count) routes)"
}
