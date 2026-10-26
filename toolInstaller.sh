#!/bin/bash
# CTF Tool Installer Script (Kali Linux optimized)
# Installs StegDetect, RsaCtfTool, CyberChef, and supplements Kali's metapackages.
# Idempotent: re-running skips anything already present.

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

log_info "Updating package lists..."
sudo apt-get update -y

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

# ==========================================
# 0. Kali metapackages (bulk coverage)
# ==========================================
# These pull in the tool categories Kali already curates, so we don't
# hand-pick versions that may drift or conflict.
log_info "--- Installing Kali metapackages ---"
install_apt_packages kali-tools-crypto-stego kali-tools-forensics \
                     kali-tools-reverse-engineering kali-tools-passwords

# ==========================================
# 1. StegDetect (LikeNmuFF)
# ==========================================
log_info "--- StegDetect ---"
if command -v stegdetect &>/dev/null; then
    log_info "Already installed: $(command -v stegdetect)"
else
    # Dependencies mostly covered by metapackages; add only gaps.
    install_apt_packages file binutils python3 libimage-exiftool-perl \
                         zbar-tools stegsnow mediainfo sox binwalk steghide ruby wget
    if ! gem list zsteg -i &>/dev/null; then
        log_info "Installing zsteg gem..."
        sudo gem install zsteg
    fi
    mkdir -p "$INSTALL_DIR"
    [ -d "$INSTALL_DIR/stegdetect" ] || git clone "$STEGDETECT_REPO" "$INSTALL_DIR/stegdetect"
    cd "$INSTALL_DIR/stegdetect" && git pull --ff-only 2>/dev/null || true
    chmod +x stegdetect.sh && sudo ./stegdetect.sh --install
fi

# ==========================================
# 2. RsaCtfTool (venv + global wrapper)
# ==========================================
log_info "--- RsaCtfTool ---"
if command -v RsaCtfTool &>/dev/null || [ -f /usr/local/bin/RsaCtfTool ]; then
    log_info "Already installed."
else
    install_apt_packages python3-venv python3-pip libgmp3-dev libmpc-dev
    mkdir -p "$INSTALL_DIR"
    [ -d "$INSTALL_DIR/RsaCtfTool" ] || git clone "$RSACTFTOOL_REPO" "$INSTALL_DIR/RsaCtfTool"
    cd "$INSTALL_DIR/RsaCtfTool" && git pull --ff-only 2>/dev/null || true
    [ -d venv ] || python3 -m venv venv
    source venv/bin/activate && pip install -e . && deactivate
    sudo tee /usr/local/bin/RsaCtfTool >/dev/null <<EOF
#!/bin/bash
source "$INSTALL_DIR/RsaCtfTool/venv/bin/activate"
python "$INSTALL_DIR/RsaCtfTool/RsaCtfTool.py" "\$@"
EOF
    sudo chmod +x /usr/local/bin/RsaCtfTool
fi

# ==========================================
# 3. CyberChef (static HTML; no Docker)
# ==========================================
log_info "--- CyberChef (static) ---"
CYBERCHEF_DIR="$INSTALL_DIR/cyberchef"
CYBERCHEF_HTML="$CYBERCHEF_DIR/CyberChef.html"
if [ -f "$CYBERCHEF_HTML" ]; then
    log_info "Already present: $CYBERCHEF_HTML"
else
    mkdir -p "$CYBERCHEF_DIR"
    ZIP_URL=$(curl -s "$CYBERCHEF_API" | grep browser_download_url | grep '\.zip"' | head -1 | cut -d '"' -f 4)
    if [ -z "$ZIP_URL" ]; then
        log_error "GitHub API rate-limited or unreachable; set ZIP_URL manually."
    else
        wget -q "$ZIP_URL" -O /tmp/cyberchef.zip
        unzip -o /tmp/cyberchef.zip -d "$CYBERCHEF_DIR"
        SRC=$(find "$CYBERCHEF_DIR" -maxdepth 1 -name 'CyberChef_*.html' | head -1)
        [ -n "$SRC" ] && mv "$SRC" "$CYBERCHEF_HTML" && log_info "Saved: $CYBERCHEF_HTML"
        rm -f /tmp/cyberchef.zip
    fi
