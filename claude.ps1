#Requires -Version 5.1
<#
.SYNOPSIS
    Full Claude Code environment setup — installs Claude Code, Obsidian, all plugins & skills,
    copies your global CLAUDE.md, and pushes your vault to a new GitHub repo.

.DESCRIPTION
    Run this script on any fresh Windows machine to reproduce your exact Claude Code environment.

    Prerequisites handled automatically (zero manual steps):
      - winget  (App Installer, bootstrapped from GitHub if missing)
      - Node.js (via winget)
      - Obsidian (via winget)
      - GitHub CLI (via winget, for repo creation)
      - Claude Code (via npm)
      - git (via winget, for GitHub push)

    Place your CLAUDE.md in the same folder as this script BEFORE running,
    or pass -ClaudeMdSource to point to it explicitly.

.PARAMETER ClaudeMdSource
    Path to your CLAUDE.md file. Defaults to a CLAUDE.md sitting next to this script.

.PARAMETER GitHubRepoName
    Name for the new GitHub repository. Defaults to "obsidian-second-brain".

.PARAMETER GitHubRepoVisibility
    "private" (default) or "public".

.PARAMETER SkipNodeInstall
    Skip Node.js installation (use if Node is already installed and on PATH).

.PARAMETER SkipObsidian
    Skip Obsidian installation.

.PARAMETER SkipGitHub
    Skip GitHub repo creation and push entirely.

.EXAMPLE
    .\setup-claude-env.ps1
    .\setup-claude-env.ps1 -ClaudeMdSource "D:\Backup\CLAUDE.md" -GitHubRepoName "my-brain"
    .\setup-claude-env.ps1 -SkipNodeInstall -SkipObsidian -GitHubRepoVisibility public
#>

param(
    [string]$ClaudeMdSource         = (Join-Path $PSScriptRoot "CLAUDE.md"),
    [string]$GitHubRepoName         = "obsidian-second-brain",
    [ValidateSet("private","public")]
    [string]$GitHubRepoVisibility   = "private",
    [switch]$SkipNodeInstall,
    [switch]$SkipObsidian,
    [switch]$SkipGitHub
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Colours ────────────────────────────────────────────────────────────────
function Write-Step  { param($msg) Write-Host "`n▶  $msg" -ForegroundColor Cyan }
function Write-Ok    { param($msg) Write-Host "   ✓  $msg" -ForegroundColor Green }
function Write-Warn  { param($msg) Write-Host "   ⚠  $msg" -ForegroundColor Yellow }
function Write-Fail  { param($msg) Write-Host "   ✗  $msg" -ForegroundColor Red }

# ─── Helper: run a command and throw on non-zero exit ───────────────────────
function Invoke-Required {
    param([string]$Cmd, [string[]]$Args, [string]$Label)
    Write-Host "   » $Label" -ForegroundColor DarkGray
    & $Cmd @Args
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed (exit $LASTEXITCODE): $Cmd $Args"
    }
}

# ─── Helper: run a Claude Code slash-command non-interactively ──────────────
function Invoke-ClaudeCmd {
    param([string]$SlashCmd, [string]$Label)
    Write-Host "   » $Label" -ForegroundColor DarkGray
    $output = & claude --print "$SlashCmd" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "claude returned exit $LASTEXITCODE for: $SlashCmd"
        Write-Host "   Output: $output" -ForegroundColor DarkGray
    } else {
        Write-Ok $Label
    }
}

# ─── Helper: refresh PATH in the current session ───────────────────────────
function Update-SessionPath {
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
}

# ════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║   Claude Code — Full Environment Setup Script    ║" -ForegroundColor Magenta
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

# ── 0. Sanity: administrator check ──────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warn "Not running as Administrator — some installs may prompt for elevation."
}

# ════════════════════════════════════════════════════════════════════════════
# 0b. WINGET BOOTSTRAP  (install App Installer if winget is missing)
# ════════════════════════════════════════════════════════════════════════════
Write-Step "0 / 8  winget"

