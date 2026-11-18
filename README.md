# Lightshot Preview

A Chatterino7/Chatterino2 Lua plugin that embeds [Lightshot](https://prnt.sc)
screenshots in chat.

```
<someone> nice play ls:rnfcsk
```

becomes the original message followed by a clickable preview of
`https://prnt.sc/rnfcsk`. The preview is rendered locally only — other users
still see the plain `ls:CODE` text.

## Installation

The plugin lives in this repository at `plugins/lightshot`. Chatterino loads
plugins from its app data directory, so link or copy the folder there:

**Linux (native build)**

```sh
ln -s "$PWD/plugins/lightshot" ~/.local/share/chatterino/Plugins/lightshot
```

**Linux (Flatpak)**

The Flatpak sandbox cannot see your home directory by default, so a symlink
into `~/Documents` would dangle inside the sandbox. Copy the folder instead:

```sh
mkdir -p ~/.var/app/com.chatterino.chatterino/data/chatterino/Plugins
cp -r "$PWD/plugins/lightshot" \
    ~/.var/app/com.chatterino.chatterino/data/chatterino/Plugins/lightshot
```

To update the Flatpak copy after editing the plugin, re-run the `cp -r` command
(or use `rsync -a --delete`).

**Windows** (`cmd`, from the repository root)

```bat
mklink /D "%APPDATA%\Chatterino2\Plugins\lightshot" "%CD%\plugins\lightshot"
```

**macOS**

```sh
ln -s "$PWD/plugins/lightshot" "$HOME/Library/Application Support/chatterino/Plugins/lightshot"
```

Then open **Settings → Plugins**, enable plugins if needed, and enable
**Lightshot Preview**. The plugin requests the `Network` permission so it can
fetch the screenshot page and image.

## Usage

- Any incoming message containing `ls:CODE` gets a preview (up to two codes
  per message).
- `/lightshot CODE`, `/ls CODE`, and `/prnt CODE` add a preview manually. A
  full `https://prnt.sc/CODE` link is also accepted.
- `/lightshotstatus` prints plugin diagnostics (hooked channels, counters, and
  how many recent messages already contain an image).
- Clicking the image opens the original Lightshot page.
- Codes already resolved are cached for the session (24 hours for valid
  screenshots, 5 minutes for misses), so repeated links don't hit the site
  again.

Codes must be 3–16 alphanumeric characters; shorter tokens are ignored.
`xxx` is not a real screenshot id — use the code from an actual
`https://prnt.sc/...` link.

## Configuration

Open `init.lua` and adjust the constants at the top:

| Constant | Default | Meaning |
| --- | --- | --- |
| `MAX_WIDTH` | `400` | Maximum preview width in pixels |
| `MAX_HEIGHT` | `400` | Maximum preview height in pixels |
| `MAX_CODES_PER_MESSAGE` | `2` | Previews per message |
| `SCAN_INTERVAL_MS` | `2000` | How often to look for newly opened channels |

Reload the plugin from the Plugins settings page after editing.

## How it works

1. `Channel:on_message_appended` looks for `ls:CODE` tokens in new messages.
   Existing messages in open channels are checked once when the channel is
   first hooked.
2. `https://prnt.sc/CODE` is fetched and the direct image URL is read from the
   `og:image` meta tag. Chat pages without a real screenshot (for example
   invalid codes, which point at a placeholder on `st.prntscr.com`) are
   ignored.
3. A `Range: bytes=0-65535` request reads just the image header to get its
   dimensions.
4. The message is cloned, a line break and an `ImageElement` are appended, and
   `Channel:replace_message` swaps it in. The original text is preserved.

The direct image is served by `image.prntscr.com` (older ids) or
`img.lightshot.app` (newer ids) without a `Referer` check, so Chatterino can
load it like any other remote image.

## Limitations

- The rewrite is local: people without the plugin see `ls:CODE` and must open
  the link themselves. Messages you send yourself are still sent to Twitch.
- Chatterino's plugin API has no global "message received" event, so the
  plugin polls open tabs every two seconds and hooks each channel. Messages
  that arrive in a brand-new channel before it is hooked are missed (the
  `/lightshot` commands cover that case).
- If a message scrolls out of the buffer before Lightshot answers, the
  replacement is silently skipped.
- Lightshot is behind Cloudflare. The plugin sends a browser-like User-Agent,
  but requests can still be rate-limited or challenged; misses are cached for
  5 minutes.
- Large screenshots are scaled to `MAX_WIDTH` × `MAX_HEIGHT`. Dimensions are
  read from the PNG/JPEG/GIF header; uncommon formats fall back to a 0.25
  scale.

## Files

| File | Purpose |
| --- | --- |
| `init.lua` | Chatterino wiring: channel hooks, HTTP, message rewriting |
| `lightshot.lua` | Parsing helpers (token, meta tag, image dimensions) with no `c2` dependency |
| `info.json` | Plugin metadata and the `Network` permission |