fi

# ==========================================
# 4. Kali's Python tooling gaps
# ==========================================
# Kali ships many of these; install only if the import/command is missing.
log_info "--- Python supplements ---"
pip3 show volatility3 &>/dev/null || pip3 install --user volatility3
pip3 show stegoveritas &>/dev/null || pip3 install --user stegoveritas
pip3 show cyberchef-py &>/dev/null || pip3 install --user cyberchef-py
# pwntools/pycryptodome/z3 are in kali-tools-*; only add if import fails.
python3 -c "import pwn" 2>/dev/null || pip3 install --user pwntools
python3 -c "import Crypto" 2>/dev/null || pip3 install --user pycryptodome
python3 -c "import z3" 2>/dev/null || pip3 install --user z3-solver

# ==========================================
# 5. Remaining apt gaps (metapackages cover most)
# ==========================================
log_info "--- Apt gaps ---"
# tshark/wireshark: Kali's sniffing metapackage may not include the GUI.
install_apt_packages tshark wireshark
# Wireshark non-root capture on Kali: the live/install image already sets
# up the wireshark group for the primary user. Only fix if missing.
if command -v wireshark &>/dev/null && ! groups "$USER" | grep -qw wireshark; then
    log_info "Adding $USER to wireshark group..."
    sudo usermod -aG wireshark "$USER"
    log_warn "Log out and back in for capture permission to apply."
fi
# Java for StegSolve/Ghidra (Kali often has default-jre via other packages).
install_apt_packages default-jre

# ==========================================
# 6. GUI tools downloaded from releases
# ==========================================
log_info "--- GUI downloads ---"
STEGSOLVE_JAR="$INSTALL_DIR/stegsolve.jar"
if [ ! -f "$STEGSOLVE_JAR" ]; then
    wget -q -O "$STEGSOLVE_JAR" \
      "https://github.com/zardus/ctf-tools/raw/master/stegsolve/stegsolve.jar" \
      || log_warn "StegSolve download failed."
fi

GHIDRA_DIR="$INSTALL_DIR/ghidra"
if [ ! -d "$GHIDRA_DIR" ]; then
    GHIDRA_URL=$(curl -s https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/latest \
        | grep browser_download_url | grep '\.zip"' | head -1 | cut -d '"' -f 4)
    if [ -n "$GHIDRA_URL" ]; then
        wget -q "$GHIDRA_URL" -O /tmp/ghidra.zip
        mkdir -p "$GHIDRA_DIR"
        unzip -o /tmp/ghidra.zip -d "$GHIDRA_DIR" --strip-components=1 2>/dev/null || \
            unzip -o /tmp/ghidra.zip -d "$GHIDRA_DIR"
        rm -f /tmp/ghidra.zip
        chmod +x "$GHIDRA_DIR/ghidraRun" 2>/dev/null || true
    fi
fi

# ==========================================
# Summary
# ==========================================
log_info "--- Done ---"
echo ""
echo "GUI:"
echo "  CyberChef:      file://$CYBERCHEF_HTML"
echo "  StegSolve:      java -jar $STEGSOLVE_JAR"
echo "  Wireshark:      wireshark"
echo "  Ghidra:         $GHIDRA_DIR/ghidraRun"
echo "  Sonic Visualiser: sonic-visualiser"
echo ""
echo "CLI:"
echo "  vol -f <dump> windows.info   (Volatility 3)"
echo "  RsaCtfTool --help"
echo "  stegdetect --version"
echo "  tshark -r <pcap>"
echo ""
echo "If Wireshark was just added to your group: log out and back in."