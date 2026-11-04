<#
.SYNOPSIS
    Installs the whole Transit Link MVP in one go (backend + new UI + distance fares).

.DESCRIPTION
    Runs, in order, transit-link-bundle.ps1, transit-link-ui.ps1 and transit-link-fares.ps1 from this
    folder, then creates a Python virtual environment, installs the requirements and loads demo data.
    With -Run it also starts the app at http://localhost:8000.

.PARAMETER Target
    Folder to create. Default: .\transit-link (inside the folder you run this from)

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-all.ps1 -Run

.NOTES
    Needs Python 3.10 or newer on PATH. Demo data only.
#>
param([string]$Target = "transit-link", [switch]$Run)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$isWin = ($env:OS -eq "Windows_NT")
$root = if ([System.IO.Path]::IsPathRooted($Target)) { $Target } else { Join-Path (Get-Location).Path $Target }
$root = [System.IO.Path]::GetFullPath($root)

foreach ($name in "transit-link-bundle.ps1", "transit-link-ui.ps1", "transit-link-fares.ps1") {
    if (-not (Test-Path (Join-Path $here $name))) { throw "Missing $name next to install-all.ps1. Keep all the .ps1 files in the same folder." }
}

Write-Host "Step 1 of 4: backend and docs" -ForegroundColor Cyan
& (Join-Path $here "transit-link-bundle.ps1") -Target $root | Out-Null
Write-Host "Step 2 of 4: new user interface" -ForegroundColor Cyan
& (Join-Path $here "transit-link-ui.ps1") -Target $root | Out-Null
Write-Host "Step 3 of 4: distance fares patch" -ForegroundColor Cyan
& (Join-Path $here "transit-link-fares.ps1") -Target $root | Out-Null

Write-Host "Step 4 of 4: Python environment and demo data (this can take a few minutes)" -ForegroundColor Cyan
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command py -ErrorAction SilentlyContinue }
if (-not $python) { throw "Python 3.10+ was not found. Install it from python.org (tick 'Add python.exe to PATH'), then run this again." }

Push-Location $root
try {
    & $python.Source -m venv .venv
    $venvPy = if ($isWin) { Join-Path $root ".venv\Scripts\python.exe" } else { Join-Path $root ".venv/bin/python" }
    & $venvPy -m pip install --quiet -r requirements.txt
    if (-not (Test-Path ".env")) { Copy-Item ".env.example" ".env" }
    & $venvPy -m app.seed --reset --history
    Write-Host ""
    Write-Host "Installed in $root" -ForegroundColor Green
    if ($Run) {
        Write-Host "Starting http://localhost:8000  (press Ctrl+C to stop)" -ForegroundColor Green
        & $venvPy -m uvicorn app.main:app --reload
    }
    else {
        Write-Host "To start it later:" -ForegroundColor Cyan
        Write-Host "  cd `"$root`""
        Write-Host "  .\.venv\Scripts\Activate.ps1"
        Write-Host "  uvicorn app.main:app --reload"
        Write-Host "Then open http://localhost:8000"
    }
}
finally { Pop-Location }
