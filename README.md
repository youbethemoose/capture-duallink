# Capture DualLink

A small native macOS menu bar app that duplicates a selected window into independent viewers. Built for Capture One Live View on a MacBook and an iPad already connected as an extended Mac display.

## Open the app

Open `dist/Capture DualLink.app`. The overlapping-rectangles icon appears in the menu bar; the app has no Dock icon.

For everyday use, quit the app and run `./scripts/install-app.sh` to copy it to your user Applications folder. This also avoids synced Documents folders adding Finder metadata to the generated bundle. Subsequent rebuilds can be installed with the same command.

1. Click **Allow Window Capture** and enable **Capture DualLink** under System Settings → Privacy & Security → Screen & System Audio Recording (called Screen Recording on some macOS releases). Follow any macOS request to quit and reopen, then click **Refresh**.
2. Open **Window → Live View** in Capture One.
3. In DualLink, select **Live View** and click **Duplicate Window**. Capture One windows are sorted first.
4. Drag the copy onto the iPad display. The original stays on the Mac. Click Duplicate Window again for more independent copies.

The iPad must be configured as an **extended display** for different window layouts. Each copy runs on the Mac and uses the existing macOS display connection.

## Resolution and sizing

Copies render with Metal at the destination window's actual backing-pixel size. Moving a viewer between Retina, non-Retina, and Sidecar displays updates its pixel density automatically. Resizing a copy doesn't resize the source or another copy.

Transparent source-window corners blend into the viewer's black background, avoiding the white corner wedges that can appear when duplicating a rounded macOS window. This preserves the whole source image without trimming its edges.

Right-click inside a copy for:

- **Fit**: the whole image, with black bars when the aspect ratios differ. Default.
- **Fill**: fills the viewer while cropping excess edges; preserves proportions.
- **Actual pixels — 1:1**: one captured pixel per backing pixel, centered.
- **Rule of Thirds Grid**, **Zoom In / Out**, and **Reset Zoom**.
- **Crop Image…**: independently trim the top, bottom, left, and right of this copy.
- **Match Source Aspect Ratio** and **Set Viewer Size in Pixels…**.
- **Move to Display**, **Fullscreen**, **Keep on Top**, **Freeze Image**, and another copy.

## Native fullscreen

Click the fullscreen toolbar button, use the green window button, double-click the image, or press **Control–Command–F** to enter a native macOS fullscreen Space. Move the pointer to the top edge to reveal the system menu bar and the native viewer toolbar. The toolbar provides Fit / Fill / 1:1, Zoom, Grid, Crop, Freeze, more options, and Exit Full Screen. Press **Escape** or **Control–Command–F** to return to the original window size.

Each copy keeps its own crop and sizing settings through fullscreen transitions. Pixel information starts hidden in fullscreen for a clean image; you can reveal it from the View menu without changing the windowed preference. The app temporarily enables its normal application menus while fullscreen viewers are open and returns to menu bar utility mode after the last fullscreen viewer exits. The system menu bar follows your macOS visibility preferences. Keep on Top is suspended during fullscreen and restored afterward. The native View menu always acts on the focused copy.

Keyboard shortcuts: **Command–1 / 2 / 3** for Fit / Fill / 1:1; **Command–K** to crop; **Shift–Command–R** to reset the crop; **Shift–Command–P** or **Space** in the image to freeze/resume; **Shift–Command–I** for pixel information; **Command–D** for another copy. Window size in pixels describes the image area, excluding the title bar and toolbar, and may be constrained by macOS minimum window dimensions.

**Native / Retina** captures the source window's available pixels, with an 8192-pixel long-edge safety limit. **Balanced** and **Light** cap the long edge at 2560 and 1920 pixels respectively without upscaling or changing aspect ratio. Capture detail and frame-rate settings apply to all active capture sessions. Available frame rates are 15, 30, and 60 fps; a source that updates more slowly still updates more slowly. Copies of one source share one capture stream.

This copies the pixels Capture One renders. It cannot add camera detail, provide a higher-resolution camera feed, or create independent Capture One camera/focus controls. Keep the original Live View window open and make its image area large enough for the detail you need. Covering the source is supported by ScreenCaptureKit; minimizing it suspends capture. Source-window resizing and display-density changes are detected approximately every two seconds. A closed source needs to be selected again after reopening.

## Performance and recovery

Capture resolution and frame rate remain at the settings you choose. The app never lowers resolution automatically to handle load. Copies of a source share one capture stream and one GPU context/command queue. Capture-to-view delivery retains only the newest pending frame; each viewer permits at most two GPU renders in flight, dropping obsolete render requests when necessary.

**Freeze** makes one GPU copy at the source's full captured pixel dimensions. Frozen viewers own their images rather than retaining buffers needed by the live capture stream. Zoom, pan, and grid still work on a frozen image. Resume keeps that image visible until a fresh live frame arrives. Pixel-information labels update only when geometry or settings change, and controls coalesce repeated updates. Hidden/minimized viewers release live frame references and stop rendering.

When all copies of a source are frozen or offscreen, capture stops after a short debounce. A visible live viewer resumes capture at the same selected resolution. Sleep releases live streams and buffers; wake and display changes refresh capture while preserving per-view crop, grid, zoom, and pan. Transient stream interruptions retry the same window and owner process with bounded delays. A closed/replaced window must be selected again; the app does not silently switch to another window.

