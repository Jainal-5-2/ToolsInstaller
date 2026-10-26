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
GHIDRA_API="https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/latest"
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
    local step="$1" reason="$2" status="${3:-failed}"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] STATUS=$status STEP=$step REASON=$reason" >> "$FAIL_LOG"
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
                log_failure "$step_name" "skipped-by-user" "skipped"
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
        log_failure "$step_name" "exit-code-$rc" "failed"
        log_error "Step failed: $step_name (exit $rc, ${elapsed}s)"
        return 1
    fi
    OK_STEPS+=("$step_name")
    log_info "Step complete: $step_name (${elapsed}s)"
    return 0
}

trap 'log_warn "Ctrl-C caught ? skipping current step..."; [[ -n "$STEP_PID" ]] && kill_tree "$STEP_PID" TERM' INT

# ==========================================
# Verification helper
# ==========================================
print_check() {
    local kind="$1" target="$2" label="$3" hint="${4:-}"
    local found=0
    case "$kind" in
        cmd)  command -v "$target" &>/dev/null && found=1 ;;
        file) [ -s "$target" ] && found=1 ;;
        exe)  [ -x "$target" ] && found=1 ;;
        dir)  [ -d "$target" ] && found=1 ;;
        py)   python3 -c "import $target" &>/dev/null && found=1 ;;
    esac
    local display="${hint:-$target}"
    if [ $found -eq 1 ]; then
        printf "  ${GREEN}[OK]${NC}      %-18s %s\n" "$label" "$display"
    else
        printf "  ${RED}[MISSING]${NC} %-18s %s\n" "$label" "$display"
    fi
}

# ==========================================
# HTTP helpers (status-checked downloads)
# ==========================================
# url_ok URL ? returns 0 if the final status after redirects is 200.
url_ok() {
    local url="$1" code
    code=$(curl -sL -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")
    [ "$code" = "200" ]
}

# fetch URL DEST ? download only if URL returns 200; never leaves a partial file.
fetch() {
    local url="$1" dest="$2" tmp
    tmp="$(mktemp)"
    if ! url_ok "$url"; then
        log_warn "HTTP status != 200 for $url ? skipping download"
        rm -f "$tmp"
        return 1
    fi
    if ! curl -fL --retry 3 --connect-timeout 30 --max-time 600 \
              -o "$tmp" "$url"; then
        log_warn "Download failed for $url"
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$dest"
    return 0
}

# fetch_progress URL DEST ? same as fetch, but uses wget for a progress bar.
fetch_progress() {
    local url="$1" dest="$2" tmp
    tmp="$(mktemp)"
    if ! url_ok "$url"; then
        log_warn "HTTP status != 200 for $url ? skipping download"
        rm -f "$tmp"
        return 1
    fi
    if ! wget --show-progress --progress=bar:force:noscroll \
              --tries=3 --timeout=30 -O "$tmp" "$url"; then
        log_warn "Download failed for $url"
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$dest"
    return 0
}

# ==========================================
# pip with PEP 668 fallback
# ==========================================
pip_install_user() {
    local pkg="$1"
    if pip3 install --user "$pkg" &>/dev/null; then return 0; fi
    log_warn "pip install $pkg (--user) failed; retrying with --break-system-packages"
    if pip3 install --user --break-system-packages "$pkg" &>/dev/null; then return 0; fi
    log_failure "$pkg" "pip-failed" "failed"
    return 1
}

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
            log_failure "apt:${to_install[*]}" "apt-failed: $tail" "failed"
            rm -f /tmp/apt-step.log
            return 1
        fi
        rm -f /tmp/apt-step.log
    else
        log_info "apt packages already present: ${packages[*]}"
    fi
}

