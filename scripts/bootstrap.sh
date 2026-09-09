#!/usr/bin/env bash
# bootstrap.sh — gets the agent alive, then gets out of the way.
#
# This script does FOUR things: Homebrew, Node + Git, Claude Code, and the
# handoff. Everything else about setting up Freedom — VS Code, the capture
# stack, the GitHub login, your workspace, the plugin, hourly sync, the
# launcher — is done afterwards by the agent, following the install skill it
# fetches at the end.
#
# Why the split is here and not further along:
#
#   Every step that runs BEFORE the agent exists is a step with no recovery.
#   A script has to predict its failures; an agent can read one it has never
#   seen, on a machine nobody tested, and ask you a question instead of dying.
#   The old version of this file ran thirteen steps before handing off, and
#   its own escape hatch was "paste the last twenty lines into your AI chat"
#   — which is the agent doing recovery anyway, just by hand, after the
#   failure, for someone who does not know what they are looking at.
#
#   So the boundary is drawn at the earliest point where an agent can exist.
#   You cannot agent your way to having an agent: something has to install
#   Node and the harness. That part is irreducible, and it is all that is
#   left here.
#
# Idempotent: every step checks before it acts. Running it twice is harmless;
# running it on a half-set-up machine finishes the job.
#
# It orchestrates only official installers (Homebrew's install script and
# Homebrew-reviewed casks). It fetches no binaries itself.
#
# Usage:
#   bash bootstrap.sh                  # the normal path
#   bash bootstrap.sh --dry-run        # print what would happen, change nothing
#   bash bootstrap.sh --no-launch      # stop before the handoff
#   bash bootstrap.sh --print-handoff  # show the handoff command and exit
#
# Executable form of:
#   https://supersuit.wiki/freedom/supersuit-up-workshop/install-your-tools

set -uo pipefail

# The install skill the agent follows once it is alive. Hosted rather than
# shipped, for the same reason the upgrade ledger is hosted: an operator who
# ran an old bootstrap still gets the CURRENT install steps, and the skill can
# be fixed without cutting a template release. It is public and needs no auth,
# which is what keeps the private-repo GitHub login on the agent's side of the
# boundary instead of dragging it back into this script.
INSTALL_SKILL_URL="${FREEDOM_INSTALL_SKILL_URL:-https://getfreedom.wiki/skills/install-freedom/SKILL.md}"
INSTALL_SKILL_FILE="$HOME/.freedom-install.md"

LOG_FILE="$HOME/.freedom-setup.log"

DRY_RUN=0
NO_LAUNCH=0
PRINT_HANDOFF=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-launch) NO_LAUNCH=1 ;;
    --print-handoff) PRINT_HANDOFF=1 ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//' | head -36
      exit 0
      ;;
    *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
  esac
  shift
done

# ---------- Logging and failure handling ----------

CURRENT_STEP="starting"
STEP_START=0

log_line() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG_FILE"
}

step_begin() {
  CURRENT_STEP="$1"
  STEP_START=$(date +%s)
  echo ""
  echo "==> $1"
  log_line "BEGIN $1"
}

step_done() {
  local elapsed=$(($(date +%s) - STEP_START))
  log_line "OK    $CURRENT_STEP (${elapsed}s)"
}

on_fail() {
  log_line "FAIL  $CURRENT_STEP"
  echo ""
  echo "=================================================="
  echo "  Setup hit a problem during: $CURRENT_STEP"
  echo ""
  echo "  This is normal and fixable. Copy the last twenty"
  echo "  lines of output above (and the log at $LOG_FILE)"
  echo "  and paste them into your AI chat (Claude, ChatGPT,"
  echo "  Gemini) with the question: \"I was running the Freedom"
  echo "  bootstrap script and got this. What do I do?\""
  echo ""
  echo "  Then run this script again. It picks up where it"
  echo "  left off; finished steps are skipped."
  echo "=================================================="
  exit 1
}

