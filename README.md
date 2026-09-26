# MX Control for Noctalia

Battery and HID++ settings for Logitech MX mice in the [Noctalia](https://noctalia.dev)
bar: DPI, SmartShift, scroll and thumb wheel, button actions and diversion, and
Easy-Switch hosts. A port of [omarchy-mxcontrol](https://github.com/zachwilke/omarchy-mxcontrol);
the Python helper in `backend/` is upstream's, unchanged (see [UPSTREAM.md](UPSTREAM.md)).

## Requirements

- Noctalia with plugin API 24
- `python3`
- [Solaar](https://pwr-solaar.github.io/Solaar/) (`sudo pacman -S solaar`) for its HID++
  libraries and the udev rules that open `/dev/hidraw*` to your user. Turn the mouse off
  and on once after installing so the rules apply.

Without Solaar the helper can only list devices and battery.

## Install from this checkout

Noctalia plugin sources are catalogs, so a local checkout needs a small catalog that
links to it:

```bash
mkdir -p ~/.local/share/noctalia-dev
ln -sfn "$PWD" ~/.local/share/noctalia-dev/mx-control
# write ~/.local/share/noctalia-dev/catalog.toml with a [[plugin]] row for
# gamaraan/mx-control (id, name, version, author, license, icon, description,
# plugin_api, tags, updated_at, added_at)
noctalia msg plugins source add mxdev path ~/.local/share/noctalia-dev
noctalia msg plugins enable gamaraan/mx-control
```

Then add **MX Control** to a bar in Settings → Bar. Left click opens the panel, right
click reads the device again.

## Panel

- **Point & scroll** – DPI (a slider when the device reports an evenly spaced DPI
  list), scroll wheel, thumb wheel, and any other device setting.
- **Buttons & actions** – one group per button with its action and mode.
- **Easy-Switch** – the paired hosts. Switching takes a second click, because it
  sends the device to the other computer.
- **Profiles** – pointer acceleration (system default or macOS-style, applied through
  Hyprland) and named snapshots of the device's settings to save, apply and delete.
- **Shortcuts** – give a divertable button a shortcut, a sequence of up to eight, or four
  directional gestures, for all apps or as a per-app override. Shortcuts are sent to the
  focused window through Hyprland. A button's Mode must be Regular to take a shortcut,
  and stays locked while it has one.

Profiles, pointer preferences and shortcuts live in `~/.config/omarchy-mx/`, the
helper's directory, so ones saved with the Omarchy plugin carry over.

Every setting is drawn from the kind the helper reports, so settings this plugin has
no special code for still get a control.

## How it works

The service is the only entry that runs processes. It keeps `backend/mxctl.py serve`
running, publishes `$XDG_RUNTIME_DIR/omarchy-mx/status.json` to the widget and panel
through Noctalia's shared state, and turns panel commands into `cmd-*.json` spool files
that `serve` picks up through inotify.

## Development

```bash
lua tests/shared_test.lua      # logic tests (plain Lua; shared.luau stays Lua-compatible)
noctalia plugins lint .        # settings declared vs. used
```

`.luau` edits reload live. Changes to `translations/` or `plugin.toml` are read at plugin
load: `noctalia msg plugins disable gamaraan/mx-control`, then `enable`.

## Licence

GPL-2.0-or-later, as upstream.