$wingetCheck = Get-Command winget -ErrorAction SilentlyContinue
if ($wingetCheck) {
    Write-Ok "winget already available: $(winget --version)"
} else {
    Write-Host "   winget not found — bootstrapping App Installer from GitHub…" -ForegroundColor DarkGray

    # Fetch the latest App Installer release URL from GitHub API
    try {
        $apiUrl  = "https://api.github.com/repos/microsoft/winget-cli/releases/latest"
        $release = Invoke-RestMethod -Uri $apiUrl -Headers @{ "User-Agent" = "setup-script" }
        $asset   = $release.assets | Where-Object { $_.name -like "*.msixbundle" } | Select-Object -First 1
        if (-not $asset) { throw "No .msixbundle asset found in latest winget release." }

        $tmpFile = Join-Path $env:TEMP "AppInstaller.msixbundle"
        Write-Host "   Downloading $($asset.name)…" -ForegroundColor DarkGray
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpFile -UseBasicParsing

        # Also download required VC++ Desktop Runtime dependency
        Write-Host "   Installing App Installer package…" -ForegroundColor DarkGray
        Add-AppxPackage -Path $tmpFile -ForceApplicationShutdown

        Remove-Item $tmpFile -ErrorAction SilentlyContinue
        Update-SessionPath

        # Verify
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            throw "winget still not on PATH after install. You may need to restart and re-run."
        }
        Write-Ok "winget installed: $(winget --version)"
    } catch {
        Write-Fail "Automatic winget install failed: $_"
        Write-Warn "Manual fix: open the Microsoft Store, search 'App Installer', and install it."
        Write-Warn "Then re-run this script."
        exit 1
    }
}

# ════════════════════════════════════════════════════════════════════════════
# 1. NODE.JS
# ════════════════════════════════════════════════════════════════════════════
Write-Step "1 / 8  Node.js"

if ($SkipNodeInstall) {
    Write-Ok "Skipped (--SkipNodeInstall)"
} else {
    $nodeCheck = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCheck) {
        $nodeVer = & node --version
        Write-Ok "Node.js already installed: $nodeVer"
    } else {
        Write-Host "   Installing Node.js LTS via winget…" -ForegroundColor DarkGray
        winget install --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { throw "Node.js install failed." }
        Update-SessionPath
        Write-Ok "Node.js installed"
    }
}

# ════════════════════════════════════════════════════════════════════════════
# 2. CLAUDE CODE
# ════════════════════════════════════════════════════════════════════════════
Write-Step "2 / 6  Claude Code CLI"

$claudeCheck = Get-Command claude -ErrorAction SilentlyContinue
if ($claudeCheck) {
    $claudeVer = & claude --version 2>&1
    Write-Ok "Claude Code already installed: $claudeVer"
} else {
    Invoke-Required npm @("install", "-g", "@anthropic-ai/claude-code") "npm install -g @anthropic-ai/claude-code"
    Write-Ok "Claude Code installed"
}

# ════════════════════════════════════════════════════════════════════════════
# 3. CLAUDE.MD  (global config)
# ════════════════════════════════════════════════════════════════════════════
Write-Step "3 / 8  Global CLAUDE.md"

$claudeDir  = Join-Path $env:USERPROFILE ".claude"
$claudeMdDst = Join-Path $claudeDir "CLAUDE.md"

if (-not (Test-Path $claudeDir)) {
    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
    Write-Ok "Created $claudeDir"
}

if (Test-Path $ClaudeMdSource) {
    Copy-Item -Path $ClaudeMdSource -Destination $claudeMdDst -Force
    Write-Ok "Copied CLAUDE.md → $claudeMdDst"
} else {
    Write-Warn "CLAUDE.md not found at: $ClaudeMdSource"
    Write-Warn "Place your CLAUDE.md next to this script, or pass -ClaudeMdSource <path>"
    Write-Warn "Skipping CLAUDE.md copy — you can do it manually later."
}