run() { # run <command...> — executes, or narrates under --dry-run
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "    [dry-run] would run: $*"
    return 0
  fi
  "$@" || on_fail
}

# The handoff command, in one place so --print-handoff and the launch below
# can never drift apart.
#
# `--permission-mode bypassPermissions` deliberately, NOT
# --dangerously-skip-permissions. This used to hand off `auto`, on the reasoning
# that an installer runs on the machine of someone new to all of this who will
# approve whatever they are shown, so the classifier should stay in the loop.
#
# What that argument missed is what the prompts actually teach. A newcomer
# cannot tell a dangerous write from an ordinary one that merely looks dangerous
# out of context, so the classifier does not hand them a judgement they can
# make; it hands them a wall of approvals during the one session where nothing
# is working yet and they have no way to evaluate any of it. What they learn
# from that is to click through, which is the habit `auto` was meant to prevent,
# taught faster.
#
# So the installer and the `freedom` launcher run the same mode again. Which
# door you came in should not change what the agent may do, which is what
# #26 was filed about; this keeps that property with the value flipped.
#
# --dangerously-skip-permissions is still refused. It is the same posture
# spelled as a warning, and test-setup-scripts.sh asserts it never appears.
handoff_cmd() {
  printf 'claude --permission-mode bypassPermissions %s\n' \
    "\"Read $INSTALL_SKILL_FILE and follow it exactly. It is the Freedom install skill.\""
}

if [[ "$PRINT_HANDOFF" -eq 1 ]]; then
  handoff_cmd
  exit 0
fi

# ---------- Platform gate ----------

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This bootstrap currently supports macOS only."
  echo "On Windows or Linux, follow the manual steps at:"
  echo "  https://supersuit.wiki/freedom/supersuit-up-workshop/install-your-tools"
  exit 1
fi

OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo 0)"
if [[ "${OS_VERSION%%.*}" -lt 13 ]]; then
  echo "macOS $OS_VERSION is below the macOS 13 floor for these tools."
  echo "Run Software Update first (System Settings > General > Software Update),"
  echo "then run this script again."
  exit 1
fi

echo "=================================================="
echo "  Freedom BOOTSTRAP"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  DRY RUN: nothing will be installed or changed."
fi
echo "  Four steps, then your agent takes over."
echo "  Log: $LOG_FILE"
echo "=================================================="
log_line "=== bootstrap run started (dry_run=$DRY_RUN) ==="

# ---------- Step 1: Homebrew ----------

step_begin "Homebrew (the Mac package manager)"
BREW_BIN=""
if command -v brew >/dev/null 2>&1; then
  BREW_BIN="$(command -v brew)"
  echo "    already installed: $(brew --version | head -1)"
elif [[ -x /opt/homebrew/bin/brew ]]; then
  BREW_BIN="/opt/homebrew/bin/brew"
  echo "    installed but not on PATH — repairing"
elif [[ -x /usr/local/bin/brew ]]; then
  BREW_BIN="/usr/local/bin/brew"
  echo "    installed but not on PATH — repairing"
else
  echo "    not found — installing via the official Homebrew installer."
  echo "    You may be asked for your Mac login password. Your typing is"
  echo "    invisible while you type it. That is normal."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "    [dry-run] would run the official Homebrew install script"
  else
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || on_fail
    if [[ -x /opt/homebrew/bin/brew ]]; then BREW_BIN="/opt/homebrew/bin/brew"; else BREW_BIN="/usr/local/bin/brew"; fi
  fi
fi

# Put brew on PATH for this shell and every future one.
if [[ -n "$BREW_BIN" && "$DRY_RUN" -eq 0 ]]; then
  eval "$("$BREW_BIN" shellenv)"
  ZPROFILE="$HOME/.zprofile"
  if ! grep -qs 'brew shellenv' "$ZPROFILE"; then
    echo "eval \"\$($BREW_BIN shellenv)\"" >> "$ZPROFILE"
    echo "    added Homebrew to PATH in ~/.zprofile"
  fi
