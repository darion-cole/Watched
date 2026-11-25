# Watched for Mac

A lightweight native macOS wrapper for watched.cx, built on WebKit.

- Fast and light: uses the system WebKit engine (no bundled Chromium), hardware video decode, persistent cache and login
- Routes through Cloudflare WARP: if WARP is in Proxy mode (`warp-cli mode proxy`, port 40000) the app uses it automatically; in normal WARP mode all traffic is already tunneled
- Hides the Anime section
- Blocks pop-ups and off-site redirects
- Window title shows the route in use ("via WARP proxy" or "direct")

## Install

Download `Watched-macOS.zip` from the latest release, unzip, and drag `Watched.app` to Applications.
The build is ad-hoc signed, so the first time, right-click the app → Open, or run:

    xattr -dr com.apple.quarantine /Applications/Watched.app

## Build locally

Requires macOS 14+ and Xcode Command Line Tools.

    bash build.sh

## Shortcuts

⌘⇧H Home · ⌘R Reload · ⌘[ Back · ⌘] Forward · ⌃⌘F Full screen
