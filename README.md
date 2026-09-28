# Stride / Shoe Monitor

A browser-based BLE dashboard for smart shoes and insole sensors. Open it in desktop Google Chrome or another supported Chromium browser; it uses Web Bluetooth and requires an HTTPS origin (GitHub Pages supplies HTTPS).

## Connect a Shoe

1. Open the deployed site in Chrome on the computer with the shoe nearby.
2. Choose **Connect shoe** and select the shoe in Chrome's Bluetooth device picker.
3. If the shoe uses different BLE UUIDs or encodings, open sensor settings and enter the vendor's values.

The browser can reconnect to a previously authorized device for this site. Bluetooth permissions are scoped to the browser and site origin. Chrome on iOS does not expose Web Bluetooth; use desktop Chrome or a supported Chromium browser.

## BLE Profile

The defaults are service `180D`, pressure characteristics `A001` through `A003`, cadence characteristic `A004`, Battery Service `180F`, and Battery Level `2A19`. The pressure and cadence IDs are examples, not a standard shoe profile. The shoe must advertise the selected primary service and expose the configured characteristics with readable or notifiable values.

Pressure is decoded per characteristic as unsigned 16-bit little-endian by default, with unsigned 8-bit and float32 little-endian options. Integer pressure readings are normalized to `0...1`; float readings are clamped to that range. Cadence is decoded as an unsigned integer in steps per minute. Confirm UUIDs, endianness, scales, and packet framing against the shoe vendor's protocol. This app expects one reading per characteristic value and does not reassemble vendor-fragmented packets.

Ground impact is shown as relative load unless a vendor-supported force scale is configured. A displayed newton value is an estimate and should not be treated as a validated measurement.

## Deploy

GitHub Actions deploys the static app to GitHub Pages whenever `main` is updated. The site URL is `https://madhalanaidu2-coder.github.io/SmartShoeBLE/`. The Pages build uses the repository root; no build step or server is required.