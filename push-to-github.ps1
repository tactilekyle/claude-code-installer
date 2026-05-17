# push-to-github.ps1
# Pushes setup-claude-env.ps1 to tactilekyle/claude-code-installer
# Run this once from the folder that contains setup-claude-env.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoUrl  = "https://github.com/tactilekyle/claude-code-installer.git"
$dir      = $PSScriptRoot   # folder this script lives in

Write-Host "`n Pushing to $repoUrl`n" -ForegroundColor Cyan

Set-Location $dir

# ── Clean up any stale / corrupt .git from earlier attempts ─────────────────
if (Test-Path ".git") {
    Write-Host " Removing existing .git folder..." -ForegroundColor DarkGray
    Remove-Item ".git" -Recurse -Force
}

# ── Init fresh repo ──────────────────────────────────────────────────────────
git init -b main
git config user.email "kyle@getgearshift.app"
git config user.name  "Kyle"

# ── Write .gitignore ──────────────────────────────────────────────────────────
@"
# Don't commit the push helper itself if you don't want it
# push-to-github.ps1
"@ | Out-File -FilePath ".gitignore" -Encoding utf8

# ── Stage + commit ────────────────────────────────────────────────────────────
git add -A
git commit -m "feat: initial Claude Code environment setup script"

# ── Wire up remote + push ─────────────────────────────────────────────────────
git remote add origin $repoUrl
git branch -M main
git push -u origin main

Write-Host "`n Done! View your repo at:" -ForegroundColor Green
Write-Host " https://github.com/tactilekyle/claude-code-installer`n" -ForegroundColor Cyan
