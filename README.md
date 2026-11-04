# Capture DualLink

A small native macOS app for collaborative still-life photography. The photographer keeps Capture One's original Live View on the laptop, directs product placement and controls focus, grids and reference overlays. The prop stylist watches a DualLink copy of the same live frame on an iPad while positioning the product.

Keep the original Capture One window on the laptop; move only the DualLink copy onto the iPad. For guides visible to both people, use Capture One's grid or overlay in the original Live View. DualLink's own Grid is local to a viewer. Enable **Control** in a copy's toolbar to click, drag and scroll in the original window. Focus is still handled by Capture One and depends on camera/lens support. The interface uses a centered layout, simple instructions and a flat sky-blue/pastel palette. Paired circle, square and triangle compositions explain the shared view without people or computer mockups.

## Open the app

For a shared disk image, drag **Capture DualLink.app** to **Applications**, eject the image, and open the installed app. The illustrated setup guide opens on first use. It shows how the camera, Capture One and independent viewers fit together, then walks through display setup and capture permission. Reopen it from **Setup Guide** in the picker or the shutter icon's right-click menu.

The **linked shutter** icon appears in both the Dock and menu bar. Click either to reopen the window picker. Closing the picker leaves DualLink running; choose **Quit Capture DualLink** to exit. To keep its Dock icon after quitting, right-click it and choose **Options → Keep in Dock**.

**About Capture DualLink** in the app menu or the menu bar icon's right-click menu shows the installed version when comparing builds with a friend.

For a local build, open `dist/Capture DualLink.app`. For everyday use, quit the app and run `./scripts/install-app.sh` to copy it to your user Applications folder.

1. Click **Allow Window Capture** and enable **Capture DualLink** under System Settings → Privacy & Security → Screen & System Audio Recording. Follow any macOS request to quit and reopen, then click **Refresh**.
2. Open **Window → Live View** in Capture One.
3. In DualLink, select **Live View** and click **Duplicate Window**. Capture One windows are sorted first.
4. Drag the copy onto an iPad or another display. **Create Another Copy** in its right-click menu makes more; every copy of a source shares one capture stream.
5. Right-click a copy, choose **Trim Capture One Toolbar…** once, and trim the toolbar and any fixed panels from the edges.

Each iPad must be connected as an **extended display**.

## Automatic startup away from home

Right-click the **DualLink** menu bar icon and choose **Automatic Startup…**. Enter your home Wi-Fi name, turn on **Start automatically away from home Wi-Fi**, and save. Allow the macOS Location Services prompt so DualLink can read the connected network name; approve its Login Item if macOS requests it.

A lightweight menu bar watcher starts at login and stays quiet at home. After another Wi-Fi network is connected for at least 10 seconds, it opens the window picker once for that away visit. Disconnected Wi-Fi and unavailable network names never count as away. Network change events drive detection, with a one-minute recovery check. The home Wi-Fi name stays in this Mac's local preferences, with no GPS updates or nearby-network scans.

Capture doesn't start until you choose a source window. Returning home leaves active viewers open. **Quit Capture DualLink** stops the watcher until you reopen the app or log in again. Disable automatic startup in the same panel to remove the Login Item. Manual launches always open normally, including at home.

## Capture One keeps the keyboard

Copies never become the key window. In view-only mode, clicking or double-clicking a copy leaves keyboard focus where it was. **Control Source** directs mouse input to the selected source and activates its app, so Capture One keeps its shortcuts. DualLink has no viewer keyboard shortcuts. The window picker, permission dialog, trim panel and automatic startup settings can bring DualLink to the front.

## Mouse control

Hover over a copy and click **Control**. Allow Capture DualLink under **System Settings → Privacy & Security → Accessibility**, then return to the copy. Its button reads **Control On** while enabled. Each copy chooses its own control mode.

Clicks, double-clicks, left/right/middle drags and scroll-wheel input target the same position in the original window. Fit/Fill, Retina scale and toolbar trimming are accounted for; letterbox bars ignore clicks. DualLink's floating controls stay local. In control mode, use the **Fill Display** button because double-clicks go to Capture One; use **⋯** for DualLink's menu. Reset Trim if you want to see and click source controls you previously cropped out. Menus, dialogs and popovers that Capture One opens as separate windows are outside the selected window's capture.

The source app handles each control's behavior, including zoom and camera focus. DualLink does not send camera commands directly or monitor global input. The desktop cursor stays on the copy. Mouse control stops if the source owner changes or its displayed geometry is stale, and releases held buttons when control is disabled or a viewer closes or pauses. Capture quality and the GPU pipeline are independent of this mode.

Window-local event positioning currently uses a runtime-resolved macOS SkyLight SPI alongside public process-targeted Quartz events. If the SPI is absent, Control Source is unavailable. macOS updates or a source app's event handling can affect compatibility; test the controls you need on your Capture One version before a shoot.

## Trim, picture detection and the grid

The trim removes fixed controls around Live View, measured in the source window's points. It applies to every copy of that source and is remembered per application on this Mac, so you set it once rather than per display. Because toolbars don't change size when you resize the Live View window, a trim in points stays correct.

Inside the trimmed area, DualLink finds the camera picture automatically. Capture One draws Live View on a perfectly flat background, while a camera feed always has noise and compression texture, even on a gray seamless backdrop. An edge row or column that is (within ±2 levels) a single color is treated as background. Detection runs about once a second and whenever the source changes size, and a new picture area must be seen twice in a row before the grid moves. When an edge is ambiguous, DualLink leaves background visible rather than cutting into the picture.

**Rule of Thirds Grid** divides the detected camera picture, not the whole window, and stays out of the gray bars. It is independent for each copy. Before a picture is detected, it falls back to the whole trimmed area.