step_build_prereqs() {
    log_info "--- Build prerequisites ---"
    # Must run before any pip/compile step so native extensions can build.
    install_apt_packages cmake build-essential pkg-config python3-dev \
                         libgmp3-dev libmpc-dev
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
    # Full dependency set from the LikeNmuFF/stegdetect README.
    # cmake is guaranteed by step_build_prereqs.
    install_apt_packages file binutils python3 libimage-exiftool-perl \
                         zbar-tools stegsnow mediainfo sox binwalk steghide ruby wget \
                         tesseract-ocr ffmpeg poppler-utils unzip
    if ! gem list zsteg -i &>/dev/null; then
        log_info "Installing zsteg gem..."
        if ! sudo gem install zsteg; then
            log_failure "zsteg" "gem-install-failed" "failed"
            return 1
        fi
    fi
    mkdir -p "$INSTALL_DIR"
    if [ ! -d "$INSTALL_DIR/stegdetect/.git" ]; then
        if ! git clone "$STEGDETECT_REPO" "$INSTALL_DIR/stegdetect"; then
            log_failure "stegdetect-repo" "git-clone-failed" "failed"
            return 1
        fi
    fi
    cd "$INSTALL_DIR/stegdetect"
    git pull --ff-only 2>/dev/null || true
    chmod +x stegdetect.sh
    if ! sudo ./stegdetect.sh --install; then
        log_failure "stegdetect-install" "script-install-failed" "failed"
        return 1
    fi
}

step_rsactftool() {
    log_info "--- RsaCtfTool ---"
    if command -v RsaCtfTool &>/dev/null || [ -f /usr/local/bin/RsaCtfTool ]; then
        log_info "Already installed."; return 0
    fi
    # libgmp3-dev / libmpc-dev are guaranteed by step_build_prereqs.
    install_apt_packages python3-venv python3-pip
    mkdir -p "$INSTALL_DIR"
    if [ ! -d "$INSTALL_DIR/RsaCtfTool/.git" ]; then
        if ! git clone "$RSACTFTOOL_REPO" "$INSTALL_DIR/RsaCtfTool"; then
            log_failure "rsactftool-repo" "git-clone-failed" "failed"
            return 1
        fi
    fi
    cd "$INSTALL_DIR/RsaCtfTool"
    git pull --ff-only 2>/dev/null || true
    [ -d venv ] || python3 -m venv venv
    source venv/bin/activate
    if ! pip install -e .; then
        log_failure "rsactftool-pip" "pip-install-failed" "failed"
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
        log_failure "rsactftool-entry" "entry-point-not-found" "failed"
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
        log_failure "rsactftool-wrapper" "verification-failed" "failed"
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
        log_failure "cyberchef" "github-api-failed" "failed"
        log_error "GitHub API rate-limited or unreachable."; return 1
    fi
    log_info "Downloading CyberChef..."
    if ! fetch_progress "$zip_url" /tmp/cyberchef.zip; then
        log_failure "cyberchef" "download-failed: $zip_url" "failed"
        return 1
    fi
    unzip -o /tmp/cyberchef.zip -d "$dir"
    local src
    src=$(find "$dir" -maxdepth 1 -name 'CyberChef_*.html' | head -1)
    if [ -z "$src" ]; then
        log_failure "cyberchef" "html-not-found-after-unzip" "failed"
        rm -f /tmp/cyberchef.zip
        return 1
    fi
    mv "$src" "$html" && log_info "Saved: $html"
    rm -f /tmp/cyberchef.zip
}

step_python_gaps() {
    log_info "--- Python supplements ---"
    local failed=0
    pip3 show volatility3 &>/dev/null  || pip_install_user volatility3  || failed=1
    pip3 show stegoveritas &>/dev/null || pip_install_user stegoveritas || failed=1
    pip3 show cyberchef-py &>/dev/null || pip_install_user cyberchef-py || failed=1
    python3 -c "import pwn" 2>/dev/null    || pip_install_user pwntools    || failed=1
    python3 -c "import Crypto" 2>/dev/null || pip_install_user pycryptodome || failed=1
    python3 -c "import z3" 2>/dev/null     || pip_install_user z3-solver   || failed=1
    return $failed
}

step_apt_gaps() {
    log_info "--- Apt gaps ---"
    # cmake is guaranteed by step_build_prereqs.
    install_apt_packages tshark wireshark default-jre sonic-visualiser || return 1
    if command -v wireshark &>/dev/null && ! groups "$USER" | grep -qw wireshark; then
        log_info "Adding $USER to wireshark group..."
        sudo usermod -aG wireshark "$USER" || log_failure "wireshark-group" "usermod-failed" "failed"
        log_warn "Log out and back in for capture permission to apply."
    fi
}

