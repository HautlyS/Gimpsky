#!/bin/bash
###############################################################################
# Whisk-GIMP Integration - Universal Installer
#
# Installs the complete Whisk AI integration for GIMP on any system.
# Supports: Debian/Ubuntu, Fedora/RHEL, Arch Linux, macOS (partial)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/YOUR_USER/whisk-gimp/main/install.sh | bash
#   OR
#   chmod +x install.sh && ./install.sh
###############################################################################

set -euo pipefail

# Configuration
INSTALL_DIR="${WHISK_INSTALL_DIR:-/opt/whisk-gimp}"
REPO_URL="https://github.com/YOUR_USER/whisk-gimp.git"
WHISK_API_REPO="https://github.com/rohitaryal/whisk-api.git"
BRIDGE_PORT="${WHISK_BRIDGE_PORT:-9876}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# State tracking
PACKAGES_TO_INSTALL=()
SERVICES_INSTALLED=()

###############################################################################
# Helper Functions
###############################################################################

log_info()     { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success()  { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()     { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()    { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()     { echo -e "\n${CYAN}═══ $1 ═══${NC}"; }

die() {
    log_error "$1"
    echo "Installation failed. Check the error above."
    exit 1
}

# Detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME=$ID
        OS_VERSION=$VERSION_ID
    elif [ "$(uname)" = "Darwin" ]; then
        OS_NAME="macos"
        OS_VERSION=$(sw_vers -productVersion)
    else
        OS_NAME="unknown"
    fi
    log_info "Detected OS: $OS_NAME $OS_VERSION"
}

# Package managers
install_packages_debian() {
    log_info "Installing packages via apt..."
    apt-get update -qq
    apt-get install -y -qq "$@" >/dev/null 2>&1
}

install_packages_fedora() {
    log_info "Installing packages via dnf..."
    dnf install -y -q "$@" >/dev/null 2>&1
}

install_packages_arch() {
    log_info "Installing packages via pacman..."
    pacman -S --noconfirm --needed "$@" >/dev/null 2>&1
}

install_packages_macos() {
    log_info "Installing packages via brew..."
    brew install "$@" >/dev/null 2>&1
}

install_packages() {
    PACKAGES_TO_INSTALL=("$@")
    case "$OS_NAME" in
        ubuntu|debian)    install_packages_debian "$@" ;;
        fedora|rhel|centos) install_packages_fedora "$@" ;;
        arch|manjaro)     install_packages_arch "$@" ;;
        macos)            install_packages_macos "$@" ;;
        *)                die "Unsupported OS: $OS_NAME" ;;
    esac
}

# Check if command exists
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Setup Node.js from nvm if available
setup_nvm_node() {
    # Try multiple possible nvm locations
    local possible_nvm_paths=(
        "$HOME/.nvm"
        "/home/node/.nvm"
        "/root/.nvm"
    )
    
    # Add SUDO_USER's home if available
    if [ -n "${SUDO_USER:-}" ]; then
        possible_nvm_paths+=("/home/$SUDO_USER/.nvm")
    fi
    
    for nvm_path in "${possible_nvm_paths[@]}"; do
        if [ -s "$nvm_path/nvm.sh" ]; then
            export NVM_DIR="$nvm_path"
            . "$NVM_DIR/nvm.sh"
            if has_cmd node; then
                log_success "Node.js from nvm ($nvm_path): $(node --version)"
                return 0
            fi
        fi
    done

    # Also try to find nvm anywhere
    if ! has_cmd node; then
        local nvm_location=$(find /home -name "nvm.sh" -path "*/.nvm/*" 2>/dev/null | head -1)
        if [ -n "$nvm_location" ]; then
            export NVM_DIR=$(dirname "$nvm_location")
            . "$NVM_DIR/nvm.sh"
            if has_cmd node; then
                log_success "Node.js from nvm ($NVM_DIR): $(node --version)"
                return 0
            fi
        fi
    fi

    log_warn "Could not find nvm-installed Node.js"
}

###############################################################################
# Installation Steps
###############################################################################

step_banner() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║          Whisk AI - GIMP Integration Installer          ║"
    echo "║                                                         ║"
    echo "║  AI image generation tools integrated into GIMP         ║"
    echo "║  Features: Generate, Refine, Caption, Gallery           ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
}

step_check_root() {
    log_step "Checking permissions"
    if [ "$(id -u)" -ne 0 ]; then
        log_warn "Not running as root. Some features may require sudo."
        USE_SUDO="sudo"
    else
        USE_SUDO=""
    fi

    # Preserve nvm and custom PATH when using sudo
    if [ -n "$USE_SUDO" ]; then
        # Export PATH explicitly for sudo commands
        export SUDO_PATH="$PATH"
    fi
}

