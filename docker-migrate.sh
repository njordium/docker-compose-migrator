#!/usr/bin/env bash
# =============================================================================
# docker-migrate.sh — Docker Compose stack migration tool
# Migrates containers + volumes between hosts with pre-flight checks,
# interactive menu, per-service selection, smart stop/pause strategy,
# verbose mode, backup/restore, and extended verification.
# Script Author: Kim Haverblad
#
# Version: 3.6.1
#
# Changelog v3.6.0:
#   - FIX: Volume transfer now uses dedicated SSH connections (not mux socket)
#         preventing keepalive timeouts during large volume transfers
#   - FIX: Post-stop container verification grep pattern handles newline-separated
#         SERVICE_LIST correctly (was silently matching only first service)
#   - FIX: Volumes registered via docker volume create before data transfer
#         (was bare mkdir which skipped Docker metadata — breaks fuse-overlayfs)
#   - FIX: Port conflict regex matches both quoted and unquoted published values
#         from docker compose config (was missing unquoted ports)
#   - FIX: PIPESTATUS checked after volume tar pipe — transfer failures now reported
#   - NEW: Postgres clean shutdown verification after docker compose down
#         warns on non-zero exit code before proceeding with volume transfer
#
# Changelog v3.6.1:
#   - FIX: CRITICAL — ssh inside while-read loops consumed stdin, causing only
#         the first volume to be migrated. All subsequent volumes were silently
#         skipped. Added -n flag to ssh_src/ssh_dst to prevent stdin consumption.
#         This also fixes volume size display in pre-flight, backup volume
#         resolution, bind mount checks, and PUID/PGID verification loops.
#   - FIX: macOS LIBARCHIVE.xattr.com.apple.provenance tar warnings suppressed
#         via COPYFILE_DISABLE=1 on the local tar during compose file transfer
#
# Requirements:
#   - Bash 4.0+ (macOS ships with 3.2 — install via: brew install bash)
#   - ssh, rsync (optional), tar, awk, grep
#   - Key-based SSH access to source and destination hosts
#   - Passwordless sudo for non-root SSH login users
#
# macOS: run with /opt/homebrew/bin/bash docker-migrate.sh
#        or add /opt/homebrew/bin to front of PATH
# =============================================================================

set -uo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; DIM='\033[2m'
RESET='\033[0m'

_ts()     { date +"%H:%M"; }
info()    { echo -e "${CYAN}[INFO]${RESET}  $(_ts) $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $(_ts) $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $(_ts) $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $(_ts) $*"; }
fatal()   { echo -e "${RED}[FATAL]${RESET} $(_ts) $*"; exit 1; }
verbose() { $VERBOSE && echo -e "${DIM}[VERB]  $(_ts) $*${RESET}" || true; }

# Show animated dots while a background process runs.
# Usage: progress_dots <pid> [label]
# Prints a dot every 3 seconds until pid exits.
progress_dots() {
    local pid="$1" label="${2:-Working}"
    local elapsed=0
    # Use printf so ANSI codes are interpreted correctly without -e flag issues
    printf "  \033[2m%s\033[0m " "$label"
    while kill -0 "$pid" 2>/dev/null; do
        sleep 3
        elapsed=$((elapsed + 3))
        printf "."
        if (( elapsed % 30 == 0 )); then
            printf " \033[2m%ds\033[0m" "$elapsed"
        fi
    done
    printf " \033[2mdone\033[0m\n"
}
header()  {
    local _title="$*"
    local _len=${#_title}
    local _inner=48
    local _pad=$(( _inner - _len - 2 ))
    [[ $_pad -lt 0 ]] && _pad=0
    local _padstr
    _padstr=$(printf ' %.0s' $(seq 1 $_pad))
    echo -e "\n${BOLD}${CYAN}╔$(printf '═%.0s' $(seq 1 $_inner))╗${RESET}"
    echo -e "${BOLD}${CYAN}║  ${RESET}${BOLD}${_title}${_padstr}${CYAN}║${RESET}"
    echo -e "${BOLD}${CYAN}╚$(printf '═%.0s' $(seq 1 $_inner))╝${RESET}"
}
section() {
    local title="$*"
    local pad=$(( 42 - ${#title} ))
    [[ $pad -lt 0 ]] && pad=0
    echo -e "\n${BOLD}${MAGENTA}── ${title} $(printf '%.0s─' $(seq 1 $pad))${RESET}"
}

# ── Globals ───────────────────────────────────────────────────────────────────
SCRIPT_VERSION="3.6.1"
LOGFILE="/tmp/docker-migrate-$(date +%Y%m%d-%H%M%S).log"
CMDLOG="/tmp/docker-migrate-$(date +%Y%m%d-%H%M%S).cmd.log"  # clean command log
PREFLIGHT_ERRORS=0
PREFLIGHT_WARNINGS=0
DRY_RUN=false
FORCE=false
VERBOSE=false

# Connection params
SRC_HOST=""; SRC_PORT="22"; SRC_USER="root"; SRC_KEY="$HOME/.ssh/id_rsa"; SRC_PATH=""
DST_HOST=""; DST_PORT="22"; DST_USER="root"; DST_KEY="$HOME/.ssh/id_rsa"; DST_PATH=""
SRC_LOGIN=""             # SSH login user on source (if different from SRC_USER, sudo is used)
DST_LOGIN=""             # SSH login user on destination (if different from DST_USER, sudo is used)
SRC_BASE="/opt"          # base path scanned for stacks on source
DST_BASE="/opt"          # base path used for destination
STACK_NAME=""
COMPOSE_FILE=""
VOLUME_LIST=""
SERVICE_LIST=""          # all services in stack
SELECTED_SERVICES=""     # user-selected subset (empty = all)
DECOMMISSION_MODE=true   # true=leave source stopped; false=restart source after migration
CONFIG_FILE="$HOME/.docker-migrate.conf"
SSH_CTRL_DIR="/tmp/docker-migrate-ssh-$$"  # multiplexing socket dir
SSH_SRC_CTRL=""   # populated by open_ssh_multiplexing
SSH_DST_CTRL=""

# Open persistent SSH control sockets for both hosts.
# All subsequent ssh_src/ssh_dst calls reuse these connections
# instead of opening a new TCP session each time — prevents
# rate-limit timeouts during pre-flight which makes many rapid calls.
open_ssh_multiplexing() {
    mkdir -p "$SSH_CTRL_DIR"
    chmod 700 "$SSH_CTRL_DIR"

    local src_login="${SRC_LOGIN:-$SRC_USER}"
    local dst_login="${DST_LOGIN:-$DST_USER}"

    SSH_SRC_CTRL="${SSH_CTRL_DIR}/src"
    SSH_DST_CTRL="${SSH_CTRL_DIR}/dst"

    verbose "Opening SSH master connection to source: ${src_login}@${SRC_HOST}"
    ssh -i "$SRC_KEY" -p "$SRC_PORT" \
        -o ControlMaster=yes \
        -o ControlPath="$SSH_SRC_CTRL" \
        -o ControlPersist=300 \
        -o ConnectTimeout=10 \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        "${src_login}@${SRC_HOST}" -fN 2>/dev/null || true

    # Small delay between host connections to avoid triggering IDS rate limiting
    sleep 2

    verbose "Opening SSH master connection to destination: ${dst_login}@${DST_HOST}"
    ssh -i "$DST_KEY" -p "$DST_PORT" \
        -o ControlMaster=yes \
        -o ControlPath="$SSH_DST_CTRL" \
        -o ControlPersist=300 \
        -o ConnectTimeout=10 \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        "${dst_login}@${DST_HOST}" -fN 2>/dev/null || true
}

close_ssh_multiplexing() {
    [[ -n "$SSH_SRC_CTRL" ]] && \
        ssh -o ControlPath="$SSH_SRC_CTRL" -O exit placeholder 2>/dev/null || true
    [[ -n "$SSH_DST_CTRL" ]] && \
        ssh -o ControlPath="$SSH_DST_CTRL" -O exit placeholder 2>/dev/null || true
    rm -rf "$SSH_CTRL_DIR" 2>/dev/null || true
}

# Ensure sockets are cleaned up on exit
trap close_ssh_multiplexing EXIT INT TERM


start_logging() { exec > >(tee -a "$LOGFILE") 2>&1; }

# =============================================================================
# SSH KEYPAIR SETUP
# Generates an ed25519 keypair and deploys the public key to source + dest
# Called from startup_sanity_checks when no key is found
# =============================================================================
setup_ssh_keypair() {
    section "SSH Keypair Setup"

    local key_path="$HOME/.ssh/id_ed25519"
    local key_comment="docker-migrate-$(hostname)-$(date +%Y%m%d)"

    # Custom path?
    echo -en "  Key path [${key_path}]: "
    read -r custom_path
    key_path="${custom_path:-$key_path}"

    # Check if it already exists
    if [[ -f "$key_path" ]]; then
        warn "Key already exists at ${key_path}"
        echo -en "  Overwrite? [y/N]: "
        read -rn1 ow; echo ""
        [[ ! "$ow" =~ ^[Yy]$ ]] && {
            SRC_KEY="$key_path"; DST_KEY="$key_path"
            ok "Using existing key: ${key_path}"
            return 0
        }
    fi

    # Passphrase
    echo -e "  ${DIM}Leave passphrase empty for unattended use (recommended for migration scripts)${RESET}"
    echo -en "  Passphrase (Enter for none): "
    read -rs passphrase; echo ""

    # Generate
    info "Generating ed25519 keypair..."
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    if ssh-keygen -t ed25519                   -f "$key_path"                   -C "$key_comment"                   -N "$passphrase"                   -q 2>/dev/null; then
        chmod 600 "$key_path"
        chmod 644 "${key_path}.pub"
        ok "Keypair generated:"
        ok "  Private: ${key_path}"
        ok "  Public : ${key_path}.pub"
        verbose "Public key: $(cat "${key_path}.pub")"
    else
        fatal "ssh-keygen failed. Check permissions on $HOME/.ssh/"
    fi

    SRC_KEY="$key_path"
    DST_KEY="$key_path"

    # ── Offer to deploy immediately ───────────────────────────────────────────
    echo ""
    if ! command -v ssh-copy-id &>/dev/null; then
        warn "ssh-copy-id not found — copy the key manually to both hosts:"
        info "  cat ${key_path}.pub | ssh -p PORT USER@HOST 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'"
        return 0
    fi

    confirm "Deploy key to source and destination hosts now?" || {
        echo ""
        info "Key generated but not yet deployed."
        info "Use menu option k → 2/3/4 to deploy when ready."
        return 0
    }

    # Gather host details inline if not already set — these populate
    # the migration globals directly so option 1 won't re-ask for them
    _gather_host_if_missing "source"
    _gather_host_if_missing "destination"

    section "Deploying Key to Hosts"
    echo -e "  ${DIM}You will be prompted for each host password once.${RESET}"
    echo -e "  ${DIM}After this, all connections use the key automatically.${RESET}"
    echo ""

    local deploy_ok=true
    [[ -n "${SRC_HOST:-}" ]] &&         _deploy_key_to_host "source"      "$SRC_HOST" "$SRC_PORT" "$SRC_USER" "$key_path" "${SRC_LOGIN:-}" || deploy_ok=false
    [[ -n "${DST_HOST:-}" ]] &&         _deploy_key_to_host "destination" "$DST_HOST" "$DST_PORT" "$DST_USER" "$key_path" "${DST_LOGIN:-}" || deploy_ok=false

    echo ""
    ok "SSH keypair setup complete. Key: ${key_path}"

    if $deploy_ok && [[ -n "${SRC_HOST:-}" && -n "${DST_HOST:-}" ]]; then
        info "Host details are now set. Use option 1 to add compose paths and finish setup."
        confirm "Save host configuration now?" && save_config
    fi
}

# Also expose as a standalone menu function for re-running after hosts are configured
# Helper — gather host details for a single side (src or dst) if not yet set
# Populates the global vars directly so they carry into migration config
_gather_host_if_missing() {
    local side="$1"   # "source" or "destination"

    if [[ "$side" == "source" ]]; then
        if [[ -n "${SRC_HOST:-}" ]]; then
            info "Source already configured: ${SRC_USER}@${SRC_HOST}:${SRC_PORT}"
            return
        fi
        section "Source Server Details"
        read -rp "  Host/IP                       : " SRC_HOST
        read -rp "  SSH port              [22]    : " input; SRC_PORT="${input:-22}"
        read -rp "  SSH login user        [root]  : " input; SRC_LOGIN="${input:-}"
        read -rp "  Effective user (sudo) [root]  : " input; SRC_USER="${input:-root}"
        [[ "$SRC_LOGIN" == "$SRC_USER" || -z "$SRC_LOGIN" ]] && SRC_LOGIN=""
    else
        if [[ -n "${DST_HOST:-}" ]]; then
            info "Destination already configured: ${DST_USER}@${DST_HOST}:${DST_PORT}"
            return
        fi
        section "Destination Server Details"
        read -rp "  Host/IP                       : " DST_HOST
        read -rp "  SSH port              [22]    : " input; DST_PORT="${input:-22}"
        read -rp "  SSH login user        [root]  : " input; DST_LOGIN="${input:-}"
        read -rp "  Effective user (sudo) [root]  : " input; DST_USER="${input:-root}"
        [[ "$DST_LOGIN" == "$DST_USER" || -z "$DST_LOGIN" ]] && DST_LOGIN=""
    fi
}

# Helper — deploy a key to a single host using ssh-copy-id
# Deploy a public key to a host.
# If login_user differs from effective_user (e.g. khaverblad vs root),
# connects as login_user then sudo-copies the key into effective_user's
# authorized_keys — no root SSH login required.
_deploy_key_to_host() {
    local label="$1" host="$2" port="$3" effective_user="$4" key="$5"
    local login_user="$6"   # optional — SSH login user (defaults to effective_user)
    login_user="${login_user:-$effective_user}"

    local pubkey="${key}.pub"
    [[ ! -f "$pubkey" ]] && { error "Public key not found: ${pubkey}"; return 1; }

    info "Deploying key to ${label}: ${login_user}@${host}:${port}"
    if [[ "$login_user" != "$effective_user" ]]; then
        info "  Login user  : ${login_user}"
        info "  Effective   : ${effective_user} (via sudo)"
        info "  You will be prompted for ${login_user}'s password."
    else
        info "  You will be prompted for the ${label} password (one-time only)."
    fi

    local pub_content
    pub_content=$(cat "$pubkey")

    if [[ "$login_user" == "$effective_user" ]]; then
        # Standard ssh-copy-id path
        if ! command -v ssh-copy-id &>/dev/null; then
            warn "ssh-copy-id not found — using manual method"
        else
            if ssh-copy-id -i "$pubkey" -p "$port" "${login_user}@${host}" 2>/dev/null; then
                ok "Key deployed to ${label} (${effective_user})"
                _verify_key_auth "$label" "$host" "$port" "$effective_user" "$key"
                return 0
            fi
        fi
        # Fallback manual method
        if ssh -p "$port"                -o ConnectTimeout=10                -o StrictHostKeyChecking=accept-new                "${login_user}@${host}"                "mkdir -p ~/.ssh &&                 echo '${pub_content}' >> ~/.ssh/authorized_keys &&                 chmod 700 ~/.ssh &&                 chmod 600 ~/.ssh/authorized_keys" 2>/dev/null; then
            ok "Key deployed to ${label} (${effective_user}) via manual method"
            _verify_key_auth "$label" "$host" "$port" "$login_user" "$key"
        else
            warn "Deploy to ${label} failed — check password and SSH access"
            _deploy_manual_hint "$label" "$host" "$port" "$login_user" "$pubkey"
        fi
    else
        # sudo path — login as login_user, copy key into effective_user's authorized_keys
        info "Connecting as ${login_user}, installing key for ${effective_user}..."
        local target_home
        # Get effective_user home dir via sudo
        target_home=$(ssh -p "$port"             -o ConnectTimeout=10             -o StrictHostKeyChecking=accept-new             "${login_user}@${host}"             "sudo -u ${effective_user} sh -c 'echo \$HOME'" 2>/dev/null || echo "/root")

        if ssh -p "$port"                -o ConnectTimeout=10                -o StrictHostKeyChecking=accept-new                "${login_user}@${host}"                "sudo -u ${effective_user} sh -c                 'mkdir -p ${target_home}/.ssh &&                  chmod 700 ${target_home}/.ssh &&                  echo "${pub_content}" >> ${target_home}/.ssh/authorized_keys &&                  chmod 600 ${target_home}/.ssh/authorized_keys'" 2>/dev/null; then
            ok "Key deployed to ${label} (${effective_user} via sudo from ${login_user})"
            _verify_key_auth "$label" "$host" "$port" "$effective_user" "$key"
        else
            warn "sudo deploy to ${label} failed"
            warn "Ensure ${login_user} has passwordless sudo or try interactively:"
            _deploy_manual_hint "$label" "$host" "$port" "$login_user" "$pubkey"
        fi
    fi
}

_verify_key_auth() {
    local label="$1" host="$2" port="$3" user="$4" key="$5"
    if ssh -i "$key" -p "$port"            -o ConnectTimeout=5 -o BatchMode=yes            -o StrictHostKeyChecking=accept-new            "${user}@${host}" "exit" 2>/dev/null; then
        ok "Key auth to ${label} (${user}@${host}): verified working"
    else
        warn "Key deployed but auth test failed for ${user}@${host}"
        warn "Check: Is PermitRootLogin set? Is AuthorizedKeysFile configured in sshd_config?"
    fi
}

_deploy_manual_hint() {
    local label="$1" host="$2" port="$3" user="$4" pubkey="$5"
    warn "Manual deploy for ${label}:"
    warn "  ssh ${user}@${host} -p ${port}"
    warn "  Then run: sudo mkdir -p /root/.ssh && sudo tee -a /root/.ssh/authorized_keys << 'EOF'"
    warn "  $(cat "$pubkey" 2>/dev/null || echo '<your public key>')"
    warn "  EOF"
    warn "  sudo chmod 700 /root/.ssh && sudo chmod 600 /root/.ssh/authorized_keys"
}

manage_ssh_keys() {
    header "SSH Key Management"

    # Show current state
    local key_status
    if [[ -f "${SRC_KEY:-}" ]]; then
        key_status="${GREEN}${SRC_KEY}${RESET}"
    else
        key_status="${RED}not set${RESET}"
    fi
    echo -e "  ${BOLD}Current key :${RESET} ${key_status}"
    if [[ -n "${SRC_HOST:-}" ]]; then
        echo -e "  ${BOLD}Source      :${RESET} ${SRC_USER}@${SRC_HOST}:${SRC_PORT}"
    else
        echo -e "  ${BOLD}Source      :${RESET} ${DIM}not configured${RESET}"
    fi
    if [[ -n "${DST_HOST:-}" ]]; then
        echo -e "  ${BOLD}Destination :${RESET} ${DST_USER}@${DST_HOST}:${DST_PORT}"
    else
        echo -e "  ${BOLD}Destination :${RESET} ${DIM}not configured${RESET}"
    fi
    echo ""
    echo -e "  ${BOLD}1)${RESET} Generate new ed25519 keypair"
    echo -e "  ${BOLD}2)${RESET} Deploy key to source host"
    echo -e "  ${BOLD}3)${RESET} Deploy key to destination host"
    echo -e "  ${BOLD}4)${RESET} Deploy key to both hosts  ${DIM}(full setup in one step)${RESET}"
    echo -e "  ${BOLD}5)${RESET} Test key auth against both hosts"
    echo -e "  ${BOLD}b)${RESET} Back"
    echo ""
    echo -en "${CYAN}  Choice: ${RESET}"
    read -rn1 sc; echo ""

    case "$sc" in
        1)
            setup_ssh_keypair
            # After generating, offer to deploy immediately if hosts known
            if [[ -n "${SRC_HOST:-}" || -n "${DST_HOST:-}" ]]; then
                confirm "Deploy new key to configured hosts now?" && {
                    [[ -n "${SRC_HOST:-}" ]] &&                         _deploy_key_to_host "source" "$SRC_HOST" "$SRC_PORT" "$SRC_USER" "$SRC_KEY" "${SRC_LOGIN:-}"
                    [[ -n "${DST_HOST:-}" ]] &&                         _deploy_key_to_host "destination" "$DST_HOST" "$DST_PORT" "$DST_USER" "$DST_KEY" "${DST_LOGIN:-}"
                }
            fi
            ;;
        2)
            # Gather source details if not yet configured — populates migration globals
            _gather_host_if_missing "source"
            [[ -z "${SRC_HOST:-}" ]] && { warn "No source host — aborted."; return; }
            [[ -z "${SRC_KEY:-}" ]] && { warn "No key set — generate one first (option 1)."; return; }
            _deploy_key_to_host "source" "$SRC_HOST" "$SRC_PORT" "$SRC_USER" "$SRC_KEY" "${SRC_LOGIN:-}"
            ;;
        3)
            # Gather destination details if not yet configured — populates migration globals
            _gather_host_if_missing "destination"
            [[ -z "${DST_HOST:-}" ]] && { warn "No destination host — aborted."; return; }
            [[ -z "${DST_KEY:-}" ]] && { warn "No key set — generate one first (option 1)."; return; }
            _deploy_key_to_host "destination" "$DST_HOST" "$DST_PORT" "$DST_USER" "$DST_KEY" "${DST_LOGIN:-}"
            ;;
        4)
            # Full setup — gather both hosts if missing, deploy to both
            # This is the single-step path for a fresh machine
            [[ -z "${SRC_KEY:-}" ]] && {
                warn "No key set. Generate one first (option 1)."
                return
            }
            _gather_host_if_missing "source"
            _gather_host_if_missing "destination"
            [[ -z "${SRC_HOST:-}" || -z "${DST_HOST:-}" ]] && {
                warn "Both hosts required for option 4."
                return
            }
            _deploy_key_to_host "source"      "$SRC_HOST" "$SRC_PORT" "$SRC_USER" "$SRC_KEY" "${SRC_LOGIN:-}"
            _deploy_key_to_host "destination" "$DST_HOST" "$DST_PORT" "$DST_USER" "$DST_KEY" "${DST_LOGIN:-}" "${DST_LOGIN:-}"
            echo ""
            ok "Both hosts configured and keys deployed."
            ok "Host details are saved to migration config — option 1 will use them."
            confirm "Save connection details now?" && save_config
            ;;
        5)
            section "Testing SSH Key Auth"
            local any_tested=false
            for _side in source destination; do
                local _h _p _u _k
                if [[ "$_side" == "source" ]]; then
                    _h="${SRC_HOST:-}"; _p="${SRC_PORT:-22}"
                    _u="${SRC_USER:-root}"; _k="${SRC_KEY:-}"
                else
                    _h="${DST_HOST:-}"; _p="${DST_PORT:-22}"
                    _u="${DST_USER:-root}"; _k="${DST_KEY:-}"
                fi
                [[ -z "$_h" ]] && { info "${_side}: not configured — skipping"; continue; }
                any_tested=true
                verbose "Testing ${_side}: ssh -i ${_k} -p ${_p} ${_u}@${_h}"
                if ssh -i "$_k" -p "$_p"                        -o ConnectTimeout=5 -o BatchMode=yes                        -o StrictHostKeyChecking=accept-new                        "${_u}@${_h}" "exit" 2>/dev/null; then
                    ok "${_side} (${_u}@${_h}): key auth working"
                else
                    error "${_side} (${_u}@${_h}): key auth FAILED"
                    info "  Fix: run option 2/3/4 to deploy the key, or check sshd on ${_h}"
                fi
            done
            $any_tested || warn "No hosts configured yet — use options 2/3/4 first."
            ;;
        b|B) return ;;
        *) warn "Invalid option" ;;
    esac
}

