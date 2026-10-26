#!/bin/bash
# CTF Tool Installer Script (Kali Linux optimized)
# Installs StegDetect, RsaCtfTool, CyberChef, and supplements Kali's metapackages.
# Idempotent: re-running skips anything already present.
#
# Interactive: press 's' + Enter at any time to skip the current step.

set -e

# --- Configuration ---
INSTALL_DIR="$HOME/ctf-tools"
STEGDETECT_REPO="https://github.com/LikeNmuFF/stegdetect.git"
RSACTFTOOL_REPO="https://github.com/RsaCtfTool/RsaCtfTool.git"
CYBERCHEF_API="https://api.github.com/repos/gchq/CyberChef/releases/latest"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Kali sanity check ---
if ! grep -qi 'kali' /etc/os-release 2>/dev/null; then
    log_warn "This script is tuned for Kali Linux. Continuing anyway, but metapackages may not exist."
fi

if [[ $EUID -ne 0 ]]; then
   log_warn "apt operations need sudo; you may be prompted."
fi

# ==========================================
# Interactive skip machinery
# ==========================================
# Each step runs in a background subshell. We poll stdin with `read -t 0.2`.
# If the user types 's' (case-insensitive), we kill the step's process group.
# Ctrl-C during a step also aborts that step (and continues the script).
# Press Ctrl-C twice in a row at a prompt to exit entirely.

STEP_PID=""
STEP_SKIPPED=0

# Runs a step function in background; returns 0 on success, 1 on failure/skip.
run_step() {
    local step_name="$1"
    local step_fn="$2"
    STEP_SKIPPED=0

    echo -e "${GREEN}[INFO]${NC} >>> $step_name  (press 's' + Enter to skip)"
    # Start the step in its own process group so we can kill the whole tree.
    setsid bash -c "$(declare -f "$step_fn"); $step_fn" &
    STEP_PID=$!

    # Poll stdin while the step runs.
    while kill -0 "$STEP_PID" 2>/dev/null; do
        # Read with timeout; returns non-zero on timeout.
        if read -r -t 0.2 -n 1 key 2>/dev/null; then
            # Drain the rest of the line if any (so Enter isn't left buffered).
            while read -r -t 0 -n 1 _ 2>/dev/null; do :; done
            if [[ "${key,,}" == "s" ]]; then
                log_warn "Skip requested ? stopping '$step_name'..."
                kill -TERM -"$STEP_PID" 2>/dev/null || kill -TERM "$STEP_PID" 2>/dev/null
                sleep 1
                kill -KILL -"$STEP_PID" 2>/dev/null || kill -KILL "$STEP_PID" 2>/dev/null
                wait "$STEP_PID" 2>/dev/null
                STEP_SKIPPED=1
                log_warn "Step skipped: $step_name"
                return 1
            fi
        fi
    done

    # Step finished naturally.
    wait "$STEP_PID"
    local rc=$?
    if [ $rc -ne 0 ]; then
        log_error "Step failed: $step_name (exit $rc)"
        return 1
    fi
    return 0
}

# Allow Ctrl-C to skip the current step rather than killing the whole script.
trap 'log_warn "Ctrl-C caught ? skipping current step..."; [[ -n "$STEP_PID" ]] && kill -TERM -"$STEP_PID" 2>/dev/null' INT

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
        sudo apt-get install -y "${to_install[@]}"
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
        sudo gem install zsteg
    fi
    mkdir -p "$INSTALL_DIR"
    [ -d "$INSTALL_DIR/stegdetect" ] || git clone "$STEGDETECT_REPO" "$INSTALL_DIR/stegdetect"
    cd "$INSTALL_DIR/stegdetect"
    git pull --ff-only 2>/dev/null || true
    chmod +x stegdetect.sh && sudo ./stegdetect.sh --install
}

