# bootstrap.ps1 - the Windows twin of bootstrap.sh: gets the agent alive, then gets out of the way.
#
# Same boundary as the Mac script, for the same reason: everything that runs BEFORE the agent
# exists is a step with no recovery, so this does only what an agent cannot do for itself.
# Node.js, Git for Windows (which brings Git Bash, the shell Claude Code runs its hooks through),
# jq, Claude Code, and the handoff. Everything else is the install skill it fetches at the end.
#
# Official installers only: winget packages, and Claude Code's own install.ps1. Fetches no
# binaries itself. Idempotent: every step checks before it acts.
#
# Usage, in PowerShell:
#   irm https://getfreedom.wiki/bootstrap.ps1 | iex      (the normal path, once hosted)
#   .\bootstrap.ps1 -DryRun          print what would happen, change nothing
#   .\bootstrap.ps1 -NoLaunch        stop before the handoff
#   .\bootstrap.ps1 -PrintHandoff    show the handoff command and exit
#
# Written for Windows PowerShell 5.1, which every Windows 10 and 11 machine has; nothing here
# needs PowerShell 7. windows-port superproject, 2026-10-10.
param([switch]$DryRun, [switch]$NoLaunch, [switch]$PrintHandoff)

$ErrorActionPreference = "Stop"

$InstallSkillUrl = if ($env:FREEDOM_INSTALL_SKILL_URL) { $env:FREEDOM_INSTALL_SKILL_URL } else { "https://www.getfreedom.wiki/skills/install-freedom-windows/SKILL.md" }
# www, never the bare domain: getfreedom.wiki answers with a 308 to www, and Windows PowerShell
# 5.1's Invoke-WebRequest does not follow a 308 (curl on the Mac does). Measured 2026-10-10.
$InstallSkillFile = Join-Path $HOME ".freedom-install.md"
$LogFile = Join-Path $HOME ".freedom-setup.log"

function Log([string]$line) {
  try { Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format s), $line) } catch { }
}

function Freedom-Mode {
  $m = $env:FREEDOM_PERMISSION_MODE
  if (-not $m) {
    $cfg = Join-Path $HOME ".freedom\config.json"
    if (Test-Path $cfg) {
      $hit = Select-String -Path $cfg -Pattern '"permissionMode"\s*:\s*"([A-Za-z]+)"' | Select-Object -First 1
      if ($hit) { $m = $hit.Matches[0].Groups[1].Value }
    }
  }
  if (@("bypassPermissions", "acceptEdits", "auto", "default", "plan") -notcontains $m) { $m = "bypassPermissions" }
  return $m
}

# The same words bootstrap.sh hands over, so both installs open the same conversation.
$HandoffPrompt = "Read $InstallSkillFile and follow it exactly. It is the Freedom install skill. It is run TOGETHER with the person who invited them, who should be on a call or in the room; the skill's first section asks, and if they are not, you stop there and say so, running nothing."
function Handoff-Command { return ('claude --permission-mode {0} "{1}"' -f (Freedom-Mode), $HandoffPrompt) }

if ($PrintHandoff) { Handoff-Command; exit 0 }

if ($env:OS -ne "Windows_NT") {
  Write-Host "This is the Windows bootstrap. On a Mac, run bootstrap.sh instead."
  exit 1
}

# winget installs to places the current session's PATH has never heard of. Re-read it from the
# registry after each install rather than asking them to open a new window halfway through.
function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}

