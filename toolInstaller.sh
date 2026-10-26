#!/bin/bash
# CTF Tool Installer Script
# Installs StegDetect, RsaCtfTool, and common CTF tools.
# Checks for existing installations before proceeding.

set -e

# --- Configuration ---
INSTALL_DIR="$HOME/ctf-tools"
STEGDETECT_REPO="https://github.com/LikeNmuFF/stegdetect.git"
RSACTFTOOL_REPO="https://github.com/RsaCtfTool/RsaCtfTool.git"

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

# Check if stegdetect command already exists
if command -v stegdetect &> /dev/null; then
    log_info "StegDetect is already installed at $(command -v stegdetect)."
else
    log_info "StegDetect not found. Installing..."
    
    # Install dependencies as per README
    install_apt_packages file binutils python3 libimage-exiftool-perl zbar-tools stegsnow mediainfo sox binwalk steghide ruby wget
    
    # Install zsteg gem if not present
    if ! gem list zsteg -i &> /dev/null; then
        log_info "Installing zsteg ruby gem..."
        sudo gem install zsteg
    else
        log_info "zsteg gem is already installed."
    fi

    # Clone and install the script
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
    
    # Install system dependencies
    install_apt_packages python3 python3-venv python3-pip libgmp3-dev libmpc-dev
    
    mkdir -p "$INSTALL_DIR"
    if [ ! -d "$INSTALL_DIR/RsaCtfTool" ]; then
        git clone "$RSACTFTOOL_REPO" "$INSTALL_DIR/RsaCtfTool"
    else
        log_info "RsaCtfTool repository already exists. Pulling latest..."
        (cd "$INSTALL_DIR/RsaCtfTool" && git pull)
    fi
    
    cd "$INSTALL_DIR/RsaCtfTool"
    
    # Create and use venv as per README
    if [ ! -d "venv" ]; then
        python3 -m venv venv
    fi
    source venv/bin/activate
    pip install -e .
    
    # Create a wrapper script in /usr/local/bin so it's globally accessible
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
# 3. Install Common CTF Tools by Category
# ==========================================
log_info "--- Installing Common CTF Tools ---"

# Categories and tools based on common CTF toolkits
# Steganography & Forensics
install_apt_packages steghide exiftool binwalk foremost pngcheck imagemagick zbar-tools \
                     tesseract-ocr poppler-utils unzip \
                     sleuthkit autopsy scalpel bulk-extractor

# Cryptography & Password Cracking
install_apt_packages hashcat john crunch \
                     sagemath openssl libssl-dev

# General Reversing / Pwn / Misc
install_apt_packages gdb radare2 binutils strace ltrace \
                     netcat-openbsd socat \
                     nmap \
                     python3-pip python3-dev build-essential \
                     file strings xxd hexdump

# Python packages commonly used in CTFs
log_info "Installing common Python packages..."
pip3 install --user pwntools pycryptodome z3-solver ROPgadget 2>/dev/null || {
    log_warn "Some pip installs failed. Trying with --break-system-packages if needed."
    pip3 install --user --break-system-packages pwntools pycryptodome z3-solver ROPgadget
}

log_info "--- Installation Complete ---"
echo "You may need to restart your shell or run 'source ~/.bashrc' to update your PATH."
echo "Verify installations with:"
echo "  stegdetect --version"
echo "  RsaCtfTool --help"