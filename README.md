# NVcontrol — GPU Hardware & Power Controller

<div align="left">

![AutoHotkey](https://img.shields.io/badge/AutoHotkey-v2.0+-334455.svg?logo=autohotkey&logoColor=white)
![RAM](https://img.shields.io/badge/RAM-~3_MB-brightgreen.svg)
![Platform](https://img.shields.io/badge/Platform-Windows_10%20%2F%2011-0078D6.svg?logo=windows&logoColor=white)
![Backend](https://img.shields.io/badge/Backend-NVIDIA_NVML-76B900.svg?logo=nvidia&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-blue.svg)

</div>

A clean, lightweight GPU utility written in **AutoHotkey v2**. It connects directly to the NVIDIA Management Library (`nvml.dll`) via in-memory Win32 calls to control power limits, fan speeds, and clock offsets — using **under ~3 MB of RAM** and featuring a live telemetry overlay docked directly inside your Windows taskbar.

Movable taskbar GUI  
<img width="719" height="57" alt="Screenshot 2026-09-06 180110" src="https://github.com/user-attachments/assets/4349fd07-41cb-490b-b54e-bdf4e8a291c7"/>  

Main window for settings  
<img width="654" height="731" alt="Screenshot 2026-09-06 175941" src="https://github.com/user-attachments/assets/99af883c-93b0-459e-9dc2-fae237c973db"/>

---

## Why I Built This

I got tired of **MSI Afterburner**. 

Afterburner was great a decade ago, but today it is bloated and slow. Between Afterburner and its RivaTuner Statistics Server (RTSS) sidecar, it eats **50 to 70 MB of RAM**, spawns multiple background services, and forces you to stare at an outdated UI from 2008.

I wanted something clean, simple, and genuinely lightweight:
* **No bloat**: Sits at **~3.2 MB RAM** on launch and drops to **~1.5–3 MB** when minimized.
* **Direct NVML communication**: Zero CMD console flashing, zero `nvidia-smi` process spawning, zero temporary files. Telemetry reads in **< 0.1 milliseconds** straight from driver memory.
* **A clean Taskbar Widget**: A live mini-telemetry widget docked cleanly into the empty left area of your taskbar. Double-click it to open the GUI; right-click for a compact 1-line mode. Remembers monitor placement across restarts.
* **Single-instance activation**: Launching the script while an instance is already running (minimized to tray or widget) instantly wakes and restores the existing window to the foreground instead of hanging or starting duplicate processes.
* **Essential controls without clutter**: Power limit slider + presets, independent 2-fan control, core/memory clock offsets, and thermal limits.

---

## ⚠️ Hardware Liability Disclaimer

> **DISCLAIMER: USE AT YOUR OWN RISK.**
> Modifying GPU power limits, clock frequencies, voltage curves, target temperatures, and fan speeds involves hardware risks. Improper settings, insufficient cooling, or aggressive overclocks can lead to thermal throttling, display driver crashes (TDRs), graphical artifacts, system instability, or permanent hardware damage.
>
> **The author and contributors of this software assume ZERO RESPONSIBILITY for any hardware failure, silicon degradation, data loss, or system damage resulting from using this utility.**
>
> By running this tool, you acknowledge that you are solely responsible for verifying your GPU's thermal limits and operating parameters.

---

## Features

### 1. Power Limit Control
* Full hardware range control (e.g. `100 W` to `380 W` on RTX 3090, default `370 W`).
* Interactive slider + numeric input with instant two-way synchronization.
* 5 quick presets (`20%`, `40%`, `60%`, `80%` of range, plus factory VBIOS default).
* Dedicated **Apply** and **Reset to VBIOS Default** buttons.

### 2. Fan & Thermal Control (Dual Fan Support)
* Independent monitoring for `Fan 0` and `Fan 1`.
* Manual fan slider (`30%` to `100%`) with quick presets (`40%`, `60%`, `80%`, `100%`).
* **One-Click Restore**: Prominent `↺ Restore Auto Fans` button to immediately hand control back to the factory VBIOS thermal curve.
* **Failsafe thermal protection**: If the script is closed while manual fan control is active, an exit handler automatically restores fans to Auto so your card is never left on a fixed fan speed.
* Target temperature adjustment (`60 °C` to `90 °C`, default `80 °C`).

### 3. Clock Offsets & Locking
* **Core Clock Offset**: `-500` to `+500 MHz` (supports full `-1000` to `+1000 MHz` hardware range).
* **Memory Clock Offset**: `-1000` to `+2000 MHz` (supports full `-2000` to `+6000 MHz` hardware range).
* Uses modern NVML versioned struct (`nvmlClockOffset_v1_t`, `0x01000018`).
* **Core Clock Lock**: Lock core frequency to a fixed cap (e.g. `1800 MHz`) for undervolting/benchmarking, or unlock to restore dynamic GPU Boost.
* One-click **Reset Offsets (0 MHz)** button.

### 4. Windows Taskbar Live Widget
* Docks right above the Start/search area on your taskbar.
* **2-Line Mode** (30px tall, vertically centered in 48px taskbar):
  * **Line 1 (Cyan)**: `GPU: {Load}%  |  BW: {MemBW}%  |  {Temp}°C`
  * **Line 2 (Green)**: `{PowerDraw}W / {PowerLimit}W  |  VRAM: {Used}/{Total} GB`
* **1-Line Compact Mode** (20px tall): Right-click widget -> *"Toggle 1-Line / 2-Line"*.
* **Interactivity & Window Controls**:
  * **Minimize (`🗕`)**: Minimizes the GUI directly into the live Taskbar Widget overlay without cluttering your taskbar with an AHK button.
  * **Close (`✕`)**: Exits the application cleanly, resetting manual fans to auto and unloading NVML.
  * **Clean Taskbar**: Uses Win32 window ownership (`+Owner`) to completely suppress generic taskbar buttons while maintaining standard title bar metrics.
  * **Double-click Widget**: Instantly restores and focuses the main controller window.
  * **Click & Drag Widget**: Reposition anywhere along your taskbars across any connected monitor (position is persisted across restarts).
  * **Right-click Widget Menu**: Open controller, refresh stats, toggle 1-line/2-line mode, restore auto fans, hide, or exit.

### 5. Memory Usage: ~3 MB vs 70 MB
Uses native Win32 working set trimming (`SetProcessWorkingSetSize(-1, -1, -1)`) after startup and whenever minimized, plus pre-allocated C struct buffers. 
* **Fresh launch**: `~3.27 MB`
* **Active polling with full GUI open**: `~4.5 – 5.7 MB`
* **Minimized to Taskbar Widget / Tray**: `~1.5 – 3.2 MB`

---

## Crash Detection & Input Clamping

Setting an unstable clock or fan speed and adding a utility to Windows Startup can lead to a crash or boot loop. To prevent this, the script implements two layers of protection:

1. **Input Range Clamping**:
   * Every input is checked against the card's VBIOS limits before anything touches NVML.
   * Fan speeds below the physical stall threshold (`30%`) or above `100%` are rejected.
   * High clock offsets (e.g. `> +300 MHz` core or `> +1500 MHz` memory) require explicit confirmation before applying.
   * Invalid characters or empty strings cleanly snap back to the last valid value.

2. **Crash Detection & Safe-Boot**:
   * When custom clocks or fan settings are active, a session canary is maintained in `%APPDATA%\NVcontrol\session_active.canary`.
   * If Windows crashes, freezes, or reboots abruptly before the session is verified stable (45 seconds), the script detects the abnormal shutdown on next boot.
   * **Safe-Boot immediately activates**: it skips custom startup clocks, resets offsets to `0 MHz`, restores fans to Auto, and resets power to VBIOS defaults, alerting you with a notification instead of crashing again.

---

## Windows Startup Integration

You can enable startup via the GUI:
1. Check **"Start with Windows"** in the top section of the controller.
2. A confirmation prompt asks to verify you want it enabled.
3. The script creates a shortcut in your Windows Startup folder (`NVcontrol.lnk`) with the `/minimized` flag.
4. On Windows boot, the utility starts **silently and minimized directly into the Taskbar Widget** (or tray) without popping up a window over your desktop.

---

## Command Line Usage

The script also supports headless CLI calls for batch scripts or shortcuts:

```powershell
# Set power limit to 250 Watts
AutoHotkey64.exe NVcontrol.ahk -pl 250

# Reset power limit to factory VBIOS default
AutoHotkey64.exe NVcontrol.ahk --reset

# Start directly minimized into taskbar widget
AutoHotkey64.exe NVcontrol.ahk /minimized
```

---

## System Requirements

* **OS**: Windows 10 or Windows 11 (64-bit)
* **GPU**: NVIDIA GeForce GTX/RTX graphics card with standard display drivers installed (tested extensively on RTX 3090; compatible with Turing, Ampere, Ada Lovelace / RTX 20/30/40 series).
* **Runtime**: [AutoHotkey v2.0+](https://www.autohotkey.com/) (64-bit)
* **Permissions**: Administrator rights are required by NVIDIA's display driver to modify power limits and clock offsets. The script will automatically request elevation via UAC prompt on launch if not already elevated.

---

## License

This project is licensed under the [MIT License](LICENSE) with an explicit hardware liability waiver.