function Have([string]$cmd) { return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

function Step([string]$title, [string]$what) {
  Write-Host ""
  Write-Host "==> $title"
  Write-Host "    $what"
  Log "step: $title"
}

function Fail([string]$why) {
  Write-Host ""
  Write-Host "    Something went wrong: $why"
  Write-Host "    The full log is at $LogFile. Run this script again; it picks up where it stopped."
  Log "FAILED: $why"
  exit 1
}

function Winget-Install([string]$id, [string]$label) {
  if ($DryRun) { Write-Host "    [dry-run] would run: winget install --id $id"; return }
  Write-Host "    installing $label..."
  winget install --id $id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
  # winget exits non-zero when the package is already present and up to date; the check that
  # matters is whether the command resolves afterwards, which the caller makes.
  Refresh-Path
}

Write-Host "=================================================="
Write-Host "  Freedom BOOTSTRAP (Windows)"
if ($DryRun) { Write-Host "  DRY RUN: nothing will be installed or changed." }
Write-Host "  Four steps, then your agent takes over."
Write-Host "  Log: $LogFile"
Write-Host "=================================================="
Log "=== bootstrap.ps1 run started (dry_run=$DryRun) ==="

# A window opened before an earlier run (or this one's parent) carries a stale PATH, so read the
# registry first: otherwise a second run reinstalls Claude Code it cannot see (CI, 2026-10-10).
Refresh-Path

if (-not (Have "winget")) {
  Fail "winget (the Windows package manager) is missing. Install 'App Installer' from the Microsoft Store, then run this again."
}

Step "Node.js and Git (what the harness runs on)" "Git for Windows brings Git Bash, which Claude Code runs Freedom's hooks through."
if (Have "node") { Write-Host "    node already installed: $(node --version)" } else { Winget-Install "OpenJS.NodeJS.LTS" "Node.js" }
if (Have "git") { Write-Host "    git already installed: $(git --version)" } else { Winget-Install "Git.Git" "Git for Windows" }
if (Have "jq") { Write-Host "    jq already installed" } else { Winget-Install "jqlang.jq" "jq" }
if (-not $DryRun) {
  foreach ($c in @("node", "git")) { if (-not (Have $c)) { Fail "$c did not install (winget finished but '$c' is not on PATH)." } }
}

# Freedom's scripts call `python3` by that name: 65 times across the skills, and from node, whose
# spawn finds only a real .exe by bare name. A stock Windows PC has no python3 at all, or the
# Microsoft Store stub that opens the Store instead of running (exit 9009). So: Python from winget,
# then a hard link python3.exe beside python.exe (same folder, so it finds its DLLs), and that
# folder ahead of WindowsApps in the User PATH so the stub never wins. windows-port, 2026-10-10.
function Real-Python3 {
  if (-not (Have "python3")) { return $false }
  try { $v = & python3 --version 2>&1; return ($LASTEXITCODE -eq 0 -and "$v" -match "^Python 3") } catch { return $false }
}
Step "Python 3 (what many of Freedom's scripts run on)" "Python from winget, and a python3 command that is the real thing rather than the Store shortcut."
if (Real-Python3) {
  Write-Host "    python3 already works: $(python3 --version 2>&1)"
} elseif ($DryRun) {
  Write-Host "    [dry-run] would install Python 3.12 and add python3.exe beside python.exe"
} else {
  $exe = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA "Programs\Python") -Filter python.exe -Recurse -Depth 1 -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
  if (-not $exe) {
    Write-Host "    installing Python 3.12..."
    winget install --id Python.Python.3.12 --exact --scope user --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
    $exe = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA "Programs\Python") -Filter python.exe -Recurse -Depth 1 -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
  }
  if (-not $exe) { Fail "Python did not install (no python.exe under $env:LOCALAPPDATA\Programs\Python)." }
  $dir = $exe.DirectoryName
  $py3 = Join-Path $dir "python3.exe"
  if (-not (Test-Path $py3)) { New-Item -ItemType HardLink -Path $py3 -Target $exe.FullName | Out-Null; Write-Host "    added python3.exe beside $($exe.FullName)" }
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $parts = @($userPath -split ";" | Where-Object { $_ -and $_ -ne $dir -and $_ -ne (Join-Path $dir "Scripts") })
  [Environment]::SetEnvironmentVariable("Path", (@($dir, (Join-Path $dir "Scripts")) + $parts) -join ";", "User")
  Refresh-Path
  # The registry User PATH comes after the Machine PATH; put Python first in this session too.
  $env:Path = "$dir;$env:Path"
  if (-not (Real-Python3)) { Fail "python3 still does not run after installing Python to $dir." }
  Write-Host "    python3 works: $(python3 --version 2>&1)"
}

Step "Claude Code (the agent)" "the agent that does the rest of the setup, from Anthropic's own Windows installer."
if (Have "claude") {
  Write-Host "    claude already installed: $(claude --version)"
} elseif ($DryRun) {
  Write-Host "    [dry-run] would run Claude Code's official installer (claude.ai/install.ps1)"
} else {
  Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
  Refresh-Path
  # Claude Code's installer puts claude.exe in ~\.local\bin and leaves adding that to PATH to
  # the person, through System Properties (measured 2026-10-10). Done here, for the User PATH, so
  # a new window finds `claude` and nobody has to edit environment variables by hand.
  $localBin = Join-Path $HOME ".local\bin"
  if (Test-Path (Join-Path $localBin "claude.exe")) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (($userPath -split ";") -notcontains $localBin) {
      [Environment]::SetEnvironmentVariable("Path", (($userPath.TrimEnd(";") + ";" + $localBin).TrimStart(";")), "User")
      Write-Host "    added $localBin to your PATH so new windows find claude"
      Log "added $localBin to User PATH"
    }
    Refresh-Path
  }
  if (-not (Have "claude")) { Fail "Claude Code's installer finished but 'claude' is not on PATH." }
}

Step "The install skill" "the written instructions the agent follows for the rest of the setup: one text file at $InstallSkillFile."
if ($DryRun) {
  Write-Host "    [dry-run] would fetch $InstallSkillUrl"
} else {
  try { Invoke-WebRequest -UseBasicParsing -Uri $InstallSkillUrl -OutFile $InstallSkillFile } catch { Fail "could not fetch the install skill from $InstallSkillUrl ($($_.Exception.Message))" }
  $head = (Get-Content $InstallSkillFile -TotalCount 20) -join "`n"
  if ($head -notmatch "install-freedom") {
    Remove-Item $InstallSkillFile -ErrorAction SilentlyContinue
    Fail "the URL returned something that is not the install skill: $InstallSkillUrl"
  }
  Write-Host "    fetched ($((Get-Content $InstallSkillFile).Count) lines)"
}

Write-Host ""
Write-Host "=================================================="
Write-Host "  Foundation ready."
foreach ($c in @("node", "git", "python3", "claude")) { Write-Host ("    {0,-12}{1}" -f $c, $(if (Have $c) { "ok" } else { "MISSING" })) }
Write-Host ""
Write-Host "  Everything else is done by your agent, which can see what"
Write-Host "  actually happens on this machine and ask you when something"
Write-Host "  is not what it expected. The first launch opens a browser so"
Write-Host "  you can sign in."
Write-Host "=================================================="
Log "=== foundation complete, handing off ==="

if ($NoLaunch -or $DryRun) {
  Write-Host ""
  Write-Host "  Not launching. When you are ready, run:"
  Write-Host ""
  Write-Host "    $(Handoff-Command)"
  exit 0
}
& claude --permission-mode (Freedom-Mode) $HandoffPrompt
