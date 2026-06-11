# Cleanup-UiPathRepos.ps1
# Adds a UiPath .gitignore to each repo under $root and untracks generated/cache files.
# Does NOT commit - review per-repo changes before committing.
#
# Usage:  .\Cleanup-UiPathRepos.ps1
# Safety: skips non-git folders, skips repos named in $exclude, skips folders with no
#         UiPath signatures (no project.json and no .xaml files).

param(
    [string]$Root = "C:\github",
    [string[]]$Exclude = @("higgins-tools")
)

$uipathGitignore = @'
# --- UiPath generated/cache files ---
.local/
.settings/
.objects/
.tmh/
.screenshots/
.scratch/
*.cache
*.local.xaml
*.tmp
*.bak

# --- Editor / IDE ---
.vscode/
.idea/

# --- OS ---
Thumbs.db
.DS_Store
'@

$marker = "# --- UiPath generated/cache files ---"

if (-not (Test-Path $Root)) {
    Write-Host "Root not found: $Root" -ForegroundColor Red
    exit 1
}

Get-ChildItem -Path $Root -Directory | ForEach-Object {
    $repo = $_
    $name = $repo.Name

    if ($Exclude -contains $name) {
        Write-Host "Skip $name (excluded)" -ForegroundColor Yellow
        return
    }

    if (-not (Test-Path (Join-Path $repo.FullName ".git"))) {
        Write-Host "Skip $name (not a git repo)" -ForegroundColor DarkGray
        return
    }

    # Detect UiPath: project.json at root OR any .xaml file anywhere
    $hasProjectJson = Test-Path (Join-Path $repo.FullName "project.json")
    $hasXaml = $null -ne (Get-ChildItem -Path $repo.FullName -Filter "*.xaml" -Recurse -ErrorAction SilentlyContinue -Force | Select-Object -First 1)

    if (-not ($hasProjectJson -or $hasXaml)) {
        Write-Host "Skip $name (no UiPath signatures)" -ForegroundColor DarkGray
        return
    }

    Write-Host ""
    Write-Host "=== $name ===" -ForegroundColor Cyan

    Push-Location $repo.FullName
    try {
        # 1. Add or extend .gitignore
        $gitignorePath = Join-Path $repo.FullName ".gitignore"
        if (Test-Path $gitignorePath) {
            $existing = Get-Content $gitignorePath -Raw
            if ($existing -match [regex]::Escape($marker)) {
                Write-Host "  .gitignore already has UiPath block - leaving alone" -ForegroundColor Gray
            } else {
                Add-Content -Path $gitignorePath -Value "`r`n$uipathGitignore"
                Write-Host "  Appended UiPath block to existing .gitignore" -ForegroundColor Green
            }
        } else {
            Set-Content -Path $gitignorePath -Value $uipathGitignore
            Write-Host "  Created .gitignore" -ForegroundColor Green
        }

        # 2. Stage the .gitignore
        git add .gitignore | Out-Null

        # 3. Untrack tracked-but-ignored paths
        $dirPatterns = @(".local", ".settings", ".objects", ".tmh", ".screenshots", ".scratch")
        foreach ($p in $dirPatterns) {
            # --ignore-unmatch swallows errors when the path isn't tracked
            git rm -r --cached --ignore-unmatch --quiet -- "$p" 2>$null
            # Also catch nested ones (e.g. apGenericInvoiceDissectionEntry/.local)
            git ls-files | Where-Object { $_ -like "*/$p/*" -or $_ -like "$p/*" } | ForEach-Object {
                git rm --cached --quiet -- $_ 2>$null
            }
        }
        # File-pattern untrack
        git ls-files | Where-Object { $_ -like "*.cache" -or $_ -like "*.local.xaml" -or $_ -like "*.tmp" -or $_ -like "*.bak" } | ForEach-Object {
            git rm --cached --quiet -- $_ 2>$null
        }

        # 4. Show what's staged
        $staged = git status --short
        if ($staged) {
            $count = ($staged | Measure-Object).Count
            Write-Host "  $count staged change(s):" -ForegroundColor Gray
            $staged | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            if ($count -gt 10) { Write-Host "    ... ($($count - 10) more)" -ForegroundColor DarkGray }
        } else {
            Write-Host "  Nothing to stage" -ForegroundColor Gray
        }
    }
    finally {
        Pop-Location
    }
}

Write-Host ""
Write-Host "Done. Review per repo, then commit:" -ForegroundColor Cyan
Write-Host '  cd <repo>; git diff --cached; git commit -m "Add UiPath .gitignore and untrack generated files"' -ForegroundColor DarkGray
Write-Host ""
Write-Host "To commit all at once after reviewing:" -ForegroundColor Cyan
Write-Host @'
  Get-ChildItem C:\github -Directory | ForEach-Object {
      if ((Test-Path "$($_.FullName)\.git") -and $_.Name -ne "higgins-tools") {
          Push-Location $_.FullName
          if (git status --short) {
              git commit -m "Add UiPath .gitignore and untrack generated files"
          }
          Pop-Location
      }
  }
'@ -ForegroundColor DarkGray