## Viewing

Hover over a copy to show its controls: **Fit/Fill**, **Grid**, **Control**, **Fill Display**, and **⋯** for everything else. In view-only mode, a click or tap also shows them and right-click opens the same options.

- **Fit** shows the whole image with black bars when aspect ratios differ. **Fill** fills the viewer and crops the excess. Both preserve proportions.
- **Fill Display**: use its button to cover the whole display, menu bar included. In view-only mode, double-click also enters/exits. It isn't macOS fullscreen, which would bring DualLink to the front and take Capture One's shortcuts. There's no separate Space, and Escape doesn't exit because keystrokes stay with Capture One.
- **Move to Display** and **Keep on Top** are in the right-click menu.

Copies render with Metal at each window's actual backing-pixel size, so moving one between Retina, non-Retina and Sidecar displays adapts automatically. Capture and rendering use Display P3, so Capture One's wide-gamut Live View colors aren't clipped to sRGB. DualLink copies the pixels Capture One renders; it doesn't add camera detail. Use Capture One's own viewer on a calibrated display for critical color evaluation.

**Native / Retina** captures the source window's available pixels, with an 8192-pixel long-edge safety limit. **Balanced** and **Light** cap the long edge at 2560 and 1920 pixels without upscaling. Frame rate is 15, 30 or 60 fps.

## Performance and recovery

Capture resolution and frame rate stay at your settings; DualLink never lowers resolution to handle load. Capture-to-view delivery keeps only the newest pending frame, and each viewer allows at most two GPU renders in flight. When every copy of a source is minimized or hidden, capture stops; it resumes when a copy is visible again. Sleep releases streams and buffers, and wake restarts them with each copy's settings intact.

Source resizes and display-density changes are detected from each frame's metadata and applied immediately; a 5-second poll is the backstop. If ScreenCaptureKit stops a stream, DualLink reconnects to the same window and owner process with growing delays of 1, 2, 4, 8 and then 15 seconds, reset once a frame actually arrives. A closed source must be selected again; DualLink never silently switches to another window.

Paused frames cannot be reused as live mouse targets when a copy is restored or added. New copies show the same paused status until a fresh frame arrives. A connection still opening when the Mac sleeps stays stopped until wake; an initial connection failure closes all copies waiting on it. Activity and settings refreshes wait for the initial connection instead of starting another. Pointer movement reuses the floating toolbar's hide timer and checks input permission once per forwarded event.

## Build and verify

Requires macOS 14 or later and Swift 5.9 or later. Building needs only the Command Line Tools; `./scripts/test.sh` needs full Xcode, because the Command Line Tools don't include XCTest. No third-party packages, network service, recording files or video encoders are used.

```sh
./scripts/build-app.sh
./scripts/test.sh
```

To build a shareable disk image for both Apple silicon and Intel Macs:

```sh
./scripts/package-app.sh
```

This creates `dist/Capture-DualLink-<version>-universal.dmg` and a SHA-256 checksum. The disk image contains only the universal app, an Applications shortcut and `START HERE.txt`; local preferences, home Wi-Fi names, source code and developer backups are excluded. The first-run guide is part of the app and needs no network connection.

**Distribution status:** the local build uses ad-hoc signing when no signing identity is installed. Such a package is a private test build; Gatekeeper may block its first launch on another Mac. Developer ID signing and Apple notarization are still needed for standard downloaded-app distribution. No quarantine removal or security-setting changes are built into the installer. See [Apple's first-launch guidance](https://support.apple.com/en-us/102445).

`build-app.sh` signs with your **Apple Development** certificate when one is installed (free with any Apple ID: Xcode → Settings → Accounts). That keeps Screen Recording permission across rebuilds without letting other programs that reuse the bundle identifier inherit it. Without a certificate it falls back to an ad-hoc signature, and macOS may ask for permission again after rebuilding. Set `DUALLINK_SIGN_IDENTITY` to choose a specific identity.

Unit tests cover Retina pixel sizing, Mac-to-iPad aspect differences, Fit/Fill, trim conversion and bounds, picture detection (pillarbox, letterbox, near-background gray backdrops, flat picture areas, ±1 color-conversion dither, leftover toolbar lines, overlays in the bars, empty viewers) and detection smoothing.

Automatic startup tests cover the 10-second confirmation, Wi-Fi dropouts, unknown or redacted network names, exact SSID matching, multiple interfaces, returning home and opening once per away visit. These are deterministic policy tests; they do not switch the Mac's real Wi-Fi network or log the user out.

Native lifecycle checks also cover extra copies joining a failed connection, sleep during the initial source lookup, and paused-frame cache, status and input behavior when a copy is added or its visibility changes.

The integration self-test captures only a calibration window owned by DualLink. The window is drawn like Capture One's Live View, with a busy toolbar, a flat gray background and a noisy 4:3 picture. The test verifies trim, picture detection and grid placement through real ScreenCaptureKit and the GPU pipeline:

```sh
'dist/Capture DualLink.app/Contents/MacOS/CaptureDualLink' --self-test "$PWD/.build/verification" --check-performance --check-fill-display
```

Read `.build/verification/capture-test.json` after it exits; it needs macOS 14.4 or later. `--check-performance` runs the production model with three live viewers, then simulated sleep/wake, minimize/restore, closing a connection while its source lookup is pending, mismatched source rejection, window-list outages and final-copy cleanup. `--check-fill-display` checks that copies can't take focus (including a click sent through AppKit's event dispatch), exercises Fill Display and checks offscreen window restoration. These are synthetic local workloads, not a Capture One, camera or physical Sidecar benchmark. Check a real Capture One session with each iPad before relying on it in a shoot.
