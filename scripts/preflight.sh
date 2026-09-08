#!/usr/bin/env bash
# preflight.sh — the night-before check for the Supersuit Up workshop.
#
# READ-ONLY. Installs nothing, changes nothing. Runs in under a minute.
# Grades your machine, reports which tools are already installed, and prints
# a personal checklist of the human-only steps to do tonight.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/SupersuitUp/freedom-workspace-template/main/scripts/preflight.sh | bash
#
# Executable form of: https://supersuit.wiki/freedom/supersuit-up-workshop/before-you-start

set -uo pipefail

PASS="✅"
WARN="⚠️ "
FAIL="❌"

WARNINGS=0
FAILURES=0

APPS_DIR="${FREEDOM_APPS_DIR:-/Applications}"   # overridable so tests can exercise the cold path

row() { # row <icon> <label> <detail>
  printf "  %s %-18s %s\n" "$1" "$2" "$3"
  case "$1" in
    "$WARN") WARNINGS=$((WARNINGS + 1)) ;;
    "$FAIL") FAILURES=$((FAILURES + 1)) ;;
  esac
}

header() {
  echo ""
  echo "$1"
  echo "--------------------------------------------------"
}

echo "=================================================="
echo "  Freedom PREFLIGHT — the night-before check"
echo "  Read-only: nothing is installed or changed."
echo "=================================================="

# ---------- Platform ----------

OS="$(uname -s)"
if [[ "$OS" != "Darwin" ]]; then
  echo ""
  echo "This preflight currently supports macOS only."
  echo "On Windows or Linux, follow the manual checklist instead:"
  echo "  https://supersuit.wiki/freedom/supersuit-up-workshop/before-you-start"
  exit 0
fi

# ---------- Hardware ----------

header "HARDWARE"

CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
  # Parse the M-generation out of e.g. "Apple M3 Pro"
  MGEN="$(echo "$CHIP" | sed -n 's/.*Apple M\([0-9][0-9]*\).*/\1/p')"
  if [[ -n "$MGEN" && "$MGEN" -ge 3 ]]; then
    row "$PASS" "Chip" "$CHIP (Apple Silicon, M3 or newer)"
  elif [[ -n "$MGEN" ]]; then
    row "$WARN" "Chip" "$CHIP — works, but M3+ is the recommended floor; expect slower sessions"
  else
    row "$PASS" "Chip" "$CHIP (Apple Silicon)"
  fi
else
  row "$FAIL" "Chip" "$CHIP — Intel Mac. The workshop will be painful; there is no software workaround. See https://supersuit.wiki/reference/laptop-requirements"
fi

RAM_BYTES="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
RAM_GB=$((RAM_BYTES / 1073741824))
if [[ "$RAM_GB" -ge 32 ]]; then
  row "$PASS" "RAM" "${RAM_GB} GB (comfortable)"
elif [[ "$RAM_GB" -ge 16 ]]; then
  row "$PASS" "RAM" "${RAM_GB} GB (honest minimum; 32 GB is the comfortable floor)"
else
  row "$FAIL" "RAM" "${RAM_GB} GB — below the 16 GB minimum. See https://supersuit.wiki/reference/laptop-requirements"
fi

DISK_AVAIL_GB="$(df -g / 2>/dev/null | awk 'NR==2 {print $4}')"
DISK_AVAIL_GB="${DISK_AVAIL_GB:-0}"
if [[ "$DISK_AVAIL_GB" -ge 30 ]]; then
  row "$PASS" "Free disk" "${DISK_AVAIL_GB} GB free"
elif [[ "$DISK_AVAIL_GB" -ge 15 ]]; then
  row "$WARN" "Free disk" "${DISK_AVAIL_GB} GB free — enough, but tight (Xcode tools alone pull ~10 GB)"
else
  row "$FAIL" "Free disk" "${DISK_AVAIL_GB} GB free — clear space before the workshop"
fi

OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo 0)"
OS_MAJOR="${OS_VERSION%%.*}"
if [[ "$OS_MAJOR" -ge 15 ]]; then
  row "$PASS" "macOS" "$OS_VERSION"
elif [[ "$OS_MAJOR" -ge 13 ]]; then
  row "$WARN" "macOS" "$OS_VERSION — works; macOS 15 (Sequoia) is recommended. Consider updating tonight."
else
  row "$FAIL" "macOS" "$OS_VERSION — below the macOS 13 floor. Update TONIGHT (System Settings > General > Software Update); this can take 1-2 hours."
