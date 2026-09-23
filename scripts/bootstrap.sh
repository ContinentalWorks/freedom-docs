#!/usr/bin/env bash
# bootstrap.sh — gets the agent alive, then gets out of the way.
#
# This script does FOUR things: Homebrew, Node + Git + jq, Claude Code, and the
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

# ---------- Saying what is happening, on three surfaces ----------
#
# WHY THIS IS HERE AT ALL. The handoff below turns every approval prompt off, for the reason
# argued over handoff_cmd: a newcomer cannot tell a dangerous write from an ordinary one, so
# a wall of dialogs only teaches them to click through. That reasoning holds, and it leaves a
# debt. The prompts were the only thing telling them what was happening, and taking them away
# without replacing them leaves someone watching a black terminal install software onto their
# own machine. If you take the prompts away, you owe them a receipt.
#
# Three surfaces, and each covers a case the others cannot:
#   the terminal   carries the explanation, and always works
#   a Mac banner   covers the ten minutes they walk away from a Homebrew download
#   the receipt    ~/Freedom-install-receipt.txt, what changed and how to undo it, kept
#
# NOT THE SAME FILE AS $LOG_FILE, and both stay. ~/.freedom-setup.log is a timestamped
# machine log for diagnosing a failed run. The receipt is a plain-text document for the
# person, in their home folder rather than hidden, written for someone who has never opened
# a terminal. Two readers, two artifacts.
#
# The install skill this hands off to writes its own copy of these functions, deliberately.
# Sharing one file across two repos on two release cadences drifts the moment either moves,
# and the skill itself warns about exactly that. The only shared contract is the receipt
# format, which is a plain text file two programs append to, documented by its own header.
#
# NOTHING HERE MAY EVER FAIL THE INSTALL. Every side effect is best-effort.

RECEIPT="$HOME/Freedom-install-receipt.txt"
BANNERS=0   # set to 1 by ask_banners once the operator has been told what is coming

receipt_init() {
  [[ "$DRY_RUN" -eq 1 || -f "$RECEIPT" ]] && return 0
  {
    echo "FREEDOM INSTALL RECEIPT"
    echo "Everything this setup changed on your Mac, in the order it happened."
    echo "Started $(date '+%Y-%m-%d %H:%M')."
    echo ""
    echo "Each entry is written as that step begins, so if setup stops partway"
    echo "through, this still shows you everything it had done by then."
    echo ""
    echo "You can delete this file. Keeping it means you always have a record of"
    echo "what was put on this machine and how to undo any of it."
    echo ""
  } >> "$RECEIPT" 2>/dev/null || true
}

# receipt_add <title> <where> <undo>
receipt_add() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  receipt_init
  {
    echo "[$(date '+%H:%M')] $1"
    [[ -n "${2:-}" ]] && echo "        Where: $2"
    [[ -n "${3:-}" ]] && echo "        Undo:  $3"
    echo ""
  } >> "$RECEIPT" 2>/dev/null || true
}

# Arguments reach osascript as argv rather than interpolated into the script text, so a
# title containing a quote cannot break or inject into the AppleScript.
banner() {
  [[ "$BANNERS" -eq 1 ]] || return 0
  osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "Freedom install"' \
    -e 'end run' -- "$1" >/dev/null 2>&1 || true
}

# Explain the macOS notification box BEFORE triggering it. The first `display notification`
# raises a permission dialog, and an unexplained system dialog during the one session where
# nothing works yet is the opposite of reassuring. This is the same courtesy the Homebrew
# step already extends about the invisible password typing.
ask_banners() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  command -v osascript >/dev/null 2>&1 || return 0
  echo ""
  echo "  This takes about ten minutes, and most of it is downloading."
  echo "  I can send you a notification as each step starts, so you can go"
  echo "  and do something else and still see where I got to."
  echo ""
  echo "  Your Mac is about to ask whether to allow that. Saying no is fine:"
  echo "  you will still see every step here in this window."
  echo ""
  BANNERS=1
  banner "Setup started. I will tell you what I am doing at each step."
}

# step_begin <title> [doing] [changes] [not-touched] [undo]
#
# The four-line block is the whole safety measure. `Not touched:` is the line that converts a
# list of operations into a boundary, and it is the one that will get dropped first if this is
# ever a documented format rather than a function.
step_begin() {
  CURRENT_STEP="$1"
  STEP_START=$(date +%s)
  echo ""
  echo "==> $1"
  if [[ -n "${2:-}" || -n "${3:-}" || -n "${4:-}" ]]; then
    echo ""
    [[ -n "${2:-}" ]] && echo "    Doing:        $2"
    [[ -n "${3:-}" ]] && echo "    Changes:      $3"
    [[ -n "${4:-}" ]] && echo "    Not touched:  $4"
    echo ""
  fi
  log_line "BEGIN $1"
  banner "$1"
  receipt_add "$1" "${3:-}" "${5:-}"
}

# NO step_look HERE, deliberately. All four steps below change something, so a read-only
# variant would be dead code in a script whose whole job is four writes. The install skill
# this hands off to DOES have one (`say_look`) and uses it five times, because most of its
# steps only look. Saying "nothing changes" out loud is not filler there: someone who only
# ever hears that phrase when it is true will believe "installing" when that is.

step_done() {
  local elapsed=$(($(date +%s) - STEP_START))
  [[ -n "${1:-}" ]] && echo "    Done:         $1"
  log_line "OK    $CURRENT_STEP (${elapsed}s)"
}

