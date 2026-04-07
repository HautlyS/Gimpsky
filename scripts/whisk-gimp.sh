#!/bin/bash
###############################################################################
# Whisk-GIMP Integration - Management Script
#
# Usage:
#   ./whisk-gimp.sh start      - Start all services
#   ./whisk-gimp.sh stop       - Stop all services
#   ./whisk-gimp.sh restart    - Restart all services
#   ./whisk-gimp.sh status     - Show service status
#   ./whisk-gimp.sh logs       - Show logs
#   ./whisk-gimp.sh gui        - Start GUI only
#   ./whisk-gimp.sh gimp       - Start GIMP only
#   ./whisk-gimp.sh bridge     - Start bridge server only
###############################################################################

set -euo pipefail

# Configuration
INSTALL_DIR="/opt/whisk-gimp"
BRIDGE_SCRIPT="$INSTALL_DIR/bridge-server.js"
GUI_SCRIPT="$INSTALL_DIR/whisk_gimp_gui.py"
CONFIG_DIR="$HOME/.config/whisk-gimp"
CONFIG_FILE="$CONFIG_DIR/config.json"
OUTPUT_DIR="$INSTALL_DIR/output"
LOG_DIR="$CONFIG_DIR/logs"
PID_DIR="$CONFIG_DIR/pids"

BRIDGE_PORT="${WHISK_BRIDGE_PORT:-9876}"
DISPLAY_NUM="${DISPLAY_NUM:-99}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Ensure directories exist
mkdir -p "$CONFIG_DIR" "$OUTPUT_DIR" "$LOG_DIR" "$PID_DIR"