# =============================================================================
# STARTUP SANITY CHECKS
# =============================================================================
startup_sanity_checks() {
    local errors=0

    echo -e "${BOLD}${CYAN}"
    echo "  ██████╗  ██████╗  ██████╗██╗  ██╗███████╗██████╗ "
    echo "  ██╔══██╗██╔═══██╗██╔════╝██║ ██╔╝██╔════╝██╔══██╗"
    echo "  ██║  ██║██║   ██║██║     █████╔╝ █████╗  ██████╔╝"
    echo "  ██║  ██║██║   ██║██║     ██╔═██╗ ██╔══╝  ██╔══██╗"
    echo "  ██████╔╝╚██████╔╝╚██████╗██║  ██╗███████╗██║  ██║"
    echo "  ╚═════╝  ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝"
    echo -e "${RESET}"
    echo -e "${BOLD}  Docker Stack Migration Tool v${SCRIPT_VERSION}${RESET}"
    $VERBOSE && echo -e "${YELLOW}  Verbose mode ON${RESET}"
    echo -e "${DIM}  Log: ${LOGFILE}${RESET}\n"

    section "Startup Sanity Checks"

    # Bash version
    verbose "Checking Bash version: ${BASH_VERSION}"
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        error "Bash 4.0+ required (found: ${BASH_VERSION})"
        if [[ "$(uname)" == "Darwin" ]]; then
            error "macOS ships with Bash 3.2. Install a modern version:"
            error "  brew install bash"
            error "Then run with: /opt/homebrew/bin/bash $(basename "$0")"
            error "Or: export PATH=/opt/homebrew/bin:\$PATH && bash $(basename "$0")"
        fi
        ((errors++))
    else
        ok "Bash version: ${BASH_VERSION}"
    fi

    # Required tools
    local tools=(ssh rsync awk grep sed tee date basename ping stat)
    local missing=()
    for t in "${tools[@]}"; do
        verbose "Checking tool: ${t}"
        command -v "$t" &>/dev/null || missing+=("$t")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}"; ((errors++))
    else
        ok "Required tools: all present"
    fi

    # SSH key detection
    verbose "Scanning for SSH keys in ~/.ssh/"
    if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
        ok "SSH key found: ~/.ssh/id_ed25519"
        SRC_KEY="$HOME/.ssh/id_ed25519"
        DST_KEY="$HOME/.ssh/id_ed25519"
    elif [[ -f "$HOME/.ssh/id_rsa" ]]; then
        ok "SSH key found: ~/.ssh/id_rsa"
        SRC_KEY="$HOME/.ssh/id_rsa"
        DST_KEY="$HOME/.ssh/id_rsa"
    else
        warn "No SSH key found — use menu option 'K' to generate and deploy one."
    fi

    # Key permissions
    if [[ -f "${SRC_KEY:-}" ]]; then
        local perms
        perms=$(stat -f "%OLp" "$SRC_KEY" 2>/dev/null || stat -c "%a" "$SRC_KEY" 2>/dev/null || echo "unknown")
        verbose "SSH key permissions: ${perms}"
        if [[ "$perms" == "600" || "$perms" == "400" ]]; then
            ok "SSH key permissions: ${perms} (correct)"
        else
            warn "SSH key permissions are ${perms} — fixing automatically..."
            chmod 600 "$SRC_KEY" && ok "Permissions fixed: 600"
        fi
    fi

    # /tmp space — handle both Linux (df -BM) and macOS (df without -B flag)
    local tmp_free
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS df: available is column 4, in 512-byte blocks; convert to MB
        tmp_free=$(df /tmp 2>/dev/null | awk 'NR==2{printf "%d", $4/2048}')
    else
        tmp_free=$(df -BM /tmp 2>/dev/null | awk 'NR==2{gsub(/M/,"",$4); print $4}')
    fi
    verbose "Local /tmp free: ${tmp_free:-?}MB"
    if [[ "${tmp_free:-0}" -gt 100 ]]; then
        ok "Local /tmp free: ${tmp_free}MB"
    else
        warn "Local /tmp has only ${tmp_free:-unknown}MB free"
    fi

    # macOS: also check for Homebrew bash availability as a soft reminder
    if [[ "$(uname)" == "Darwin" ]]; then
        if command -v /opt/homebrew/bin/bash &>/dev/null; then
            verbose "Homebrew bash available: $(/opt/homebrew/bin/bash --version | head -1)"
        fi
    fi

    # Network — macOS uses -t for timeout, Linux uses -W
    verbose "Testing outbound network (ping 8.8.8.8)"
    local ping_cmd="ping -c1"
    [[ "$(uname)" == "Darwin" ]] && ping_cmd="ping -c1 -t2" || ping_cmd="ping -c1 -W2"
    if $ping_cmd 8.8.8.8 &>/dev/null; then
        ok "Network: outbound connectivity OK"
    else
        warn "Cannot reach 8.8.8.8 — may be offline or restricted"
    fi

    # Saved config
    if [[ -f "$CONFIG_FILE" ]]; then
        ok "Saved config found: ${CONFIG_FILE}"
    else
        verbose "No saved config at ${CONFIG_FILE}"
    fi

    echo ""
    [[ $errors -gt 0 ]] && fatal "Startup checks failed with ${errors} error(s). Fix above first."
    ok "All startup checks passed."
    sleep 1
}

# =============================================================================
# HELPERS
# =============================================================================
run() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${RESET} $*"
    else
        verbose "Executing: $*"
        eval "$@"
    fi
}

# ssh_src / ssh_dst — connect as the login user, optionally sudo to effective
# user, and reuse the persistent ControlMaster socket when available.
_ssh_opts() {
    local ctrl="$1"
    local opts="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
    if [[ -n "$ctrl" && -S "$ctrl" ]]; then
        opts+=" -o ControlMaster=no -o ControlPath=${ctrl}"
    fi
    echo "$opts"
}

ssh_src() {
    local login="${SRC_LOGIN:-$SRC_USER}"
    local opts
    opts=$(_ssh_opts "${SSH_SRC_CTRL:-}")
    verbose "ssh_src [${login}→${SRC_USER}]: $*"
    [[ -n "${CMDLOG:-}" ]] && echo "[$(date +%H:%M:%S)] SRC: $*" >> "$CMDLOG" 2>/dev/null
    if [[ -n "$SRC_LOGIN" && "$SRC_LOGIN" != "$SRC_USER" ]]; then
        # shellcheck disable=SC2086
        # -n prevents ssh from consuming stdin — critical when called inside
        # while-read loops where stdin feeds the loop variable
        ssh -n -i "$SRC_KEY" -p "$SRC_PORT" $opts \
            "${login}@${SRC_HOST}" \
            "sudo -- sh -c $(printf '%q' "$*")"
    else
        # shellcheck disable=SC2086
        ssh -n -i "$SRC_KEY" -p "$SRC_PORT" $opts \
            "${SRC_USER}@${SRC_HOST}" "$@"
    fi
}

ssh_dst() {
    local login="${DST_LOGIN:-$DST_USER}"
    local opts
    opts=$(_ssh_opts "${SSH_DST_CTRL:-}")
    verbose "ssh_dst [${login}→${DST_USER}]: $*"
    [[ -n "${CMDLOG:-}" ]] && echo "[$(date +%H:%M:%S)] DST: $*" >> "$CMDLOG" 2>/dev/null
    if [[ -n "$DST_LOGIN" && "$DST_LOGIN" != "$DST_USER" ]]; then
        # shellcheck disable=SC2086
        ssh -n -i "$DST_KEY" -p "$DST_PORT" $opts \
            "${login}@${DST_HOST}" \
            "sudo -- sh -c $(printf '%q' "$*")"
    else
        # shellcheck disable=SC2086
        ssh -n -i "$DST_KEY" -p "$DST_PORT" $opts \
            "${DST_USER}@${DST_HOST}" "$@"
    fi
}

confirm() {
    local prompt="${1:-Continue?}"
    $FORCE && return 0
    echo -en "\n${YELLOW}${prompt} [y/N] ${RESET}"
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

log_result() {
    local level="$1"; shift
    case "$level" in
        ok)    ok "$*" ;;
        warn)  warn "$*"; ((PREFLIGHT_WARNINGS++)) ;;
        error) error "$*"; ((PREFLIGHT_ERRORS++))  ;;
    esac
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
# docker-migrate saved configuration — $(date)
SRC_HOST="${SRC_HOST}"
SRC_PORT="${SRC_PORT}"
SRC_USER="${SRC_USER}"
SRC_LOGIN="${SRC_LOGIN}"
SRC_KEY="${SRC_KEY}"
SRC_BASE="${SRC_BASE}"
SRC_PATH="${SRC_PATH}"
DST_HOST="${DST_HOST}"
DST_PORT="${DST_PORT}"
DST_USER="${DST_USER}"
DST_LOGIN="${DST_LOGIN}"
DST_KEY="${DST_KEY}"
DST_BASE="${DST_BASE}"
DST_PATH="${DST_PATH}"
STACK_NAME="${STACK_NAME}"
COMPOSE_FILE="${COMPOSE_FILE}"
SELECTED_SERVICES="${SELECTED_SERVICES}"
DECOMMISSION_MODE="${DECOMMISSION_MODE}"
EOF
    ok "Configuration saved to ${CONFIG_FILE}"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    local _src_disp="${SRC_LOGIN:-$SRC_USER}@${SRC_HOST}:${SRC_PORT}"
    [[ -n "${SRC_LOGIN:-}" ]] && _src_disp+=" (sudo→${SRC_USER})"
    local _dst_disp="${DST_LOGIN:-$DST_USER}@${DST_HOST}:${DST_PORT}"
    [[ -n "${DST_LOGIN:-}" ]] && _dst_disp+=" (sudo→${DST_USER})"
    echo ""
    echo -e "  ${BOLD}Source :${RESET} ${DIM}${_src_disp}  base: ${SRC_BASE}${RESET}"
    echo -e "  ${BOLD}Dest   :${RESET} ${DIM}${_dst_disp}  base: ${DST_BASE}${RESET}"
    echo ""
    confirm "Use this configuration?" && return 0
    return 1
}

print_connection_summary() {
    echo ""
    echo -e "  ${BOLD}Source     :${RESET} ${SRC_USER}@${SRC_HOST}:${SRC_PORT}  →  ${SRC_PATH}"
    echo -e "  ${BOLD}Destination:${RESET} ${DST_USER}@${DST_HOST}:${DST_PORT}  →  ${DST_PATH}"
    echo -e "  ${BOLD}Stack      :${RESET} ${STACK_NAME}"
    [[ -n "$SELECTED_SERVICES" ]] && \
        echo -e "  ${BOLD}Services   :${RESET} ${YELLOW}${SELECTED_SERVICES}${RESET} ${DIM}(partial migration)${RESET}"
    echo ""
}

# =============================================================================
# YAML ANALYSIS — dependency resolution and volume-to-service mapping
# =============================================================================