on_fail() {
  log_line "FAIL  $CURRENT_STEP"
  banner "Setup stopped during: $CURRENT_STEP"
  echo ""
  echo "=================================================="
  echo "  Setup hit a problem during: $CURRENT_STEP"
  echo ""
  # The receipt is written per step as each begins, so it is an accurate account of what
  # exists even now. This is the case it was built for: the moment they most need to know
  # what is on their machine is the moment the thing telling them has just failed.
  if [[ -f "$RECEIPT" ]]; then
    echo "  Nothing is in a broken state. What setup had already"
    echo "  done is written down in:"
    echo "    $RECEIPT"
    echo ""
  fi
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
#
# The mode is READ rather than baked in, since #227. bootstrap usually runs on a
# machine with no ~/.freedom/config.json yet, so in the ordinary case this IS the
# default; what it buys is the re-run. An operator who has recorded `auto` and
# re-bootstraps is not quietly put back on bypass by an installer that predates
# their decision. The parse matches lib/freedom-permission-mode.mjs exactly, and
# test-setup-scripts.sh checks that rather than trusting it.
freedom_mode() {
  # `:-` is load-bearing: this script runs under `set -u`, and a bare expansion of an unset
  # override aborted the function mid-way and emitted an EMPTY --permission-mode.
  local m="${FREEDOM_PERMISSION_MODE:-}"
  [ -z "$m" ] && m="$(sed -n 's/.*"permissionMode"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p' \
    "${FREEDOM_HOME:-$HOME}/.freedom/config.json" 2>/dev/null | head -1)"
  case "$m" in bypassPermissions|acceptEdits|auto|default|plan) ;; *) m=bypassPermissions ;; esac
  printf '%s' "$m"
}
# One prompt, used by the exec at the end and by --print-handoff, so the two cannot disagree.
HANDOFF_PROMPT="Read \$INSTALL_SKILL_FILE and follow it exactly. It is the Freedom install skill. It is run TOGETHER with the person who invited them, who should be on a call or in the room; the skill's first section asks, and if they are not, you stop there and say so, running nothing."
handoff_prompt() { printf '%s' "${HANDOFF_PROMPT//\$INSTALL_SKILL_FILE/$INSTALL_SKILL_FILE}"; }
handoff_cmd() {
  printf 'claude --permission-mode %s "%s"\n' "$(freedom_mode)" "$(handoff_prompt)"
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

# Offered before the first step, so the operator hears about the notification box from this
# script rather than meeting it cold from macOS.
ask_banners

# ---------- Step 1: Homebrew ----------

step_begin "Homebrew (the Mac package manager)" \
  "installing the tool that installs everything else on a Mac" \
  "a new folder for Homebrew, and one line added to ~/.zprofile so your shell can find it" \
  "any app you already have, and nothing existing is upgraded or replaced" \
  "see https://github.com/homebrew/install#uninstall-homebrew"
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
step_done "Homebrew is on this Mac and your shell can find it"

# ---------- Step 2: Node and Git ----------
#
# Only what the harness itself needs to run. The GitHub CLI used to be
# installed here too, but nothing before the handoff uses it: it exists for
# the private-repo login and the workspace, both of which are now the agent's
# job. It installs `gh` itself, and can actually recover when the login fails
# on a managed work device.

# jq joins node and git because capture depends on it and its absence is SILENT: both
# readers' sync.sh print "jq: command not found" and exit 0 with an empty result, which
# reads as a clean "0 new" run. A fresh machine that reaches capture without it gets a
# relationship manager that reports success and stays empty (#53, @yyabdi).
step_begin "Node.js, Git and jq (what the harness runs on)" \
  "installing the three building blocks Freedom itself runs on" \
  "three command line tools, installed by Homebrew" \
  "nothing you have installed yourself; if you already have any of these, they are left alone" \
  "brew uninstall node git jq"
for formula in node git jq; do
  if command -v "$formula" >/dev/null 2>&1; then
    echo "    $formula already installed: $("$formula" --version 2>/dev/null | head -1)"
  else
    echo "    installing $formula..."
    run brew install "$formula"
  fi
done
step_done "Node.js, Git and jq are installed"

# ---------- Step 3: Claude Code ----------

step_begin "Claude Code (the agent)" \
  "installing the agent that does the rest of the setup and that you will talk to afterwards" \
  "the Claude Code app, from Homebrew's reviewed and signed build" \
  "your files; installing it does not sign you in to anything or read anything" \
  "brew uninstall --cask claude-code"
if command -v claude >/dev/null 2>&1; then
  echo "    already installed: $(claude --version 2>/dev/null | head -1)"
else
  echo "    installing via Homebrew cask (reviewed, signed binary)..."
  run brew install --cask claude-code
fi
step_done "Claude Code is installed; nothing is signed in yet"

# ---------- Step 4: Fetch the install skill ----------
#
# Fetched BEFORE the launch, and failing here is fatal on purpose. Handing an
# agent a prompt that points at a file which does not exist is the worst of
# both worlds: it looks like it worked, then wanders.

step_begin "The install skill" \
  "downloading the written instructions the agent follows for the rest of the setup" \
  "one text file at $INSTALL_SKILL_FILE" \
  "anything else; this is a document, not a program, and you can open and read it" \
  "rm $INSTALL_SKILL_FILE"
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
step_done "the install skill is on disk, and you can open it and read it"

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
echo "  It will tell you what it is doing at every step, and"
echo "  write it down in Freedom-install-receipt.txt in your"
echo "  home folder, with how to undo any of it."
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

# THE INSTALL IS ONE HALF OF A CO-BUILD SESSION, never a solo run. The skill's first section
# asks whether the person who invited them is on with them and refuses to continue when the
# answer is no; the prompt says so too, so the agent does not read that section as a
# formality. A new operator followed the skill alone on 2026-09-19, dead-ended at the editor
# and filed four defects from a bare terminal in his first hour (Gary: "let's not allow people
# to manually install").
exec claude --permission-mode "$(freedom_mode)" "$(handoff_prompt)"