step_detect_os() {
    log_step "Detecting operating system"
    detect_os
}

step_install_dependencies() {
    log_step "Installing dependencies"

    # Setup PATH for sudo if needed
    if [ -n "$USE_SUDO" ] && [ -n "$SUDO_PATH" ]; then
        export PATH="$SUDO_PATH"
    fi

    # Try to load nvm for Node.js
    setup_nvm_node

    # Node.js
    if ! has_cmd node; then
        log_info "Installing Node.js..."
        case "$OS_NAME" in
            ubuntu|debian)
                curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
                install_packages nodejs
                ;;
            fedora|rhel)
                install_packages nodejs
                ;;
            arch)
                install_packages nodejs npm
                ;;
            macos)
                install_packages node
                ;;
        esac
    fi
    if has_cmd node; then
        log_success "Node.js: $(node --version)"
    else
        die "Node.js installation failed"
    fi

    # npm/bun
    if ! has_cmd bun && ! has_cmd npm; then
        log_info "Installing npm..."
        case "$OS_NAME" in
            ubuntu|debian|fedora|rhel|arch) install_packages npm ;;
            macos) install_packages npm ;;
        esac
    fi

    # TypeScript (for building whisk-api)
    if ! has_cmd tsc; then
        log_info "Installing TypeScript..."
        npm install -g typescript >/dev/null 2>&1 || true
    fi

    # GIMP
    if ! has_cmd gimp; then
        log_info "Installing GIMP..."
        case "$OS_NAME" in
            ubuntu|debian)
                install_packages gimp gimp-plugin-registry
                ;;
            fedora|rhel)
                install_packages gimp
                ;;
            arch)
                install_packages gimp
                ;;
            macos)
                log_warn "GIMP on macOS: Please install from https://www.gimp.org/downloads/"
                ;;
        esac
    fi
    if has_cmd gimp; then
        log_success "GIMP: $(gimp --version 2>&1 | head -1)"
    fi

    # Python3 + GTK
    if ! python3 -c "import gi" 2>/dev/null; then
        log_info "Installing Python GTK bindings..."
        case "$OS_NAME" in
            ubuntu|debian)
                install_packages python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-gdkpixbuf-2.0
                ;;
            fedora|rhel)
                install_packages python3-gobject gtk3 gdk-pixbuf2
                ;;
            arch)
                install_packages python-gobject gtk3 gdk-pixbuf2
                ;;
            macos)
                install_packages pygobject3 gtk+3
                ;;
        esac
    fi
    log_success "Python GTK: OK"

    # curl, wget
    if ! has_cmd curl; then
        install_packages curl
    fi
}

step_clone_repos() {
    log_step "Setting up Whisk API"

    # Setup PATH for sudo if needed
    if [ -n "$USE_SUDO" ] && [ -n "$SUDO_PATH" ]; then
        export PATH="$SUDO_PATH"
    fi

    local whisk_api_dir="$INSTALL_DIR/whisk-api"
    if [ ! -d "$whisk_api_dir" ]; then
        log_info "Cloning whisk-api..."
        mkdir -p "$INSTALL_DIR"
        git clone "$WHISK_API_REPO" "$whisk_api_dir"
    fi

    cd "$whisk_api_dir"

    # Install dependencies - ensure we're in the right directory
    log_info "Installing whisk-api dependencies..."
    if has_cmd bun; then
        # Clean install to avoid PathAlreadyExists and cache errors
        rm -rf node_modules bun.lockb 2>/dev/null || true
        
        # Clear bun's global cache if it exists
        if [ -d "$HOME/.bun/install/cache" ]; then
            log_info "Clearing bun cache..."
            rm -rf "$HOME/.bun/install/cache" 2>/dev/null || true
        fi
        
        bun install 2>&1 || {
            log_warn "bun install failed, falling back to npm..."
            rm -rf node_modules bun.lockb 2>/dev/null || true
            npm install 2>&1 || die "Failed to install whisk-api dependencies"
        }
    else
        npm install 2>&1 || die "Failed to install whisk-api dependencies"
    fi

    # Install TypeScript type definitions if missing
    if [ ! -d "node_modules/@types/node" ] || [ ! -d "node_modules/@types/yargs" ]; then
        log_info "Installing TypeScript type definitions..."
        npm install --save-dev @types/node @types/yargs 2>&1 || true
    fi

    # Build
    if [ ! -d "dist" ] || [ ! -f "dist/index.js" ]; then
        log_info "Building whisk-api..."

        # Fix tsconfig.json to include rootDir if it's missing
        if [ -f "tsconfig.json" ]; then
            if ! grep -q '"rootDir"' tsconfig.json; then
                log_info "Fixing tsconfig.json to include rootDir..."
                # Add rootDir before outDir
                sed -i 's/"outDir":/"rootDir": ".\/src",\n        "outDir":/' tsconfig.json
            fi
        fi

        # Try bun first, then npm+tsc
        if has_cmd bun; then
            bun run build 2>&1 >/dev/null || true
        fi

        if [ ! -d "dist" ] || [ ! -f "dist/index.js" ]; then
            # Check if package.json has build script
            if grep -q '"build"' package.json 2>/dev/null; then
                npm run build 2>&1 >/dev/null || {
                    # Build may fail on types but still produce JS files
                    if [ -d "dist" ] && [ -f "dist/index.js" ]; then
                        log_success "whisk-api built (with type warnings)"
                    else
                        log_error "TypeScript build failed"
                        log_warn "Continuing anyway, you may need to build manually later"
                    fi
                }
            else
                log_warn "No build script found in package.json"
            fi
        fi
    fi

    if [ -d "dist" ] && [ -f "dist/index.js" ]; then
        log_success "whisk-api: Built successfully"
    else
        log_warn "whisk-api: Build may have issues, continuing anyway..."
    fi
}

