#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────
LOG_FILE="/var/log/dep_satisfier.log"
DRY_RUN=false
VERBOSE=false
MAX_DEPTH=20                      # Safety cap — prevents infinite recursion
declare -A VISITED                # Dedup — tracks already-processed packages

# ─────────────────────────────────────────────
# COLOURS
# ─────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ─────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────
log()     { echo -e "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
info()    { log "${CYAN}[INFO]${RESET}  $*"; }
success() { log "${GREEN}[OK]${RESET}    $*"; }
warn()    { log "${YELLOW}[WARN]${RESET}  $*"; }
error()   { log "${RED}[ERROR]${RESET} $*"; }
debug()   { $VERBOSE && log "[DEBUG] $*" || true; }

usage() {
    cat <<EOF
${BOLD}Usage:${RESET}
  sudo $0 [OPTIONS] <package-name>

${BOLD}Options:${RESET}
  -d, --dry-run     Show what would be installed without installing anything
  -v, --verbose     Print every dependency as it is resolved
  -l, --log FILE    Log file path (default: /var/log/dep_satisfier.log)
  -h, --help        Show this help message

${BOLD}Examples:${RESET}
  sudo $0 ffmpeg
  sudo $0 --dry-run nginx
  sudo $0 --verbose --log ~/my.log curl
EOF
    exit 0
}

# ─────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────
parse_args() {
    [[ $# -eq 0 ]] && usage

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dry-run)  DRY_RUN=true;       shift ;;
            -v|--verbose)  VERBOSE=true;        shift ;;
            -l|--log)      LOG_FILE="$2";       shift 2 ;;
            -h|--help)     usage ;;
            -*)  error "Unknown option: $1"; exit 1 ;;
            *)   TARGET_PKG="$1";               shift ;;
        esac
    done

    if [[ -z "${TARGET_PKG:-}" ]]; then
        error "No package name provided."
        usage
    fi
}