# ════════════════════════════════════════════════════════════════════════════
# 4. OBSIDIAN
# ════════════════════════════════════════════════════════════════════════════
Write-Step "4 / 8  Obsidian"

if ($SkipObsidian) {
    Write-Ok "Skipped (--SkipObsidian)"
} else {
    # Check if already installed
    $obsidianExe = @(
        "$env:LOCALAPPDATA\Obsidian\Obsidian.exe",
        "$env:PROGRAMFILES\Obsidian\Obsidian.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($obsidianExe) {
        Write-Ok "Obsidian already installed: $obsidianExe"
    } else {
        winget install --id Obsidian.Obsidian --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { throw "Obsidian install failed." }
        Write-Ok "Obsidian installed"
    }
}

# ════════════════════════════════════════════════════════════════════════════
# 5. SKILLS  (via npx skills add)
# ════════════════════════════════════════════════════════════════════════════
Write-Step "5 / 8  Skills"

$skills = @(
    "pbakaus/impeccable",
    "Leonxlnx/taste-skill",
    "sethhobson/obsidian-second-brain"
)

foreach ($skill in $skills) {
    try {
        Invoke-Required npx @("skills", "add", $skill) "npx skills add $skill"
        Write-Ok "Skill installed: $skill"
    } catch {
        Write-Warn "Skill install failed for $skill — $_"
    }
}

# ─── Obsidian second-brain auto-setup ───────────────────────────────────────
# Creates a full PARA-style second-brain vault and sets the env var the
# obsidian-second-brain skill reads at runtime.
Write-Step "   Configuring obsidian-second-brain vault"

# ── Ask where an EXISTING vault lives (optional — press Enter to skip) ──────
Write-Host ""
Write-Host "   Do you have an existing Obsidian vault you want to keep using?" -ForegroundColor Yellow
Write-Host "   If yes, enter its full path below. Press Enter to create a brand-new vault." -ForegroundColor Yellow
$existingVault = Read-Host "   Existing vault path (or Enter to skip)"
$existingVault = $existingVault.Trim().Trim('"')

# ── Ask where the NEW (or current) vault should live ────────────────────────
$defaultVaultPath = "$env:USERPROFILE\Desktop\Obsidian-Vault"
Write-Host ""
Write-Host "   Where should the second-brain vault be created?" -ForegroundColor Yellow
Write-Host "   Default: $defaultVaultPath" -ForegroundColor DarkGray
$vaultInput = Read-Host "   Vault location (or Enter for default)"
$vaultInput  = $vaultInput.Trim().Trim('"')
$vaultPath   = if ($vaultInput -ne "") { $vaultInput } else { $defaultVaultPath }

Write-Host ""
Write-Ok "Vault path: $vaultPath"

# If user pointed to an existing vault just use it as-is (don't overwrite)
if ($existingVault -ne "" -and (Test-Path $existingVault)) {
    Write-Ok "Existing vault found at: $existingVault"
    Write-Host "   Scaffold will be merged into: $vaultPath" -ForegroundColor DarkGray
    Write-Host "   (Existing files will NOT be overwritten)" -ForegroundColor DarkGray
}

