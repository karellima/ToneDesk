# AutoEQ & Headphone Correction

ToneDesk can apply headphone- and speaker-specific frequency response corrections using profiles from [AutoEQ](https://github.com/jaakkopasanen/AutoEq), [REW](https://www.roomeqwizard.com/), or [Equalizer APO](https://sourceforge.net/projects/equalizerapo/). This compensates for your headphones' or speakers' natural frequency curve, giving you a flatter, more accurate sound.

## How It Works

Every pair of headphones and every room colors the sound differently. AutoEQ and REW measure these deviations and generate corrective parametric EQ filters. ToneDesk applies these filters per output device, so each pair of headphones or DAC gets its own correction profile.

AutoEQ corrections stack cleanly with ToneDesk's per-device **Global Parametric EQ** and per-app **10-band EQ**, so you can still fine-tune the sound to your taste after applying a profile.

## Import Profiles into the Library

The primary way to add custom or downloaded profiles is through **Settings › Profiles**:

1. Open **ToneDesk Settings › Profiles**
2. Click **Import…** (or drag & drop `.txt` files or whole folders directly onto the window)
3. Select one or more Equalizer APO / REW `ParametricEQ.txt` files
4. Hover a profile and click **Apply** (or right-click the menu bar icon to switch profiles with one click)

You can also click the **wand icon** on any output device row in the menu bar popup to browse the built-in AutoEQ database, search by headphone model, toggle **Correction** or **Preamp**, or import a `.txt` file directly.

### Supported File Format

ToneDesk accepts Equalizer APO and REW `ParametricEQ.txt` files:

```
Preamp: -6.2 dB
Filter 1: ON PK Fc 100 Hz Gain -2.3 dB Q 1.41
Filter 2: ON LSC Fc 105 Hz Gain 7.0 dB Q 0.71
Filter 3: ON HSC Fc 8000 Hz Gain 2.1 dB Q 0.71
```

### Supported Filter Types

| Code | Type | Description |
|------|------|-------------|
| `PK` / `PEQ` | Peaking | Boost or cut a narrow frequency range |
| `LS` / `LSC` | Low shelf | Boost or cut everything below a frequency |
| `HS` / `HSC` | High shelf | Boost or cut everything above a frequency |

- Up to **64 filters** per profile. Files with more filters are rejected with a clear message (nothing is silently truncated).
- Per-filter limits: gain ±30 dB, Fc 1 Hz–30 kHz, Q 0.01–100; out-of-range values are rejected with the offending line number.
- Unknown or unsupported lines (e.g., `Device:`, `LP`, `LS 12dB`) are skipped and reported as warnings. Shelves without a `Q` default to `Q = 0.707`.
- The `Preamp` line sets a global gain offset to prevent clipping and is applied while **Preamp** is enabled in the AutoEQ picker.
- Imported files are applied faithfully at any device sample rate (44.1, 48, 96 kHz…), matching Equalizer APO and REW. Built-in AutoEQ database profiles keep their 48 kHz correction.
- Switching profiles, toggling correction, or toggling preamp during playback crossfades smoothly over 25 ms with no clicks.

## Profile Library & A/B Comparison

In **Settings › Profiles**, you can:

- **Search & organize:** filter profiles by name, star favorites, drag to reorder, double-click to rename, duplicate, or delete.
- **Inspect filters:** expand any row to view its frequency response graph alongside the preamp and filter table.
- **Compare A/B:** assign two profiles to **Slot A** and **Slot B**, enable **Level-match** (K-weighted LUFS trim so you compare tonal balance rather than loudness), switch between **Overlay** and **Difference** graph views, and click either card — or press your global **Toggle EQ A/B** hotkey in **Settings › Shortcuts** — to switch sides instantaneously.
- **Backup & restore:** use **Backup › Export Backup…** and **Restore Backup…** to save or restore your entire library as a `.zip` archive.

## Where to Get Profiles

- **Built-in search** — Click the wand icon on an output device to search thousands of headphones from the AutoEQ database (cached locally for offline use).
- **[autoeq.app](https://www.autoeq.app/)** — Select **EqualizerAPO ParametricEq**, download the `.txt` file, and import it via **Settings › Profiles › Import…**.
- **[AutoEQ GitHub](https://github.com/jaakkopasanen/AutoEq)** — Full repository of measurements and generated profiles.
- **Custom measurements (REW)** — Export filters in Equalizer APO format from REW and import the `.txt` file into ToneDesk.

## Storage & Device Persistence

- Imported profile files are stored in `~/Library/Application Support/ToneDesk/AutoEQ/`.
- Each output device remembers its assigned profile independently, and assignments are also tracked by device name — so plugging a USB DAC into a different port keeps its active profile.
- To temporarily bypass a profile, click the wand icon on the device row and turn **Correction** off; to remove it, select **No correction**.