Display Check caches its static artwork and animates its marker on the GPU. Its animation timer stops while no live Display Check viewer is visible.

## Grid, zoom, and iPad controls

Each viewer has its own **Grid** toggle and **− / zoom / +** toolbar controls. Zoom ranges from 1× to 8× relative to the selected Fit, Fill, or actual-pixel sizing. Click the middle zoom value to reset magnification and pan; choosing Fit, Fill, or 1:1 also resets them. Drag the image with a mouse or Apple Pencil to pan a magnified image. Trackpad pinch zooms around the pointer, and two-finger scrolling pans. Pan stops at the image edges. The rule of thirds grid follows the cropped image and stays out of letterbox bars; crop away Capture One's surrounding controls first if you want the grid aligned only to the camera picture.

Keyboard shortcuts: **Command–G** toggles the grid; **Command–= / −** zoom in/out; **Command–0** resets zoom. Apple Pencil side double-tap toggles the grid when that feature is enabled in Sidecar settings.

**Floating controls** appear over the bottom of the viewer with **Grid**, **− / Fit / +**, and a hide button. Their visibility does not change the viewer's size, Metal drawable dimensions, captured image resolution, backing scale, or fit/zoom settings. Use **Show Floating Controls** in the viewer options or **Shift–Command–T** to show/hide them. The center button displays the current zoom factor while magnified; tapping it fits the image again. These controls work in native fullscreen and can be used with Apple Pencil or a mouse while Sidecar's Touch Bar is off.

Sidecar's system Touch Bar is optional. To maximize the iPad's available image area, leave **Show Touch Bar** off in **System Settings → Displays → your iPad**. If you prefer finger buttons on older systems, turn it on and focus the DualLink copy on the iPad; it provides **Grid**, **− / Fit / +**, and **Freeze / Resume**, including in fullscreen. Sidecar controls its own display layout when its sidebar or Touch Bar is shown, so DualLink cannot guarantee identical usable display dimensions across those system setting changes. DualLink's controls affect only that copy; they do not send clicks to Capture One or change the Mac's display mode.

According to [Apple's Sidecar guide](https://support.apple.com/en-us/102597), direct finger interaction with Mac windows and menus requires **macOS 27 and iPadOS 27 or later**. On those systems the image surface uses native direct-touch recognizers for pan, pinch, and double-tap fullscreen. Earlier versions offer limited gestures: use the Sidecar Touch Bar for finger buttons, or Apple Pencil / mouse / trackpad for the viewer's toolbar. Physical Sidecar input still needs verification with your iPad and OS versions.

The grid uses cached procedural GPU lines and zoom changes the existing image transform. Both use the same capture stream and renderer as before.

The app uses an SDR sRGB rendering pipeline. Use Capture One's original viewer on a calibrated display for critical color evaluation.

## Display Check

**Display Check** opens a moving grid without screen-recording permission. Drag it to the iPad, resize it, and compare Fit, Fill, and 1:1. The circle should stay round. Right-click the menu bar icon to see open copies, close all copies, access permissions, or quit.

## Build and verify

Requires macOS 14 or later and Xcode Command Line Tools with Swift 5.9 or later. The supplied build is for Apple silicon; rebuilding uses the current Mac's architecture. No third-party packages, network service, recording files, or video encoders are used.

```sh
./scripts/build-app.sh
./scripts/test.sh
```

The build script packages and locally signs the `.app`. This is a local development build, not a notarized distribution. Generated apps and build artifacts are ignored by Git.

The test suite covers Retina pixel sizing, Mac-to-iPad aspect-ratio differences, Fit/Fill/1:1, crop origin and bounds, zoom limits, pinch focal points, pan bounds, and invalid dimensions. A separate app integration check captures only a calibration window owned by DualLink, verifies pixels through the real ScreenCaptureKit/Core Image pipeline, tests two viewers, grid/zoom rendering, floating controls, native Touch Bar actions and a source resize, and saves a report and PNGs. It verifies that showing/hiding floating controls preserves viewer dimensions, Metal drawable pixels, backing scale, captured image size, display mode, and fit/crop/zoom settings in windowed and fullscreen views:

```sh
open -n 'dist/Capture DualLink.app' --args --self-test "$PWD/.build/verification"
```

Read `.build/verification/capture-test.json` after the test app exits. This check needs macOS 14.4 or later. A real Capture One session and physical iPad must still be checked on the shoot setup.

Add `--check-fullscreen` to also exercise native fullscreen entry/exit, auto-hiding menus and toolbar, original window-size restoration, per-copy settings, and menu bar utility mode restoration.

Add `--check-performance` to exercise the production capture model with an animated 3200 × 1800 calibration source on a 2× display, four independently frozen viewers and one live viewer, idle capture suspension/resume, simulated app sleep/wake, and minimize/restore. The report includes delivered frames, process CPU time, and viewer GPU timing for a five-second steady interval. Calibration dimensions follow the source display's actual backing scale. This is a local synthetic workload, not a Capture One/camera/physical Sidecar benchmark, and does not establish end-to-end iPad latency.
