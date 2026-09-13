# Managerium demo scrape

Captured from `https://mgm.ibos.io/` on 2026-09-13 using the supplied demo account and Firecrawl's authenticated browser.

## Coverage

- 105 application routes discovered from the authenticated navigation
- 103 route bodies successfully captured
- 2,427 controls captured from base route views
- 146 tab states captured
- 114 table snapshots captured, including their rendered rows
- 608 dropdown/search controls indexed
- 7,710 total control records across base pages, tabs, and create views
- 66 create/new actions inspected
- 63 create/new views opened and captured
- 39 distinct create/new destination URLs discovered

The route inventory covers Account, Asset, Configuration, Payroll/HR, Inventory, Production, Purchase, Sales, Post CRM, Approval, Multilayer Approval, and the home dashboard.

## Archive files

- [`all-pages.json`](.firecrawl/all-pages.json) — authoritative route-by-route capture: visible text, headings, links, controls, forms, tables, lists, images, element counts, dropdown attempts, and tab states
- [`create-views.json`](.firecrawl/create-views.json) — create/new action results and blank-form schemas
- [`page-index.csv`](.firecrawl/page-index.csv) — one row per route with coverage statistics
- [`field-inventory.csv`](.firecrawl/field-inventory.csv) — flattened inventory of fields and controls across base, tab, and create contexts
- [`table-index.csv`](.firecrawl/table-index.csv) — table locations, dimensions, and first-row/header text
- [`dropdown-index.csv`](.firecrawl/dropdown-index.csv) — every dropdown/search control and its option-count result
- [`dropdown-options.csv`](.firecrawl/dropdown-options.csv) — options that Firecrawl could expose without supplying a search query
- [`site-map.md`](.firecrawl/site-map.md) — readable module and route map
- [`text/`](.firecrawl/text/) — one readable Markdown file per route
- [`create-text/`](.firecrawl/create-text/) — readable Markdown snapshots of opened create/new views
- [`routes.json`](.firecrawl/routes.json) — original authenticated navigation links
- [`coverage.json`](.firecrawl/coverage.json) — machine-readable totals

The scripts [`capture_routes.ps1`](capture_routes.ps1), [`capture_create_views.ps1`](capture_create_views.ps1), and [`build_archive.ps1`](build_archive.ps1) document the extraction and archive-building process.

## Known gaps

Firecrawl returned an empty application body for these routes after direct-navigation and sidebar-navigation retries:

- `https://mgm.ibos.io/postcrm/ticket`
- `https://mgm.ibos.io/sales/salesOrder`

Three create controls could not be reopened reliably during the full-reload verification pass:

- Project Accounting → Create Tender
- Complain Management → Create Complain
- Delivery Schedule → Approved SO → Create Schedule

Search-driven selectors such as customer, supplier, employee, and item lookups require a query, so their complete server-side datasets cannot be enumerated from the interface without inventing search terms. The archive records the selectors, their current values, and their constraints. Static dropdown opening was also inconsistent in Firecrawl; six option values were exposed and the remaining controls are recorded in `dropdown-index.csv`.

All paginators found on the eleven paginated route views had their next-page control disabled in the rendered state. No records were created, edited, approved, submitted, or deleted.

Transient browser connection details and authentication tokens were removed from the saved artifacts. The archive is kept under `.firecrawl/` and excluded from Git because it contains demo business and contact data displayed by the application.