# Logging
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if a process is running by PID file
is_running() {
    local pidfile="$1"
    if [ -f "$pidfile" ]; then
        local pid
        pid=$(cat "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Get PID from file
get_pid() {
    local pidfile="$1"
    if [ -f "$pidfile" ]; then
        cat "$pidfile"
    else
        echo ""
    fi
}

# Save PID to file
save_pid() {
    local pidfile="$1"
    local pid="$2"
    echo "$pid" > "$pidfile"
}

# Wait for bridge server to be ready
wait_for_bridge() {
    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if curl -s "http://127.0.0.1:$BRIDGE_PORT/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
        attempt=$((attempt + 1))
    done
    return 1
}

###############################################################################
# Service Management Functions
###############################################################################

start_bridge() {
    local pidfile="$PID_DIR/bridge.pid"
    local logfile="$LOG_DIR/bridge.log"

    if is_running "$pidfile"; then
        log_warn "Bridge server already running (PID: $(get_pid "$pidfile"))"
        return 0
    fi

    # Check if bridge script exists
    if [ ! -f "$BRIDGE_SCRIPT" ]; then
        log_error "Bridge server script not found: $BRIDGE_SCRIPT"
        return 1
    fi

    log_info "Starting bridge server on port $BRIDGE_PORT..."

    # Start bridge server
    cd "$INSTALL_DIR"
    NODE_PATH="$INSTALL_DIR" nohup node "$BRIDGE_SCRIPT" > "$logfile" 2>&1 &
    local pid=$!
    save_pid "$pidfile" "$pid"

    # Wait for it to be ready
    if wait_for_bridge; then
        log_success "Bridge server started (PID: $pid, Port: $BRIDGE_PORT)"
        return 0
    else
        log_error "Bridge server failed to start. Check log: $logfile"
        rm -f "$pidfile"
        return 1
    fi
}

stop_bridge() {
    local pidfile="$PID_DIR/bridge.pid"

    if ! is_running "$pidfile"; then
        log_info "Bridge server is not running"
        rm -f "$pidfile"
        return 0
    fi

    local pid
    pid=$(get_pid "$pidfile")
    log_info "Stopping bridge server (PID: $pid)..."

    kill "$pid" 2>/dev/null || true

    # Wait for graceful shutdown
    local wait_count=0
    while kill -0 "$pid" 2>/dev/null && [ $wait_count -lt 10 ]; do
        sleep 1
        wait_count=$((wait_count + 1))
    done

    # Force kill if still running
    if kill -0 "$pid" 2>/dev/null; then
        log_warn "Force killing bridge server..."
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$pidfile"
    log_success "Bridge server stopped"
}

start_gui() {
    local pidfile="$PID_DIR/gui.pid"
    local logfile="$LOG_DIR/gui.log"

    if is_running "$pidfile"; then
        log_warn "GUI already running (PID: $(get_pid "$pidfile"))"
        return 0
    fi

    # Ensure bridge is running
    if ! curl -s "http://127.0.0.1:$BRIDGE_PORT/health" >/dev/null 2>&1; then
        log_info "Bridge server not running, starting it first..."
        start_bridge || return 1
    fi

    log_info "Starting Whisk GUI..."

    # Set display
    export DISPLAY=":$DISPLAY_NUM"

    # Start GUI
    nohup python3 "$GUI_SCRIPT" > "$logfile" 2>&1 &
    local pid=$!
    save_pid "$pidfile" "$pid"

    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        log_success "GUI started (PID: $pid)"
        return 0
    else
        log_error "GUI failed to start. Check log: $logfile"
        rm -f "$pidfile"
        return 1
    fi
}

stop_gui() {
    local pidfile="$PID_DIR/gui.pid"

    if ! is_running "$pidfile"; then
        log_info "GUI is not running"
        rm -f "$pidfile"
        return 0
    fi

    local pid
    pid=$(get_pid "$pidfile")
    log_info "Stopping GUI (PID: $pid)..."

    kill "$pid" 2>/dev/null || true
    sleep 2

    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$pidfile"
    log_success "GUI stopped"
}

start_gimp() {
    local pidfile="$PID_DIR/gimp.pid"

    if is_running "$pidfile"; then
        log_warn "GIMP already running (PID: $(get_pid "$pidfile"))"
        return 0
    fi

    log_info "Starting GIMP..."

    export DISPLAY=":$DISPLAY_NUM"

    nohup gimp > "$LOG_DIR/gimp.log" 2>&1 &
    local pid=$!
    save_pid "$pidfile" "$pid"

    sleep 3
    if kill -0 "$pid" 2>/dev/null; then
        log_success "GIMP started (PID: $pid)"
        return 0
    else
        log_error "GIMP failed to start"
        rm -f "$pidfile"
        return 1
    fi
}

stop_gimp() {
    local pidfile="$PID_DIR/gimp.pid"

    if ! is_running "$pidfile"; then
        log_info "GIMP is not running"
        rm -f "$pidfile"
        return 0
    fi

    local pid
    pid=$(get_pid "$pidfile")
    log_info "Stopping GIMP (PID: $pid)..."

    kill "$pid" 2>/dev/null || true
    rm -f "$pidfile"
    log_success "GIMP stopped"
}

###############################################################################
# Main Commands
###############################################################################

cmd_start() {
    echo "========================================="
    echo "  Whisk AI - GIMP Integration"
    echo "========================================="
    echo ""

    # Start bridge server
    start_bridge || exit 1
    echo ""

    # Start GUI
    start_gui
    echo ""

    # Start GIMP
    start_gimp
    echo ""

    echo "========================================="
    log_success "All services started!"
    echo "========================================="
    echo ""
    echo "Service PIDs:"
    echo "  Bridge:    $(get_pid "$PID_DIR/bridge.pid" 2>/dev/null || echo 'N/A')"
    echo "  GUI:       $(get_pid "$PID_DIR/gui.pid" 2>/dev/null || echo 'N/A')"
    echo "  GIMP:      $(get_pid "$PID_DIR/gimp.pid" 2>/dev/null || echo 'N/A')"
    echo ""
    echo "Logs: $LOG_DIR/"
    echo ""
}

cmd_stop() {
    echo "Stopping all services..."
    echo ""

    stop_gimp
    stop_gui
    stop_bridge

    echo ""
    log_success "All services stopped"
}

cmd_restart() {
    cmd_stop
    sleep 2
    cmd_start
}

cmd_status() {
    echo "========================================="
    echo "  Service Status"
    echo "========================================="
    echo ""

    # Bridge Server
    if curl -s "http://127.0.0.1:$BRIDGE_PORT/health" >/dev/null 2>&1; then
        local health
        health=$(curl -s "http://127.0.0.1:$BRIDGE_PORT/health")
        log_success "Bridge Server (Port $BRIDGE_PORT) - Running"
        echo "           Health: $health"
    else
        log_error "Bridge Server - Stopped"
    fi

    # GUI
    if is_running "$PID_DIR/gui.pid"; then
        log_success "Whisk GUI (PID: $(get_pid "$PID_DIR/gui.pid")) - Running"
    else
        log_error "Whisk GUI - Stopped"
    fi

    # GIMP
    if is_running "$PID_DIR/gimp.pid"; then
        log_success "GIMP (PID: $(get_pid "$PID_DIR/gimp.pid")) - Running"
    else
        log_error "GIMP - Stopped"
    fi

    echo ""
    echo "Configuration:"
    echo "  Config: $CONFIG_FILE"
    if [ -f "$CONFIG_FILE" ]; then
        local has_cookie
        has_cookie=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print('Yes' if c.get('cookie') else 'No')" 2>/dev/null || echo "Unknown")
        echo "  Cookie configured: $has_cookie"
    else
        echo "  Cookie configured: No"
    fi

    echo ""
    echo "Output Directory: $OUTPUT_DIR"
    if [ -d "$OUTPUT_DIR" ]; then
        local file_count
        file_count=$(ls -1 "$OUTPUT_DIR" 2>/dev/null | wc -l)
        echo "  Generated files: $file_count"
    fi

    echo ""
}

cmd_logs() {
    local service="${1:-all}"

    case "$service" in
        bridge)
            tail -f "$LOG_DIR/bridge.log" 2>/dev/null || echo "No bridge log found"
            ;;
        gui)
            tail -f "$LOG_DIR/gui.log" 2>/dev/null || echo "No GUI log found"
            ;;
        gimp)
            tail -f "$LOG_DIR/gimp.log" 2>/dev/null || echo "No GIMP log found"
            ;;
        all)
            echo "=== Bridge Server Log (last 20 lines) ==="
            tail -20 "$LOG_DIR/bridge.log" 2>/dev/null || echo "No log"
            echo ""
            echo "=== GUI Log (last 20 lines) ==="
            tail -20 "$LOG_DIR/gui.log" 2>/dev/null || echo "No log"
            echo ""
            echo "=== GIMP Log (last 20 lines) ==="
            tail -20 "$LOG_DIR/gimp.log" 2>/dev/null || echo "No log"
            ;;
        *)
            echo "Unknown service: $service"
            echo "Available: bridge, gui, gimp, all"
            ;;
    esac
}

