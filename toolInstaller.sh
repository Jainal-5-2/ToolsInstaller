#!/bin/bash
# CTF Tool Installer Script
# Installs StegDetect, RsaCtfTool, CyberChef, and common CTF tools.
# Checks for existing installations before proceeding.

set -e

# --- Configuration ---
INSTALL_DIR="$HOME/ctf-tools"
STEGDETECT_REPO="https://github.com/LikeNmuFF/stegdetect.git"
RSACTFTOOL_REPO="https://github.com/RsaCtfTool/RsaCtfTool.git"
CYBERCHEF_API="https://api.github.com/repos/gchq/CyberChef/releases/latest"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Check for root (needed for apt) ---
if [[ $EUID -ne 0 ]]; then
   log_warn "This script uses apt-get for system dependencies. You may be prompted for your sudo password."
fi

# --- Update package lists ---
log_info "Updating package lists..."
sudo apt-get update -y

# --- Helper function to install apt packages ---
install_apt_packages() {
    local packages=("$@")
    local to_install=()
    for pkg in "${packages[@]}"; do
        if ! dpkg -s "$pkg" &> /dev/null; then
            to_install+=("$pkg")
        fi
    done
    if [ ${#to_install[@]} -gt 0 ]; then
        log_info "Installing missing packages: ${to_install[*]}"
        sudo apt-get install -y "${to_install[@]}"
    else
        log_info "All specified apt packages are already installed."
    fi
}

# ==========================================
# 1. Install StegDetect (LikeNmuFF version)
# ==========================================
log_info "--- Setting up StegDetect ---"

if command -v stegdetect &> /dev/null; then
    log_info "StegDetect is already installed at $(command -v stegdetect)."
else
    log_info "StegDetect not found. Installing..."
    
    install_apt_packages file binutils python3 libimage-exiftool-perl zbar-tools stegsnow mediainfo sox binwalk steghide ruby wget
    
    if ! gem list zsteg -i &> /dev/null; then
        log_info "Installing zsteg ruby gem..."
        sudo gem install zsteg
    else
        log_info "zsteg gem is already installed."
    fi

    mkdir -p "$INSTALL_DIR"
    if [ ! -d "$INSTALL_DIR/stegdetect" ]; then
        git clone "$STEGDETECT_REPO" "$INSTALL_DIR/stegdetect"
    else
        log_info "StegDetect repository already exists. Pulling latest..."
        (cd "$INSTALL_DIR/stegdetect" && git pull)
    fi
    
    cd "$INSTALL_DIR/stegdetect"
    chmod +x stegdetect.sh
    sudo ./stegdetect.sh --install
    log_info "StegDetect installed to /usr/local/bin/stegdetect"
fi

# ==========================================
# 2. Install RsaCtfTool
# ==========================================
log_info "--- Setting up RsaCtfTool ---"

if command -v RsaCtfTool &> /dev/null || [ -f "/usr/local/bin/RsaCtfTool" ]; then
    log_info "RsaCtfTool appears to be installed."
else
    log_info "RsaCtfTool not found. Installing via virtual environment (recommended method)..."
    
    install_apt_packages python3 python3-venv python3-pip libgmp3-dev libmpc-dev
    
    mkdir -p "$INSTALL_DIR"
    if [ ! -d "$INSTALL_DIR/RsaCtfTool" ]; then
        git clone "$RSACTFTOOL_REPO" "$INSTALL_DIR/RsaCtfTool"
    else
        log_info "RsaCtfTool repository already exists. Pulling latest..."
        (cd "$INSTALL_DIR/RsaCtfTool" && git pull)
    fi
    
    cd "$INSTALL_DIR/RsaCtfTool"
    
    if [ ! -d "venv" ]; then
        python3 -m venv venv
    fi
    source venv/bin/activate
    pip install -e .
    
    if [ ! -f "/usr/local/bin/RsaCtfTool" ]; then
        log_info "Creating wrapper for RsaCtfTool..."
        sudo tee /usr/local/bin/RsaCtfTool > /dev/null <<EOF
#!/bin/bash
source "$INSTALL_DIR/RsaCtfTool/venv/bin/activate"
python "$INSTALL_DIR/RsaCtfTool/RsaCtfTool.py" "\$@"
EOF
        sudo chmod +x /usr/local/bin/RsaCtfTool
    fi
    deactivate
    log_info "RsaCtfTool installed. Run with 'RsaCtfTool'."
fi

# ==========================================
# 3. Install CyberChef (Static Site)
# ==========================================
log_info "--- Setting up CyberChef (Static) ---"

CYBERCHEF_DIR="$INSTALL_DIR/cyberchef"
CYBERCHEF_HTML="$CYBERCHEF_DIR/CyberChef.html"

if [ -f "$CYBERCHEF_HTML" ]; then
    log_info "CyberChef static HTML already exists at: $CYBERCHEF_HTML"
else
    log_info "Downloading latest CyberChef release..."
    mkdir -p "$CYBERCHEF_DIR"
    
    CYBERCHEF_ZIP_URL=$(curl -s "$CYBERCHEF_API" | grep browser_download_url | grep '\.zip"' | head -1 | cut -d '"' -f 4)
    
    if [ -z "$CYBERCHEF_ZIP_URL" ]; then
        log_error "Could not fetch CyberChef release URL. Check network or GitHub API rate limit."
    else
        log_info "Downloading: $CYBERCHEF_ZIP_URL"
        wget -q "$CYBERCHEF_ZIP_URL" -O /tmp/cyberchef.zip
        unzip -o /tmp/cyberchef.zip -d "$CYBERCHEF_DIR"
        
        EXTRACTED_HTML=$(find "$CYBERCHEF_DIR" -maxdepth 1 -name "CyberChef_*.html" | head -1)
        if [ -n "$EXTRACTED_HTML" ]; then
            mv "$EXTRACTED_HTML" "$CYBERCHEF_HTML"
            log_info "CyberChef saved to: $CYBERCHEF_HTML"
        else
            log_warn "Extracted HTML not found. Check: $CYBERCHEF_DIR"
        fi
        rm -f /tmp/cyberchef.zip
    fi
fi

if ! pip3 show cyberchef-py &> /dev/null; then
    log_info "Installing cyberchef-py (Python CyberChef operations)..."
    pip3 install --user cyberchef-py 2>/dev/null || pip3 install --user --break-system-packages cyberchef-py
else
    log_info "cyberchef-py is already installed."
fi

# ==========================================
# 4. Install Additional Analysis Tools
# ==========================================
log_info "--- Installing Additional Analysis Tools ---"

# stegoveritas: automated stego analysis
if ! pip3 show stegoveritas &> /dev/null; then
    log_info "Installing stegoveritas..."
    pip3 install --user stegoveritas 2>/dev/null || pip3 install --user --break-system-packages stegoveritas
    log_info "Running stegoveritas dependency installer..."
    stegoveritas_install_deps 2>/dev/null || log_warn "stegoveritas_install_deps failed; install deps manually if needed."
else
    log_info "stegoveritas is already installed."
fi

# ctfh: interactive menu-driven CTF toolkit
if ! pip3 show ctfh &> /dev/null; then
    log_info "Installing ctfh (interactive CTF toolkit)..."
    pip3 install --user "ctfh[full]" 2>/dev/null || pip3 install --user --break-system-packages "ctfh[full]"
else
    log_info "ctfh is already installed."
fi

# Volatility 3: memory forensics framework
if ! command -v vol &> /dev/null && ! python3 -c "import volatility3" &> /dev/null; then
    log_info "Installing Volatility 3 (memory forensics)..."
    pip3 install --user volatility3 2>/dev/null || pip3 install --user --break-system-packages volatility3
    log_info "Volatility 3 installed. Run as: vol -f <memory_dump> windows.info"
else
    log_info "Volatility 3 appears to be installed."
fi

# YARA: pattern matching for malware/forensics
if ! command -v yara &> /dev/null; then
    log_info "Installing YARA..."
    install_apt_packages yara
    if ! pip3 show yara-python &> /dev/null; then
        pip3 install --user yara-python 2>/dev/null || pip3 install --user --break-system-packages yara-python
    fi
else
    log_info "YARA is already installed."
fi

# ==========================================
# 5. Install Common CTF Tools by Category
# ==========================================
log_info "--- Installing Common CTF Tools ---"

# Steganography & Forensics
install_apt_packages steghide exiftool binwalk foremost pngcheck imagemagick zbar-tools \
                     tesseract-ocr poppler-utils unzip \
                     sleuthkit autopsy scalpel bulk-extractor \
                     sonic-visualiser

# Network Forensics (tshark = CLI, wireshark = GUI)
install_apt_packages tshark wireshark

# Configure Wireshark for non-root packet capture (non-interactive)
if ! groups "$USER" | grep -q '\bwireshark\b'; then
    log_info "Configuring Wireshark for non-root capture..."
    echo "wireshark-common wireshark-common/install-setuid boolean true" | sudo debconf-set-selections
    sudo dpkg-reconfigure -f noninteractive wireshark-common 2>/dev/null || true
    sudo usermod -aG wireshark "$USER" 2>/dev/null || true
    log_info "User added to 'wireshark' group (log out/in for it to take effect)."
fi

# Cryptography & Password Cracking
install_apt_packages hashcat john crunch \
                     sagemath openssl libssl-dev

# General Reversing / Pwn / Misc
install_apt_packages gdb radare2 binutils strace ltrace \
                     netcat-openbsd socat \
                     nmap \
                     python3-pip python3-dev build-essential \
                     file strings xxd hexdump \
                     default-jre

# ==========================================
# 6. Download GUI-based Tools (Non-apt)
# ==========================================
log_info "--- Downloading GUI Tools ---"

# StegSolve: image bit-plane analysis (requires Java, installed above)
STEGSOLVE_JAR="$INSTALL_DIR/stegsolve.jar"
if [ ! -f "$STEGSOLVE_JAR" ]; then
    log_info "Downloading StegSolve..."
    wget -q -O "$STEGSOLVE_JAR" \
        "https://github.com/zardus/ctf-tools/raw/master/stegsolve/stegsolve.jar" \
        || log_warn "StegSolve download failed. Download manually if needed."
    [ -f "$STEGSOLVE_JAR" ] && log_info "StegSolve saved to: $STEGSOLVE_JAR (run: java -jar $STEGSOLVE_JAR)"
else
    log_info "StegSolve already exists at: $STEGSOLVE_JAR"
fi

# Ghidra: reverse engineering suite (requires Java 21+)
GHIDRA_DIR="$INSTALL_DIR/ghidra"
if [ ! -d "$GHIDRA_DIR" ]; then
    log_info "Downloading Ghidra..."
    GHIDRA_URL=$(curl -s https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/latest \
        | grep browser_download_url | grep '\.zip"' | head -1 | cut -d '"' -f 4)
    if [ -n "$GHIDRA_URL" ]; then
        wget -q "$GHIDRA_URL" -O /tmp/ghidra.zip
        mkdir -p "$GHIDRA_DIR"
        unzip -o /tmp/ghidra.zip -d "$GHIDRA_DIR" --strip-components=1 2>/dev/null \
            || unzip -o /tmp/ghidra.zip -d "$GHIDRA_DIR"
        rm -f /tmp/ghidra.zip
        chmod +x "$GHIDRA_DIR/ghidraRun" 2>/dev/null || true
        log_info "Ghidra saved to: $GHIDRA_DIR (run: $GHIDRA_DIR/ghidraRun)"
    else
        log_warn "Could not fetch Ghidra release URL."
    fi
else
    log_info "Ghidra directory already exists at: $GHIDRA_DIR"
fi

# ==========================================
# 7. Python packages commonly used in CTFs
# ==========================================
log_info "Installing common Python packages..."
pip3 install --user pwntools pycryptodome z3-solver ROPgadget 2>/dev/null || {
    log_warn "Some pip installs failed. Trying with --break-system-packages if needed."
    pip3 install --user --break-system-packages pwntools pycryptodome z3-solver ROPgadget
}

# ==========================================
# Summary
# ==========================================
log_info "--- Installation Complete ---"
echo ""
echo "=== GUI Tools ==="
echo "CyberChef:      file://$CYBERCHEF_HTML"
echo "                Or serve: cd $CYBERCHEF_DIR && python3 -m http.server 8000"
echo "StegSolve:      java -jar $STEGSOLVE_JAR"
echo "Sonic Visualiser: sonic-visualiser"
echo "Wireshark:      wireshark   (log out/in first if group was just added)"
echo "Ghidra:         $GHIDRA_DIR/ghidraRun"
echo ""
echo "=== CLI Tools ==="
echo "Volatility 3:   vol -f <memory_dump> windows.info"
echo "RsaCtfTool:     RsaCtfTool --help"
echo "StegDetect:     stegdetect --version"
echo "YARA:           yara --version"
echo "tshark:         tshark -r <pcap>"
echo ""
echo "You may need to restart your shell or run 'source ~/.bashrc' to update your PATH."