# Parse depends_on for a given service from the normalised compose config.
# docker compose config normalises YAML so depends_on always appears as:
#   depends_on:
#     other_service:
#       condition: service_started
# We extract all dependency names for a service.
get_service_depends() {
    local svc="$1"
    # Pull the rendered config once and parse it locally
    ssh_src "docker compose -f ${COMPOSE_FILE} config 2>/dev/null" \
    | awk "
        /^  ${svc}:/ { in_svc=1; next }
        in_svc && /^  [a-z]/ && !/^  ${svc}:/ { in_svc=0 }
        in_svc && /^    depends_on:/ { in_dep=1; next }
        in_svc && in_dep && /^      [a-z]/ { gsub(/:$/,\"\"); print \$1 }
        in_svc && in_dep && /^    [a-z]/ && !/^    depends_on:/ { in_dep=0 }
    " 2>/dev/null || true
}

# Recursively resolve a service + all its depends_on into a flat unique list.
# Result written to the RESOLVED_SERVICES global (newline-separated).
RESOLVED_SERVICES=""
resolve_dependencies() {
    local svc="$1"
    # Skip if already resolved
    echo "$RESOLVED_SERVICES" | grep -qx "$svc" && return
    RESOLVED_SERVICES="${RESOLVED_SERVICES}${svc}"$'\n'
    verbose "  Resolving deps for: ${svc}"
    local deps
    deps=$(get_service_depends "$svc")
    if [[ -n "$deps" ]]; then
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            verbose "    depends_on: ${dep}"
            resolve_dependencies "$dep"
        done <<< "$deps"
    fi
}

# Return volumes that belong to a given set of services (newline-separated).
# Reads from the compose config — maps service → volume sources.
get_volumes_for_services() {
    local services_nl="$1"   # newline-separated service names
    local compose_config
    compose_config=$(ssh_src "docker compose -f ${COMPOSE_FILE} config 2>/dev/null" || echo "")
    [[ -z "$compose_config" ]] && return

    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        verbose "  Mapping volumes for service: ${svc}"
        # Extract volume sources under this service's volumes block
        echo "$compose_config" | awk "
            /^  ${svc}:/ { in_svc=1; next }
            in_svc && /^  [a-z]/ && !/^  ${svc}:/ { in_svc=0 }
            in_svc && /^    volumes:/ { in_vol=1; next }
            in_svc && in_vol && /^      - / { in_vol=1 }
            in_svc && in_vol && /source:/ { gsub(/.*source: /,\"\"); gsub(/${STACK_NAME}_/,\"\"); print }
            in_svc && in_vol && /^    [a-z]/ && !/^    volumes:/ { in_vol=0 }
        " 2>/dev/null || true
    done <<< "$services_nl"
}

# =============================================================================
# SERVICE SELECTOR
# Shows services with running state, volumes, and depends_on.
# Selecting a service auto-expands to include all its dependencies.
# =============================================================================
select_services() {
    if [[ -z "$COMPOSE_FILE" ]]; then
        warn "No compose file loaded — run pre-flight first."
        return 1
    fi

    header "Service Selection"

    # Enumerate services
    local raw_services
    raw_services=$(ssh_src "docker compose -f ${COMPOSE_FILE} config --services 2>/dev/null" || echo "")
    if [[ -z "$raw_services" ]]; then
        error "Could not enumerate services from compose file."
        return 1
    fi

    mapfile -t SVC_ARRAY <<< "$raw_services"
    SERVICE_LIST="$raw_services"

    # Fetch compose config once for local parsing
    local compose_config
    compose_config=$(ssh_src "docker compose -f ${COMPOSE_FILE} config 2>/dev/null" || echo "")

    echo -e "  ${BOLD}Services in stack '${STACK_NAME}':${RESET}\n"

    local i=1
    for svc in "${SVC_ARRAY[@]}"; do
        [[ -z "$svc" ]] && continue

        # Running state
        local running
        running=$(ssh_src "docker inspect --format '{{.State.Running}}' \
            ${STACK_NAME}-${svc}-1 2>/dev/null || \
            docker inspect --format '{{.State.Running}}' ${svc} 2>/dev/null || echo false")
        local status_icon
        [[ "$running" == "true" ]] && status_icon="${GREEN}●${RESET}" || status_icon="${RED}○${RESET}"

        # Volumes for this service from config
        local svc_vols
        svc_vols=$(echo "$compose_config" | awk "
            /^  ${svc}:/ { in_svc=1; next }
            in_svc && /^  [a-z]/ && !/^  ${svc}:/ { in_svc=0 }
            in_svc && /^    volumes:/ { in_vol=1; next }
            in_svc && in_vol && /source:/ { gsub(/.*source: /,\"\"); gsub(/${STACK_NAME}_/,\"\"); printf \"%s \",\$0 }
            in_svc && in_vol && /^    [a-z]/ && !/^    volumes:/ { in_vol=0 }
        " 2>/dev/null | xargs)

        # depends_on for this service
        local svc_deps
        svc_deps=$(echo "$compose_config" | awk "
            /^  ${svc}:/ { in_svc=1; next }
            in_svc && /^  [a-z]/ && !/^  ${svc}:/ { in_svc=0 }
            in_svc && /^    depends_on:/ { in_dep=1; next }
            in_svc && in_dep && /^      [a-z]/ { gsub(/:$/,\"\"); printf \"%s \",\$1 }
            in_svc && in_dep && /^    [a-z]/ && !/^    depends_on:/ { in_dep=0 }
        " 2>/dev/null | xargs)

        printf "  ${BOLD}%2d)${RESET} %b %-28s" "$i" "$status_icon" "$svc"
        local meta=""
        [[ -n "$svc_vols" ]]  && meta+="${DIM}vols: ${svc_vols}${RESET}  "
        [[ -n "$svc_deps" ]]  && meta+="${DIM}deps: ${svc_deps}${RESET}"
        [[ -n "$meta" ]] && echo -e "$meta" || echo ""
        ((i++))
    done

    echo ""
    echo -e "  ${BOLD}a)${RESET} Migrate ALL services (full stack)"
    echo -e "  ${BOLD}b)${RESET} Back to menu"
    echo ""
    echo -e "  ${DIM}Selecting a service automatically includes its depends_on chain.${RESET}"
    echo -e "  ${DIM}Enter numbers separated by spaces (e.g: 1 3)${RESET}"
    echo -en "${CYAN}  Select: ${RESET}"
    read -r selection

    case "$selection" in
        a|A)
            SELECTED_SERVICES=""
            RESOLVED_SERVICES=""
            ok "Selected: all services (full stack)"
            ;;
        b|B)
            return 1
            ;;
        *)
            local chosen=()
            for num in $selection; do
                if [[ "$num" =~ ^[0-9]+$ ]] && \
                   [[ "$num" -ge 1 ]] && \
                   [[ "$num" -le "${#SVC_ARRAY[@]}" ]]; then
                    chosen+=("${SVC_ARRAY[$((num-1))]}")
                else
                    warn "Invalid selection: ${num} — skipped"
                fi
            done
            if [[ ${#chosen[@]} -eq 0 ]]; then
                warn "No valid services selected."
                return 1
            fi

            # Resolve dependency chain for each chosen service
            RESOLVED_SERVICES=""
            for svc in "${chosen[@]}"; do
                resolve_dependencies "$svc"
            done

            # Clean up and deduplicate
            local resolved_clean
            resolved_clean=$(echo "$RESOLVED_SERVICES" | grep -v '^$' | sort -u)
            SELECTED_SERVICES=$(echo "$resolved_clean" | tr '\n' ' ' | sed 's/ $//')

            # Show what was auto-expanded
            local orig_chosen="${chosen[*]}"
            local expanded=""
            for svc in $SELECTED_SERVICES; do
                echo "$orig_chosen" | grep -qw "$svc" || expanded="${expanded} ${svc}"
            done

            ok "Selected services: ${BOLD}${SELECTED_SERVICES}${RESET}"
            if [[ -n "$expanded" ]]; then
                info "Auto-included via depends_on:${YELLOW}${expanded}${RESET}"
            fi
            ;;
    esac
    # Auto-save so service selection persists across menu navigation
    save_config
    return 0
}

# Returns the effective service list for migration operations
get_effective_services() {
    if [[ -n "$SELECTED_SERVICES" ]]; then
        echo "$SELECTED_SERVICES" | tr ' ' '\n'
    else
        echo "$SERVICE_LIST"
    fi
}

# Returns volumes for the effective service set, or all volumes for full stack
get_effective_volumes() {
    # Always re-fetch fresh — never trust stale VOLUME_LIST from saved config
    if [[ -n "$COMPOSE_FILE" ]]; then
        VOLUME_LIST=$(ssh_src             "sudo docker compose -f ${COMPOSE_FILE} config --volumes 2>/dev/null"             2>/dev/null | grep -v '^$' | sort -u)
    fi

    # For full stack migration, ALSO query docker volume ls for stack-prefixed volumes.
    # This catches volumes that exist but aren't declared in compose (orphaned volumes,
    # volumes created by older compose versions, etc.)
    if [[ -z "$SELECTED_SERVICES" ]]; then
        local actual_stack_vols
        actual_stack_vols=$(ssh_src             "sudo docker volume ls --format '{{.Name}}' 2>/dev/null | grep '^${STACK_NAME}_' | sed 's|^${STACK_NAME}_||'"             2>/dev/null | sort -u)

        # Union of declared volumes and actual volumes (deduplicated)
        if [[ -n "$actual_stack_vols" ]]; then
            (echo "$VOLUME_LIST"; echo "$actual_stack_vols") | grep -v '^$' | sort -u
        else
            echo "$VOLUME_LIST"
        fi
        return
    fi

    # Partial migration → try to map per-service
    verbose "Mapping volumes to selected services: ${SELECTED_SERVICES}"
    local svc_nl
    svc_nl=$(echo "$SELECTED_SERVICES" | tr ' ' '\n')
    local mapped_vols
    mapped_vols=$(get_volumes_for_services "$svc_nl")

    if [[ -n "$mapped_vols" ]]; then
        # Got mapping — use it but verify all declared volumes are accounted for
        # If mapping is incomplete (missed volumes), fall through to full list
        local mapped_count vol_list_count
        mapped_count=$(echo "$mapped_vols" | grep -cv '^$' || echo 0)
        vol_list_count=$(echo "$VOLUME_LIST" | grep -cv '^$' || echo 0)

        if [[ "${mapped_count:-0}" -ge "${vol_list_count:-0}" ]]; then
            echo "$mapped_vols" | grep -v '^$' | sort -u
            return
        else
            warn "Volume mapping incomplete (${mapped_count}/${vol_list_count}) — using full volume list for safety"
            echo "$VOLUME_LIST"
            return
        fi
    fi

    # Mapping returned nothing — fallback to docker inspect on running containers
    verbose "  Config mapping empty — falling back to docker inspect"
    local inspect_result
    inspect_result=""
    for svc in $SELECTED_SERVICES; do
        local cname="${STACK_NAME}-${svc}-1"
        inspect_result+=$(ssh_src "sudo docker inspect --format \
            '{{range .Mounts}}{{if eq .Type \"volume\"}}{{.Name}}{{\"\\n\"}}{{end}}{{end}}' \
            ${cname} 2>/dev/null || \
            sudo docker inspect --format \
            '{{range .Mounts}}{{if eq .Type \"volume\"}}{{.Name}}{{\"\\n\"}}{{end}}{{end}}' \
            ${svc} 2>/dev/null" 2>/dev/null || echo "")
        inspect_result+=$'\n'
    done
    inspect_result=$(echo "$inspect_result" | sed "s|^${STACK_NAME}_||" | grep -v '^$' | sort -u)

    if [[ -n "$inspect_result" ]]; then
        echo "$inspect_result"
    else
        # Last resort — use full volume list
        warn "Could not map volumes — using full volume list for safety"
        echo "$VOLUME_LIST"
    fi
}

# =============================================================================
# PRE-MIGRATION BACKUP
# Tars compose project dir + all relevant volumes to a local path
# =============================================================================
do_backup() {
    local backup_services="${1:-}"  # empty = all

    section "Pre-migration Backup"

    local default_dir="$HOME/docker-backups"
    read -rp "  Backup destination path [${default_dir}]: " bpath
    bpath="${bpath:-$default_dir}"
    mkdir -p "$bpath" || { error "Cannot create backup dir: ${bpath}"; return 1; }

    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local backup_name="${STACK_NAME}-backup-${ts}"
    local backup_file="${bpath}/${backup_name}.tar.gz"

    info "Backup target: ${backup_file}"
    info "This may take a while for large volumes..."

    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${RESET} Would backup compose project + volumes to ${backup_file}"
        return 0
    fi

    # Build volume list to back up
    local vols_to_backup
    if [[ -n "$backup_services" ]]; then
        local svc_nl
        svc_nl=$(echo "$backup_services" | tr ' ' '\n')
        vols_to_backup=$(get_volumes_for_services "$svc_nl")
    else
        vols_to_backup="$VOLUME_LIST"
    fi

    # Build the remote backup script as a local file then pipe it
    info "Streaming backup from source..."

    # Write the remote script to a temp file to avoid quoting hell
    local _bscript
    _bscript=$(mktemp)
    cat > "$_bscript" << REMOTESCRIPT
#!/bin/sh
set -e
TMPDIR=\$(mktemp -d)
STAGE="\${TMPDIR}/${backup_name}"
mkdir -p "\${STAGE}/compose" "\${STAGE}/volumes"

# Compose project
cp -a "${SRC_PATH}/." "\${STAGE}/compose/" 2>/dev/null || true

REMOTESCRIPT

    # Append volume copy commands
    while IFS= read -r vol; do
        [[ -z "$vol" ]] && continue
        # Resolve actual volume name
        local full_vol="${STACK_NAME}_${vol}"
        local actual_vols
        actual_vols=$(ssh_src "sudo docker volume ls --format '{{.Name}}'" 2>/dev/null || echo "")
        if echo "$actual_vols" | grep -qx "$full_vol"; then
            : # correct
        elif echo "$actual_vols" | grep -qx "$vol"; then
            full_vol="$vol"
        else
            local matched
            matched=$(echo "$actual_vols" | grep -E "_${vol}$|^${vol}$" | head -1)
            [[ -n "$matched" ]] && full_vol="$matched"
        fi
        cat >> "$_bscript" << REMOTESCRIPT
VOL_PATH="/var/lib/docker/volumes/${full_vol}/_data"
if [ -d "\${VOL_PATH}" ]; then
    mkdir -p "\${STAGE}/volumes/${full_vol}"
    cp -a "\${VOL_PATH}/." "\${STAGE}/volumes/${full_vol}/"
fi
REMOTESCRIPT
    done <<< "$vols_to_backup"

    cat >> "$_bscript" << REMOTESCRIPT
tar czf - -C "\${TMPDIR}" "${backup_name}"
rm -rf "\${TMPDIR}"
REMOTESCRIPT

    # Stream: pipe script to source, capture tar output locally
    # Run in background so we can show progress dots
    ssh -i "$SRC_KEY" -p "$SRC_PORT"         -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=10         -o BatchMode=yes -o StrictHostKeyChecking=accept-new         "${SRC_LOGIN:-$SRC_USER}@${SRC_HOST}"         "sudo bash -s" < "$_bscript" > "$backup_file" 2>/dev/null &
    local _bpid=$!
    progress_dots $_bpid "Backing up"
    wait $_bpid
    local _bstatus=$?
    rm -f "$_bscript"
    if [[ $_bstatus -ne 0 ]]; then
        warn "Backup may be incomplete (exit code ${_bstatus}) — continuing"
    fi

    local backup_size
    backup_size=$(du -sh "$backup_file" 2>/dev/null | awk '{print $1}')
    ok "Backup complete: ${backup_file} (${backup_size})"
    info "Restore with: tar xzf ${backup_file} -C /tmp && ls /tmp/${backup_name}/"
}

# =============================================================================
# GATHER INPUTS
# =============================================================================
# Scan a base path on the source for directories containing a compose file.
# Prints a numbered list and returns the chosen full path in SRC_PATH.
# Scan source base path for compose projects and let user pick one.
# Sets SRC_PATH, STACK_NAME, DST_PATH globally.
# Can be called repeatedly — picks a different stack each time.
pick_stack_from_source() {
    header "Select Stack to Migrate"

    local _login="${SRC_LOGIN:-$SRC_USER}"
    section "Scanning ${_login}@${SRC_HOST}:${SRC_BASE} for compose projects"

    # Use ssh_src which handles SRC_LOGIN/sudo automatically.
    # The find command is passed as a single heredoc-style string to avoid
    # quoting issues when tunnelled through SSH.
    local found
    found=$(ssh_src "sudo find '${SRC_BASE}' -maxdepth 3         -name 'docker-compose.yml'         -o -name 'docker-compose.yaml'         -o -name 'compose.yml'         -o -name 'compose.yaml'         2>/dev/null         | sed 's|/[^/]*\$||'         | sort -u" 2>/dev/null || echo "")

    if [[ -z "$found" ]]; then
        warn "No compose projects found under ${SRC_BASE} on ${SRC_HOST}"
        info "Common causes:"
        info "  - Wrong base path (current: ${SRC_BASE})"
        info "  - SSH key not accepted by source host (test: ssh ${_login}@${SRC_HOST} echo ok)"
        info "  - Passwordless sudo not configured for ${_login}"
        echo ""
        read -rp "  Enter base path to try [${SRC_BASE}]: " new_base
        [[ -n "$new_base" ]] && SRC_BASE="$new_base" && DST_BASE="$new_base"
        echo ""
        echo -e "  ${BOLD}m)${RESET} Enter full stack path manually"
        echo -e "  ${BOLD}b)${RESET} Back to menu"
        echo -en "${CYAN}  Choice [m]: ${RESET}"
        read -rn1 fb; echo ""
        case "${fb:-m}" in
            b|B) return 1 ;;
            *)
                read -rp "  Full source path (e.g. /opt/teslamate): " SRC_PATH
                [[ -z "$SRC_PATH" ]] && return 1
                STACK_NAME=$(basename "$SRC_PATH")
                DST_PATH="${DST_BASE}/${STACK_NAME}"
                return 0
                ;;
        esac
    fi

    mapfile -t STACK_DIRS <<< "$found"

    echo ""
    echo -e "  ${BOLD}Compose projects found on ${SRC_HOST}:${RESET}"
    echo ""

    # Fetch service counts — one ssh_src call per stack, sudo-aware
    local i=1
    for dir in "${STACK_DIRS[@]}"; do
        [[ -z "$dir" ]] && continue
        local name svcs
        name=$(basename "$dir")
        # Find the compose file in this directory and count services
        local _cf
        _cf=$(ssh_src "ls '${dir}/docker-compose.yml'             '${dir}/docker-compose.yaml'             '${dir}/compose.yml'             '${dir}/compose.yaml' 2>/dev/null | head -1" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$_cf" ]]; then
            svcs=$(ssh_src "sudo docker compose -f '${_cf}'                 config --services 2>/dev/null | grep -c ." 2>/dev/null | tr -d '[:space:]' || echo "?")
        else
            svcs="?"
        fi
        [[ "$svcs" == "0" || -z "$svcs" ]] && svcs="?"
        # Check if running containers are compose-managed — ONE ssh_src call per stack
        # to avoid overwhelming sshd with rapid connections during the scan.
        # Single remote command: get service names, check all containers at once.
        local _tag=""
        if [[ -n "$_cf" ]]; then
            local _compose_check
            _compose_check=$(ssh_src "
                svcs=\$(sudo docker compose -f '${_cf}' config --services 2>/dev/null)
                unmanaged=0
                for svc in \$svcs; do
                    cid=\$(sudo docker ps -q --filter name=^\${svc}\$ 2>/dev/null)
                    [ -z "\$cid" ] && continue
                    has_label=\$(sudo docker inspect "\$cid"                         --format '{{json .Config.Labels}}' 2>/dev/null                         | grep -c 'compose.project' || echo 0)
                    [ "\$has_label" = "0" ] && unmanaged=1 && break
                done
                echo \$unmanaged
            " 2>/dev/null | tr -d '[:space:]' | tail -1)
            [[ "${_compose_check}" == "1" ]] && _tag=" ${YELLOW}[docker run]${RESET}"
        fi
        echo -e "  ${BOLD}$(printf "%2d" $i))${RESET} $(printf "%-28s" "$name") ${DIM}$(printf "%2s" "$svcs") svc  $dir${RESET}${_tag}"
        ((i++))
    done

    echo ""
    echo -e "  ${DIM}Select a number to migrate that stack.${RESET}"
    echo -e "  ${BOLD}m)${RESET} Enter path manually"
    echo -e "  ${BOLD}b)${RESET} Back to menu"
    echo ""
    echo -en "${CYAN}  Select stack: ${RESET}"
    read -r pick

    local chosen_dir=""
    case "$pick" in
        m|M)
            read -rp "  Full source path: " chosen_dir
            ;;
        b|B)
            return 1
            ;;
        *)
            if [[ "$pick" =~ ^[0-9]+$ ]] &&                [[ "$pick" -ge 1 ]] &&                [[ "$pick" -le "${#STACK_DIRS[@]}" ]]; then
                chosen_dir="${STACK_DIRS[$((pick-1))]}"
            else
                warn "Invalid — enter path manually."
                read -rp "  Full source path: " chosen_dir
            fi
            ;;
    esac

    [[ -z "$chosen_dir" ]] && return 1

    SRC_PATH="$chosen_dir"
    STACK_NAME=$(basename "$SRC_PATH")
    read -rp "  Stack name [${STACK_NAME}]: " input
    STACK_NAME="${input:-$STACK_NAME}"

    # Destination path — default matches source layout on dst base
    local dst_default="${DST_BASE}/${STACK_NAME}"
    read -rp "  Destination path [${dst_default}]: " input
    DST_PATH="${input:-$dst_default}"

    # Reset compose/volume state since stack changed
    COMPOSE_FILE=""
    VOLUME_LIST=""
    SERVICE_LIST=""
    SELECTED_SERVICES=""

    ok "Stack: ${STACK_NAME}"
    ok "  Source : ${SRC_PATH}"
    ok "  Dest   : ${DST_PATH}"
    # Auto-save so stack persists across menu navigation
    save_config
    return 0
}

gather_inputs() {
    header "Connection Setup"

    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "${DIM}  Saved configuration found.${RESET}"
        if load_config; then
            ok "Configuration loaded — all settings restored."
            return 0
        fi
        echo ""
    fi

    # ── Source host ───────────────────────────────────────────────────────────
    section "Source Server"
    if [[ -n "${SRC_HOST:-}" ]]; then
        local _src_show="${SRC_LOGIN:-$SRC_USER}@${SRC_HOST}:${SRC_PORT}"
        [[ -n "$SRC_LOGIN" ]] && _src_show+=" (sudo→${SRC_USER})"
        echo -e "  ${DIM}Already set: ${_src_show}${RESET}"
        if confirm "  Change source host details?"; then
            SRC_HOST=""; SRC_PORT="22"; SRC_USER="root"; SRC_LOGIN=""
        fi
    fi
    if [[ -z "$SRC_HOST" ]]; then
        read -rp "  Host/IP                        : " SRC_HOST
        read -rp "  SSH port               [22]    : " input; SRC_PORT="${input:-22}"
        echo -e "  ${DIM}SSH login user — the account you SSH in as (e.g. khaverblad)${RESET}"
        read -rp "  SSH login user         [root]  : " input; SRC_LOGIN="${input:-}"
        local _src_login="${SRC_LOGIN:-root}"
        echo -e "  ${DIM}Effective user — who runs docker commands (usually root)${RESET}"
        echo -e "  ${DIM}If login user = effective user, leave blank${RESET}"
        read -rp "  Effective user (sudo)  [root]  : " input; SRC_USER="${input:-root}"
        [[ "$SRC_LOGIN" == "$SRC_USER" || -z "$SRC_LOGIN" ]] && SRC_LOGIN=""
    fi
    read -rp "  SSH key [${SRC_KEY:-~/.ssh/id_ed25519}]: " input
    SRC_KEY="${input:-${SRC_KEY:-$HOME/.ssh/id_ed25519}}"
    read -rp "  Base projects path on source   [${SRC_BASE}]: " input
    SRC_BASE="${input:-$SRC_BASE}"

    # ── Destination host ──────────────────────────────────────────────────────
    section "Destination Server"
    if [[ -n "${DST_HOST:-}" ]]; then
        local _dst_show="${DST_LOGIN:-$DST_USER}@${DST_HOST}:${DST_PORT}"
        [[ -n "$DST_LOGIN" ]] && _dst_show+=" (sudo→${DST_USER})"
        echo -e "  ${DIM}Already set: ${_dst_show}${RESET}"
        if confirm "  Change destination host details?"; then
            DST_HOST=""; DST_PORT="22"; DST_USER="root"; DST_LOGIN=""
        fi
    fi
    if [[ -z "$DST_HOST" ]]; then
        read -rp "  Host/IP                        : " DST_HOST
        read -rp "  SSH port               [22]    : " input; DST_PORT="${input:-22}"
        echo -e "  ${DIM}SSH login user — the account you SSH in as${RESET}"
        read -rp "  SSH login user         [root]  : " input; DST_LOGIN="${input:-}"
        echo -e "  ${DIM}Effective user — who runs docker commands (usually root)${RESET}"
        echo -e "  ${DIM}If login user = effective user, leave blank${RESET}"
        read -rp "  Effective user (sudo)  [root]  : " input; DST_USER="${input:-root}"
        [[ "$DST_LOGIN" == "$DST_USER" || -z "$DST_LOGIN" ]] && DST_LOGIN=""
    fi
    read -rp "  SSH key [${DST_KEY:-~/.ssh/id_ed25519}]: " input
    DST_KEY="${input:-${DST_KEY:-$HOME/.ssh/id_ed25519}}"
    read -rp "  Base projects path on destination [${DST_BASE}]: " input
    DST_BASE="${input:-$DST_BASE}"

    echo ""
    ok "Hosts configured. Use option 2 to select a stack to migrate."
    confirm "Save this configuration for future runs?" && save_config
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================
preflight_checks() {
    header "Pre-flight Checks"
    PREFLIGHT_ERRORS=0
    PREFLIGHT_WARNINGS=0

    # ── SSH ───────────────────────────────────────────────────────────────────
    # Open persistent SSH connections — reused by all subsequent checks
    open_ssh_multiplexing

    section "SSH Connectivity"
    # Connect as the login user (SRC_LOGIN if set, else SRC_USER)
    local _src_login="${SRC_LOGIN:-$SRC_USER}"
    local _dst_login="${DST_LOGIN:-$DST_USER}"

    # KEY DESIGN: combine SSH connectivity + sudo test into ONE connection per host.
    # Multiple rapid SSH connections from the same source IP trigger UniFi IDS/IPS
    # rate limiting which blocks the Mac mid-preflight. A single connection that
    # tests both SSH auth AND sudo avoids the burst entirely.

    verbose "Testing SSH + sudo on source: ${_src_login}@${SRC_HOST}:${SRC_PORT}"
    local _src_test
    if [[ -n "$SRC_LOGIN" && "$SRC_LOGIN" != "$SRC_USER" ]]; then
        # Single connection: test SSH auth AND sudo in one round trip
        _src_test=$(ssh -i "$SRC_KEY" -p "$SRC_PORT"             -o ConnectTimeout=10 -o BatchMode=yes             -o StrictHostKeyChecking=accept-new             "${_src_login}@${SRC_HOST}"             "echo ssh_ok && sudo -n echo sudo_ok" 2>/dev/null || echo "failed")
        if echo "$_src_test" | grep -q "ssh_ok"; then
            log_result ok "SSH to source OK (${_src_login}@${SRC_HOST}:${SRC_PORT})"
            if echo "$_src_test" | grep -q "sudo_ok"; then
                log_result ok "Sudo on source: ${_src_login} -> ${SRC_USER} (passwordless)"
            else
                log_result error "Sudo on source failed — add NOPASSWD to /etc/sudoers.d/${_src_login}"
            fi
        else
            log_result error "Cannot SSH to source as ${_src_login}@${SRC_HOST} — check key and authorized_keys"
        fi
    else
        _src_test=$(ssh -i "$SRC_KEY" -p "$SRC_PORT"             -o ConnectTimeout=10 -o BatchMode=yes             -o StrictHostKeyChecking=accept-new             "${_src_login}@${SRC_HOST}" "echo ssh_ok" 2>/dev/null || echo "failed")
        if echo "$_src_test" | grep -q "ssh_ok"; then
            log_result ok "SSH to source OK (${_src_login}@${SRC_HOST}:${SRC_PORT})"
        else
            log_result error "Cannot SSH to source as ${_src_login}@${SRC_HOST} — check key and authorized_keys"
        fi
    fi

    verbose "Testing SSH + sudo on destination: ${_dst_login}@${DST_HOST}:${DST_PORT}"
    local _dst_test
    if [[ -n "$DST_LOGIN" && "$DST_LOGIN" != "$DST_USER" ]]; then
        # Single connection: test SSH auth AND sudo in one round trip
        # Add a small delay between hosts to avoid IDS rate limiting
        sleep 1
        _dst_test=$(ssh -i "$DST_KEY" -p "$DST_PORT"             -o ConnectTimeout=10 -o BatchMode=yes             -o StrictHostKeyChecking=accept-new             "${_dst_login}@${DST_HOST}"             "echo ssh_ok && sudo -n echo sudo_ok" 2>/dev/null || echo "failed")
        if echo "$_dst_test" | grep -q "ssh_ok"; then
            log_result ok "SSH to destination OK (${_dst_login}@${DST_HOST}:${DST_PORT})"
            if echo "$_dst_test" | grep -q "sudo_ok"; then
                log_result ok "Sudo on destination: ${_dst_login} -> ${DST_USER} (passwordless)"
            else
                log_result error "Sudo on destination failed — add NOPASSWD to /etc/sudoers.d/${_dst_login}"
            fi
        else
            log_result error "Cannot SSH to destination as ${_dst_login}@${DST_HOST} — check key and authorized_keys"
        fi
    else
        sleep 1
        _dst_test=$(ssh -i "$DST_KEY" -p "$DST_PORT"             -o ConnectTimeout=10 -o BatchMode=yes             -o StrictHostKeyChecking=accept-new             "${_dst_login}@${DST_HOST}" "echo ssh_ok" 2>/dev/null || echo "failed")
        if echo "$_dst_test" | grep -q "ssh_ok"; then
            log_result ok "SSH to destination OK (${_dst_login}@${DST_HOST}:${DST_PORT})"
        else
            log_result error "Cannot SSH to destination as ${_dst_login}@${DST_HOST} — check key and authorized_keys"
        fi
    fi

    [[ $PREFLIGHT_ERRORS -gt 0 ]] && fatal "SSH connectivity failed — cannot continue."

    # ── Docker ────────────────────────────────────────────────────────────────
    section "Docker"
    verbose "Querying Docker version on source"
    SRC_DOCKER_VER=$(ssh_src "docker version --format '{{.Server.Version}}'" 2>/dev/null || echo "")
    verbose "Querying Docker version on destination"
    DST_DOCKER_VER=$(ssh_dst "docker version --format '{{.Server.Version}}'" 2>/dev/null || echo "")

    [[ -n "$SRC_DOCKER_VER" ]] \
        && log_result ok  "Docker on source: v${SRC_DOCKER_VER}" \
        || log_result error "Docker not running on source"
    [[ -n "$DST_DOCKER_VER" ]] \
        && log_result ok  "Docker on destination: v${DST_DOCKER_VER}" \
        || log_result error "Docker not running on destination"

    verbose "Querying Compose version on source"
    SRC_COMPOSE=$(ssh_src "docker compose version --short 2>/dev/null || echo ''" || echo "")
    verbose "Querying Compose version on destination"
    DST_COMPOSE=$(ssh_dst "docker compose version --short 2>/dev/null || echo ''" || echo "")

    [[ -n "$SRC_COMPOSE" ]] \
        && log_result ok  "Compose on source: v${SRC_COMPOSE}" \
        || log_result error "Docker Compose missing on source"
    [[ -n "$DST_COMPOSE" ]] \
        && log_result ok  "Compose on destination: v${DST_COMPOSE}" \
        || log_result error "Docker Compose missing on destination"

    # ── LXC / storage driver ──────────────────────────────────────────────────
    section "Docker Storage & LXC"
    verbose "Detecting virt type on destination"
    DST_VIRT=$(ssh_dst "systemd-detect-virt 2>/dev/null || echo none" 2>/dev/null \
        | tr -d '[:space:]' | grep -oE '[a-z0-9-]+$' | tail -1)
    DST_VIRT="${DST_VIRT:-none}"
    verbose "Detecting Docker storage driver on destination"
    DST_DRIVER=$(ssh_dst "docker info --format '{{.Driver}}' 2>/dev/null || echo unknown")
    info "Destination virt: ${DST_VIRT}  |  Storage driver: ${DST_DRIVER}"

    if [[ "$DST_VIRT" == "lxc" ]]; then
        case "$DST_DRIVER" in
            fuse-overlayfs) log_result ok "fuse-overlayfs — correct for unprivileged LXC" ;;
            overlay2)       log_result warn "overlay2 in LXC — may fail; recommend fuse-overlayfs" ;;
            vfs)            log_result warn "vfs driver — works but slow; recommend fuse-overlayfs" ;;
            *)              log_result warn "Unknown storage driver '${DST_DRIVER}' in LXC" ;;
        esac

        verbose "Checking /dev/fuse on destination"
        local dst_fuse
        dst_fuse=$(ssh_dst "test -e /dev/fuse && echo yes || echo no")
        [[ "$dst_fuse" == "yes" ]] \
            && log_result ok  "/dev/fuse present in LXC" \
            || log_result warn "/dev/fuse missing — add fuse=1 to LXC features"

        verbose "Checking LXC capabilities"
        local dst_nest
        dst_nest=$(ssh_dst "grep -c CapPrm /proc/1/status 2>/dev/null || echo 0")
        [[ "${dst_nest:-0}" -gt 0 ]] \
            && log_result ok  "LXC capabilities readable (nesting likely enabled)" \
            || log_result warn "Cannot verify LXC nesting — ensure features: nesting=1"
    else
        log_result ok "Destination is not LXC (${DST_VIRT}) — no LXC-specific constraints"
    fi

    # ── iGPU ──────────────────────────────────────────────────────────────────
    section "Hardware Transcoding (Plex/VAAPI)"
    verbose "Checking /dev/dri on source"
    local src_dri dst_dri
    src_dri=$(ssh_src "ls /dev/dri/renderD128 2>/dev/null && echo yes || echo no")
    verbose "Checking /dev/dri on destination"
    dst_dri=$(ssh_dst "test -e /dev/dri/renderD128 && echo yes || echo no" 2>/dev/null | tr -d '[:space:]' || echo "no")

    [[ "$src_dri" == "yes" ]] \
        && log_result ok  "Source: /dev/dri/renderD128 present (HW transcode active)" \
        || info "Source: no /dev/dri (software transcode)"
    [[ "$dst_dri" == "yes" ]] \
        && log_result ok  "Destination: /dev/dri/renderD128 present" \
        || log_result warn "Destination: /dev/dri missing — Plex will CPU transcode. Fix: add dri passthrough to LXC config"

    # ── Compose file & services ───────────────────────────────────────────────
    section "Compose Project & Services"

    # Detect database images in the stack — they need special handling
    local _db_images
    _db_images=$(ssh_src         "sudo docker compose -f ${COMPOSE_FILE} config 2>/dev/null         | grep -iE 'image:.*(postgres|mysql|mariadb|mongo|redis|influxdb)'         | awk '{print \$2}'" 2>/dev/null || echo "")
    if [[ -n "$_db_images" ]]; then
        log_result warn "Database containers detected in stack:"
        while IFS= read -r dbimg; do
            [[ -z "$dbimg" ]] && continue
            warn "    • ${dbimg}"
        done <<< "$_db_images"
        warn "  Migration will use full_stop strategy with 60s graceful shutdown"
        warn "  Consider creating logical backup (pg_dump/mysqldump) as insurance"
    fi

    # Check for s6-overlay temp dir pollution (linuxserver containers write
    # custom-cont-init.d.* and custom-services.d.* to bind-mounted config dirs)
    local s6_dirs
    s6_dirs=$(ssh_src         "sudo find '${SRC_PATH}' -maxdepth 1         -name 'custom-cont-init.d.*' -o -name 'custom-services.d.*'         2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]' || echo 0)
    if [[ "${s6_dirs:-0}" -gt 0 ]]; then
        log_result warn "s6-overlay temp dirs found in ${SRC_PATH} (${s6_dirs} dirs)"
        warn "  These are linuxserver container artifacts — safe to delete before migrating:"
        warn "  ssh ${SRC_LOGIN:-$SRC_USER}@${SRC_HOST} 'sudo rm -rf ${SRC_PATH}/custom-cont-init.d.* ${SRC_PATH}/custom-services.d.*'"
    fi
    verbose "Locating compose file in ${SRC_PATH}"
    COMPOSE_FILE=$(ssh_src "ls ${SRC_PATH}/docker-compose.yml \
        ${SRC_PATH}/docker-compose.yaml \
        ${SRC_PATH}/compose.yml \
        ${SRC_PATH}/compose.yaml 2>/dev/null | head -1" || echo "")

    if [[ -n "$COMPOSE_FILE" ]]; then
        log_result ok "Compose file: ${COMPOSE_FILE}"
        verbose "Enumerating services"
        SERVICE_LIST=$(ssh_src "docker compose -f ${COMPOSE_FILE} config --services 2>/dev/null" || echo "")
        local svc_count
        svc_count=$(echo "$SERVICE_LIST" | grep -c . || echo 0)
        log_result ok "Services in stack: ${svc_count}"
        $VERBOSE && echo "$SERVICE_LIST" | while read -r s; do [[ -n "$s" ]] && verbose "  service: ${s}"; done
    else
        log_result error "No compose file found in ${SRC_PATH}"
    fi

    # ── Named volumes ─────────────────────────────────────────────────────────
    verbose "Enumerating named volumes"
    VOLUME_LIST=$(ssh_src "sudo docker compose -f ${COMPOSE_FILE} config --volumes 2>/dev/null" || echo "")
    if [[ -n "$VOLUME_LIST" ]]; then
        ok "Named volumes to migrate:"
        while IFS= read -r vol; do
            [[ -z "$vol" ]] && continue
            local vol_size
            verbose "  Getting size of volume: ${STACK_NAME}_${vol}"
            vol_size=$(ssh_src "sudo du -sh /var/lib/docker/volumes/${STACK_NAME}_${vol}/_data                 2>/dev/null | awk '{print \$1}'" || echo "?")
            echo -e "    ${GREEN}•${RESET} ${STACK_NAME}_${vol}  ${DIM}(${vol_size})${RESET}"
        done <<< "$VOLUME_LIST"
    else
        info "No named volumes — stack uses bind mounts"
    fi

    # ── Bind mount analysis ───────────────────────────────────────────────────
    verbose "Checking for bind mounts"
    local bind_mounts
    bind_mounts=$(ssh_src "sudo docker compose -f ${COMPOSE_FILE} config 2>/dev/null         | grep -E '^\s+source:'         | awk '{print \$2}'         | grep '^/'         | sort -u" 2>/dev/null || echo "")

    if [[ -n "$bind_mounts" ]]; then
        local outside_mounts=""
        local inside_mounts=""
        while IFS= read -r bm; do
            [[ -z "$bm" ]] && continue
            if [[ "$bm" == "${SRC_PATH}"* ]]; then
                inside_mounts="${inside_mounts}
    ${GREEN}•${RESET} ${DIM}${bm}  (inside project — transferred automatically)${RESET}"
            else
                outside_mounts="${outside_mounts}
    ${YELLOW}•${RESET} ${YELLOW}${bm}  (outside project — needs manual handling)${RESET}"
            fi
        done <<< "$bind_mounts"

        if [[ -n "$inside_mounts" ]]; then
            ok "Bind mounts inside project path (auto-transferred):"
            echo -e "$inside_mounts"
        fi
        if [[ -n "$outside_mounts" ]]; then
            log_result warn "Bind mounts OUTSIDE project path — not auto-transferred:"
            echo -e "$outside_mounts"
            warn "  These paths must exist on the destination with the same content."
            warn "  Ensure they are NFS mounts, manually copied, or re-created before starting."
            # Check if outside bind mount paths actually exist on destination
            while IFS= read -r bm; do
                [[ -z "$bm" ]] && continue
                local bm_exists
                bm_exists=$(ssh_dst "test -d '${bm}' && echo yes || echo no" 2>/dev/null | tr -d '[:space:]')
                if [[ "$bm_exists" == "yes" ]]; then
                    ok "  Destination path exists: ${bm}"
                else
                    log_result warn "  Destination path MISSING: ${bm} — create or mount before migrating"
                fi
            done <<< "$bind_mounts"
        fi
    fi

    # ── PUID/PGID verification ────────────────────────────────────────────────
    section "PUID/PGID Verification"
    local puid_vals pgid_vals
    puid_vals=$(ssh_src "sudo docker compose -f ${COMPOSE_FILE} config 2>/dev/null         | grep -oP 'PUID=\K[0-9]+' | sort -u" 2>/dev/null || echo "")
    pgid_vals=$(ssh_src "sudo docker compose -f ${COMPOSE_FILE} config 2>/dev/null         | grep -oP 'PGID=\K[0-9]+' | sort -u" 2>/dev/null || echo "")

    if [[ -z "$puid_vals" && -z "$pgid_vals" ]]; then
        info "No PUID/PGID configured in compose file"
    else
        local puid_issues=false
        while IFS= read -r puid; do
            [[ -z "$puid" ]] && continue
            local uid_exists
            uid_exists=$(ssh_dst "getent passwd ${puid} > /dev/null 2>&1 && echo yes || echo no"                 2>/dev/null | tr -d '[:space:]')
            if [[ "$uid_exists" == "yes" ]]; then
                local uname
                uname=$(ssh_dst "getent passwd ${puid} | cut -d: -f1" 2>/dev/null | tr -d '[:space:]')
                log_result ok "PUID ${puid} (${uname}) exists on destination"
            else
                log_result warn "PUID ${puid} missing on destination"
                warn "  Fix: sudo useradd -u ${puid} -g PGID -s /usr/sbin/nologin -M username"
                puid_issues=true
            fi
        done <<< "$puid_vals"

        while IFS= read -r pgid; do
            [[ -z "$pgid" ]] && continue
            local gid_exists
            gid_exists=$(ssh_dst "getent group ${pgid} > /dev/null 2>&1 && echo yes || echo no"                 2>/dev/null | tr -d '[:space:]')
            if [[ "$gid_exists" == "yes" ]]; then
                local gname
                gname=$(ssh_dst "getent group ${pgid} | cut -d: -f1" 2>/dev/null | tr -d '[:space:]')
                log_result ok "PGID ${pgid} (${gname}) exists on destination"
            else
                log_result warn "PGID ${pgid} missing on destination"
                warn "  Fix: sudo groupadd -g ${pgid} groupname"
                puid_issues=true
            fi
        done <<< "$pgid_vals"

        if ! $puid_issues; then
            ok "All PUID/PGID values verified on destination"
        fi
    fi

    # ── Disk space ────────────────────────────────────────────────────────────
    section "Disk Space"
    verbose "Measuring source project size"
    local src_used vol_used=0
    src_used=$(ssh_src "du -sb ${SRC_PATH} 2>/dev/null | awk '{print \$1}'" || echo 0)
    if [[ -n "$VOLUME_LIST" ]]; then
        while IFS= read -r vol; do
            [[ -z "$vol" ]] && continue
            verbose "  Measuring volume: ${STACK_NAME}_${vol}"
            local vsize
            vsize=$(ssh_src "du -sb /var/lib/docker/volumes/${STACK_NAME}_${vol}/_data \
                2>/dev/null | awk '{print \$1}'" || echo 0)
            vol_used=$((vol_used + vsize))
        done <<< "$VOLUME_LIST"
    fi
    local total_bytes total_mb dst_free dst_free_mb
    total_bytes=$((src_used + vol_used))
    total_mb=$((total_bytes / 1024 / 1024))
    verbose "Checking destination free space"
    dst_free=$(ssh_dst "df -B1 / 2>/dev/null | awk 'NR==2{print \$4}'" || echo 0)
    dst_free_mb=$((dst_free / 1024 / 1024))
    info "Data to transfer  : ~${total_mb} MB"
    info "Destination free  : ~${dst_free_mb} MB"
    [[ $dst_free -gt $((total_bytes * 12 / 10)) ]] \
        && log_result ok  "Disk space sufficient (${dst_free_mb}MB free vs ~${total_mb}MB needed)" \
        || log_result warn "Disk space tight: ${dst_free_mb}MB free vs ~${total_mb}MB needed"

    # ── Architecture & compatibility ──────────────────────────────────────────
    section "Architecture & Compatibility"
    # Check if source image exists on registry for destination architecture
    verbose "Checking image manifest availability"
    local src_image
    src_image=$(ssh_src         "sudo docker compose -f ${COMPOSE_FILE} config 2>/dev/null         | grep 'image:' | head -1 | awk '{print \$2}'"         2>/dev/null | tr -d '[:space:]')
    if [[ -n "$src_image" ]]; then
        local manifest_ok
        manifest_ok=$(ssh_dst             "sudo docker manifest inspect '${src_image}' > /dev/null 2>&1             && echo ok || echo fail" 2>/dev/null | tr -d '[:space:]')
        if [[ "$manifest_ok" == "ok" ]]; then
            log_result ok "Image manifest available: ${src_image}"
        else
            # Try pulling to get a more specific error
            local pull_err
            pull_err=$(ssh_dst                 "sudo docker pull '${src_image}' 2>&1 | tail -1"                 2>/dev/null | tr -d '
')
            if echo "$pull_err" | grep -qi "manifest unknown\|not found\|deprecated"; then
                log_result error "Image unavailable on registry: ${src_image}"
                error "  Pull error: ${pull_err}"
                error "  The image tag may be deprecated or removed — check for alternatives"
            else
                log_result warn "Could not verify image manifest: ${src_image}"
                warn "  This may be a network issue or private registry"
            fi
        fi
    fi
    verbose "Checking CPU architecture"
    local src_arch dst_arch
    src_arch=$(ssh_src "uname -m")
    dst_arch=$(ssh_dst "uname -m")
    [[ "$src_arch" == "$dst_arch" ]] \
        && log_result ok  "Architecture match: ${src_arch}" \
        || log_result error "Architecture mismatch: source=${src_arch} dst=${dst_arch} — images won't run"

    local src_maj dst_maj
    src_maj=$(echo "${SRC_DOCKER_VER:-0}" | cut -d. -f1)
    dst_maj=$(echo "${DST_DOCKER_VER:-0}" | cut -d. -f1)
    if [[ "$src_maj" == "$dst_maj" ]]; then
        log_result ok "Docker version parity: v${SRC_DOCKER_VER} / v${DST_DOCKER_VER}"
    else
        # Version mismatch — volumes are still compatible across versions,
        # only flag as error if gap is >2 major versions
        local ver_gap=$(( src_maj - dst_maj ))
        [[ $ver_gap -lt 0 ]] && ver_gap=$(( -ver_gap ))
        if [[ $ver_gap -gt 2 ]]; then
            log_result warn "Docker version gap: v${SRC_DOCKER_VER} vs v${DST_DOCKER_VER} — consider upgrading destination"
        else
            info "Docker versions: v${SRC_DOCKER_VER} (src) / v${DST_DOCKER_VER} (dst) — compatible"
        fi
    fi

    if [[ "$DST_VIRT" == "lxc" ]]; then
        verbose "Checking source virt type for UID shift assessment"
        local src_virt
        src_virt=$(ssh_src "systemd-detect-virt 2>/dev/null || echo none" 2>/dev/null             | tr -d '[:space:]' | grep -oE '[a-z0-9-]+$' | tail -1)
        src_virt="${src_virt:-none}"
        if [[ "$src_virt" == "none" ]]; then
            log_result ok "Source is bare metal — real UIDs (no shift needed)"
        else
            log_result ok "Source virt: ${src_virt} — volumes should transfer cleanly"
        fi
    fi

    # ── Port conflicts ────────────────────────────────────────────────────────
    section "Port Conflicts"
    verbose "Extracting exposed ports from compose config"
    local exposed_ports conflicts=""
    # Match both quoted (published: "1883") and unquoted (published: 1883)
    # formats — Docker Compose v2 output varies between versions
    exposed_ports=$(ssh_src "docker compose -f ${COMPOSE_FILE} config 2>/dev/null \
        | grep -oP 'published:\s*\"?\K[0-9]+' | sort -u" || echo "")
    if [[ -n "$exposed_ports" ]]; then
        while IFS= read -r port; do
            [[ -z "$port" ]] && continue
            verbose "  Checking port ${port} on destination"
            local in_use owner_container
            in_use=$(ssh_dst "ss -tlnp 2>/dev/null | grep -c ':${port} '" 2>/dev/null | tr -d '[:space:]' || echo 0)
            in_use="${in_use:-0}"
            if [[ "$in_use" =~ ^[0-9]+$ ]] && [[ "$in_use" -gt 0 ]]; then
                # Find which container owns this port
                owner_container=$(ssh_dst                     "sudo docker ps --format '{{.Names}}:{{.Ports}}' 2>/dev/null                     | grep ':${port}->' | cut -d: -f1"                     2>/dev/null | tr -d '[:space:]' | head -1)
                if [[ -n "$owner_container" ]]; then
                    conflicts="${conflicts}
    ${YELLOW}•${RESET} Port ${port} — in use by container: ${BOLD}${owner_container}${RESET}"
                else
                    conflicts="${conflicts}
    ${YELLOW}•${RESET} Port ${port} — in use by unknown process"
                fi
            fi
        done <<< "$exposed_ports"
        if [[ -n "$conflicts" ]]; then
            log_result warn "Port conflicts on destination:"
            echo -e "$conflicts"
        else
            log_result ok "No port conflicts detected"
        fi
    else
        info "No published ports found in compose config"
    fi

    # ── inotify ───────────────────────────────────────────────────────────────
    section "inotify Limits"
    verbose "Reading inotify limits on destination"
    local dst_watches dst_instances
    dst_watches=$(ssh_dst "sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0")
    dst_instances=$(ssh_dst "sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0")
    verbose "  watches=${dst_watches}  instances=${dst_instances}"
    [[ "${dst_watches:-0}" -ge 524288 ]] \
        && log_result ok  "inotify watches: ${dst_watches} (sufficient)" \
        || log_result warn "inotify watches: ${dst_watches} — recommend ≥524288 for *arr suite"
    [[ "${dst_instances:-0}" -ge 1024 ]] \
        && log_result ok  "inotify instances: ${dst_instances} (sufficient)" \
        || log_result warn "inotify instances: ${dst_instances} — recommend ≥1024"

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Pre-flight summary:${RESET}"
    echo -e "  Errors   : ${RED}${PREFLIGHT_ERRORS}${RESET}"
    echo -e "  Warnings : ${YELLOW}${PREFLIGHT_WARNINGS}${RESET}"
    echo ""

    [[ $PREFLIGHT_ERRORS -gt 0 ]] && \
        fatal "Pre-flight failed with ${PREFLIGHT_ERRORS} error(s). Resolve before migrating."

    if [[ $PREFLIGHT_WARNINGS -gt 0 ]] && ! $FORCE; then
        confirm "Pre-flight has ${PREFLIGHT_WARNINGS} warning(s). Continue anyway?" \
            || { info "Returning to menu."; return 1; }
    fi
    return 0
}

# =============================================================================
# EXTENDED DIAGNOSTICS (always verbose)
# =============================================================================
run_diagnostics() {
    header "Extended Diagnostics"
    local prev_verbose=$VERBOSE
    VERBOSE=true  # diagnostics always verbose

    [[ -z "$SRC_HOST" || -z "$DST_HOST" ]] && gather_inputs

    section "Source Host Report (${SRC_HOST})"
    ssh_src "
        echo '--- OS & Kernel ---'
        cat /etc/os-release 2>/dev/null | grep -E '^(NAME|VERSION)='
        uname -r
        echo '--- Virt ---'
        systemd-detect-virt 2>/dev/null || echo bare
        echo '--- CPU ---'
        lscpu | grep -E '^(Model name|CPU\(s\)|Thread|Core)'
        cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null | xargs -I{} echo 'Governor: {}'
        echo '--- Docker ---'
        docker info --format 'Version: {{.ServerVersion}}  Driver: {{.Driver}}  Cgroup: {{.CgroupDriver}} v{{.CgroupVersion}}' 2>/dev/null
        echo '--- Running containers ---'
        docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null
        echo '--- Disk ---'
        df -h / /var/lib/docker 2>/dev/null | uniq
        echo '--- Memory ---'
        free -h
        echo '--- inotify ---'
        sysctl fs.inotify.max_user_watches fs.inotify.max_user_instances 2>/dev/null
        echo '--- /dev/dri ---'
        ls -la /dev/dri/ 2>/dev/null || echo 'not present'
    " 2>/dev/null || error "Could not connect to source"

    section "Destination Host Report (${DST_HOST})"
    ssh_dst "
        echo '--- OS & Kernel ---'
        cat /etc/os-release 2>/dev/null | grep -E '^(NAME|VERSION)='
        uname -r
        echo '--- Virt ---'
        systemd-detect-virt 2>/dev/null || echo bare
        echo '--- LXC capabilities ---'
        grep -E '^Cap' /proc/1/status 2>/dev/null || echo n/a
        echo '--- Docker ---'
        docker info --format 'Version: {{.ServerVersion}}  Driver: {{.Driver}}  Cgroup: {{.CgroupDriver}} v{{.CgroupVersion}}' 2>/dev/null
        echo '--- Running containers ---'
        docker ps --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || echo 'none'
        echo '--- Disk ---'
        df -h / /var/lib/docker 2>/dev/null | uniq
        echo '--- Memory ---'
        free -h
        echo '--- inotify ---'
        sysctl fs.inotify.max_user_watches fs.inotify.max_user_instances 2>/dev/null
        echo '--- /dev/dri ---'
        ls -la /dev/dri/ 2>/dev/null || echo 'not present'
        echo '--- /dev/fuse ---'
        ls -la /dev/fuse 2>/dev/null || echo 'not present'
        echo '--- Docker storage ---'
        docker info --format 'Storage driver: {{.Driver}}\nDocker root: {{.DockerRootDir}}' 2>/dev/null
        df -h /var/lib/docker 2>/dev/null || true
    " 2>/dev/null || error "Could not connect to destination"

    if [[ -n "$COMPOSE_FILE" ]]; then
        section "Stack Analysis (${STACK_NAME})"
        ssh_src "
            echo '--- Services ---'
            docker compose -f ${COMPOSE_FILE} config --services 2>/dev/null
            echo '--- Named volumes ---'
            docker compose -f ${COMPOSE_FILE} config --volumes 2>/dev/null
            echo '--- Exposed ports ---'
            docker compose -f ${COMPOSE_FILE} config 2>/dev/null | grep -E 'published'
            echo '--- Volume sizes ---'
            for v in \$(docker compose -f ${COMPOSE_FILE} config --volumes 2>/dev/null); do
                path=\"/var/lib/docker/volumes/${STACK_NAME}_\${v}/_data\"
                size=\$(du -sh \"\$path\" 2>/dev/null | awk '{print \$1}')
                echo \"  \${STACK_NAME}_\${v}: \${size:-not found}\"
            done
            echo '--- Container resource usage ---'
            docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null || true
        " 2>/dev/null
    else
        warn "No compose file loaded — run pre-flight first for stack analysis"
    fi

    echo ""
    info "Full diagnostic output saved to: ${LOGFILE}"
    VERBOSE=$prev_verbose
}

# =============================================================================
# DESTINATION VERIFICATION
# =============================================================================
run_verification() {
    header "Destination Verification"
    [[ -z "$DST_HOST" ]] && gather_inputs

    local all_ok=true

    section "Container Status"
    verbose "Querying container status on destination"
    local status_output
    status_output=$(ssh_dst "cd ${DST_PATH} && \
        docker compose ps --format 'table {{.Name}}\t{{.Status}}' 2>/dev/null" || echo "")

    if [[ -n "$status_output" ]]; then
        echo "$status_output"
        local unhealthy
        unhealthy=$(ssh_dst "cd ${DST_PATH} && \
            docker compose ps --format '{{.Name}}|{{.Status}}' 2>/dev/null" \
            | grep -v -iE '\|(up|running)' | grep -v '^$' || echo "")
        if [[ -n "$unhealthy" ]]; then
            warn "Unhealthy containers:"
            while IFS='|' read -r name status; do
                error "  ${name}: ${status}"
            done <<< "$unhealthy"
            all_ok=false
        else
            ok "All containers running"
        fi
    else
        error "No containers found at ${DST_PATH}"
        all_ok=false
    fi

    section "Volume Integrity"
    local check_vols
    check_vols=$(get_effective_volumes)
    if [[ -n "$check_vols" ]]; then
        while IFS= read -r vol; do
            [[ -z "$vol" ]] && continue
            local vpath="/var/lib/docker/volumes/${STACK_NAME}_${vol}/_data"
            verbose "  Checking volume: ${vpath}"
            local vsize vfiles
            vsize=$(ssh_dst "du -sh ${vpath} 2>/dev/null | awk '{print \$1}'" || echo "missing")
            vfiles=$(ssh_dst "find ${vpath} -maxdepth 1 2>/dev/null | wc -l" || echo 0)
            if [[ "$vsize" != "missing" && "${vfiles:-0}" -gt 1 ]]; then
                ok "Volume ${STACK_NAME}_${vol}: ${vsize}, ${vfiles} entries"
            else
                error "Volume ${STACK_NAME}_${vol}: empty or missing"
                all_ok=false
            fi
        done <<< "$check_vols"
    else
        info "No named volumes to verify"
    fi

    section "Port Accessibility"
    verbose "Checking listening ports on destination"
    local exposed_ports
    exposed_ports=$(ssh_dst "cd ${DST_PATH} && \
        docker compose ps --format '{{.Ports}}' 2>/dev/null | \
        grep -oP '0\.0\.0\.0:\K[0-9]+(?=->)' | sort -u" || echo "")
    if [[ -n "$exposed_ports" ]]; then
        while IFS= read -r port; do
            [[ -z "$port" ]] && continue
            verbose "  Checking port ${port}"
            if ssh_dst "ss -tlnp 2>/dev/null | grep -q ':${port} '"; then
                ok "Port ${port}: listening"
            else
                warn "Port ${port}: not yet listening"
                all_ok=false
            fi
        done <<< "$exposed_ports"
    else
        info "No published ports detected"
    fi

    section "Log Error Scan"
    local services
    services=$(ssh_dst "cd ${DST_PATH} && docker compose config --services 2>/dev/null" || echo "")
    if [[ -n "$services" ]]; then
        while IFS= read -r svc; do
            [[ -z "$svc" ]] && continue
            verbose "  Scanning logs for: ${svc}"
            local errs
            errs=$(ssh_dst "cd ${DST_PATH} && \
                docker compose logs --tail=30 ${svc} 2>/dev/null | \
                grep -i -E '(error|fatal|panic|exception)' | tail -3" || echo "")
            if [[ -n "$errs" ]]; then
                warn "Errors in ${svc}:"
                while read -r line; do
                    echo -e "    ${RED}${line}${RESET}"
                done <<< "$errs"
            else
                ok "${svc}: no errors in last 30 log lines"
            fi
        done <<< "$services"
    fi

    echo ""
    if $all_ok; then
        echo -e "${GREEN}${BOLD}  ✓ Verification passed — stack is healthy${RESET}"
    else
        echo -e "${YELLOW}${BOLD}  ⚠ Verification completed with warnings — review above${RESET}"
    fi
    echo ""
}

# =============================================================================
# MIGRATION
# =============================================================================
do_migration() {
    header "Stack Migration"
    $DRY_RUN && warn "DRY-RUN mode — no changes will be made.\n"

    # ── Re-evaluate volume list fresh at migration time ───────────────────────
    # VOLUME_LIST may be stale if stack was changed since last pre-flight
    if [[ -n "$COMPOSE_FILE" ]]; then
        verbose "Re-evaluating volume list from compose file"
        VOLUME_LIST=$(ssh_src "sudo docker compose -f ${COMPOSE_FILE} config --volumes 2>/dev/null" || echo "")
    fi

    local migrate_vols
    migrate_vols=$(get_effective_volumes)

    # Show migration plan
    section "Migration Plan"
    if [[ -n "$SELECTED_SERVICES" ]]; then
        echo -e "  ${YELLOW}Partial migration${RESET}"
        echo -e "  ${BOLD}Services :${RESET} ${SELECTED_SERVICES}"
    else
        echo -e "  ${CYAN}Full stack migration${RESET}"
        echo -e "  ${BOLD}Services :${RESET} $(echo "$SERVICE_LIST" | tr '\n' ' ')"
    fi
    if [[ -n "$migrate_vols" ]]; then
        echo -e "  ${BOLD}Volumes  :${RESET}"
        while IFS= read -r vol; do
            [[ -z "$vol" ]] && continue
            local vsz
            vsz=$(ssh_src "du -sh /var/lib/docker/volumes/${STACK_NAME}_${vol}/_data \
                2>/dev/null | awk '{print \$1}'" || echo "?")
            echo -e "    ${GREEN}•${RESET} ${STACK_NAME}_${vol}  ${DIM}(${vsz})${RESET}"
        done <<< "$migrate_vols"
    else
        echo -e "  ${BOLD}Volumes  :${RESET} ${DIM}none (bind mounts only)${RESET}"
    fi
    echo ""

    confirm "Proceed with this migration plan?" || { info "Returning to menu."; return; }

    local step=0
    local total_steps=8
    step_header() { ((step++)); section "Step ${step}/${total_steps} — $*"; }

    # ── Step 1: Pre-migration backup ──────────────────────────────────────────
    step_header "Pre-migration backup"
    # Auto-skip backup prompt if there's nothing substantial to back up
    local _has_backup_data=false
    [[ -n "$migrate_vols" ]] && _has_backup_data=true
    if ! $_has_backup_data; then
        local _extra
        _extra=$(ssh_src             "sudo find '${SRC_PATH}' -maxdepth 2              -not -name '*.yml' -not -name '*.yaml'              -not -name '*.env' -not -type d 2>/dev/null | head -1"             2>/dev/null | tr -d '[:space:]')
        [[ -n "$_extra" ]] && _has_backup_data=true
    fi
    if ! $_has_backup_data; then
        info "Nothing substantial to back up — skipping backup."
    elif confirm "Create a local backup before migrating? (recommended)"; then
        do_backup "${SELECTED_SERVICES:-}"
    else
        warn "Skipping backup — proceeding without safety net."
    fi

    # ── Step 2: Analyse and stop/pause source as needed ─────────────────────────
    step_header "Stop source stack"

    # Determine stop strategy:
    #   full_stop — named volumes with active writes (DB/SQLite)
    #   pause     — writable bind mounts inside project path
    #   none      — only read-only or outside-project mounts
    local _stop_strategy="none"
    local _stop_reason=""
    local _PAUSED_IDS=""

    if [[ -n "$migrate_vols" ]]; then
        _stop_strategy="full_stop"
        _stop_reason="named volumes with active data"
    else
        local _rw_inside
        _rw_inside=$(ssh_src             "sudo docker compose -f ${COMPOSE_FILE} config 2>/dev/null             | awk '/type: bind/{f=1} f && /source:/{print \$2; f=0}'             | grep '^${SRC_PATH}'" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$_rw_inside" ]]; then
            _stop_strategy="pause"
            _stop_reason="writable config bind mounts inside project"
        else
            _stop_strategy="none"
            _stop_reason="only read-only or outside-project mounts"
        fi
    fi

    info "Stop strategy: ${_stop_strategy} — ${_stop_reason}"

    # Helper — find running container ID for a service
    _find_cid() {
        local _svc="$1"
        # Try 4 naming patterns in order — each is a separate ssh call
        # to keep the quoting simple and reliable
        local _cid

        # Pattern 1: exact service name (docker run with --name)
        _cid=$(ssh_src "sudo docker ps -q --filter name=^${_svc}\$ 2>/dev/null | head -1" \
            2>/dev/null | tr -d '[:space:]' | head -1)
        [[ -n "$_cid" ]] && echo "$_cid" && return

        # Pattern 2: compose default naming (STACK-SERVICE-1)
        _cid=$(ssh_src "sudo docker ps -q --filter name=^${STACK_NAME}-${_svc}-1\$ 2>/dev/null | head -1" \
            2>/dev/null | tr -d '[:space:]' | head -1)
        [[ -n "$_cid" ]] && echo "$_cid" && return

        # Pattern 3: container_name from compose config — separate query
        local _cname
        _cname=$(ssh_src "sudo docker compose -f ${COMPOSE_FILE} config 2>/dev/null | grep container_name | head -1 | awk '{print \$2}'" \
            2>/dev/null | tr -d '[:space:]')
        if [[ -n "$_cname" ]]; then
            _cid=$(ssh_src "sudo docker ps -q --filter name=^${_cname}\$ 2>/dev/null | head -1" \
                2>/dev/null | tr -d '[:space:]' | head -1)
            [[ -n "$_cid" ]] && echo "$_cid" && return
        fi

        # Pattern 4: partial name match as last resort
        _cid=$(ssh_src "sudo docker ps -q --filter name=${_svc} 2>/dev/null | head -1" \
            2>/dev/null | tr -d '[:space:]' | head -1)
        echo "$_cid"
    }

    case "$_stop_strategy" in
        full_stop)
            confirm "Full stop required (${_stop_reason}) — proceed?"                 || { info "Aborted."; return; }
            if ! $DRY_RUN; then
                # Detect database containers in the stack — need extra care
                local _db_containers
                _db_containers=$(ssh_src                     "sudo docker compose -f ${COMPOSE_FILE} config 2>/dev/null                     | grep -iE 'image:.*(postgres|mysql|mariadb|mongo|redis)'                     | awk '{print \$2}'" 2>/dev/null | tr -d '[:space:]')

                if [[ -n "$_db_containers" ]]; then
                    info "Database containers detected — using extended shutdown timeout"
                    info "  ${_db_containers}"

                    # Increase shutdown timeout from default 10s to 60s for clean DB shutdown
                    # Postgres needs to finish active transactions, checkpoint, flush WAL
                    info "Stopping stack with 60s graceful shutdown timeout..."
                    local _down_out
                    _down_out=$(ssh_src \
                        "sudo docker compose -f ${COMPOSE_FILE} down -t 60 2>&1" \
                        || echo "")
                    echo "$_down_out"

                    # Verify database containers exited cleanly (exit code 0)
                    # A non-zero exit means SIGKILL after timeout — data may be dirty
                    if echo "$_db_containers" | grep -qi postgres; then
                        local _pg_exit
                        _pg_exit=$(ssh_src \
                            "sudo docker ps -a --filter label=com.docker.compose.project=${STACK_NAME} \
                            --filter status=exited \
                            --format '{{.Names}}:{{.Status}}' 2>/dev/null \
                            | grep -i 'database\|postgres'" \
                            2>/dev/null || echo "")
                        if echo "$_pg_exit" | grep -qiE 'Exited \(0\)'; then
                            ok "Postgres exited cleanly (code 0) — safe to transfer"
                        elif [[ -n "$_pg_exit" ]]; then
                            warn "Postgres exit status: ${_pg_exit}"
                            warn "Non-zero exit may indicate dirty shutdown — WAL may be incomplete"
                            confirm "Continue anyway? (risky — consider pg_dump first)" \
                                || { info "Aborted. Create a pg_dump backup, then retry."; return; }
                        else
                            warn "Could not verify Postgres exit status — proceeding with caution"
                        fi
                    fi
                else
                    local _down_out
                    _down_out=$(ssh_src                         "sudo docker compose -f ${COMPOSE_FILE} down 2>&1" || echo "")
                    echo "$_down_out"
                fi
                if ! echo "$_down_out" | grep -qiE "stopped|removed|down"; then
                    # Fallback to docker stop/rm by name
                    while IFS= read -r svc; do
                        [[ -z "$svc" ]] && continue
                        local _cid
                        _cid=$(_find_cid "$svc")
                        if [[ -n "$_cid" ]]; then
                            info "  Stopping: ${svc} (${_cid})"
                            ssh_src "sudo docker stop ${_cid} > /dev/null && sudo docker rm ${_cid} > /dev/null"                                 2>/dev/null || true
                        fi
                    done <<< "$(echo "${SELECTED_SERVICES:-$SERVICE_LIST}" | tr ' ' '
')"
                fi
            else
                echo -e "${YELLOW}[DRY-RUN]${RESET} docker compose down on source"
            fi
            # Verify containers are actually stopped
            if ! $DRY_RUN; then
                local _still_running
                # Build grep pattern from services — handle both space-separated
                # (SELECTED_SERVICES) and newline-separated (SERVICE_LIST) inputs
                local _svc_pattern
                _svc_pattern=$(echo "${SELECTED_SERVICES:-$SERVICE_LIST}" \
                    | tr ' \n' '|' | sed 's/^|//;s/|$//')
                _still_running=$(ssh_src \
                    "sudo docker ps --format '{{.Names}}' 2>/dev/null \
                    | grep -E '${_svc_pattern}'" \
                    2>/dev/null | tr -d '[:space:]')
                if [[ -n "$_still_running" ]]; then
                    warn "Some containers still running after stop — forcing:"
                    ssh_src "sudo docker ps -q --filter name=${STACK_NAME}                         | xargs -r sudo docker stop > /dev/null" 2>/dev/null || true
                fi
            fi
            ok "Source fully stopped."
            ;;

        pause)
            confirm "Pause source containers during transfer? (${_stop_reason})"                 || { info "Aborted."; return; }
            if ! $DRY_RUN; then
                while IFS= read -r svc; do
                    [[ -z "$svc" ]] && continue
                    local _cid
                    _cid=$(_find_cid "$svc")
                    if [[ -n "$_cid" ]]; then
                        info "  Pausing: ${svc} (${_cid})"
                        ssh_src "sudo docker pause ${_cid} > /dev/null" 2>/dev/null || true
                        _PAUSED_IDS="${_PAUSED_IDS} ${_cid}"
                    fi
                done <<< "$(echo "${SELECTED_SERVICES:-$SERVICE_LIST}" | tr ' ' '
')"
                ok "Source paused — will unpause after transfer."
                info "Note: container shows as 'running' in Portainer/docker ps — paused containers are frozen but still registered."
            else
                echo -e "${YELLOW}[DRY-RUN]${RESET} docker pause on source containers"
            fi
            ;;

        none)
            info "No interruption needed — proceeding without stopping source."
            ;;
    esac


    # ── Step 3: Prepare destination ───────────────────────────────────────────
    step_header "Prepare destination"
    run "ssh_dst 'mkdir -p ${DST_PATH}'"
    ok "Destination path ready."

    # ── Step 4: Transfer compose project ──────────────────────────────────────
    step_header "Transfer compose project"
    local _src_login="${SRC_LOGIN:-$SRC_USER}"
    local _dst_login="${DST_LOGIN:-$DST_USER}"

    # SSH options for data transfers — NEVER use the mux socket for transfers.
    # The mux socket is shared; saturating it during tar/rsync causes keepalive
    # packets to be delayed, which drops ALL connections using that socket
    # including interactive terminal sessions.
    # Data transfers always use a fresh dedicated connection with keepalives.
    local _xfer_ssh_opts
    _xfer_ssh_opts="-o ControlMaster=no         -o ConnectTimeout=30         -o ServerAliveInterval=15         -o ServerAliveCountMax=20         -o StrictHostKeyChecking=accept-new         -o BatchMode=yes"

    if ! $DRY_RUN; then
        local _tmp_compose
        _tmp_compose=$(mktemp -d)
        # Ensure temp dir is always cleaned up
        trap "rm -rf '${_tmp_compose}' 2>/dev/null || true" RETURN

        info "  Pulling compose files from source..."
        # Always use sudo tar — rsync runs as the login user (khaverblad) and
        # cannot read files owned by PUID (e.g. 977:unifi-nfs). sudo tar reads
        # everything regardless of ownership.
        # shellcheck disable=SC2086
        ssh -i "$SRC_KEY" -p "$SRC_PORT" ${_xfer_ssh_opts}             "${_src_login}@${SRC_HOST}"             "sudo tar czf - -C ${SRC_PATH} ."             | tar xzf - -C "${_tmp_compose}/"
        if [[ ${PIPESTATUS[0]} -ne 0 || ${PIPESTATUS[1]} -ne 0 ]]; then
            error "Failed to pull compose files from source — check permissions on ${SRC_PATH}"
            return 1
        fi

        info "  Creating destination directory..."
        # Use mux socket for control commands (fast, no data)
        ssh_dst "sudo mkdir -p ${DST_PATH} && sudo chmod 755 ${DST_PATH}"

        info "  Pushing compose files to destination..."
        # Fresh dedicated connection — never mux for data transfers
        # COPYFILE_DISABLE=1 prevents macOS bsdtar from embedding Apple
        # extended attributes (LIBARCHIVE.xattr.com.apple.provenance) that
        # cause noisy warnings when GNU tar on Linux extracts them.
        # shellcheck disable=SC2086
        COPYFILE_DISABLE=1 tar czf - -C "${_tmp_compose}" . 2>/dev/null \
            | ssh -i "$DST_KEY" -p "$DST_PORT" ${_xfer_ssh_opts} \
                  "${_dst_login}@${DST_HOST}" \
                  "sudo tar xzf - -C ${DST_PATH} 2>/dev/null" &
        local _push_pid=$!
        progress_dots $_push_pid "Transferring"
        wait $_push_pid
        if [[ $? -ne 0 ]]; then
            error "Transfer to destination failed"
            return 1
        fi

        # Temp dir cleaned up by trap on RETURN

        # Unpause source containers if they were paused (not full-stopped)
        if [[ -n "$_PAUSED_IDS" ]]; then
            info "  Unpausing source containers..."
            for _pid in $_PAUSED_IDS; do
                ssh_src "sudo docker unpause ${_pid} > /dev/null" 2>/dev/null || true
            done
            ok "Source unpaused."
        fi

        # Fix ownership after transfer:
        # 1. Compose/env files → root:root (Docker reads these as root)
        # 2. Config data directory → PUID:PGID from compose file
        #    (linuxserver containers require this — if wrong, they throw
        #     "Access to path denied" on startup)
        verbose "Fixing ownership of transferred files"

        # Step 1: compose files to root:root
        ssh_dst "sudo find ${DST_PATH} -maxdepth 1             \( -name '*.yml' -o -name '*.yaml' -o -name '*.env' \)             | xargs -r sudo chown root:root" 2>/dev/null || true

        # Step 2: detect PUID/PGID from compose file and chown config data
        local _puid _pgid
        _puid=$(ssh_src             "sudo docker compose -f ${COMPOSE_FILE} config 2>/dev/null             | grep -oP 'PUID=\K[0-9]+' | head -1"             2>/dev/null | tr -d '[:space:]')
        _pgid=$(ssh_src             "sudo docker compose -f ${COMPOSE_FILE} config 2>/dev/null             | grep -oP 'PGID=\K[0-9]+' | head -1"             2>/dev/null | tr -d '[:space:]')

        if [[ -n "$_puid" && -n "$_pgid" ]]; then
            verbose "Setting config ownership to ${_puid}:${_pgid} (PUID:PGID from compose)"
            ssh_dst "sudo chown -R ${_puid}:${_pgid} ${DST_PATH}" 2>/dev/null || true
            # Re-apply root:root to compose files on top
            ssh_dst "sudo find ${DST_PATH} -maxdepth 1                 \( -name '*.yml' -o -name '*.yaml' -o -name '*.env' \)                 | xargs -r sudo chown root:root" 2>/dev/null || true
            info "Ownership set: ${DST_PATH} → ${_puid}:${_pgid} (data), root:root (compose files)"
        else
            verbose "No PUID/PGID in compose — leaving ownership as transferred"
        fi
    else
        echo -e "${YELLOW}[DRY-RUN]${RESET} tar: ${SRC_HOST}:${SRC_PATH}/ → local → ${DST_HOST}:${DST_PATH}/"
    fi
    ok "Compose project transferred."

    # ── Step 5: Migrate volumes ───────────────────────────────────────────────
    step_header "Migrate volumes"
    if [[ -z "$migrate_vols" ]]; then
        warn "No named volumes to migrate — skipping."
    else
        # Get actual docker volume names from source (avoids prefix guessing)
        local actual_vols
        actual_vols=$(ssh_src "sudo docker volume ls --format '{{.Name}}'" 2>/dev/null || echo "")

        # Show what we're about to migrate up front
        local _vol_count
        _vol_count=$(echo "$migrate_vols" | grep -cv '^$' || echo 0)
        info "Migrating ${_vol_count} volume(s):"
        while IFS= read -r v; do
            [[ -z "$v" ]] && continue
            info "    • ${STACK_NAME}_${v}"
        done <<< "$migrate_vols"
        echo ""

        while IFS= read -r vol; do
            [[ -z "$vol" ]] && continue
            # Try STACK_NAME_vol first, then bare vol name, then match from actual list
            local full_vol="${STACK_NAME}_${vol}"
            if ! echo "$actual_vols" | grep -qx "$full_vol"; then
                # Try exact match (volume already has stack prefix in compose)
                if echo "$actual_vols" | grep -qx "$vol"; then
                    full_vol="$vol"
                else
                    # Fuzzy match — find any volume ending with the vol name
                    local matched
                    matched=$(echo "$actual_vols" | grep -E "_${vol}$|^${vol}$" | head -1)
                    [[ -n "$matched" ]] && full_vol="$matched"
                fi
            fi
            local src_vol="/var/lib/docker/volumes/${full_vol}/_data"
            local dst_vol="/var/lib/docker/volumes/${full_vol}/_data"

            info "  Migrating: ${full_vol}"
            verbose "    ${SRC_HOST}:${src_vol} → ${DST_HOST}:${dst_vol}"

            # Register volume with Docker properly (creates metadata + _data dir)
            # Using docker volume create ensures Docker owns the volume —
            # bare mkdir only creates the directory without registering it,
            # which can fail on fuse-overlayfs and other non-default drivers.
            if ! $DRY_RUN; then
                ssh_dst "sudo docker volume create ${full_vol} > /dev/null 2>&1 || true"
            else
                echo -e "${YELLOW}[DRY-RUN]${RESET}  docker volume create ${full_vol}"
            fi

            if ! $DRY_RUN; then
                local _src_login_vol="${SRC_LOGIN:-$SRC_USER}"
                local _dst_login_vol="${DST_LOGIN:-$DST_USER}"

                # Build source tar command — wrap in sudo if login differs from effective
                local _src_tar_cmd="tar czf - -C ${src_vol} ."
                if [[ -n "$SRC_LOGIN" && "$SRC_LOGIN" != "$SRC_USER" ]]; then
                    _src_tar_cmd="sudo tar czf - -C ${src_vol} ."
                fi

                local _dst_tar_cmd="tar xzf - -C ${dst_vol}"
                # If using sudo, wrap tar in sudo so it can write to /var/lib/docker
                if [[ -n "$DST_LOGIN" && "$DST_LOGIN" != "$DST_USER" ]]; then
                    _dst_tar_cmd="sudo tar xzf - -C ${dst_vol}"
                fi
                # Dedicated connections for volume transfer — NEVER use mux socket.
                # Saturating the shared mux connection during large tar streams
                # delays keepalive packets and drops ALL multiplexed sessions.
                # Both source and destination use fresh direct SSH connections.
                # Source side uses -n (no stdin) to prevent consuming the
                # while-read loop's input. Destination side must NOT use -n
                # because it reads tar data from the pipe on stdin.
                ssh -n -i "$SRC_KEY" -p "$SRC_PORT" \
                    -o ControlMaster=no \
                    -o ConnectTimeout=60 \
                    -o ServerAliveInterval=15 \
                    -o ServerAliveCountMax=40 \
                    -o StrictHostKeyChecking=accept-new \
                    -o BatchMode=yes \
                    "${_src_login_vol}@${SRC_HOST}" \
                    "${_src_tar_cmd}" \
                    | ssh -i "$DST_KEY" -p "$DST_PORT" \
                          -o ControlMaster=no \
                          -o ConnectTimeout=60 \
                          -o ServerAliveInterval=15 \
                          -o ServerAliveCountMax=40 \
                          -o StrictHostKeyChecking=accept-new \
                          -o BatchMode=yes \
                          "${_dst_login_vol}@${DST_HOST}" \
                          "${_dst_tar_cmd}"
                local _vol_pipe_status=("${PIPESTATUS[@]}")
                if [[ "${_vol_pipe_status[0]}" -ne 0 ]]; then
                    error "  Volume tar from source failed (exit ${_vol_pipe_status[0]}): ${full_vol}"
                    warn "  Check source connectivity and permissions on ${src_vol}"
                elif [[ "${_vol_pipe_status[1]}" -ne 0 ]]; then
                    error "  Volume tar to destination failed (exit ${_vol_pipe_status[1]}): ${full_vol}"
                    warn "  Check destination connectivity and permissions on ${dst_vol}"
                fi
                # Verify transfer
                local src_count dst_count
                src_count=$(ssh_src "find ${src_vol} -maxdepth 1 | wc -l" || echo 0)
                dst_count=$(ssh_dst "find ${dst_vol} -maxdepth 1 | wc -l" || echo 0)
                verbose "    entries: src=${src_count} dst=${dst_count}"
                if [[ "$dst_count" -ge "$src_count" ]]; then
                    ok "  Migrated: ${full_vol} (${dst_count} entries)"
                else
                    warn "  ${full_vol}: entry count mismatch (src=${src_count} dst=${dst_count}) — verify manually"
                fi
            else
                echo -e "${YELLOW}[DRY-RUN]${RESET}  tar pipe: ${src_vol} → ${DST_HOST}:${dst_vol}"
            fi
        done <<< "$migrate_vols"
    fi

    # ── Step 6: Pull images on destination ────────────────────────────────────
    step_header "Pull images on destination"
    local _dst_login_run="${DST_LOGIN:-$DST_USER}"
    # Pull via nohup+background so SSH disconnection doesn't kill the pull.
    # Image pulls can take 60-120s for large images — longer than IDS tolerates
    # for a persistent SSH connection. Fire and forget, then poll docker images.
    if ! $DRY_RUN; then
        local _pull_cmd _pull_svcs=""
        [[ -n "$SELECTED_SERVICES" ]] && _pull_svcs="$SELECTED_SERVICES"
        _pull_cmd="sudo sh -c 'cd ${DST_PATH} && nohup docker compose pull ${_pull_svcs} > /tmp/docker-migrate-pull.log 2>&1 &'"

        verbose "Firing background pull: ${_pull_cmd}"
        ssh_dst "${_pull_cmd}" 2>/dev/null || true

        # Poll until images are present (max 300s for large images)
        info "  Pulling images in background..."
        local _p_elapsed=0
        local _img_done=false
        while [[ $_p_elapsed -lt 300 ]]; do
            sleep 5
            _p_elapsed=$((_p_elapsed + 5))
            # Check if pull log exists and pull has finished (no longer running)
            local _pull_running
            _pull_running=$(ssh_dst                 "pgrep -f 'docker compose pull' 2>/dev/null | wc -l"                 2>/dev/null | tr -d '[:space:]' || echo "0")
            verbose "  ${_p_elapsed}s: pull processes=${_pull_running}"
            if [[ "${_pull_running:-1}" == "0" && $_p_elapsed -gt 10 ]]; then
                _img_done=true
                break
            fi
            echo -n "."
        done
        echo ""
        # Verify image actually exists on destination regardless of pgrep result
        local _img_name
        _img_name=$(ssh_src "sudo docker compose -f ${COMPOSE_FILE} config             | grep 'image:' | head -1 | awk '{print \$2}'" 2>/dev/null | tr -d '[:space:]')
        local _img_exists="no"
        if [[ -n "$_img_name" ]]; then
            _img_exists=$(ssh_dst                 "sudo docker image inspect '${_img_name}' > /dev/null 2>&1 && echo yes || echo no"                 2>/dev/null | tr -d '[:space:]')
        fi
        if [[ "$_img_exists" == "yes" ]]; then
            ok "Images pulled and verified on destination."
        elif $_img_done; then
            ok "Images pulled."
        else
            warn "Pull may still be in progress — check: ssh ${_dst_login_run}@${DST_HOST} 'cat /tmp/docker-migrate-pull.log'"
            ok "Continuing (pull runs in background on destination)."
        fi
    else
        echo -e "${YELLOW}[DRY-RUN]${RESET} docker compose pull on ${DST_HOST}:${DST_PATH}"
        ok "Images pulled."
    fi

    # ── Step 7: Start on destination ──────────────────────────────────────────
    step_header "Start stack on destination"
    if ! $DRY_RUN; then
        # Run docker compose up via nohup — fire and forget, poll for result
        local _up_cmd _up_svcs=""
        [[ -n "$SELECTED_SERVICES" ]] && _up_svcs="$SELECTED_SERVICES"
        # Use fixed log name — avoid $$ which expands locally before SSH transmission
        _up_cmd="sudo sh -c 'cd ${DST_PATH} && nohup docker compose up -d ${_up_svcs} > /tmp/docker-migrate-up.log 2>&1 &'"

        verbose "Running: ${_up_cmd}"
        ssh_dst "${_up_cmd}" 2>/dev/null || true

        # Poll until containers are running or timeout (120s)
        info "  Waiting for containers to start..."
        sleep 10  # initial wait — nohup needs time to launch compose
        local _elapsed=0
        local _expected_svcs
        if [[ -n "$SELECTED_SERVICES" ]]; then
            _expected_svcs=$(echo "$SELECTED_SERVICES" | wc -w | tr -d '[:space:]')
        else
            _expected_svcs=$(echo "$SERVICE_LIST" | grep -c . | tr -d '[:space:]' || echo 1)
        fi
        # Ensure numeric
        _expected_svcs=$(( ${_expected_svcs:-1} + 0 )) 2>/dev/null || _expected_svcs=1

        while [[ $_elapsed -lt 120 ]]; do
            sleep 5
            _elapsed=$((_elapsed + 5))
            local _running
            # Find compose file on destination and check running state
            # Count running containers by project name via docker ps
            # Avoids compose ps format issues and sudo wrapper noise
            _running=$(ssh_dst                 "sudo docker ps --filter label=com.docker.compose.project=${STACK_NAME}                     --filter status=running --format '{{.Names}}' 2>/dev/null | wc -l"                 2>/dev/null | tr -d '[:space:]' | grep -oE '^[0-9]+' || echo 0)
            _running=$(( 10#${_running:-0} )) 2>/dev/null || _running=0
            verbose "  ${_elapsed}s: ${_running}/${_expected_svcs} containers running"
            if [[ $_running -ge $_expected_svcs ]]; then
                ok "  All containers running (${_running}/${_expected_svcs})"
                break
            fi
            echo -n "."
        done
        echo ""

        if [[ $_elapsed -ge 120 ]]; then
            warn "Timeout waiting for containers — check manually:"
            warn "  ssh ${_dst_login_run}@${DST_HOST} 'cat /tmp/docker-migrate-up.log'"
        fi
    else
        echo -e "${YELLOW}[DRY-RUN]${RESET} docker compose up -d on ${DST_HOST}:${DST_PATH}"
    fi
    ok "Stack started."

    # ── Step 8: Initial health check ──────────────────────────────────────────
    step_header "Initial health check"
    if ! $DRY_RUN; then
        info "Waiting 15s for containers to initialise..."
        sleep 15
        run_verification
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    # Clean up temp logs on destination
    ssh_dst "sudo rm -f /tmp/docker-migrate-pull.log /tmp/docker-migrate-up.log" 2>/dev/null || true

    header "Migration Complete"
    echo -e "  ${BOLD}Stack      :${RESET} ${STACK_NAME}"
    [[ -n "$SELECTED_SERVICES" ]] && \
        echo -e "  ${BOLD}Services   :${RESET} ${YELLOW}${SELECTED_SERVICES}${RESET}"
    echo -e "  ${BOLD}Source     :${RESET} ${SRC_LOGIN:-$SRC_USER}@${SRC_HOST}:${SRC_PATH} ${DIM}(stopped)${RESET}"
    echo -e "  ${BOLD}Destination:${RESET} ${DST_LOGIN:-$DST_USER}@${DST_HOST}:${DST_PATH} ${GREEN}(running)${RESET}"
    echo -e "  ${BOLD}Log file   :${RESET} ${LOGFILE}"
    echo ""
    echo -e "  ${BOLD}Useful commands:${RESET}"
    local _dst_ssh="${DST_LOGIN:-$DST_USER}@${DST_HOST}"
    local _sp=""
    [[ -n "${DST_LOGIN:-}" ]] && _sp="sudo "
    local _dp="${DST_PATH}"
    echo "    Logs   : ssh ${_dst_ssh} \"${_sp}sh -c 'cd ${_dp} && docker compose logs -f'\""
    echo "    Status : ssh ${_dst_ssh} \"${_sp}sh -c 'cd ${_dp} && docker compose ps'\""
    echo "    Restart: ssh ${_dst_ssh} \"${_sp}sh -c 'cd ${_dp} && docker compose restart'\""
    echo ""
    # ── Source restart prompt ──────────────────────────────────────────────
    echo ""
    if $DECOMMISSION_MODE; then
        echo -e "  ${YELLOW}Note:${RESET} Source is stopped and will NOT be restarted (decommission mode)."
        echo -e "  ${YELLOW}Note:${RESET} Verify destination thoroughly before shutting down source server."
    else
        echo -e "  ${YELLOW}Note:${RESET} Source is stopped."
        if confirm "Restart source container for parallel running period?"; then
            local _src_login="${SRC_LOGIN:-$SRC_USER}"
            ssh -i "$SRC_KEY" -p "$SRC_PORT"                 -o ConnectTimeout=10 -o BatchMode=yes                 -o StrictHostKeyChecking=accept-new                 "${_src_login}@${SRC_HOST}"                 "sudo docker compose -f ${COMPOSE_FILE} up -d" 2>/dev/null                 && ok "Source restarted for parallel running."                 || warn "Could not restart source — start manually if needed."
        fi
        echo -e "  ${YELLOW}Note:${RESET} Keep source running 24-48h before decommissioning."
    fi
    echo ""
}

# =============================================================================
# ACCESS VERIFICATION
# Tests every layer of the access chain for both hosts with fix instructions
# =============================================================================
verify_access() {
    header "Access Verification"

    if [[ -z "$SRC_HOST" || -z "$DST_HOST" ]]; then
        warn "Hosts not configured — run option 1 first."
        return 1
    fi

    local src_login="${SRC_LOGIN:-$SRC_USER}"
    local dst_login="${DST_LOGIN:-$DST_USER}"
    local all_ok=true

    # ── Test a single host ────────────────────────────────────────────────────
    _test_host_access() {
        local label="$1" host="$2" port="$3" login="$4"               effective="$5" key="$6"

        section "${label} (${login}@${host}:${port})"

        # Layer 1: SSH key exists locally
        if [[ -f "$key" ]]; then
            ok "  [1] SSH key exists: ${key}"
        else
            error "  [1] SSH key missing: ${key}"
            echo -e "      ${DIM}Fix: ssh-keygen -t ed25519 -f ${key} -C docker-migrate${RESET}"
            all_ok=false
            return
        fi

        # Layer 2: Key permissions
        local perms
        perms=$(stat -f "%OLp" "$key" 2>/dev/null || stat -c "%a" "$key" 2>/dev/null || echo "unknown")
        if [[ "$perms" == "600" || "$perms" == "400" ]]; then
            ok "  [2] Key permissions: ${perms}"
        else
            error "  [2] Key permissions: ${perms} (must be 600)"
            echo -e "      ${DIM}Fix: chmod 600 ${key}${RESET}"
            all_ok=false
        fi

        # Layer 3: TCP reachability
        if ssh -i "$key" -p "$port"                -o ConnectTimeout=5 -o BatchMode=yes                -o StrictHostKeyChecking=accept-new                "${login}@${host}" "exit" 2>/dev/null; then
            ok "  [3] SSH TCP connection: OK"
        else
            error "  [3] SSH TCP connection: FAILED"
            echo -e "      ${DIM}Possible causes:${RESET}"
            echo -e "      ${DIM}  - Host unreachable (check network/firewall)${RESET}"
            echo -e "      ${DIM}  - SSH key not in authorized_keys${RESET}"
            echo -e "      ${DIM}  - Wrong port (current: ${port})${RESET}"
            echo -e "      ${DIM}Fix: ssh-copy-id -i ${key}.pub -p ${port} ${login}@${host}${RESET}"
            all_ok=false
            return
        fi

        # Layer 4: Key-based auth (no password)
        local auth_test
        auth_test=$(ssh -i "$key" -p "$port"             -o ConnectTimeout=5 -o BatchMode=yes             -o PasswordAuthentication=no             -o StrictHostKeyChecking=accept-new             "${login}@${host}" "echo key_auth_ok" 2>/dev/null | tr -d '[:space:]')
        if [[ "$auth_test" == "key_auth_ok" ]]; then
            ok "  [4] Key-based auth: working (no password required)"
        else
            error "  [4] Key-based auth: FAILED (password still required)"
            echo -e "      ${DIM}Fix: ssh-copy-id -i ${key}.pub -p ${port} ${login}@${host}${RESET}"
            echo -e "      ${DIM}Then verify: ssh -i ${key} ${login}@${host} echo ok${RESET}"
            all_ok=false
            return
        fi

        # Layer 5: sudo without password (only if login != effective)
        if [[ "$login" != "$effective" ]]; then
            local sudo_test
            sudo_test=$(ssh -i "$key" -p "$port"                 -o ConnectTimeout=5 -o BatchMode=yes                 -o StrictHostKeyChecking=accept-new                 "${login}@${host}"                 "sudo -n echo sudo_ok" 2>/dev/null | tr -d '[:space:]')
            if [[ "$sudo_test" == "sudo_ok" ]]; then
                ok "  [5] Passwordless sudo: working (${login} → ${effective})"
            else
                error "  [5] Passwordless sudo: FAILED"
                echo -e "      ${DIM}Fix: SSH into ${host} as ${login} and run:${RESET}"
                echo -e "      ${DIM}  echo '${login} ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/${login}${RESET}"
                echo -e "      ${DIM}  sudo chmod 440 /etc/sudoers.d/${login}${RESET}"
                all_ok=false
                return
            fi

            # Layer 6: sudo can run docker
            local docker_test
            docker_test=$(ssh -i "$key" -p "$port"                 -o ConnectTimeout=5 -o BatchMode=yes                 -o StrictHostKeyChecking=accept-new                 "${login}@${host}"                 "sudo docker info --format '{{.ServerVersion}}'" 2>/dev/null | tr -d '[:space:]')
            if [[ -n "$docker_test" && "$docker_test" =~ ^[0-9] ]]; then
                ok "  [6] sudo docker: working (v${docker_test})"
            else
                error "  [6] sudo docker: FAILED"
                echo -e "      ${DIM}Possible causes:${RESET}"
                echo -e "      ${DIM}  - Docker not installed or not running${RESET}"
                echo -e "      ${DIM}  - sudo PATH doesn't include docker binary${RESET}"
                echo -e "      ${DIM}Fix: sudo systemctl start docker${RESET}"
                echo -e "      ${DIM}     sudo usermod -aG docker ${login}${RESET}"
                all_ok=false
            fi
        else
            # Direct root login — test docker directly
            local docker_test
            docker_test=$(ssh -i "$key" -p "$port"                 -o ConnectTimeout=5 -o BatchMode=yes                 -o StrictHostKeyChecking=accept-new                 "${login}@${host}"                 "docker info --format '{{.ServerVersion}}'" 2>/dev/null | tr -d '[:space:]')
            if [[ -n "$docker_test" && "$docker_test" =~ ^[0-9] ]]; then
                ok "  [5] Docker access: working (v${docker_test})"
            else
                error "  [5] Docker access: FAILED"
                echo -e "      ${DIM}Fix: systemctl start docker${RESET}"
                all_ok=false
            fi
        fi

        # Layer 7: can write to base path
        local write_test
        write_test=$(ssh -i "$key" -p "$port"             -o ConnectTimeout=5 -o BatchMode=yes             -o StrictHostKeyChecking=accept-new             "${login}@${host}"             "sudo test -w ${SRC_BASE} && echo writable || echo readonly"             2>/dev/null | tr -d '[:space:]')
        if [[ "$write_test" == "writable" ]]; then
            ok "  [7] Base path writable: ${SRC_BASE}"
        else
            warn "  [7] Base path not writable: ${SRC_BASE}"
            echo -e "      ${DIM}Fix: sudo mkdir -p ${SRC_BASE} && sudo chmod 755 ${SRC_BASE}${RESET}"
        fi

        echo ""
    }

    _test_host_access "Source"         "$SRC_HOST" "$SRC_PORT" "$src_login" "$SRC_USER" "$SRC_KEY"

    _test_host_access "Destination"         "$DST_HOST" "$DST_PORT" "$dst_login" "$DST_USER" "$DST_KEY"

    # ── Summary ───────────────────────────────────────────────────────────────
    echo -e "  ${BOLD}── Access Verification Summary ──────────────────${RESET}"
    if $all_ok; then
        echo -e "  ${GREEN}${BOLD}  ✓ All access checks passed — ready to migrate${RESET}"
    else
        echo -e "  ${RED}${BOLD}  ✗ Access issues found — fix above before migrating${RESET}"
        echo ""
        echo -e "  ${DIM}Quick reference:${RESET}"
        echo -e "  ${DIM}  Deploy key : ssh-copy-id -i ${SRC_KEY}.pub USER@HOST${RESET}"
        echo -e "  ${DIM}  No-pwd sudo: echo 'USER ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/USER${RESET}"
        echo -e "  ${DIM}  Test key   : ssh -i ${SRC_KEY} USER@HOST echo ok${RESET}"
        echo -e "  ${DIM}  Test sudo  : ssh -i ${SRC_KEY} USER@HOST sudo -n echo ok${RESET}"
    fi
    echo ""
}

# =============================================================================
# STANDALONE BACKUP
# =============================================================================
run_backup() {
    header "Backup Stack"

    if [[ -z "$SRC_HOST" || -z "$SRC_PATH" ]]; then
        warn "No stack configured — use option 1 and 2 first."
        return 1
    fi

    info "Stack  : ${STACK_NAME}"
    info "Source : ${SRC_USER}@${SRC_HOST}:${SRC_PATH}"
    echo ""

    # Re-evaluate volumes
    if [[ -n "$COMPOSE_FILE" ]]; then
        VOLUME_LIST=$(ssh_src             "sudo docker compose -f ${COMPOSE_FILE} config --volumes 2>/dev/null"             || echo "")
    fi

    do_backup "${SELECTED_SERVICES:-}"
}

# =============================================================================
# RESTORE
# =============================================================================
run_restore() {
    header "Restore Stack to Destination"

    if [[ -z "$DST_HOST" || -z "$DST_PATH" || -z "$STACK_NAME" ]]; then
        warn "No stack configured — use option 1 and 2 first."
        return 1
    fi

    local backup_dir="$HOME/docker-backups"
    if [[ ! -d "$backup_dir" ]]; then
        warn "No backup directory found at ${backup_dir}"
        read -rp "  Enter backup directory path: " backup_dir
        [[ ! -d "$backup_dir" ]] && { error "Directory not found: ${backup_dir}"; return 1; }
    fi

    # Find backups for this stack, newest first
    section "Available Backups for '${STACK_NAME}'"
    local backups=()
    while IFS= read -r -d '' f; do
        backups+=("$f")
    done < <(find "$backup_dir" -maxdepth 1         -name "${STACK_NAME}-backup-*.tar.gz"         -printf "%T@ %p" 2>/dev/null         | sort -rz -k1         | cut -z -d' ' -f2-)

    if [[ ${#backups[@]} -eq 0 ]]; then
        warn "No backups found for '${STACK_NAME}' in ${backup_dir}"
        info "Backups are named: ${STACK_NAME}-backup-YYYYMMDD-HHMMSS.tar.gz"
        read -rp "  Enter full path to backup file: " manual_path
        [[ ! -f "$manual_path" ]] && { error "File not found: ${manual_path}"; return 1; }
        backups=("$manual_path")
    fi

    echo ""
    local i=1
    for bfile in "${backups[@]}"; do
        local bname bsize bdate
        bname=$(basename "$bfile")
        bsize=$(du -sh "$bfile" 2>/dev/null | awk '{print $1}')
-:        bdate=$(echo "$bname" | grep -oE '[0-9]{8}-[0-9]{6}'             | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)-\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/ :/')
        printf "  ${BOLD}%2d)${RESET} %-45s ${DIM}%6s  %s${RESET}
"             "$i" "$bname" "$bsize" "$bdate"
        ((i++))
    done
    echo ""
    echo -e "  ${BOLD}b)${RESET} Back"
    echo ""
    echo -en "${CYAN}  Select backup to restore: ${RESET}"
    read -r pick

    [[ "$pick" =~ ^[bB]$ ]] && return 0

    local chosen_backup=""
    if [[ "$pick" =~ ^[0-9]+$ ]] &&        [[ "$pick" -ge 1 ]] &&        [[ "$pick" -le "${#backups[@]}" ]]; then
        chosen_backup="${backups[$((pick-1))]}"
    else
        warn "Invalid selection."
        return 1
    fi

    local bname
    bname=$(basename "$chosen_backup")
    local backup_name="${bname%.tar.gz}"

    echo ""
    info "Restoring: ${bname}"
    info "Target   : ${DST_USER}@${DST_HOST}:${DST_PATH}"
    echo ""

    confirm "This will STOP destination containers and overwrite data. Proceed?"         || { info "Aborted."; return 0; }

    section "Step 1/4 — Stop destination containers"
    if ! $DRY_RUN; then
        ssh_dst "sudo sh -c 'cd ${DST_PATH} && docker compose down 2>/dev/null || true'"             2>/dev/null || true
        ok "Destination containers stopped."
    else
        echo -e "${YELLOW}[DRY-RUN]${RESET} docker compose down on destination"
    fi

    section "Step 2/4 — Extract backup locally"
    local _tmp_restore
    _tmp_restore=$(mktemp -d)
    trap "rm -rf '${_tmp_restore}' 2>/dev/null || true" RETURN

    if ! $DRY_RUN; then
        info "Extracting ${bname}..."
        tar xzf "$chosen_backup" -C "$_tmp_restore" &
        local _epid=$!
        progress_dots $_epid "Extracting"
        wait $_epid
        if [[ $? -ne 0 ]]; then
            error "Failed to extract backup"
            return 1
        fi
        ok "Extracted to ${_tmp_restore}/${backup_name}/"
    else
        echo -e "${YELLOW}[DRY-RUN]${RESET} tar xzf ${bname} to temp dir"
    fi

    section "Step 3/4 — Restore compose files"
    local _compose_src="${_tmp_restore}/${backup_name}/compose"
    if ! $DRY_RUN; then
        if [[ -d "$_compose_src" ]]; then
            ssh_dst "sudo mkdir -p ${DST_PATH}"
            tar czf - -C "$_compose_src" .                 | ssh -i "$DST_KEY" -p "$DST_PORT"                       -o ControlMaster=no                       -o ConnectTimeout=30                       -o ServerAliveInterval=15                       -o StrictHostKeyChecking=accept-new                       -o BatchMode=yes                       "${DST_LOGIN:-$DST_USER}@${DST_HOST}"                       "sudo tar xzf - -C ${DST_PATH}" &
            local _rpid=$!
            progress_dots $_rpid "Restoring compose files"
            wait $_rpid
            ok "Compose files restored."
        else
            warn "No compose directory in backup — skipping."
        fi
    else
        echo -e "${YELLOW}[DRY-RUN]${RESET} restore compose files to ${DST_PATH}"
    fi

    section "Step 4/4 — Restore volumes"
    local _vols_src="${_tmp_restore}/${backup_name}/volumes"
    if ! $DRY_RUN; then
        if [[ -d "$_vols_src" ]]; then
            local _vol_count=0
            for vol_dir in "$_vols_src"/*/; do
                [[ -d "$vol_dir" ]] || continue
                local vol_name
                vol_name=$(basename "$vol_dir")
                local dst_vol="/var/lib/docker/volumes/${vol_name}/_data"
                info "  Restoring volume: ${vol_name}"
                ssh_dst "sudo mkdir -p ${dst_vol}"
                tar czf - -C "$vol_dir" .                     | ssh -i "$DST_KEY" -p "$DST_PORT"                           -o ControlMaster=no                           -o ConnectTimeout=60                           -o ServerAliveInterval=15                           -o ServerAliveCountMax=40                           -o StrictHostKeyChecking=accept-new                           -o BatchMode=yes                           "${DST_LOGIN:-$DST_USER}@${DST_HOST}"                           "sudo tar xzf - -C ${dst_vol}" &
                local _vpid=$!
                progress_dots $_vpid "  Restoring ${vol_name}"
                wait $_vpid
                ok "  Restored: ${vol_name}"
                ((_vol_count++))
            done
            [[ $_vol_count -eq 0 ]] && info "No volumes in backup."
        else
            info "No volumes directory in backup."
        fi
    else
        echo -e "${YELLOW}[DRY-RUN]${RESET} restore volumes to destination"
    fi

    # Start destination stack
    if ! $DRY_RUN; then
        info "Starting stack on destination..."
        ssh_dst "sudo sh -c 'cd ${DST_PATH} &&             nohup docker compose up -d > /tmp/docker-migrate-restore.log 2>&1 &'"             2>/dev/null || true
        sleep 5
        local _running
        _running=$(ssh_dst             "sudo docker ps --filter label=com.docker.compose.project=${STACK_NAME}                 --filter status=running --format '{{.Names}}' 2>/dev/null | wc -l"             2>/dev/null | tr -d '[:space:]' | grep -oE '^[0-9]+' || echo 0)
        if [[ "${_running:-0}" -gt 0 ]]; then
            ok "Stack started — ${_running} container(s) running."
        else
            warn "Stack may still be starting — check manually:"
            warn "  ssh ${DST_LOGIN:-$DST_USER}@${DST_HOST} 'cat /tmp/docker-migrate-restore.log'"
        fi
    fi

    echo ""
    ok "Restore complete: ${bname} → ${DST_USER}@${DST_HOST}:${DST_PATH}"
    echo ""
}

# =============================================================================
# MAIN MENU
# =============================================================================
main_menu() {
    while true; do
        header "Main Menu  v${SCRIPT_VERSION}"

        # ── Status panel ──────────────────────────────────────────────────────
        # Use plain [ok]/[!!]/[--] tags — consistent width regardless of
        # Unicode glyph rendering differences across terminals
        local _ok="${GREEN}[ok]${RESET}" _warn="${YELLOW}[!!]${RESET}" _err="${RED}[--]${RESET}"
        echo -e "  ${BOLD}┌─ Status ──────────────────────────────────┐${RESET}"

        # SSH key
        if [[ -f "${SRC_KEY:-}" ]]; then
            echo -e "  ${BOLD}|${RESET} ${_ok} Key    : ${DIM}${SRC_KEY}${RESET}"
        else
            echo -e "  ${BOLD}|${RESET} ${_err} Key    : ${RED}no SSH key — use menu option k${RESET}"
        fi

        # Source connection
        if [[ -n "${SRC_HOST:-}" ]]; then
            local _src_display="${SRC_USER}@${SRC_HOST}:${SRC_PORT}"
            [[ -n "${SRC_LOGIN:-}" ]] && _src_display="${SRC_LOGIN}→${SRC_USER}@${SRC_HOST}:${SRC_PORT}"
            echo -e "  ${BOLD}|${RESET} ${_ok} Source : ${DIM}${_src_display}  base: ${SRC_BASE}${RESET}"
        else
            echo -e "  ${BOLD}|${RESET} ${_warn} Source : ${YELLOW}not set — use option 1 or k${RESET}"
        fi

        # Destination connection
        if [[ -n "${DST_HOST:-}" ]]; then
            local _dst_display="${DST_USER}@${DST_HOST}:${DST_PORT}"
            [[ -n "${DST_LOGIN:-}" ]] && _dst_display="${DST_LOGIN}→${DST_USER}@${DST_HOST}:${DST_PORT}"
            echo -e "  ${BOLD}|${RESET} ${_ok} Dest   : ${DIM}${_dst_display}  base: ${DST_BASE}${RESET}"
        else
            echo -e "  ${BOLD}|${RESET} ${_warn} Dest   : ${YELLOW}not set — use option 1 or k${RESET}"
        fi

        # Selected stack
        if [[ -n "${SRC_PATH:-}" ]]; then
            echo -e "  ${BOLD}|${RESET} ${_ok} Stack  : ${DIM}${STACK_NAME}  (${SRC_PATH} -> ${DST_PATH})${RESET}"
        else
            echo -e "  ${BOLD}|${RESET} ${_warn} Stack  : ${YELLOW}not selected — use option 2${RESET}"
        fi

        # Compose file state
        if [[ -n "${COMPOSE_FILE:-}" ]]; then
            echo -e "  ${BOLD}|${RESET} ${_ok} Compose: ${DIM}${COMPOSE_FILE}${RESET}"
        elif [[ -n "${SRC_PATH:-}" ]]; then
            echo -e "  ${BOLD}|${RESET} ${_warn} Compose: ${YELLOW}not loaded — run pre-flight (option 3)${RESET}"
        fi

        # Scope
        if [[ -n "${SELECTED_SERVICES:-}" ]]; then
            echo -e "  ${BOLD}|${RESET} ${_warn} Scope  : ${YELLOW}partial — ${SELECTED_SERVICES}${RESET}"
        else
            echo -e "  ${BOLD}|${RESET}      Scope  : ${DIM}full stack${RESET}"
        fi

        # Decommission mode
        if ${DECOMMISSION_MODE:-true}; then
            echo -e "  ${BOLD}|${RESET} ${_warn} Mode   : ${YELLOW}decommission — source stays stopped${RESET}"
        else
            echo -e "  ${BOLD}|${RESET}      Mode   : ${DIM}parallel — source restarted after migration${RESET}"
        fi

        # Verbose mode
        if $VERBOSE; then
            echo -e "  ${BOLD}|${RESET} ${_warn} Verbose: ON"
        fi

        echo -e "  ${BOLD}└───────────────────────────────────────────┘${RESET}"
        echo ""

        echo -e "  ${BOLD}── Setup ──────────────────────────────${RESET}"
        echo -e "  ${BOLD}1)${RESET} Configure connection"
        echo -e "  ${BOLD}2)${RESET} Select stack + services to migrate"
        echo ""
        echo -e "  ${BOLD}── Checks ─────────────────────────────${RESET}"
        echo -e "  ${BOLD}3)${RESET} Run pre-flight checks"
        echo -e "  ${BOLD}4)${RESET} Run extended diagnostics"
        echo ""
        echo -e "  ${BOLD}── Migration ──────────────────────────${RESET}"
        echo -e "  ${BOLD}5)${RESET} Start migration"
        echo -e "  ${BOLD}6)${RESET} Dry-run migration (no changes)"
        echo -e "  ${BOLD}7)${RESET} Verify destination"
        echo ""
        echo -e "  ${BOLD}── Backup & Restore ───────────────────${RESET}"
        echo -e "  ${BOLD}b)${RESET} Backup source stack"
        echo -e "  ${BOLD}r)${RESET} Restore backup to destination"
        echo ""
        echo -e "  ${BOLD}── Tools ──────────────────────────────${RESET}"
        echo -e "  ${BOLD}8)${RESET} Toggle verbose mode      [$(  $VERBOSE && echo ON || echo off)]"
        echo -e "  ${BOLD}9)${RESET} Toggle decommission mode  [$( $DECOMMISSION_MODE && echo ON || echo off)]"
        echo -e "  ${BOLD}0)${RESET} View log file"
        echo -e "  ${BOLD}c)${RESET} Clear saved configuration"
        echo -e "  ${BOLD}a)${RESET} Verify access (SSH + sudo + docker)"
        echo -e "  ${BOLD}k)${RESET} SSH key management (generate + deploy)"
        echo -e "  ${BOLD}q)${RESET} Quit"
        echo ""
        echo -en "${CYAN}Select option: ${RESET}"
        read -rn1 choice
        echo ""

        case "$choice" in
            1)  gather_inputs ;;
            2)
                if [[ -z "$SRC_HOST" ]]; then
                    warn "Configure connection first (option 1)."
                else
                    pick_stack_from_source || true
                    # After picking a stack, offer to also select specific services
                    if [[ -n "$SRC_PATH" ]]; then
                        if [[ -z "$COMPOSE_FILE" ]]; then
                            info "Running pre-flight to load compose file..."
                            preflight_checks || true
                        fi
                        [[ -n "$COMPOSE_FILE" ]] && { select_services || true; }
                    fi
                fi
                ;;
            3)
                [[ -z "$SRC_HOST" ]] && gather_inputs
                preflight_checks || true
                ;;
            4)
                [[ -z "$SRC_HOST" ]] && gather_inputs
                run_diagnostics
                ;;
            5)
                [[ -z "$SRC_HOST" ]] && gather_inputs
                if [[ -z "$SRC_PATH" ]]; then
                    warn "No stack selected — use option 2 first."
                elif [[ -z "$COMPOSE_FILE" ]]; then
                    info "Running pre-flight to locate compose file..."
                    preflight_checks || continue
                fi
                DRY_RUN=false
                do_migration
                ;;
            6)
                [[ -z "$SRC_HOST" ]] && gather_inputs
                if [[ -z "$SRC_PATH" ]]; then
                    warn "No stack selected — use option 2 first."
                elif [[ -z "$COMPOSE_FILE" ]]; then
                    info "Running pre-flight to locate compose file..."
                    preflight_checks || continue
                fi
                DRY_RUN=true
                do_migration
                DRY_RUN=false
                ;;
            7)
                [[ -z "$DST_HOST" ]] && gather_inputs
                run_verification
                ;;
            8)
                $VERBOSE && VERBOSE=false || VERBOSE=true
                $VERBOSE && ok "Verbose mode ON" || info "Verbose mode OFF"
                ;;
            9)
                $DECOMMISSION_MODE && DECOMMISSION_MODE=false || DECOMMISSION_MODE=true
                $DECOMMISSION_MODE                     && ok  "Decommission mode ON — source will NOT be restarted after migration"                     || info "Decommission mode OFF — script will offer to restart source after migration"
                ;;
            0)
                if [[ -f "$LOGFILE" ]]; then
                    less +G "$LOGFILE"
                else
                    warn "Log file not found: ${LOGFILE}"
                fi
                ;;
            c|C)
                if [[ -f "$CONFIG_FILE" ]]; then
                    confirm "Delete saved config ${CONFIG_FILE}?"                         && rm "$CONFIG_FILE" && ok "Config cleared."
                else
                    info "No saved config to clear."
                fi
                ;;
            a|A)
                verify_access
                ;;
            b|B)
                if [[ -z "$SRC_HOST" ]]; then
                    warn "Configure connection first (option 1)."
                else
                    run_backup
                fi
                ;;
            r|R)
                if [[ -z "$DST_HOST" ]]; then
                    warn "Configure connection first (option 1)."
                else
                    run_restore
                fi
                ;;
            k|K)
                manage_ssh_keys
                ;;
            q|Q)
                echo ""
                info "Exiting. Log saved to: ${LOGFILE}"
                exit 0
                ;;
            *)
                warn "Invalid option: '${choice}'"
                ;;
        esac

        echo ""
        echo -en "${DIM}Press any key to return to menu...${RESET}"
        read -rn1
    done
}

# =============================================================================
# ENTRY POINT
# =============================================================================
usage() {
    cat <<EOF
${BOLD}Usage:${RESET} $(basename "$0") [OPTIONS]

${BOLD}Options:${RESET}
  -v, --verbose   Show detailed output for all checks and operations
  -f, --force     Skip confirmation prompts
  -h, --help      Show this help

${BOLD}Examples:${RESET}
  $(basename "$0")                  # Interactive menu
  $(basename "$0") --verbose        # Menu with verbose output
  $(basename "$0") --verbose --force

Log file: ${LOGFILE}
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose) VERBOSE=true ;;
        -f|--force)   FORCE=true ;;
        -h|--help)    usage ;;
        *) fatal "Unknown option: $1. Use --help for usage." ;;
    esac
    shift
done

startup_sanity_checks
start_logging

# Auto-load saved config silently if it exists — no prompt, just restore state
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE" 2>/dev/null || true
    verbose "Auto-loaded config from ${CONFIG_FILE}"
fi

main_menu