step_rsactftool() {
    log_info "--- RsaCtfTool ---"
    if command -v RsaCtfTool &>/dev/null || [ -f /usr/local/bin/RsaCtfTool ]; then
        log_info "Already installed."; return 0
    fi
    install_apt_packages python3-venv python3-pip libgmp3-dev libmpc-dev
    mkdir -p "$INSTALL_DIR"
    [ -d "$INSTALL_DIR/RsaCtfTool" ] || git clone "$RSACTFTOOL_REPO" "$INSTALL_DIR/RsaCtfTool"
    cd "$INSTALL_DIR/RsaCtfTool"
    git pull --ff-only 2>/dev/null || true
    [ -d venv ] || python3 -m venv venv
    source venv/bin/activate && pip install -e . && deactivate
    sudo tee /usr/local/bin/RsaCtfTool >/dev/null <<EOF
#!/bin/bash
source "$INSTALL_DIR/RsaCtfTool/venv/bin/activate"
python "$INSTALL_DIR/RsaCtfTool/RsaCtfTool.py" "\$@"
EOF
    sudo chmod +x /usr/local/bin/RsaCtfTool
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
        log_error "GitHub API rate-limited or unreachable."; return 1
    fi
    wget -q "$zip_url" -O /tmp/cyberchef.zip
    unzip -o /tmp/cyberchef.zip -d "$dir"
    local src
    src=$(find "$dir" -maxdepth 1 -name 'CyberChef_*.html' | head -1)
    [ -n "$src" ] && mv "$src" "$html" && log_info "Saved: $html"
    rm -f /tmp/cyberchef.zip
}

step_python_gaps() {
    log_info "--- Python supplements ---"
    pip3 show volatility3 &>/dev/null || pip3 install --user volatility3
    pip3 show stegoveritas &>/dev/null || pip3 install --user stegoveritas
    pip3 show cyberchef-py &>/dev/null || pip3 install --user cyberchef-py
    python3 -c "import pwn" 2>/dev/null || pip3 install --user pwntools
    python3 -c "import Crypto" 2>/dev/null || pip3 install --user pycryptodome
    python3 -c "import z3" 2>/dev/null || pip3 install --user z3-solver
}

step_apt_gaps() {
    log_info "--- Apt gaps ---"
    install_apt_packages tshark wireshark default-jre
    if command -v wireshark &>/dev/null && ! groups "$USER" | grep -qw wireshark; then
        log_info "Adding $USER to wireshark group..."
        sudo usermod -aG wireshark "$USER"
        log_warn "Log out and back in for capture permission to apply."
    fi
}

step_gui_downloads() {
    log_info "--- GUI downloads ---"
    mkdir -p "$INSTALL_DIR"
    local jar="$INSTALL_DIR/stegsolve.jar" gdir="$INSTALL_DIR/ghidra"
    if [ ! -f "$jar" ]; then
        wget -q -O "$jar" \
          "https://github.com/zardus/ctf-tools/raw/master/stegsolve/stegsolve.jar" \
          || log_warn "StegSolve download failed."
    fi
    if [ ! -d "$gdir" ]; then
        local url
        url=$(curl -s https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/latest \
            | grep browser_download_url | grep '\.zip"' | head -1 | cut -d '"' -f 4)
        if [ -n "$url" ]; then
            wget -q "$url" -O /tmp/ghidra.zip
            mkdir -p "$gdir"
            unzip -o /tmp/ghidra.zip -d "$gdir" --strip-components=1 2>/dev/null || \
                unzip -o /tmp/ghidra.zip -d "$gdir"
            rm -f /tmp/ghidra.zip
            chmod +x "$gdir/ghidraRun" 2>/dev/null || true
        fi
    fi
}

# ==========================================
# Main
# ==========================================
log_info "Updating package lists..."
sudo apt-get update -y

log_info "Tip: type 's' + Enter during any step to skip it. Ctrl-C also skips."
echo ""

run_step "Kali metapackages" step_metapackages || true
run_step "StegDetect"       step_stegdetect   || true
run_step "RsaCtfTool"       step_rsactftool   || true
run_step "CyberChef"        step_cyberchef    || true
run_step "Python gaps"      step_python_gaps  || true
run_step "Apt gaps"         step_apt_gaps     || true
run_step "GUI downloads"    step_gui_downloads || true

# Summary always runs
CYBERCHEF_HTML="$INSTALL_DIR/cyberchef/CyberChef.html"
STEGSOLVE_JAR="$INSTALL_DIR/stegsolve.jar"
GHIDRA_DIR="$INSTALL_DIR/ghidra"

log_info "--- Done ---"
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