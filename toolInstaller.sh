#!/bin/bash
# CTF Tool Installer Script (Kali Linux optimized)
# Installs StegDetect, RsaCtfTool, CyberChef, and supplements Kali's metapackages.
# Idempotent: re-running skips anything already present.
#
# Interactive:
#   s + Enter  ? skip current step
#   any other key + Enter ? print progress report for current step
# Failures and skips are logged to $INSTALL_DIR/install-failures.log

set -e

# --- Configuration ---
INSTALL_DIR="$HOME/ctf-tools"
STEGDETECT_REPO="https://github.com/LikeNmuFF/stegdetect.git"
RSACTFTOOL_REPO="https://github.com/RsaCtfTool/RsaCtfTool.git"
CYBERCHEF_API="https://api.github.com/repos/gchq/CyberChef/releases/latest"
FAIL_LOG="$INSTALL_DIR/install-failures.log"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

mkdir -p "$INSTALL_DIR"

declare -a FAILED_STEPS=()
declare -a SKIPPED_STEPS=()
declare -a OK_STEPS=()

log_failure() {
    local step="$1" reason="$2"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] STEP=$step REASON=$reason" >> "$FAIL_LOG"
}

if ! grep -qi 'kali' /etc/os-release 2>/dev/null; then
    log_warn "This script is tuned for Kali Linux. Continuing anyway, but metapackages may not exist."
fi
if [[ $EUID -ne 0 ]]; then
   log_warn "apt operations need sudo; you may be prompted."
fi

# ==========================================
# Interactive skip + progress machinery
# ==========================================
STEP_PID=""
STEP_NAME=""
STEP_START=0

kill_tree() {
    local pid="$1" sig="$2"
    local children
    children=$(pgrep -P "$pid" 2>/dev/null || true)
    for c in $children; do kill_tree "$c" "$sig"; done
    kill -"$sig" "$pid" 2>/dev/null || true
}

describe_activity() {
    local pid="$1"
    local depth=0
    local current="$pid"
    while [ $depth -lt 8 ]; do
        local kids
        kids=$(pgrep -P "$current" 2>/dev/null | head -1)
        if [ -z "$kids" ]; then break; fi
        current="$kids"
        depth=$((depth + 1))
    done

    local leaf="$current"
    local cmd args
    cmd=$(ps -o comm= -p "$leaf" 2>/dev/null || echo "?")
    args=$(ps -o args= -p "$leaf" 2>/dev/null | cut -c1-120 || echo "")

    local elapsed=$(( $(date +%s) - STEP_START ))
    local mins=$((elapsed / 60)) secs=$((elapsed % 60))

    local fd_count=0
    [ -d "/proc/$leaf/fd" ] && fd_count=$(ls /proc/"$leaf"/fd 2>/dev/null | wc -l)

    echo ""
    echo -e "${CYAN}${BOLD}--- progress: $STEP_NAME ---${NC}"
    echo "  Elapsed:     ${mins}m ${secs}s"
    echo "  Active:      $cmd  (pid $leaf, depth $depth)"
    echo "  Command:     $args"
    echo "  Open FDs:    $fd_count"

    if [ -s /tmp/apt-step.log ]; then
        echo "  Last apt output:"
        tail -3 /tmp/apt-step.log | sed 's/^/    /'
    fi

    if [ -d "/proc/$leaf/fd" ]; then
        local sockets
        sockets=$(ls -l /proc/"$leaf"/fd 2>/dev/null | grep -c 'socket:' || echo 0)
        [ "$sockets" -gt 0 ] && echo "  Sockets:     $sockets active"
    fi

    if [ -r "/proc/$leaf/io" ]; then
        local rb wb
        rb=$(awk '/^read_bytes/{print $2}' /proc/"$leaf"/io 2>/dev/null)
        wb=$(awk '/^write_bytes/{print $2}' /proc/"$leaf"/io 2>/dev/null)
        [ -n "$rb" ] && echo "  I/O:         read ${rb}B, wrote ${wb}B"
    fi
    echo -e "${CYAN}-----------------------------------${NC}"
    echo ""
}

