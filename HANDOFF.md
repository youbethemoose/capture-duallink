# Capture DualLink handoff

DualLink copies Capture One Live View to a Sidecar iPad while the original stays on the Mac. Preserve native capture detail and keep automatic startup off by default. Use a local clone such as `~/Developer/capture-duallink` on each Mac. The current app release is [1.10.1 (build 21)](https://github.com/youbethemoose/capture-duallink/releases/tag/v1.10.1).

## Capture One 16.9.1 crash investigation, November 20, 2026

Four reports from Capture One 16.9.1.27 on macOS 27.2.1 show Capture One aborting on a background thread. It passed a missing image to AppKit's bitmap initializer (`Invalid parameter not satisfying: cgImage != NULL`). The latest incident happened during Nikon tethered capture with Live View open, shortly after Capture One copied adjustments to a new shot. That timing is a lead, rather than an identified cause.

DualLink was open during the crashes. The retained ScreenCaptureKit logs show a DualLink stream starting after all four incidents and no stream activity at the crash times. Those logs do not prove that an earlier stream was never active. DualLink captures a rendered window through macOS, and its optional Control mode sends mouse events. The crash reports identify Capture One's internal bitmap handling and provide no evidence for a DualLink code change. The app build and installer were therefore left at 1.10.1.

For the next tethered test, quit DualLink fully and use a new local Capture One Session with the same camera and Live View workflow. If it is stable, repeat with a DualLink copy in view-only mode, then try Control separately. If the crash happens during standalone tethered capture, test **Next Capture Adjustments → All Other → Defaults** in the test session to isolate copied edits on new shots. The camera was unavailable during this investigation, so these tethered comparisons and the workaround still need a real run.

See [Capture One's crash guide](https://support.captureone.com/hc/en-us/articles/27489980414237-Capture-One-Crashes-on-macOS-and-Windows-Troubleshooting) and [Next Capture Adjustments](https://support.captureone.com/hc/en-us/articles/360002556677-Adding-adjustments-to-captured-images). If a shoot requires reverting to the last working Capture One version, preserve the current session or catalog and test a separate copy using [Capture One's rollback guide](https://support.captureone.com/hc/en-us/articles/360002427218-Revert-to-a-Previous-Version-of-Capture-One-and-Restore-Catalogs-or-Sessions).

The November 20 run built DualLink and passed all 42 unit tests from the local Developer clone. The installed app passed 86 checks using its own calibration window, including capture, rendering, input mapping, and viewer lifecycle. The [README](README.md#build-and-verify) has the build, package and native test commands.