step_install_application() {
    log_step "Installing Whisk-GIMP Integration"

    # Setup PATH for sudo if needed
    if [ -n "$USE_SUDO" ] && [ -n "$SUDO_PATH" ]; then
        export PATH="$SUDO_PATH"
    fi

    # Create directories
    $USE_SUDO mkdir -p "$INSTALL_DIR"
    $USE_SUDO mkdir -p "$INSTALL_DIR/output"
    $USE_SUDO mkdir -p "$INSTALL_DIR/logs"
    $USE_SUDO mkdir -p "$INSTALL_DIR/pids"
    mkdir -p "$HOME/.config/whisk-gimp"
    mkdir -p "$HOME/.config/whisk-gimp/logs"
    mkdir -p "$HOME/.config/whisk-gimp/output"

    # Resolve the script's directory (handles symlinks and relative paths)
    local script_dir="$SCRIPT_DIR"

    # Verify source files exist before copying
    if [ ! -f "$script_dir/src/bridge-server.js" ]; then
        die "Source file bridge-server.js not found in $script_dir/src/"
    fi
    if [ ! -f "$script_dir/src/whisk_gimp_gui.py" ]; then
        die "Source file whisk_gimp_gui.py not found in $script_dir/src/"
    fi
    if [ ! -f "$script_dir/scripts/whisk-gimp.sh" ]; then
        die "Source file whisk-gimp.sh not found in $script_dir/scripts/"
    fi

    # Copy files
    log_info "Copying application files..."
    $USE_SUDO cp "$script_dir/src/bridge-server.js" "$INSTALL_DIR/"
    $USE_SUDO cp "$script_dir/src/whisk_gimp_gui.py" "$INSTALL_DIR/"
    $USE_SUDO cp "$script_dir/scripts/whisk-gimp.sh" "$INSTALL_DIR/"
    $USE_SUDO chmod +x "$INSTALL_DIR/whisk-gimp.sh"
    $USE_SUDO chmod +x "$INSTALL_DIR/whisk_gimp_gui.py"

    # Update bridge server import path to use local whisk-api
    if [ -f "$INSTALL_DIR/bridge-server.js" ]; then
        $USE_SUDO sed -i "s|/home/workspace/whisk-api/dist/index.js|$INSTALL_DIR/whisk-api/dist/index.js|g" "$INSTALL_DIR/bridge-server.js" 2>/dev/null || true
    fi

    # Install GIMP Script-Fu plugin
    local gimp_scripts_dir="$HOME/.config/GIMP/2.10/scripts"
    mkdir -p "$gimp_scripts_dir"
    cp "$script_dir/gimp-scripts/whisk_ai_tools.scm" "$gimp_scripts_dir/"
    log_success "GIMP Script-Fu plugin: Installed"

    # Create symlink for easy access
    if [ -d /usr/local/bin ]; then
        $USE_SUDO ln -sf "$INSTALL_DIR/whisk-gimp.sh" /usr/local/bin/whisk-gimp 2>/dev/null || true
    fi

    log_success "Application files: Installed to $INSTALL_DIR"
}