step_gui_downloads() {
    log_info "--- GUI downloads ---"
    mkdir -p "$INSTALL_DIR"
    local jar="$INSTALL_DIR/stegsolve.jar" gdir="$INSTALL_DIR/ghidra"

    if [ ! -f "$jar" ]; then
        log_info "Downloading StegSolve..."
        if ! fetch_progress \
             "https://github.com/eugenekolo/sec-tools/raw/master/stego/stegsolve/stegsolve/stegsolve.jar" \
             "$jar"; then
            log_failure "stegsolve" "download-failed" "failed"
        fi
    fi

    if [ ! -d "$gdir" ]; then
        local url
        url=$(curl -s "$GHIDRA_API" \
            | grep browser_download_url | grep '\.zip"' | head -1 | cut -d '"' -f 4)
        if [ -z "$url" ]; then
            log_failure "ghidra" "github-api-failed" "failed"
            return 0
        fi

        # Preflight: refuse to start if the URL doesn't return 200.
        if ! url_ok "$url"; then
            log_failure "ghidra" "http-status-not-200: $url" "failed"
            return 0
        fi

        log_info "Downloading Ghidra (~400MB, this can take several minutes)..."
        log_info "URL: $url"

        wget -c --show-progress --progress=bar:force:noscroll \
             --tries=3 --timeout=30 -O /tmp/ghidra.zip "$url" &
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
                    log_failure "ghidra" "download-stalled-at-${cur_mb}MB" "failed"
                    rm -f /tmp/ghidra.zip
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
            log_failure "ghidra" "download-failed-exit-$rc" "failed"
            rm -f /tmp/ghidra.zip
            return 0
        fi
        if ! unzip -t /tmp/ghidra.zip >/dev/null 2>&1; then
            log_failure "ghidra" "downloaded-file-is-not-a-valid-zip" "failed"
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
    log_failure "apt-update" "apt-get-update-failed" "failed"
fi

log_info "Tip: 's'+Enter = skip step, any other key+Enter = show progress."
echo ""

run_step "Build prerequisites" step_build_prereqs  || true
run_step "Kali metapackages"  step_metapackages   || true
run_step "StegDetect"         step_stegdetect     || true
run_step "RsaCtfTool"         step_rsactftool     || true
run_step "CyberChef"          step_cyberchef      || true
run_step "Python gaps"        step_python_gaps    || true
run_step "Apt gaps"           step_apt_gaps       || true
run_step "GUI downloads"      step_gui_downloads  || true

# ==========================================
# Recap
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
    recent_fails=$(grep 'STATUS=failed' "$FAIL_LOG" | tail -10)
    if [ -n "$recent_fails" ]; then
        echo "  Recent failed components:"
        echo "$recent_fails" | sed 's/^/    /'
    fi
fi

# ==========================================
# Verified tool summary
# ==========================================
echo ""
echo -e "${BOLD}--- Installed tools (verified) ---${NC}"
echo ""
echo "GUI:"
print_check file "$CYBERCHEF_HTML"            "CyberChef"          "file://$CYBERCHEF_HTML"
print_check file "$STEGSOLVE_JAR"             "StegSolve"          "java -jar $STEGSOLVE_JAR"
print_check cmd  wireshark                    "Wireshark"          "wireshark"
print_check exe  "$GHIDRA_DIR/ghidraRun"      "Ghidra"             "$GHIDRA_DIR/ghidraRun"
print_check cmd  sonic-visualiser             "Sonic Visualiser"   "sonic-visualiser"
echo ""
echo "CLI:"
print_check cmd  vol                          "Volatility 3"       "vol -f <dump> windows.info"
print_check cmd  RsaCtfTool                   "RsaCtfTool"         "RsaCtfTool --help"
print_check cmd  stegdetect                   "StegDetect"         "stegdetect --version"
print_check cmd  tshark                       "tshark"             "tshark -r <pcap>"
print_check cmd  stegoveritas                 "stegoveritas"       "stegoveritas <image>"
print_check cmd  cmake                        "cmake"              "cmake --version"
echo ""
echo "Python modules:"
print_check py   pychef                       "cyberchef-py"       "import pychef"
print_check py   pwn                          "pwntools"           "import pwn"
print_check py   Crypto                       "pycryptodome"       "import Crypto"
print_check py   z3                           "z3-solver"          "import z3"

echo ""
echo "If Wireshark was just added to your group: log out and back in."