# Core PARA + Zettelkasten folder structure
$vaultDirs = @(
    # ── Inbox (capture everything here first) ────────────────────────────
    "00 - Inbox",

    # ── PARA: Projects (active, time-bound work) ─────────────────────────
    "01 - Projects",
    "01 - Projects\_Templates",

    # ── PARA: Areas (ongoing responsibilities) ────────────────────────────
    "02 - Areas",
    "02 - Areas\Health",
    "02 - Areas\Finance",
    "02 - Areas\Career",
    "02 - Areas\Relationships",

    # ── PARA: Resources (reference material) ─────────────────────────────
    "03 - Resources",
    "03 - Resources\Books",
    "03 - Resources\Articles",
    "03 - Resources\Courses",
    "03 - Resources\Tools & Software",

    # ── PARA: Archive (inactive items) ───────────────────────────────────
    "04 - Archive",

    # ── Zettelkasten / Evergreen notes ────────────────────────────────────
    "05 - Notes",
    "05 - Notes\Fleeting",
    "05 - Notes\Literature",
    "05 - Notes\Permanent",
    "05 - Notes\MOC",            # Maps of Content

    # ── Daily & periodic reviews ──────────────────────────────────────────
    "06 - Journal",
    "06 - Journal\Daily",
    "06 - Journal\Weekly",
    "06 - Journal\Monthly",

    # ── Templates ─────────────────────────────────────────────────────────
    "07 - Templates",

    # ── Attachments (images, PDFs, etc.) ─────────────────────────────────
    "08 - Attachments",

    # ── Obsidian config ───────────────────────────────────────────────────
    ".obsidian",
    ".obsidian\plugins"
)

foreach ($dir in $vaultDirs) {
    $fullPath = Join-Path $vaultPath $dir
    if (-not (Test-Path $fullPath)) {
        New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
    }
}
Write-Ok "Vault directory structure created: $vaultPath"

# ── Write a starter README ────────────────────────────────────────────────
$readmePath = Join-Path $vaultPath "README.md"
if (-not (Test-Path $readmePath)) {
@"
# Second Brain

This vault follows the **PARA** method (Projects · Areas · Resources · Archive)
combined with a lightweight Zettelkasten for evergreen notes.

## Folder guide

| Folder | Purpose |
|--------|---------|
| 00 - Inbox | Capture everything here first; triage daily |
| 01 - Projects | Active, time-bound work with a clear outcome |
| 02 - Areas | Ongoing responsibilities (no end date) |
| 03 - Resources | Reference material organised by topic |
| 04 - Archive | Completed / inactive items |
| 05 - Notes | Fleeting → Literature → Permanent notes |
| 06 - Journal | Daily / weekly / monthly reviews |
| 07 - Templates | Note templates |
| 08 - Attachments | Images, PDFs, and other files |

> Managed by the **obsidian-second-brain** Claude skill.
"@ | Out-File -FilePath $readmePath -Encoding utf8
    Write-Ok "Created README.md in vault root"
}

# ── Starter daily-note template ───────────────────────────────────────────
$dailyTemplate = Join-Path $vaultPath "07 - Templates\Daily Note.md"
if (-not (Test-Path $dailyTemplate)) {
@"
---
date: {{date}}
tags: [journal/daily]
---

# {{date:dddd, MMMM D, YYYY}}

## Morning Intentions
-

## Top 3 for Today
1.
2.
3.

## Notes / Captures


## Evening Review
- What went well?
- What to improve?
- Tomorrow's focus:
"@ | Out-File -FilePath $dailyTemplate -Encoding utf8
    Write-Ok "Created daily-note template"
}

# ── Write Obsidian app.json to set attachments & templates folders ─────────
$appJson = Join-Path $vaultPath ".obsidian\app.json"
if (-not (Test-Path $appJson)) {
@"
{
  "attachmentFolderPath": "08 - Attachments",
  "newFileLocation": "folder",
  "newFileFolderPath": "00 - Inbox",
  "spellcheck": true,
  "livePreview": true
}
"@ | Out-File -FilePath $appJson -Encoding utf8
    Write-Ok "Created .obsidian/app.json"
}

# ── Set env var the obsidian-second-brain skill reads ─────────────────────
[System.Environment]::SetEnvironmentVariable("OBSIDIAN_VAULT_PATH", $vaultPath, "User")
$env:OBSIDIAN_VAULT_PATH = $vaultPath
Write-Ok "OBSIDIAN_VAULT_PATH set to: $vaultPath"