cmd_configure() {
    echo "========================================="
    echo "  Whisk AI - Initial Configuration"
    echo "========================================="
    echo ""
    echo "To use Whisk AI, you need a Google cookie:"
    echo ""
    echo "1. Install 'Cookie Editor' extension in your browser"
    echo "2. Go to: https://labs.google/fx/tools/whisk/project"
    echo "3. Make sure you're logged in"
    echo "4. Click Cookie Editor icon"
    echo "5. Click Export -> Header String"
    echo "6. Copy the cookie string"
    echo ""
    echo "Then in the Whisk GUI:"
    echo "  1. Go to Settings tab"
    echo "  2. Paste your cookie"
    echo "  3. Click 'Test Connection'"
    echo ""

    # Optionally set cookie via command line
    if [ $# -gt 0 ]; then
        local cookie="$1"
        mkdir -p "$CONFIG_DIR"

        # Load existing config or create new
        local config="{}"
        if [ -f "$CONFIG_FILE" ]; then
            config=$(cat "$CONFIG_FILE")
        fi

        # Update cookie
        echo "$config" | python3 -c "
import sys, json
config = json.load(sys.stdin)
config['cookie'] = '$cookie'
print(json.dumps(config, indent=2))
" > "$CONFIG_FILE"

        log_success "Cookie saved to $CONFIG_FILE"
    fi
}

###############################################################################
# Entry Point
###############################################################################

case "${1:-help}" in
    start)
        cmd_start
        ;;
    stop)
        cmd_stop
        ;;
    restart)
        cmd_restart
        ;;
    status)
        cmd_status
        ;;
    logs)
        cmd_logs "${2:-all}"
        ;;
    gui)
        start_bridge
        start_gui
        ;;
    gimp)
        start_gimp
        ;;
    bridge)
        start_bridge
        ;;
    configure)
        cmd_configure "$2"
        ;;
    help|--help|-h)
        echo "Usage: $0 <command> [options]"
        echo ""
        echo "Commands:"
        echo "  start        - Start all services"
        echo "  stop         - Stop all services"
        echo "  restart      - Restart all services"
        echo "  status       - Show service status"
        echo "  logs [svc]   - Show logs (bridge, gui, gimp, all)"
        echo "  gui          - Start GUI only"
        echo "  gimp         - Start GIMP only"
        echo "  bridge       - Start bridge server only"
        echo "  configure    - Show configuration instructions"
        echo "  help         - Show this help"
        echo ""
        echo "Environment Variables:"
        echo "  WHISK_BRIDGE_PORT  - Bridge server port (default: 9876)"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run '$0 help' for usage"
        exit 1
        ;;
esac
