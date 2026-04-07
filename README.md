# Whisk AI - GIMP Integration

> Free AI image generation tools (Google Whisk/Imagen) integrated directly into GIMP.

![License](https://img.shields.io/badge/license-MIT-green)
![Node](https://img.shields.io/badge/node-%3E%3D18-green)
![Python](https://img.shields.io/badge/python-3.8+-blue)
![GTK](https://img.shields.io/badge/GTK-3.0-purple)

## Features

- **Text-to-Image Generation** - Generate images from text prompts using Google's IMAGEN 3.5
- **Image Refinement** - Edit/refine images with AI instructions (add, remove, change elements)
- **Image Captioning** - Generate AI descriptions for any image
- **Image-to-Video** - Animate images into short videos (VEO)
- **Reference-Based Generation** - Use subject, scene, and style references
- **Gallery Management** - Browse and manage generated images
- **GIMP Integration** - Full integration via Script-Fu menus

## Quick Install

```bash
# One-line install (Linux)
curl -fsSL https://raw.githubusercontent.com/HautlyS/Gimpsky/master/install.sh | bash

# Or clone and install
git clone https://github.com/HautlyS/Gimpsky.git
cd Gimpsky
chmod +x install.sh
./install.sh
```

## Usage

### Start Services

```bash
Gimpsky start
```

This starts:
- **Bridge Server** (Node.js API on port 9876)
- **Whisk GUI** (GTK3 application)
- **GIMP** (Image editor with Script-Fu plugins)

### Management

```bash
Gimpsky start      # Start all services
Gimpsky stop       # Stop all services
Gimpsky restart    # Restart everything
Gimpsky status     # Check service status
Gimpsky logs       # View logs
Gimpsky configure  # Configure Google cookie
```

## First Time Setup

1. **Get your Google cookie:**
   - Install [Cookie Editor](https://github.com/Moustachauve/cookie-editor) extension
   - Go to https://labs.google/fx/tools/whisk/project
   - Login with your Google account
   - Click Cookie Editor > Export > Header String
   - Copy the cookie

2. **Configure in GUI:**
   - Open Whisk AI GUI
   - Go to Settings tab
   - Paste cookie
   - Click "Test Connection"

3. **Start creating!**

## Architecture

```
┌─────────────────────────────────────────────────┐
│                 Your Local Machine               │
│  ┌─────────────┐      ┌─────────────────────┐   │
│  │  SSH Client │──────│  SSH Tunnel (:9876) │   │
│  └─────────────┘      └─────────────────────┘   │
└──────────────────────────┬──────────────────────┘
                           │ SSH
┌──────────────────────────┴──────────────────────┐
│              Remote Server / EC2                 │
│  ┌─────────────────────────────────────────┐    │
│  │  ┌──────────┐  ┌───────────┐           │    │
│  │  │ Whisk GUI│  │   GIMP    │           │    │
│  │  │  (GTK3)  │  │+ Script-Fu│           │    │
│  │  └────┬─────┘  └─────┬─────┘           │    │
│  │       └──────┬───────┘                  │    │
│  │              │                          │    │
│  │  ┌───────────┴──────────────┐           │    │
│  │  │   Bridge Server (:9876)  │           │    │
│  │  │   Node.js + whisk-api    │           │    │
│  │  └───────────┬──────────────┘           │    │
│  │              │                          │    │
│  │              ▼                          │    │
│  │   ┌─────────────────────┐               │    │
│  │   │  Google Whisk API   │               │    │
│  │   │  (labs.google)      │               │    │
│  │   └─────────────────────┘               │    │
│  └─────────────────────────────────────────┘    │
└─────────────────────────────────────────────────┘
```

## Project Structure

```
Gimpsky/
├── install.sh                 # Universal installer
├── README.md                  # This file
├── src/
│   ├── bridge-server.js       # Node.js HTTP bridge server
│   └── whisk_gimp_gui.py      # GTK3 GUI application
├── scripts/
│   └── Gimpsky.sh          # Service management script
├── gimp-scripts/
│   └── whisk_ai_tools.scm     # GIMP Script-Fu plugin
└── plugins/                   # (future) Additional plugins
```

## API Reference

The bridge server exposes REST endpoints at `http://localhost:9876`:

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/health` | Health check |
| POST | `/init` | Initialize session with cookie |
| POST | `/generate` | Generate image from prompt |
| POST | `/refine` | Refine/edit an image |
| POST | `/caption` | Generate image captions |
| POST | `/animate` | Animate image to video |
| POST | `/project` | Create a new project |
| POST | `/upload` | Upload reference image |
| POST | `/fetch` | Fetch media by ID |
| POST | `/delete` | Delete media |
| GET | `/list-outputs` | List generated files |
| GET | `/output/:file` | Download output file |

### Example: Generate Image

```bash
curl -X POST http://localhost:9876/generate \
  -H "Content-Type: application/json" \
  -d '{
    "cookie": "your_google_cookie_here",
    "prompt": "A cyberpunk city at night with neon lights",
    "aspectRatio": "IMAGE_ASPECT_RATIO_LANDSCAPE",
    "model": "IMAGEN_3_5",
    "seed": 0
  }'
```

## Requirements

### Linux (Debian/Ubuntu)
- Node.js 18+
- GIMP 2.10+
- Python 3.8+ with GTK3 bindings

### Linux (Fedora/RHEL)
- Same as above, installed via dnf

### macOS (Partial)
- Node.js 18+
- GIMP (manual install from gimp.org)
- Python 3 with PyGObject

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `WHISK_INSTALL_DIR` | `/opt/Gimpsky` | Installation directory |
| `WHISK_BRIDGE_PORT` | `9876` | Bridge server port |

## Troubleshooting

### "Bridge server not responding"
```bash
curl http://localhost:9876/health
Gimpsky restart
```

### "Invalid cookie" error
- Get a fresh cookie from labs.google
- Cookie expires after a few hours
- Make sure you export as "Header String"

### GIMP Script-Fu menus not showing
```bash
# Verify plugin is installed
ls -la ~/.config/GIMP/2.10/scripts/whisk_ai_tools.scm

# Restart GIMP
Gimpsky restart
```

### View logs
```bash
Gimpsky logs
# Or check individual logs
tail -f ~/.config/Gimpsky/logs/bridge.log
tail -f ~/.config/Gimpsky/logs/gui.log
```

## License

MIT License - see [LICENSE](LICENSE) file

## Acknowledgments

- [whisk-api](https://github.com/rohitaryal/whisk-api) - Unofficial Google Whisk API
- [GIMP](https://www.gimp.org/) - GNU Image Manipulation Program
- Google ImageFX/Whisk - AI image generation service

## Disclaimer

This project uses Google's private API and is not affiliated with Google. Use at your own risk.