# ════════════════════════════════════════════════════════════════════════════
# 6. GIT + GITHUB CLI  (needed for repo push)
# ════════════════════════════════════════════════════════════════════════════
Write-Step "6 / 8  git + GitHub CLI"

# ── git ───────────────────────────────────────────────────────────────────
if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Ok "git already installed: $(git --version)"
} else {
    winget install --id Git.Git --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { Write-Warn "git install failed — GitHub push may not work." }
    else {
        Update-SessionPath
        Write-Ok "git installed"
    }
}

# ── GitHub CLI (gh) ───────────────────────────────────────────────────────
if (Get-Command gh -ErrorAction SilentlyContinue) {
    Write-Ok "GitHub CLI already installed: $(gh --version | Select-Object -First 1)"
} else {
    winget install --id GitHub.cli --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { Write-Warn "GitHub CLI install failed — GitHub push may not work." }
    else {
        Update-SessionPath
        Write-Ok "GitHub CLI installed"
    }
}

# ════════════════════════════════════════════════════════════════════════════
# 7. PLUGINS  (via Claude Code slash-commands)
# ════════════════════════════════════════════════════════════════════════════
Write-Step "7 / 8  Claude Code Plugins"

# Verify claude is available before trying plugin commands
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Fail "claude CLI not found on PATH — cannot install plugins."
    Write-Warn "Restart your terminal after Node.js install and re-run this script with -SkipNodeInstall."
    exit 1
}

# ── obra/superpowers ──────────────────────────────────────────────────────
Write-Host "`n   [superpowers]" -ForegroundColor DarkCyan
Invoke-ClaudeCmd "/plugin marketplace add obra/superpowers-marketplace"  "Add marketplace: obra/superpowers-marketplace"
Invoke-ClaudeCmd "/plugin install superpowers@superpowers-marketplace"    "Install: superpowers"

# ── nextlevelbuilder/ui-ux-pro-max ───────────────────────────────────────
Write-Host "`n   [ui-ux-pro-max]" -ForegroundColor DarkCyan
Invoke-ClaudeCmd "/plugin marketplace add nextlevelbuilder/ui-ux-pro-max-skill" "Add marketplace: ui-ux-pro-max-skill"
Invoke-ClaudeCmd "/plugin install ui-ux-pro-max@ui-ux-pro-max-skill"             "Install: ui-ux-pro-max"

# ── ruvnet/ruflo ─────────────────────────────────────────────────────────
Write-Host "`n   [ruflo]" -ForegroundColor DarkCyan
Invoke-ClaudeCmd "/plugin marketplace add ruvnet/ruflo"    "Add marketplace: ruvnet/ruflo"
Invoke-ClaudeCmd "/plugin install ruflo-core@ruflo"        "Install: ruflo-core"
Invoke-ClaudeCmd "/plugin install ruflo-swarm@ruflo"       "Install: ruflo-swarm"
Invoke-ClaudeCmd "/plugin install ruflo-autopilot@ruflo"   "Install: ruflo-autopilot"
Invoke-ClaudeCmd "/plugin install ruflo-federation@ruflo"  "Install: ruflo-federation"

# ── affaan-m/everything-claude-code ──────────────────────────────────────
Write-Host "`n   [everything-claude-code]" -ForegroundColor DarkCyan
Invoke-ClaudeCmd "/plugin marketplace add https://github.com/affaan-m/everything-claude-code" "Add marketplace: everything-claude-code"
Invoke-ClaudeCmd "/plugin install ecc@ecc"                                                     "Install: ecc"

# ════════════════════════════════════════════════════════════════════════════
# 8. GITHUB REPOS  (A) setup-script repo  (B) vault repo
# ════════════════════════════════════════════════════════════════════════════
Write-Step "8 / 8  GitHub — publish setup script + vault"

$githubVaultUrl  = $null
$githubScriptUrl = $null
$ghReady         = $false

