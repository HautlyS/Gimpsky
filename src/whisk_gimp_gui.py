#!/usr/bin/env python3
"""
Whisk AI - GIMP Integration GUI
A clean, production-ready GTK3 application for Whisk AI image tools.
"""

import os
import sys
import json
import base64
import urllib.request
import urllib.error
import subprocess
import time
import threading
import glob
import logging
from pathlib import Path

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GdkPixbuf, GLib, Pango

# Configuration
BRIDGE_HOST = "127.0.0.1"
BRIDGE_PORT = 9876
BRIDGE_URL = f"http://{BRIDGE_HOST}:{BRIDGE_PORT}"

CONFIG_DIR = os.path.expanduser("~/.config/whisk-gimp")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
OUTPUT_DIR = "/opt/whisk-gimp/output"
LOG_FILE = os.path.join(CONFIG_DIR, "whisk-gui.log")

# Setup logging
os.makedirs(CONFIG_DIR, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger("WhiskGIMP")


def ensure_dirs():
    os.makedirs(CONFIG_DIR, exist_ok=True)
    os.makedirs(OUTPUT_DIR, exist_ok=True)


def load_config():
    ensure_dirs()
    try:
        with open(CONFIG_FILE, 'r') as f:
            return json.load(f)
    except:
        return {'cookie': '', 'session_id': ''}


def save_config(config):
    ensure_dirs()
    with open(CONFIG_FILE, 'w') as f:
        json.dump(config, f, indent=2)


def api_call(endpoint, data=None, timeout=300):
    """Make API call to bridge server."""
    url = f"{BRIDGE_URL}/{endpoint}"
    payload = json.dumps(data).encode() if data else None
    headers = {'Content-Type': 'application/json'}
    req = urllib.request.Request(url, data=payload, headers=headers,
                                  method='POST' if data else 'GET')
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.URLError as e:
        raise Exception(f"Connection error: {e}. Is bridge server running?")
    except Exception as e:
        raise Exception(f"API error: {e}")


def start_bridge_if_needed():
    """Start bridge server if not running."""
    try:
        api_call('health')
        return True
    except:
        pass

    bridge_script = '/opt/whisk-gimp/bridge-server.js'
    if not os.path.exists(bridge_script):
        return False

    env = os.environ.copy()
    env['WHISK_BRIDGE_PORT'] = str(BRIDGE_PORT)
    subprocess.Popen(['node', bridge_script], env=env,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     start_new_session=True)

    for _ in range(20):
        time.sleep(0.5)
        try:
            if api_call('health').get('status') == 'ok':
                return True
        except:
            pass
    return False


def base64_to_pixbuf(b64_data):
    """Convert base64 image to GdkPixbuf."""
    if ',' in b64_data:
        b64_data = b64_data.split(',', 1)[1]
    img_bytes = base64.b64decode(b64_data)
    loader = GdkPixbuf.PixbufLoader()
    loader.write(img_bytes)
    loader.close()
    return loader.get_pixbuf()


def open_in_gimp(filepath):
    """Open image in GIMP."""
    try:
        subprocess.Popen(['gimp', filepath], start_new_session=True)
        return True
    except Exception as e:
        logger.error(f"Failed to open GIMP: {e}")
        return False


class ProgressWindow(Gtk.Window):
    """Simple progress window."""
    def __init__(self, title="Processing"):
        super().__init__(title=title)
        self.set_default_size(400, 100)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_resizable(False)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(15)
        self.add(box)

        self.label = Gtk.Label(label="Processing...")
        box.pack_start(self.label, True, True, 0)

        self.progress = Gtk.ProgressBar()
        self.progress.set_pulse_step(0.05)
        box.pack_start(self.progress, False, False, 0)

        self.show_all()

    def update(self, text):
        self.label.set_text(text)
        self.progress.pulse()
        while Gtk.events_pending():
            Gtk.main_iteration()


class MainWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title="Whisk AI - GIMP Integration")
        self.set_default_size(700, 650)
        self.set_border_width(10)
        self.set_position(Gtk.WindowPosition.CENTER)

        self.config = load_config()
        self.current_base64 = None
        self.current_media_id = None
        self.refine_b64 = None
        self.caption_b64 = None

        # Start bridge
        start_bridge_if_needed()

        # Build UI
        self._build_ui()
        self.connect("destroy", Gtk.main_quit)

    def _build_ui(self):
        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)

        # Header
        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        title = Gtk.Label()
        title.set_markup("<big><b>Whisk AI Tools</b></big>")
        title.set_xalign(0)
        header.pack_start(title, True, True, 0)

        self.status_lbl = Gtk.Label()
        self._update_status()
        header.pack_start(self.status_lbl, False, False, 0)
        main_box.pack_start(header, False, False, 0)

        # Notebook
        notebook = Gtk.Notebook()

        # Tabs
        notebook.append_page(self._create_generate_tab(), Gtk.Label(label="Generate"))
        notebook.append_page(self._create_refine_tab(), Gtk.Label(label="Refine"))
        notebook.append_page(self._create_caption_tab(), Gtk.Label(label="Caption"))
        notebook.append_page(self._create_gallery_tab(), Gtk.Label(label="Gallery"))
        notebook.append_page(self._create_settings_tab(), Gtk.Label(label="Settings"))

        main_box.pack_start(notebook, True, True, 0)
        self.add(main_box)
        self.show_all()

    def _update_status(self):
        try:
            api_call('health')
            self.status_lbl.set_markup("<span color='green'>Server: Online</span>")
        except:
            self.status_lbl.set_markup("<span color='red'>Server: Offline</span>")

    def _create_generate_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)

        # Prompt
        box.pack_start(Gtk.Label(label="Prompt:"), False, False, 0)
        self.prompt_tv = Gtk.TextView()
        self.prompt_tv.set_wrap_mode(Gtk.WrapMode.WORD)
        sw = Gtk.ScrolledWindow()
        sw.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        sw.set_size_request(-1, 80)
        sw.add(self.prompt_tv)
        box.pack_start(sw, False, False, 0)

        # Settings row
        settings = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)

        settings.pack_start(Gtk.Label(label="Aspect:"), False, False, 0)
        self.aspect_cb = Gtk.ComboBoxText()
        for t in ["Landscape (16:9)", "Portrait (9:16)", "Square (1:1)"]:
            self.aspect_cb.append_text(t)
        self.aspect_cb.set_active(0)
        settings.pack_start(self.aspect_cb, False, False, 0)

        settings.pack_start(Gtk.Label(label="Seed:"), False, False, 0)
        self.seed_spin = Gtk.SpinButton.new_with_range(0, 999999999, 1)
        settings.pack_start(self.seed_spin, False, False, 0)

        box.pack_start(settings, False, False, 0)

        # Generate button
        gen_btn = Gtk.Button(label="Generate Image")
        gen_btn.get_style_context().add_class(Gtk.STYLE_CLASS_SUGGESTED_ACTION)
        gen_btn.connect("clicked", self._on_generate)
        box.pack_start(gen_btn, False, False, 0)

        # Preview
        box.pack_start(Gtk.Label(label="Result:"), False, False, 0)
        self.gen_preview = Gtk.Image()
        self.gen_preview.set_size_request(400, 250)
        self.gen_preview.set_from_icon_name("image-x-generic", Gtk.IconSize.DIALOG)
        sw2 = Gtk.ScrolledWindow()
        sw2.add(self.gen_preview)
        box.pack_start(sw2, True, True, 0)

        # Actions
        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        open_btn = Gtk.Button(label="Open in GIMP")
        open_btn.connect("clicked", self._on_open_gimp)
        actions.pack_start(open_btn, False, False, 0)

        save_btn = Gtk.Button(label="Save As...")
        save_btn.connect("clicked", self._on_save)
        actions.pack_start(save_btn, False, False, 0)
        box.pack_start(actions, False, False, 0)

        self.gen_status = Gtk.Label()
        self.gen_status.set_line_wrap(True)
        self.gen_status.set_xalign(0)
        box.pack_start(self.gen_status, False, False, 0)

        box.show_all()
        return box

    def _create_refine_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)

        # Upload
        upload_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        upload_btn = Gtk.Button(label="Upload Image")
        upload_btn.connect("clicked", self._on_upload_refine)
        upload_box.pack_start(upload_btn, False, False, 0)
        box.pack_start(upload_box, False, False, 0)

        self.refine_preview = Gtk.Image()
        self.refine_preview.set_size_request(400, 200)
        self.refine_preview.set_from_icon_name("image-x-generic", Gtk.IconSize.DIALOG)
        box.pack_start(self.refine_preview, False, False, 0)

        # Edit prompt
        box.pack_start(Gtk.Label(label="Edit Instruction:"), False, False, 0)
        self.edit_tv = Gtk.TextView()
        self.edit_tv.set_wrap_mode(Gtk.WrapMode.WORD)
        sw = Gtk.ScrolledWindow()
        sw.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        sw.set_size_request(-1, 60)
        sw.add(self.edit_tv)
        box.pack_start(sw, False, False, 0)

        refine_btn = Gtk.Button(label="Refine Image")
        refine_btn.get_style_context().add_class(Gtk.STYLE_CLASS_SUGGESTED_ACTION)
        refine_btn.connect("clicked", self._on_refine)
        box.pack_start(refine_btn, False, False, 0)

        self.refine_status = Gtk.Label()
        self.refine_status.set_line_wrap(True)
        self.refine_status.set_xalign(0)
        box.pack_start(self.refine_status, False, False, 0)

        box.show_all()
        return box

    def _create_caption_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)

        # Upload
        up_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        up_btn = Gtk.Button(label="Upload Image")
        up_btn.connect("clicked", self._on_upload_caption)
        up_box.pack_start(up_btn, False, False, 0)
        box.pack_start(up_box, False, False, 0)

        # Count
        count_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        count_box.pack_start(Gtk.Label(label="Captions:"), False, False, 0)
        self.count_spin = Gtk.SpinButton.new_with_range(1, 8, 1)
        self.count_spin.set_value(3)
        count_box.pack_start(self.count_spin, False, False, 0)
        box.pack_start(count_box, False, False, 0)

        cap_btn = Gtk.Button(label="Generate Captions")
        cap_btn.get_style_context().add_class(Gtk.STYLE_CLASS_SUGGESTED_ACTION)
        cap_btn.connect("clicked", self._on_caption)
        box.pack_start(cap_btn, False, False, 0)

        # Results
        box.pack_start(Gtk.Label(label="Results:"), False, False, 0)
        self.caption_tv = Gtk.TextView()
        self.caption_tv.set_editable(False)
        self.caption_tv.set_wrap_mode(Gtk.WrapMode.WORD)
        sw = Gtk.ScrolledWindow()
        sw.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        sw.set_size_request(-1, 200)
        sw.add(self.caption_tv)
        box.pack_start(sw, True, True, 0)

        box.show_all()
        return box

    def _create_gallery_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)

        ref_btn = Gtk.Button(label="Refresh Gallery")
        ref_btn.connect("clicked", self._refresh_gallery)
        box.pack_start(ref_btn, False, False, 0)

        self.store = Gtk.ListStore(GdkPixbuf.Pixbuf, str)
        self.iconview = Gtk.IconView.new()
        self.iconview.set_model(self.store)
        self.iconview.set_pixbuf_column(0)
        self.iconview.set_tooltip_column(1)
        self.iconview.set_item_width(120)
        self.iconview.connect("item-activated", self._on_gallery_activate)

        sw = Gtk.ScrolledWindow()
        sw.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        sw.add(self.iconview)
        box.pack_start(sw, True, True, 0)

        self._refresh_gallery(None)
        box.show_all()
        return box

    def _create_settings_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)

        # Cookie
        box.pack_start(Gtk.Label(label="Google Cookie:"), False, False, 0)
        self.cookie_entry = Gtk.Entry()
        self.cookie_entry.set_text(self.config.get('cookie', ''))
        self.cookie_entry.set_visibility(False)
        box.pack_start(self.cookie_entry, False, False, 0)

        show_btn = Gtk.Button(label="Show/Hide Cookie")
        show_btn.connect("clicked", lambda w: self.cookie_entry.set_visibility(not self.cookie_entry.get_visibility()))
        box.pack_start(show_btn, False, False, 0)

        test_btn = Gtk.Button(label="Test Connection")
        test_btn.connect("clicked", self._test_cookie)
        box.pack_start(test_btn, False, False, 0)

        self.settings_status = Gtk.Label()
        self.settings_status.set_line_wrap(True)
        self.settings_status.set_xalign(0)
        box.pack_start(self.settings_status, False, False, 0)

        box.show_all()
        return box

    def _get_prompt(self):
        buf = self.prompt_tv.get_buffer()
        return buf.get_text(buf.get_start_iter(), buf.get_end_iter(), True).strip()

    def _get_edit(self):
        buf = self.edit_tv.get_buffer()
        return buf.get_text(buf.get_start_iter(), buf.get_end_iter(), True).strip()

    def _on_generate(self, widget):
        prompt = self._get_prompt()
        if not prompt:
            self.gen_status.set_markup("<span color='red'>Enter a prompt first</span>")
            return

        cookie = self.config.get('cookie', '')
        if not cookie:
            self.gen_status.set_markup("<span color='red'>Configure cookie in Settings tab</span>")
            return

        aspect_map = ['IMAGE_ASPECT_RATIO_LANDSCAPE', 'IMAGE_ASPECT_RATIO_PORTRAIT', 'IMAGE_ASPECT_RATIO_SQUARE']
        aspect = aspect_map[self.aspect_cb.get_active()]
        seed = int(self.seed_spin.get_value())

        def work():
            prog = ProgressWindow("Generating Image")
            try:
                GLib.idle_add(prog.update, "Sending request...")
                result = api_call('generate', {
                    'cookie': cookie, 'prompt': prompt,
                    'aspectRatio': aspect, 'model': 'IMAGEN_3_5', 'seed': seed
                }, timeout=180)

                if 'error' in result:
                    GLib.idle_add(self.gen_status.set_markup, f"<span color='red'>{result['error']}</span>")
                    GLib.idle_add(prog.destroy)
                    return

                imgs = result.get('images', [])
                if not imgs:
                    GLib.idle_add(self.gen_status.set_markup, "<span color='orange'>No images generated</span>")
                    GLib.idle_add(prog.destroy)
                    return

                img = imgs[0]
                self.current_base64 = img['base64']
                self.current_media_id = img.get('mediaGenerationId', '')

                GLib.idle_add(prog.update, "Loading image...")
                pixbuf = base64_to_pixbuf(img['base64'])
                GLib.idle_add(self.gen_preview.set_from_pixbuf, pixbuf)
                GLib.idle_add(self.gen_status.set_markup,
                    f"<span color='green'>Success!</span>\n<small>Saved: {img.get('savedPath', '')}</small>")
            except Exception as e:
                GLib.idle_add(self.gen_status.set_markup, f"<span color='red'>Error: {e}</span>")
            finally:
                GLib.idle_add(prog.destroy)

        threading.Thread(target=work, daemon=True).start()

    def _on_open_gimp(self, widget):
        if self.current_base64:
            temp = os.path.join(OUTPUT_DIR, f"whisk_{int(time.time())}.png")
            b64 = self.current_base64.split(',', 1)[1] if ',' in self.current_base64 else self.current_base64
            with open(temp, 'wb') as f:
                f.write(base64.b64decode(b64))
            open_in_gimp(temp)

    def _on_save(self, widget):
        if not self.current_base64:
            return
        dlg = Gtk.FileChooserDialog(title="Save Image", parent=self,
                                     action=Gtk.FileChooserAction.SAVE,
                                     buttons=(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
                                              Gtk.STOCK_SAVE, Gtk.ResponseType.OK))
        dlg.set_current_name(f"whisk_{int(time.time())}.png")
        if dlg.run() == Gtk.ResponseType.OK:
            path = dlg.get_filename()
            b64 = self.current_base64.split(',', 1)[1] if ',' in self.current_base64 else self.current_base64
            with open(path, 'wb') as f:
                f.write(base64.b64decode(b64))
        dlg.destroy()

    def _on_upload_refine(self, widget):
        dlg = Gtk.FileChooserDialog(title="Select Image", parent=self,
                                     action=Gtk.FileChooserAction.OPEN,
                                     buttons=(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
                                              Gtk.STOCK_OPEN, Gtk.ResponseType.OK))
        flt = Gtk.FileFilter()
        flt.add_pattern("*.png"); flt.add_pattern("*.jpg"); flt.add_pattern("*.webp")
        dlg.add_filter(flt)
        if dlg.run() == Gtk.ResponseType.OK:
            path = dlg.get_filename()
            try:
                pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_size(path, 400, 300)
                self.refine_preview.set_from_pixbuf(pixbuf)
                with open(path, 'rb') as f:
                    self.refine_b64 = f"data:image/png;base64,{base64.b64encode(f.read()).decode()}"
                self.refine_status.set_markup(f"<span color='green'>Loaded: {os.path.basename(path)}</span>")
            except Exception as e:
                self.refine_status.set_markup(f"<span color='red'>Error: {e}</span>")
        dlg.destroy()

    def _on_refine(self, widget):
        edit = self._get_edit()
        if not edit:
            self.refine_status.set_markup("<span color='red'>Enter edit instruction</span>")
            return
        if not self.refine_b64:
            self.refine_status.set_markup("<span color='red'>Upload an image first</span>")
            return

        cookie = self.config.get('cookie', '')
        if not cookie:
            self.refine_status.set_markup("<span color='red'>Configure cookie in Settings</span>")
            return

        def work():
            prog = ProgressWindow("Refining Image")
            try:
                # Caption
                GLib.idle_add(prog.update, "Analyzing image...")
                cap = api_call('caption', {'cookie': cookie, 'base64Image': self.refine_b64, 'count': 1})
                caption = cap.get('captions', ['Image'])[0]

                # Project
                GLib.idle_add(prog.update, "Creating project...")
                proj = api_call('project', {'cookie': cookie, 'projectName': 'GIMP Whisk'})
                pid = proj.get('projectId', '')

                # Upload
                GLib.idle_add(prog.update, "Uploading...")
                up = api_call('upload', {
                    'cookie': cookie, 'base64Image': self.refine_b64,
                    'caption': caption, 'category': 'SUBJECT', 'projectId': pid
                })
                mid = up.get('uploadMediaGenerationId', '')

                # Refine
                GLib.idle_add(prog.update, "Refining...")
                ref = api_call('refine', {
                    'cookie': cookie, 'mediaGenerationId': mid, 'editPrompt': edit
                }, timeout=120)

                pixbuf = base64_to_pixbuf(ref['base64'])
                GLib.idle_add(self.refine_preview.set_from_pixbuf, pixbuf)
                GLib.idle_add(self.refine_status.set_markup,
                    f"<span color='green'>Refined!</span>\n<small>{ref.get('savedPath', '')}</small>")
                self.current_base64 = ref['base64']
            except Exception as e:
                GLib.idle_add(self.refine_status.set_markup, f"<span color='red'>Error: {e}</span>")
            finally:
                GLib.idle_add(prog.destroy)

        threading.Thread(target=work, daemon=True).start()

    def _on_upload_caption(self, widget):
        dlg = Gtk.FileChooserDialog(title="Select Image", parent=self,
                                     action=Gtk.FileChooserAction.OPEN,
                                     buttons=(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
                                              Gtk.STOCK_OPEN, Gtk.ResponseType.OK))
        if dlg.run() == Gtk.ResponseType.OK:
            path = dlg.get_filename()
            with open(path, 'rb') as f:
                self.caption_b64 = f"data:image/png;base64,{base64.b64encode(f.read()).decode()}"
        dlg.destroy()

    def _on_caption(self, widget):
        if not self.caption_b64:
            return
        cookie = self.config.get('cookie', '')
        if not cookie:
            return
        count = int(self.count_spin.get_value())

        def work():
            prog = ProgressWindow("Generating Captions")
            try:
                GLib.idle_add(prog.update, "Generating...")
                result = api_call('caption', {
                    'cookie': cookie, 'base64Image': self.caption_b64, 'count': count
                })
                caps = result.get('captions', [])
                text = "\n\n".join([f"{i+1}. {c}" for i, c in enumerate(caps)])
                GLib.idle_add(self.caption_tv.get_buffer().set_text, text)
            except Exception as e:
                GLib.idle_add(self.caption_tv.get_buffer().set_text, f"Error: {e}")
            finally:
                GLib.idle_add(prog.destroy)

        threading.Thread(target=work, daemon=True).start()

    def _refresh_gallery(self, widget):
        self.store.clear()
        for ext in ['*.png', '*.jpg', '*.jpeg', '*.webp']:
            for f in glob.glob(os.path.join(OUTPUT_DIR, ext)):
                try:
                    pb = GdkPixbuf.Pixbuf.new_from_file_at_size(f, 100, 100)
                    self.store.append([pb, os.path.basename(f)])
                except:
                    pass

    def _on_gallery_activate(self, iconview, path):
        it = self.store.get_iter(path)
        fn = self.store.get_value(it, 1)
        open_in_gimp(os.path.join(OUTPUT_DIR, fn))

    def _test_cookie(self, widget):
        cookie = self.cookie_entry.get_text().strip()
        if not cookie:
            self.settings_status.set_markup("<span color='red'>Enter cookie</span>")
            return

        self.settings_status.set_markup("<span color='blue'>Testing...</span>")
        while Gtk.events_pending():
            Gtk.main_iteration()

        try:
            result = api_call('init', {'cookie': cookie})
            self.config['cookie'] = cookie
            self.config['session_id'] = result.get('sessionId', '')
            save_config(self.config)
            self.settings_status.set_markup(f"<span color='green'>Connected!</span>\n<small>{result.get('account', '')}</small>")
        except Exception as e:
            self.settings_status.set_markup(f"<span color='red'>Error: {e}</span>")


def main():
    ensure_dirs()
    logger.info("Starting WhiskGIMP GUI")
    win = MainWindow()
    win.show_all()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