fi
step_done

# ---------- Step 2: Node and Git ----------
#
# Only what the harness itself needs to run. The GitHub CLI used to be
# installed here too, but nothing before the handoff uses it: it exists for
# the private-repo login and the workspace, both of which are now the agent's
# job. It installs `gh` itself, and can actually recover when the login fails
# on a managed work device.

step_begin "Node.js and Git (what the harness runs on)"
for formula in node git; do
  if command -v "$formula" >/dev/null 2>&1; then
    echo "    $formula already installed: $("$formula" --version 2>/dev/null | head -1)"
  else
    echo "    installing $formula..."
    run brew install "$formula"
  fi
done
step_done

# ---------- Step 3: Claude Code ----------

step_begin "Claude Code (the agent)"
if command -v claude >/dev/null 2>&1; then
  echo "    already installed: $(claude --version 2>/dev/null | head -1)"
else
  echo "    installing via Homebrew cask (reviewed, signed binary)..."
  run brew install --cask claude-code
fi
step_done

# ---------- Step 4: Fetch the install skill ----------
#
# Fetched BEFORE the launch, and failing here is fatal on purpose. Handing an
# agent a prompt that points at a file which does not exist is the worst of
# both worlds: it looks like it worked, then wanders.

step_begin "The install skill"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "    [dry-run] would fetch $INSTALL_SKILL_URL"
  echo "    [dry-run] would write $INSTALL_SKILL_FILE"
else
  if ! curl -fsSL "$INSTALL_SKILL_URL" -o "$INSTALL_SKILL_FILE"; then
    echo "    could not fetch the install skill from:"
    echo "      $INSTALL_SKILL_URL"
    echo "    Check your internet connection and run this script again."
    on_fail
  fi
  # A 200 that returns a login page or an error body is still a failure, and it
  # is the one that gets through. Prove it is the skill, not merely bytes.
  if ! head -20 "$INSTALL_SKILL_FILE" | grep -qi 'install-freedom'; then
    echo "    the URL returned something that is not the install skill."
    # Truncated hard: a minified HTML page is ONE line, so head -5 prints the
    # entire document at someone who cannot read it anyway.
    echo "    What came back instead (first 200 characters):"
    head -c 200 "$INSTALL_SKILL_FILE" | tr -d '\n' | sed 's/^/      /'
    echo ""
    rm -f "$INSTALL_SKILL_FILE"
    on_fail
  fi
  echo "    fetched ($(wc -l < "$INSTALL_SKILL_FILE" | tr -d ' ') lines)"
fi
step_done

# ---------- Handoff ----------

echo ""
echo "=================================================="
echo "  Foundation ready."
echo ""
echo "    Homebrew      $(command -v brew >/dev/null 2>&1 && echo ok || echo MISSING)"
echo "    Node.js       $(command -v node >/dev/null 2>&1 && node --version || echo MISSING)"
echo "    Git           $(command -v git  >/dev/null 2>&1 && echo ok || echo MISSING)"
echo "    Claude Code   $(command -v claude >/dev/null 2>&1 && echo ok || echo MISSING)"
echo ""
echo "  Everything else is done by your agent, which can"
echo "  see what actually happens on this machine and ask"
echo "  you when something is not what it expected."
echo ""
echo "  The first launch opens a browser so you can sign in."
echo "=================================================="
log_line "=== foundation complete, handing off ==="

if [[ "$NO_LAUNCH" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
  echo ""
  echo "  Not launching. When you are ready, run:"
  echo ""
  echo "    $(handoff_cmd)"
  echo ""
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  echo ""
  echo "  Claude Code is installed but not on this shell's PATH yet."
  echo "  Open a NEW terminal window and run:"
  echo ""
  echo "    $(handoff_cmd)"
  echo ""
  exit 0
fi

exec claude --permission-mode bypassPermissions \
  "Read $INSTALL_SKILL_FILE and follow it exactly. It is the Freedom install skill."