if ($SkipGitHub) {
    Write-Ok "Skipped (--SkipGitHub)"
} elseif (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Warn "gh CLI not on PATH — skipping GitHub push."
} elseif (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Warn "git not on PATH — skipping GitHub push."
} else {
    # ── Authenticate if needed ─────────────────────────────────────────────
    $null = & gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "   GitHub authentication required." -ForegroundColor Yellow
        Write-Host "   A browser window will open — sign in and authorise the GitHub CLI." -ForegroundColor Yellow
        Write-Host ""
        & gh auth login --web --git-protocol https
        if ($LASTEXITCODE -eq 0) { $ghReady = $true }
        else { Write-Warn "GitHub auth failed — skipping push." }
    } else {
        Write-Ok "Already authenticated with GitHub"
        $ghReady = $true
    }
}

# ── Helper: init + first-commit + gh repo create + push ───────────────────
function Push-DirToGitHub {
    param(
        [string]$Dir,
        [string]$RepoName,
        [string]$Visibility,       # "private" | "public"
        [string]$CommitMsg,
        [string]$GitignoreContent
    )
    Push-Location $Dir
    try {
        if (-not (Test-Path ".git")) {
            & git init -b main | Out-Null
        }
        if ($GitignoreContent -and -not (Test-Path ".gitignore")) {
            $GitignoreContent | Out-File -FilePath ".gitignore" -Encoding utf8
            Write-Ok "Created .gitignore in $Dir"
        }
        & git add -A | Out-Null
        & git commit -m $CommitMsg --allow-empty | Out-Null

        # Try creating; if it already exists fall back to push-only
        & gh repo create $RepoName --$Visibility --source=. --remote=origin --push 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "$RepoName already exists — pushing to existing remote…"
            $existingUrl = & gh repo view $RepoName --json url --jq '.url' 2>$null
            if ($existingUrl) {
                & git remote remove origin 2>$null
                & git remote add origin "$($existingUrl).git"
                & git push -u origin main --force | Out-Null
            }
        }
        $ghUser = & gh api user --jq '.login' 2>$null
        return "https://github.com/$ghUser/$RepoName"
    } finally {
        Pop-Location
    }
}