run_step() {
    local step_name="$1"
    local step_fn="$2"
    STEP_NAME="$step_name"
    STEP_START=$(date +%s)

    echo -e "${GREEN}[INFO]${NC} >>> $step_name  (s=skip, any other key=progress)"
    ( "$step_fn" ) &
    STEP_PID=$!

    while kill -0 "$STEP_PID" 2>/dev/null; do
        if read -r -t 0.2 -n 1 key 2>/dev/null; then
            while read -r -t 0 -n 1 _ 2>/dev/null; do :; done
            if [[ "${key,,}" == "s" ]]; then
                log_warn "Skip requested ? stopping '$step_name'..."
                kill_tree "$STEP_PID" TERM
                sleep 1
                kill_tree "$STEP_PID" KILL
                wait "$STEP_PID" 2>/dev/null || true
                SKIPPED_STEPS+=("$step_name")
                log_failure "$step_name" "skipped-by-user"
                log_warn "Step skipped: $step_name"
                return 1
            else
                describe_activity "$STEP_PID"
            fi
        fi
    done

    wait "$STEP_PID"
    local rc=$?
    local elapsed=$(( $(date +%s) - STEP_START ))
    if [ $rc -ne 0 ]; then
        FAILED_STEPS+=("$step_name (exit $rc)")
        log_failure "$step_name" "exit-code-$rc"
        log_error "Step failed: $step_name (exit $rc, ${elapsed}s)"
        return 1
    fi
    OK_STEPS+=("$step_name")
    log_info "Step complete: $step_name (${elapsed}s)"
    return 0
}

trap 'log_warn "Ctrl-C caught ? skipping current step..."; [[ -n "$STEP_PID" ]] && kill_tree "$STEP_PID" TERM' INT