fi

# ---------- Tools already installed ----------

header "TOOLS ALREADY ON THIS MACHINE"

check_tool() { # check_tool <cmd> <label> <version-args>
  local cmd="$1" label="$2"
  shift 2
  if command -v "$cmd" >/dev/null 2>&1; then
    local v
    v="$("$cmd" "$@" 2>/dev/null | head -1 || true)"
    row "$PASS" "$label" "installed (${v:-version unknown})"
    return 0
  else
    row "$WARN" "$label" "not installed — the bootstrap script will install it"
    return 1
  fi
}

# Homebrew may be installed but not on PATH in this shell
if command -v brew >/dev/null 2>&1; then
  row "$PASS" "Homebrew" "installed ($(brew --version 2>/dev/null | head -1))"
elif [[ -x /opt/homebrew/bin/brew || -x /usr/local/bin/brew ]]; then
  row "$WARN" "Homebrew" "installed but not on PATH — the bootstrap script will repair this"
else
  row "$WARN" "Homebrew" "not installed — the bootstrap script will install it"
fi

check_tool node "Node.js" --version || true
check_tool git "Git" --version || true
check_tool gh "GitHub CLI" --version || true

if [[ -d "$APPS_DIR/Visual Studio Code.app" ]] || command -v code >/dev/null 2>&1; then
  row "$PASS" "VS Code" "installed"
else
  row "$WARN" "VS Code" "not installed — the bootstrap script will install it"
fi

check_tool claude "Claude Code" --version || true

for app_check in "Granola.app|Granola" "Wispr Flow.app|Wispr Flow"; do
  app="${app_check%%|*}"; label="${app_check##*|}"
  if [[ -d "$APPS_DIR/$app" ]]; then
    row "$PASS" "$label" "installed"
  else
    row "$WARN" "$label" "not installed — the bootstrap script will install it"
  fi
done

# ---------- Accounts and auth ----------

header "ACCOUNTS"

GH_READY=0
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  GH_USER="$(gh api user -q .login 2>/dev/null || echo "")"
  row "$PASS" "GitHub" "logged in${GH_USER:+ as $GH_USER}"
  GH_READY=1
else
  row "$WARN" "GitHub" "not logged in on this machine (account signup + login are human steps)"
fi

# ---------- The human checklist ----------

header "YOUR CHECKLIST FOR TONIGHT (no script can do these)"

N=1
if [[ "$OS_MAJOR" -lt 15 ]]; then
  echo "  $N. Run Software Update (System Settings > General > Software Update)."
  echo "     Plug in your charger and let it finish. Do NOT start the workshop"
  echo "     with a pending OS update."
  N=$((N + 1))
fi
if [[ "$GH_READY" -eq 0 ]]; then
  echo "  $N. Create a GitHub account at https://github.com if you do not have one."
  N=$((N + 1))
fi
echo "  $N. Pick the email you will sign up with, and log into it in your browser."
N=$((N + 1))
echo "  $N. Have a working credit card ready (most tools need one on file, even free tiers)."
N=$((N + 1))
echo "  $N. Decide your harness plan: Claude Pro (\$20/mo) or Max (\$100/mo). See"
echo "     https://supersuit.wiki/freedom/supersuit-up-workshop/install-your-tools"
N=$((N + 1))
echo "  $N. Create a Wispr Flow account at https://wisprflow.ai (voice-to-text,"
echo "     free trial then ~\$10/mo). The bootstrap installs the app; you sign in."
N=$((N + 1))
echo "  $N. Create a Granola account at https://granola.ai (meeting notes, free tier"
echo "     is enough to start). The bootstrap installs the app; you sign in."

# ---------- Verdict ----------

echo ""
echo "=================================================="
if [[ "$FAILURES" -gt 0 ]]; then
  echo "  VERDICT: $FAILURES blocker(s), $WARNINGS warning(s)."
  echo "  Fix the ${FAIL} items above before the workshop."
elif [[ "$WARNINGS" -gt 0 ]]; then
  echo "  VERDICT: ready, with $WARNINGS item(s) to note."
  echo "  Do the checklist tonight; run the bootstrap script on the day."
else
  echo "  VERDICT: fully ready. Run the bootstrap script on the day."
fi
echo "=================================================="
echo ""
echo "On workshop day, run the bootstrap script:"
echo "  https://supersuit.wiki/freedom/one-command-setup"
echo ""