step_create_desktop_entry() {
    log_step "Creating desktop integration"

    local desktop_file="$HOME/.local/share/applications/whisk-gimp.desktop"
    mkdir -p "$(dirname "$desktop_file")"

    cat > "$desktop_file" << EOF
[Desktop Entry]
Name=Whisk AI for GIMP
Comment=AI image generation tools integrated with GIMP
Exec=$INSTALL_DIR/whisk-gimp.sh start
Icon=org.gimp.GIMP
Terminal=false
Type=Application
Categories=Graphics;2DGraphics;RasterGraphics;GTK;
Keywords=AI;Image;Generation;GIMP;
EOF

    log_success "Desktop entry: Created"
}

step_create_config() {
    log_step "Creating configuration"

    local config_file="$HOME/.config/whisk-gimp/config.json"
    if [ ! -f "$config_file" ]; then
        cat > "$config_file" << 'EOF'
{
  "cookie": "",
  "session_id": "",
  "aspect_ratio": "IMAGE_ASPECT_RATIO_LANDSCAPE",
  "model": "IMAGEN_3_5",
  "seed": 0
}
EOF
        log_info "Config created at: $config_file"
        log_warn "You need to configure your Google cookie after first launch"
    else
        log_info "Config already exists"
    fi
}

step_post_install() {
    log_step "Post-installation setup"

    # Create wrapper script in user's PATH
    local wrapper="$HOME/.local/bin/whisk-gimp"
    mkdir -p "$(dirname "$wrapper")"
    cat > "$wrapper" << EOF
#!/bin/bash
# Whisk-GIMP wrapper
exec "$INSTALL_DIR/whisk-gimp.sh" "\$@"
EOF
    chmod +x "$wrapper"

    # Add to PATH if needed
    if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc" 2>/dev/null || true
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc" 2>/dev/null || true
    fi

    log_success "Command 'whisk-gimp' available in PATH"
}

step_verify_installation() {
    log_step "Verifying installation"

    local errors=0

    # Check files
    if [ -f "$INSTALL_DIR/bridge-server.js" ]; then
        log_success "Bridge server script"
    else
        log_error "Bridge server script missing"
        errors=$((errors + 1))
    fi

    if [ -f "$INSTALL_DIR/whisk_gimp_gui.py" ]; then
        log_success "GUI application"
    else
        log_error "GUI application missing"
        errors=$((errors + 1))
    fi

    if [ -f "$INSTALL_DIR/whisk-gimp.sh" ]; then
        log_success "Management script"
    else
        log_error "Management script missing"
        errors=$((errors + 1))
    fi

    # Check whisk-api build
    if [ -d "$INSTALL_DIR/whisk-api/dist" ]; then
        log_success "whisk-api built"
    else
        log_warn "whisk-api not built (may need manual build)"
    fi

    # Check GIMP plugin
    if [ -f "$HOME/.config/GIMP/2.10/scripts/whisk_ai_tools.scm" ]; then
        log_success "GIMP Script-Fu plugin"
    else
        log_warn "GIMP Script-Fu plugin not found"
    fi

    # Check Python GTK
    if python3 -c "import gi; gi.require_version('Gtk', '3.0'); from gi.repository import Gtk" 2>/dev/null; then
        log_success "Python GTK bindings"
    else
        log_error "Python GTK bindings missing"
        errors=$((errors + 1))
    fi

    if [ $errors -gt 0 ]; then
        echo ""
        log_warn "Installation completed with $errors warning(s)"
    else
        log_success "All checks passed!"
    fi
}

step_print_usage() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              Installation Complete!                     ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "Installation directory: $INSTALL_DIR"
    echo ""
    echo "Quick Start:"
    echo "  1. Start all services:"
    echo "     whisk-gimp start"
    echo ""
    echo "  2. Configure your Google cookie in the GUI Settings tab"
    echo ""
    echo "Management Commands:"
    echo "  whisk-gimp start      - Start all services"
    echo "  whisk-gimp stop       - Stop all services"
    echo "  whisk-gimp restart    - Restart everything"
    echo "  whisk-gimp status     - Check service status"
    echo "  whisk-gimp logs       - View logs"
    echo "  whisk-gimp configure  - Configure cookie"
    echo ""
    echo "Documentation: $INSTALL_DIR/README.md"
    echo "Support: https://github.com/YOUR_USER/whisk-gimp/issues"
    echo ""
}

###############################################################################
# Main Installation Flow
###############################################################################

main() {
    # Save the script's directory at the very beginning (before any cd commands)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    step_banner
    step_check_root
    step_detect_os
    step_install_dependencies
    step_clone_repos
    step_install_application
    step_create_desktop_entry
    step_create_config
    step_post_install
    step_verify_installation
    step_print_usage
}

# Run installation
main "$@"