# ─────────────────────────────────────────────
# PREFLIGHT CHECKS
# ─────────────────────────────────────────────
preflight() {
    # Must be root (unless dry-run)
    if ! $DRY_RUN && [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (or with sudo) unless using --dry-run."
        exit 1
    fi

    # apt-cache must exist
    if ! command -v apt-cache &>/dev/null; then
        error "apt-cache not found. This script requires a Debian/Ubuntu-based system."
        exit 1
    fi

    # apt-get must exist
    if ! command -v apt-get &>/dev/null; then
        error "apt-get not found."
        exit 1
    fi

    # Ensure log directory exists
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || {
        warn "Cannot write to $LOG_FILE — falling back to /tmp/dep_satisfier.log"
        LOG_FILE="/tmp/dep_satisfier.log"
    }

    # Check internet / apt reachability
    info "Updating apt package index..."
    if ! $DRY_RUN; then
        apt-get update -qq || warn "apt-get update failed — results may be stale."
    fi
}

# ─────────────────────────────────────────────
# CHECK IF PACKAGE EXISTS IN APT
# ─────────────────────────────────────────────
pkg_exists() {
    apt-cache show "$1" &>/dev/null
}

# ─────────────────────────────────────────────
# CHECK IF PACKAGE IS ALREADY INSTALLED
# ─────────────────────────────────────────────
pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# ─────────────────────────────────────────────
# RESOLVE VIRTUAL PACKAGE / ALTERNATIVE
# e.g. "libssl-dev | openssl-dev" → first available
# ─────────────────────────────────────────────
resolve_pkg() {
    local raw="$1"

    # Strip version constraints like "libfoo (>= 2.0)"
    local name
    name=$(echo "$raw" | awk '{print $1}' | tr -d '()')

    # If it's a virtual package, find the first provider
    if ! apt-cache show "$name" &>/dev/null; then
        local provider
        provider=$(apt-cache showpkg "$name" 2>/dev/null \
            | awk '/^Reverse Provides:/,0' \
            | tail -n +2 \
            | awk '{print $1}' \
            | head -1)
        if [[ -n "$provider" ]]; then
            debug "Virtual pkg '$name' → resolved to '$provider'"
            echo "$provider"
            return
        fi
    fi

    echo "$name"
}

# ─────────────────────────────────────────────
# CORE: RECURSIVE DEPENDENCY WALKER
# ─────────────────────────────────────────────
# Arguments:
#   $1 — package name
#   $2 — current recursion depth
# ─────────────────────────────────────────────
walk_deps() {
    local pkg="$1"
    local depth="${2:-0}"
    local indent
    indent=$(printf '  %.0s' $(seq 1 "$depth"))   # visual indent by depth

    # ── Depth guard ───────────────────────────
    if [[ $depth -ge $MAX_DEPTH ]]; then
        warn "${indent}Max depth ($MAX_DEPTH) reached at '$pkg' — stopping branch."
        return
    fi

    # ── Resolve virtual/alternative packages ──
    pkg=$(resolve_pkg "$pkg")

    # ── Dedup guard ───────────────────────────
    if [[ -n "${VISITED[$pkg]+_}" ]]; then
        debug "${indent}Already visited '$pkg' — skipping."
        return
    fi
    VISITED["$pkg"]=1

    # ── Package existence check ───────────────
    if ! pkg_exists "$pkg"; then
        warn "${indent}Package '$pkg' not found in apt — skipping."
        return
    fi

    # ── Already installed? ────────────────────
    if pkg_installed "$pkg"; then
        success "${indent}[INSTALLED] $pkg"
        # Still walk its deps — children might be missing
    else
        info "${indent}[MISSING]   $pkg (depth=$depth)"
    fi

    # ── Get direct Depends (not Recommends) ───
    local raw_deps
    raw_deps=$(apt-cache depends "$pkg" 2>/dev/null \
        | grep '^\s*Depends:' \
        | awk '{print $2}' \
        | grep -v '^<' \
        | sort -u)

    # ── Recurse into each dependency ──────────
    local dep
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        debug "${indent}→ dep of '$pkg': '$dep'"
        walk_deps "$dep" $((depth + 1))
    done <<< "$raw_deps"

    # ── Install if missing ────────────────────
    if ! pkg_installed "$pkg"; then
        install_pkg "$pkg" "$indent"
    fi
}

# ─────────────────────────────────────────────
# INSTALL A SINGLE PACKAGE
# ─────────────────────────────────────────────
install_pkg() {
    local pkg="$1"
    local indent="${2:-}"

    if $DRY_RUN; then
        warn "${indent}[DRY-RUN]   Would install: $pkg"
        return
    fi

    info "${indent}[INSTALLING] $pkg ..."
    if apt-get install -y --no-install-recommends "$pkg" >> "$LOG_FILE" 2>&1; then
        success "${indent}[DONE]       $pkg installed successfully."
    else
        error "${indent}[FAILED]     Could not install $pkg — check $LOG_FILE for details."
    fi
}

# ─────────────────────────────────────────────
# SUMMARY REPORT
# ─────────────────────────────────────────────
print_summary() {
    local total=${#VISITED[@]}
    echo ""
    echo -e "${BOLD}════════════════════════════════════════${RESET}"
    echo -e "${BOLD}  Dependency Satisfier — Summary${RESET}"
    echo -e "${BOLD}════════════════════════════════════════${RESET}"
    echo -e "  Target package : ${CYAN}${TARGET_PKG}${RESET}"
    echo -e "  Total packages resolved : ${BOLD}${total}${RESET}"
    echo -e "  Dry-run mode   : $(  $DRY_RUN && echo "${YELLOW}YES${RESET}" || echo "${GREEN}NO${RESET}")"
    echo -e "  Log file       : ${LOG_FILE}"
    echo -e "${BOLD}════════════════════════════════════════${RESET}"
    echo ""
}

# ─────────────────────────────────────────────
# ENTRYPOINT
# ─────────────────────────────────────────────
main() {
    parse_args "$@"

    echo ""
    echo -e "${BOLD}  Clawdbot Dependency Satisfier${RESET}"
    echo -e "  Target: ${CYAN}${TARGET_PKG}${RESET}"
    echo -e "  Mode:   $( $DRY_RUN && echo 'DRY-RUN' || echo 'LIVE')"
    echo ""

    preflight

    # Verify target package exists before starting
    if ! pkg_exists "$TARGET_PKG"; then
        error "Package '${TARGET_PKG}' does not exist in apt repositories."
        error "Check spelling or run: apt-cache search ${TARGET_PKG}"
        exit 1
    fi

    info "Starting recursive dependency walk for '${TARGET_PKG}'..."
    walk_deps "$TARGET_PKG" 0

    # Final install of the target itself
    if ! pkg_installed "$TARGET_PKG"; then
        install_pkg "$TARGET_PKG"
    else
        success "Target package '${TARGET_PKG}' is already installed."
    fi

    print_summary
}

main "$@"