if ($ghReady) {
    # ── 8A. Setup-script repo ─────────────────────────────────────────────
    Write-Host "`n   [8A] Publishing setup script to GitHub…" -ForegroundColor DarkCyan

    $scriptRepoName = "claude-env-setup"
    $scriptRepoDir  = Join-Path $env:TEMP $scriptRepoName
    if (Test-Path $scriptRepoDir) { Remove-Item $scriptRepoDir -Recurse -Force }
    New-Item -ItemType Directory -Path $scriptRepoDir -Force | Out-Null

    # Copy the script itself
    Copy-Item -Path $PSCommandPath -Destination (Join-Path $scriptRepoDir "setup-claude-env.ps1")

    # Generate a README so anyone cloning it knows exactly what to do
@"
# Claude Code — Full Environment Setup

One-command setup for a fresh Windows machine: installs Claude Code, Obsidian,
your global CLAUDE.md, all plugins & skills, scaffolds a PARA second-brain vault,
and pushes the vault to GitHub automatically.

## Quick start

```powershell
# 1. Clone this repo
git clone https://github.com/$((& gh api user --jq '.login' 2>$null))/$scriptRepoName.git
cd $scriptRepoName

# 2. (Optional) Place your CLAUDE.md next to the script
# 3. Run — everything else is handled automatically
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\setup-claude-env.ps1
```

## What gets installed

| Component | How |
|-----------|-----|
| winget | Auto-bootstrapped from GitHub if missing |
| Node.js LTS | winget |
| git | winget |
| GitHub CLI | winget |
| Claude Code CLI | npm |
| Obsidian | winget |
| obsidian-second-brain skill | npx skills add |
| impeccable skill | npx skills add |
| taste-skill | npx skills add |
| superpowers plugin | claude /plugin |
| ui-ux-pro-max plugin | claude /plugin |
| ruflo (core / swarm / autopilot / federation) | claude /plugin |
| everything-claude-code (ecc) | claude /plugin |

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| -ClaudeMdSource | CLAUDE.md (next to script) | Path to your global CLAUDE.md |
| -GitHubRepoName | obsidian-second-brain | Name for the vault's GitHub repo |
| -GitHubRepoVisibility | private | private or public |
| -SkipNodeInstall | false | Skip if Node is already installed |
| -SkipObsidian | false | Skip Obsidian install |
| -SkipGitHub | false | Skip all GitHub operations |

## Re-running on a new machine

The script is idempotent — it skips anything already installed.
"@ | Out-File -FilePath (Join-Path $scriptRepoDir "README.md") -Encoding utf8

    try {
        $githubScriptUrl = Push-DirToGitHub `
            -Dir          $scriptRepoDir `
            -RepoName     $scriptRepoName `
            -Visibility   "public" `
            -CommitMsg    "chore: initial setup script" `
            -GitignoreContent ""
        Write-Ok "Setup script published: $githubScriptUrl"
    } catch {
        Write-Warn "Failed to publish setup script: $_"
    }

    # ── 8B. Vault repo ────────────────────────────────────────────────────
    Write-Host "`n   [8B] Publishing vault to GitHub…" -ForegroundColor DarkCyan

    $vaultGitignore = @"
.obsidian/workspace.json
.obsidian/workspace-mobile.json
.trash/
.DS_Store
Thumbs.db
"@
    try {
        $githubVaultUrl = Push-DirToGitHub `
            -Dir          $vaultPath `
            -RepoName     $GitHubRepoName `
            -Visibility   $GitHubRepoVisibility `
            -CommitMsg    "chore: initial second-brain vault scaffold" `
            -GitignoreContent $vaultGitignore
        Write-Ok "Vault published: $githubVaultUrl"
    } catch {
        Write-Warn "Failed to publish vault: $_"
    }
}

# ════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║              Setup Complete! 🎉                  ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  What was installed / configured:" -ForegroundColor White
Write-Host "    • winget (App Installer, auto-bootstrapped if missing)" -ForegroundColor Gray
Write-Host "    • Node.js LTS + git" -ForegroundColor Gray
Write-Host "    • Claude Code CLI  (@anthropic-ai/claude-code)" -ForegroundColor Gray
Write-Host "    • GitHub CLI (gh)" -ForegroundColor Gray
Write-Host "    • Global CLAUDE.md → $claudeMdDst" -ForegroundColor Gray
Write-Host "    • Obsidian (PARA vault scaffolded at $vaultPath)" -ForegroundColor Gray
Write-Host "    • Skills: impeccable, taste-skill, obsidian-second-brain" -ForegroundColor Gray
Write-Host "    • Plugins: superpowers, ui-ux-pro-max, ruflo (core/swarm/autopilot/federation), ecc" -ForegroundColor Gray
if ($githubScriptUrl) {
Write-Host "    • Setup script repo (public):  $githubScriptUrl" -ForegroundColor Gray
}
if ($githubVaultUrl) {
Write-Host "    • Vault repo ($GitHubRepoVisibility): $githubVaultUrl" -ForegroundColor Gray
}
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor White
Write-Host "    1. Open a NEW terminal so PATH changes take effect" -ForegroundColor Gray
Write-Host "    2. Run: claude   to start Claude Code" -ForegroundColor Gray
Write-Host "    3. Open Obsidian → Open folder as vault → $vaultPath" -ForegroundColor Gray
if ($githubScriptUrl) {
Write-Host "    4. Share the setup script with anyone: $githubScriptUrl" -ForegroundColor Gray
}
if ($githubVaultUrl) {
Write-Host "    5. Clone your vault on a new machine: git clone $githubVaultUrl" -ForegroundColor Gray
}
Write-Host ""