# ==========================================
# Step implementations
# ==========================================
install_apt_packages() {
    local packages=("$@") to_install=()
    for pkg in "${packages[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then to_install+=("$pkg"); fi
    done
    if [ ${#to_install[@]} -gt 0 ]; then
        log_info "Installing: ${to_install[*]}"
        if ! sudo apt-get install -y "${to_install[@]}" 2>&1 | tee /tmp/apt-step.log; then
            local tail
            tail=$(tail -5 /tmp/apt-step.log | tr '\n' '|')
            log_failure "apt:${to_install[*]}" "apt-failed: $tail"
            rm -f /tmp/apt-step.log
            return 1
        fi
        rm -f /tmp/apt-step.log
    else
        log_info "apt packages already present: ${packages[*]}"
    fi
}

step_metapackages() {
    log_info "--- Kali metapackages ---"
    install_apt_packages kali-tools-crypto-stego kali-tools-forensics \
                         kali-tools-reverse-engineering kali-tools-passwords
}

step_stegdetect() {
    log_info "--- StegDetect ---"
    if command -v stegdetect &>/dev/null; then
        log_info "Already installed: $(command -v stegdetect)"; return 0
    fi
    install_apt_packages file binutils python3 libimage-exiftool-perl \
                         zbar-tools stegsnow mediainfo sox binwalk steghide ruby wget
    if ! gem list zsteg -i &>/dev/null; then
        log_info "Installing zsteg gem..."
        if ! sudo gem install zsteg; then
            log_failure "zsteg" "gem-install-failed"
            return 1
        fi
    fi
    mkdir -p "$INSTALL_DIR"
    if [ ! -d "$INSTALL_DIR/stegdetect/.git" ]; then
        if ! git clone "$STEGDETECT_REPO" "$INSTALL_DIR/stegdetect"; then
            log_failure "stegdetect-repo" "git-clone-failed"
            return 1
        fi
    fi
    cd "$INSTALL_DIR/stegdetect"
    git pull --ff-only 2>/dev/null || true
    chmod +x stegdetect.sh
    if ! sudo ./stegdetect.sh --install; then
        log_failure "stegdetect-install" "script-install-failed"
        return 1
    fi
}

step_rsactftool() {
    log_info "--- RsaCtfTool ---"
    if command -v RsaCtfTool &>/dev/null || [ -f /usr/local/bin/RsaCtfTool ]; then
        log_info "Already installed."; return 0
    fi
    install_apt_packages python3-venv python3-pip libgmp3-dev libmpc-dev
    mkdir -p "$INSTALL_DIR"
    if [ ! -d "$INSTALL_DIR/RsaCtfTool/.git" ]; then
        if ! git clone "$RSACTFTOOL_REPO" "$INSTALL_DIR/RsaCtfTool"; then
            log_failure "rsactftool-repo" "git-clone-failed"
            return 1
        fi
    fi
    cd "$INSTALL_DIR/RsaCtfTool"
    git pull --ff-only 2>/dev/null || true
    [ -d venv ] || python3 -m venv venv
    source venv/bin/activate
    if ! pip install -e .; then
        log_failure "rsactftool-pip" "pip-install-failed"
        deactivate
        return 1
    fi
    deactivate

    local entry=""
    for candidate in \
        "$INSTALL_DIR/RsaCtfTool/RsaCtfTool.py" \
        "$INSTALL_DIR/RsaCtfTool/src/RsaCtfTool/main.py" \
        "$INSTALL_DIR/RsaCtfTool/src/RsaCtfTool/RsaCtfTool.py"; do
        if [ -f "$candidate" ]; then entry="$candidate"; break; fi
    done
    if [ -z "$entry" ]; then
        log_failure "rsactftool-entry" "entry-point-not-found"
        log_error "Could not locate RsaCtfTool entry point."
        return 1
    fi
    log_info "Using entry point: $entry"
    sudo tee /usr/local/bin/RsaCtfTool >/dev/null <<EOF
#!/bin/bash
source "$INSTALL_DIR/RsaCtfTool/venv/bin/activate"
python "$entry" "\$@"
EOF
    sudo chmod +x /usr/local/bin/RsaCtfTool

    if ! RsaCtfTool --help &>/dev/null; then
        log_failure "rsactftool-wrapper" "verification-failed"
        log_error "RsaCtfTool wrapper exists but 'RsaCtfTool --help' failed."
        return 1
    fi
    log_info "RsaCtfTool verified successfully."
}

step_cyberchef() {
    log_info "--- CyberChef (static) ---"
    local dir="$INSTALL_DIR/cyberchef" html="$INSTALL_DIR/cyberchef/CyberChef.html"
    if [ -f "$html" ]; then
        log_info "Already present: $html"; return 0
    fi
    mkdir -p "$dir"
    local zip_url
    zip_url=$(curl -s "$CYBERCHEF_API" | grep browser_download_url | grep '\.zip"' | head -1 | cut -d '"' -f 4)
    if [ -z "$zip_url" ]; then
        log_failure "cyberchef" "github-api-failed"
        log_error "GitHub API rate-limited or unreachable."; return 1
    fi
    log_info "Downloading CyberChef..."
    if ! wget --show-progress --progress=bar:force:noscroll \
              "$zip_url" -O /tmp/cyberchef.zip; then
        log_failure "cyberchef" "download-failed: $zip_url"
        return 1
    fi
    unzip -o /tmp/cyberchef.zip -d "$dir"
    local src
    src=$(find "$dir" -maxdepth 1 -name 'CyberChef_*.html' | head -1)
    if [ -z "$src" ]; then
        log_failure "cyberchef" "html-not-found-after-unzip"
        rm -f /tmp/cyberchef.zip
        return 1
    fi
    mv "$src" "$html" && log_info "Saved: $html"
    rm -f /tmp/cyberchef.zip
}

step_python_gaps() {
    log_info "--- Python supplements ---"
    local failed=0
    if ! pip3 show volatility3 &>/dev/null; then
        pip3 install --user volatility3 || { log_failure "volatility3" "pip-failed"; failed=1; }
    fi
    if ! pip3 show stegoveritas &>/dev/null; then
        pip3 install --user stegoveritas || { log_failure "stegoveritas" "pip-failed"; failed=1; }
    fi
    if ! pip3 show cyberchef-py &>/dev/null; then
        pip3 install --user cyberchef-py || { log_failure "cyberchef-py" "pip-failed"; failed=1; }
    fi
    python3 -c "import pwn" 2>/dev/null || pip3 install --user pwntools || { log_failure "pwntools" "pip-failed"; failed=1; }
    python3 -c "import Crypto" 2>/dev/null || pip3 install --user pycryptodome || { log_failure "pycryptodome" "pip-failed"; failed=1; }
    python3 -c "import z3" 2>/dev/null || pip3 install --user z3-solver || { log_failure "z3-solver" "pip-failed"; failed=1; }
    return $failed
}

step_apt_gaps() {
    log_info "--- Apt gaps ---"
    install_apt_packages tshark wireshark default-jre || return 1
    if command -v wireshark &>/dev/null && ! groups "$USER" | grep -qw wireshark; then
        log_info "Adding $USER to wireshark group..."
        sudo usermod -aG wireshark "$USER" || log_failure "wireshark-group" "usermod-failed"
        log_warn "Log out and back in for capture permission to apply."
    fi
}

step_gui_downloads() {
    log_info "--- GUI downloads ---"
    mkdir -p "$INSTALL_DIR"
    local jar="$INSTALL_DIR/stegsolve.jar" gdir="$INSTALL_DIR/ghidra"

    if [ ! -f "$jar" ]; then
        log_info "Downloading StegSolve (small, ~50KB)..."
        if ! wget --show-progress --progress=bar:force:noscroll \
                  -O "$jar" \
                  "https://github.com/zardus/ctf-tools/raw/master/stegsolve/stegsolve.jar"; then
            log_failure "stegsolve" "download-failed"
        fi
    fi

    if [ ! -d "$gdir" ]; then
        local url
        url=$(curl -s https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/latest \
            | grep browser_download_url | grep '\.zip"' | head -1 | cut -d '"' -f 4)
        if [ -z "$url" ]; then
            log_failure "ghidra" "github-api-failed"
            return 0
        fi

        log_info "Downloading Ghidra (~400MB, this can take several minutes)..."
        log_info "URL: $url"

        wget -c --show-progress --progress=bar:force:noscroll \
             -O /tmp/ghidra.zip "$url" &
        local wget_pid=$!

        local last_size=0 stall_count=0
        while kill -0 "$wget_pid" 2>/dev/null; do
            sleep 5
            local cur_size
            cur_size=$(stat -c%s /tmp/ghidra.zip 2>/dev/null || echo 0)
            local cur_mb=$((cur_size / 1048576))
            if [ "$cur_size" -eq "$last_size" ]; then
                stall_count=$((stall_count + 1))
                if [ $stall_count -ge 12 ]; then
                    log_error "Download stalled at ${cur_mb}MB for 60s ? aborting."
                    kill "$wget_pid" 2>/dev/null || true
                    wait "$wget_pid" 2>/dev/null || true
                    log_failure "ghidra" "download-stalled-at-${cur_mb}MB"
                    return 0
                fi
            else
                stall_count=0
                last_size="$cur_size"
                log_info "Downloading... ${cur_mb}MB so far"
            fi
        done
        wait "$wget_pid"
        local rc=$?
        if [ $rc -ne 0 ]; then
            log_failure "ghidra" "download-failed-exit-$rc"
            return 0
        fi
        if ! unzip -t /tmp/ghidra.zip >/dev/null 2>&1; then
            log_failure "ghidra" "downloaded-file-is-not-a-valid-zip"
            rm -f /tmp/ghidra.zip
            return 0
        fi
        mkdir -p "$gdir"
        unzip -o /tmp/ghidra.zip -d "$gdir" --strip-components=1 2>/dev/null || \
            unzip -o /tmp/ghidra.zip -d "$gdir"
        rm -f /tmp/ghidra.zip
        chmod +x "$gdir/ghidraRun" 2>/dev/null || true
        log_info "Ghidra extracted to: $gdir"
    fi
}

# ==========================================
# Main
# ==========================================
log_info "Updating package lists..."
if ! sudo apt-get update -y; then
    log_failure "apt-update" "apt-get-update-failed"
fi

log_info "Tip: 's'+Enter = skip step, any other key+Enter = show progress."
echo ""

run_step "Kali metapackages" step_metapackages || true
run_step "StegDetect"       step_stegdetect   || true
run_step "RsaCtfTool"       step_rsactftool   || true
run_step "CyberChef"        step_cyberchef    || true
run_step "Python gaps"      step_python_gaps  || true
run_step "Apt gaps"         step_apt_gaps     || true
run_step "GUI downloads"    step_gui_downloads || true

# ==========================================
# Recap (ASCII markers only)
# ==========================================
CYBERCHEF_HTML="$INSTALL_DIR/cyberchef/CyberChef.html"
STEGSOLVE_JAR="$INSTALL_DIR/stegsolve.jar"
GHIDRA_DIR="$INSTALL_DIR/ghidra"

echo ""
log_info "--- Done ---"
echo ""
echo "Successful steps (${#OK_STEPS[@]}):"
for s in "${OK_STEPS[@]}"; do echo -e "  ${GREEN}[OK]${NC}   $s"; done
if [ ${#FAILED_STEPS[@]} -gt 0 ]; then
    echo ""
    echo -e "${RED}Failed steps (${#FAILED_STEPS[@]}):${NC}"
    for s in "${FAILED_STEPS[@]}"; do echo -e "  ${RED}[FAIL]${NC} $s"; done
fi
if [ ${#SKIPPED_STEPS[@]} -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Skipped steps (${#SKIPPED_STEPS[@]}):${NC}"
    for s in "${SKIPPED_STEPS[@]}"; do echo -e "  ${YELLOW}[SKIP]${NC} $s"; done
fi

if [ -s "$FAIL_LOG" ]; then
    echo ""
    log_warn "Failure log: $FAIL_LOG"
    echo "  Re-run the script to retry only failed/skipped steps (idempotent)."
fi

echo ""
echo "GUI:"
echo "  CyberChef:        file://$CYBERCHEF_HTML"
echo "  StegSolve:        java -jar $STEGSOLVE_JAR"
echo "  Wireshark:        wireshark"
echo "  Ghidra:           $GHIDRA_DIR/ghidraRun"
echo "  Sonic Visualiser: sonic-visualiser"
echo ""
echo "CLI:"
echo "  vol -f <dump> windows.info   (Volatility 3)"
echo "  RsaCtfTool --help"
echo "  stegdetect --version"
echo "  tshark -r <pcap>"
echo ""
echo "If Wireshark was just added to your group: log out and back in."