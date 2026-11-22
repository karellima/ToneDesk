# Troubleshooting

## No sound / audio stops working

ToneDesk requires the **Screen & System Audio Recording** permission to capture and route app audio.

1. Open **System Settings** → **Privacy & Security** → **Screen & System Audio Recording**
2. Find **ToneDesk** in the list and enable it
3. **Restart ToneDesk** — the permission doesn't take effect until relaunch

If you previously denied the permission prompt, you'll need to enable it manually from System Settings.

## App not appearing

ToneDesk only shows apps that are **actively playing audio** (plus any apps you have pinned). If an app isn't visible:

- Make sure the app is actually producing sound (start playback)
- Check if the app is hidden. Open **edit mode** (pencil icon) and look for the eye icon next to the app name. A crossed-out eye means the app is being ignored.
- Some apps use helper processes for audio. Try restarting the app.

## App causing audio issues

Some apps don't work well with CoreAudio process taps — particularly audio processors, DAWs, VoIP tools, and apps that do their own low-level audio routing. Symptoms include distorted audio, echo, or audio cutting out.

**Fix:** Open **edit mode** (pencil icon) and click the eye icon to ignore the problematic app. This tears down the process tap entirely for that app, so it goes back to normal macOS audio routing.

Common apps that may need to be ignored:
- Audio Hijack, Loopback, and other Rogue Amoeba apps
- Some VoIP/conferencing tools with custom audio engines
- FaceTime, WhatsApp, and other calling apps (tapping can break echo cancellation, causing volume ducking)

## Volume slider not working

There are two cases.

**Per-app slider.** Some apps use helper processes to play audio rather than the main app process, so the slider you see might be controlling the wrong process. Try restarting the app. If the issue persists, check edit mode to see if the app appears as a different process name.

**Per-device slider.** When you open a device, ToneDesk picks a volume backend automatically:

- **Hardware**: the device reports a native volume control (most USB DACs, AirPods, built-in speakers).
- **DDC**: an external display that responds to the monitor-control protocol.
- **Software**: ToneDesk attenuates inside its own audio graph.

Auto-detection gets it right for most devices, but some USB DACs and HDMI/DisplayPort outputs advertise a hardware slider that doesn't actually move the output level. If the device slider doesn't change the volume, open the device inspector (the `i` button on the device row) and turn on **Software volume**. ToneDesk remembers the choice per device. The toggle is hidden when auto-detect already picked Software, because there's no alternative backend to switch to.

## Audio device not switching automatically

ToneDesk uses a **device priority list** to decide which output device to use. When a device connects, ToneDesk only switches to it if it's ranked higher than the current device. When a device disconnects, ToneDesk falls back to the next highest-priority device that's still connected.

By default, devices are added to the bottom of the list in the order they're first seen. Since your Mac's built-in speakers are always connected, they end up at the top (highest priority), so ToneDesk won't auto-switch to headphones, external speakers, or other devices when they connect.

**This is a one-time setup.** Once you set your preferred order, it's saved permanently and works across app restarts.

**How to reorder:**

1. Click the **pencil icon** in the menu bar popup to enter edit mode
2. **Drag** devices to reorder, or **click the priority number** and type a new position
3. Click the **checkmark** to exit edit mode — your order is saved

The device at position 1 has the highest priority. ToneDesk will always prefer the highest-priority device that's currently connected.

Input and output devices have **separate priority lists** — switch between them using the speaker/microphone tabs in edit mode.

> **Note:** For AirPods, taking them out of your ears and putting them back in (without the case) is handled by macOS Automatic Ear Detection. ToneDesk doesn't interfere with that.

## Input devices not showing

ToneDesk's input device monitoring requires separate microphone permission.

1. Open **System Settings** → **Privacy & Security** → **Microphone**
2. Find **ToneDesk** and enable it
3. Restart ToneDesk

## Bluetooth headphones sound muffled or low quality

macOS switches Bluetooth headsets from high-quality music playback (AAC/A2DP) to a low-bandwidth call profile (SCO/HFP) whenever any app activates the headset's microphone.

**Fix:** Open the device inspector (`i` button on your Bluetooth output device) and enable **Keep Music Quality (Output Only)**, or lock a separate microphone in **Settings › Audio › Lock Input Device**.

## Media keys don't control ToneDesk

Media keys (F10, F11, and F12) are opt-in and require the **Accessibility** permission so ToneDesk can intercept the keystrokes.

1. Open **ToneDesk Settings › Shortcuts**
2. Click **Grant** in the Accessibility strip (or open **System Settings** → **Privacy & Security** → **Accessibility** and enable **ToneDesk**; if it's already on, toggle it off and back on)
3. Turn on **Media Keys Control** and choose your preferred **HUD Style** (Tahoe, Classic, or None)

If the keys still don't work right after launch, a WindowServer handoff can briefly swallow the first keypress. Try once more; subsequent presses are reliable.

## Volume HUD not appearing

- Check **ToneDesk Settings › Shortcuts**. The HUD appears when **Media Keys Control** is active with Accessibility granted and **HUD Style** is set to Tahoe or Classic.
- Switch HUD styles if one isn't rendering as expected. Tahoe uses the modern compact HUD look; Classic matches the traditional translucent rounded-rect style.

## EQ or AutoEQ not applying / sounds the same

- **Per-app 10-band EQ:** check that the toggle switch in the EQ panel header is on, and that you selected a preset other than **Flat** (all bands at 0 dB). Make sure you're adjusting the EQ for the right app.
- **Per-device AutoEQ / Parametric EQ:** open **Settings › Profiles › Import…** to add `ParametricEQ.txt` profiles, or click the **wand icon** / **`i` inspector button** on the output device row to verify that correction is enabled for the active output device.

## Audio quality sounds degraded

- Check if volume boost is set above 1x — high boost levels can cause clipping on loud passages.
- If using manual EQ, large boosts across multiple bands can push levels too high. Try pulling bands down instead of boosting others up.
- AutoEQ profiles include a preamp gain reduction to prevent clipping; make sure **Preamp** is enabled in the AutoEQ picker.
- Try resetting app volumes via URL: `open "tonedesk://reset"` in Terminal.

## Resetting ToneDesk completely

- To clear volumes, EQ, and device routings inside the app, go to **Settings › General › Reset All Settings**.
- To start completely from scratch (including saved profiles), quit ToneDesk and remove `~/Library/Application Support/ToneDesk/`. Back up your profiles first via **Settings › Profiles › Backup › Export Backup…** if you want to keep them.
