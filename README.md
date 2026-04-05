# vkd3d-proton-wcp

Custom builds of [VKD3D-Proton](https://github.com/HansKristian-Work/vkd3d-proton) optimized for Android-based Windows emulation (Winlator, Box64/FEXCore+WowBox64).

---

## Overview

VKD3D-Proton is a Direct3D 12 to Vulkan translation layer used in Proton.
This repository provides builds tuned for:

- Android emulation environments (Winlator Vanilla/Bionic)
- Arm64ec hybrid execution via FEXCore
- Mobile GPU constraints (Adreno 7xx / 8xx, Mesa Turnip)

---

## Build Targets

| Architecture | Runtime  | Status      |
|--------------|----------|-------------|
| Proton Arm64ec + 86 (32-bit)   | FEXCore + WowBox64 |Stable | 
| Proton x86_64       | Box64    | Stable      |

---

## Installation (Winlator)

### Via Winlator Contents Manager (recommended)

1. Download the `.wcp` file from Releases
2. Open Winlator → **ContentsManager** tab
3. Tap **+** → **Import from file** → select the `.wcp`
4. Open your container settings → **VKD3D** → select the imported version

   The spinner displays entries as `{versionCode}`, for example:
   ```
   3.0b-20260405
   3.0b-20260405-arm64ec
   ```
5. Tap **Apply**

---

## WCP File Format

A `.wcp` file is a zstd-compressed tar archive with this structure:

```
build.wcp
├── profile.json
├── system32/
│   ├── d3d12.dll
│   └── d3d12core.dll
└── syswow64/
    ├── d3d12.dll
    └── d3d12core.dll
```

## Driver Requirements

| Requirement                      | Status      |
|----------------------------------|-------------|
| Vulkan 1.3                       | Mandatory   |
| Descriptor indexing (1M+ UAB)    | Mandatory   |
| `VK_EXT_robustness2`             | Mandatory   |
| `VK_KHR_push_descriptor`         | Mandatory   |
| `VK_EXT_descriptor_buffer`       | Recommended |
| `VK_EXT_mutable_descriptor_type` | Recommended |

Recommended driver: **Mesa Turnip** (latest experimental build for Adreno 7xx/8xx).

---

## Environment Variables

Winlator has a built-in UI for some variables (`TU_DEBUG`, `DXVK_HUD`, `WINEESYNC`, etc.).
VKD3D-specific variables are not in the Winlator UI and must be added manually in container settings → **Environment Variables**.

Recommended (add manually):
```
VKD3D_CONFIG=dxr,dxr11
VKD3D_DEBUG=none
DXVK_LOG_LEVEL=none.
DXVK_CONFIG_FILE=/dxvk.conf
```

Optional:
```
VKD3D_SWAPCHAIN_PRESENT_MODE=MAILBOX
VKD3D_FRAME_RATE=0
```

Variables available directly in Winlator UI:

| Variable               | Type            | Notes                          |
|------------------------|-----------------|--------------------------------|
| `TU_DEBUG`             | Multi-select    | Turnip debug flags             |
| `DXVK_HUD`             | Multi-select    | Overlay (fps, memory, etc.)    |
| `WINEESYNC`            | Checkbox        | ESync (0 / 1)                  |
| `MESA_SHADER_CACHE_DISABLE` | Checkbox   | Disable Mesa shader cache      |
| `mesa_glthread`        | Checkbox        | GL threading                   |
| `FD_DEV_FEATURES`      | Multi-select    | Freedreno device features      |
| `ZINK_DESCRIPTORS`     | Select          | Zink descriptor mode           |

---

## ARM64EC Notes

ARM64EC (Emulation Compatible) enables hybrid execution:

- Native ARM64 code runs at full hardware speed
- x86_64 code is recompiled at runtime by FEXCore
- System libraries (Vulkan, Wine, etc.) run natively as ARM64 — no x86 rootfs needed

This eliminates the CPU bottleneck of pure software emulation (Box64) for DX12-heavy workloads.

Build reference: [FEX-Emu ARM64EC wiki](https://wiki.fex-emu.com/index.php/Development:ARM64EC)

---

## Debugging

Enable verbose logging:
```
VKD3D_DEBUG=warn
VKD3D_LOG_FILE=/vkd3d.log.txt
```

Dump shaders:
```
VKD3D_SHADER_DUMP_PATH=/storage/emulated/0/vkd3d-dumps
```

Disable problematic extensions:
```
VKD3D_DISABLE_EXTENSIONS=VK_EXT_descriptor_buffer
```

Disable shader cache:
```
VKD3D_SHADER_CACHE_PATH=0
```

---

## Recommended Stack

| Component | Version          |
|-----------|------------------|
| WineProton      | Latest Arm64ec + x86_64 build    |
| FEXCore   | Latest stable    |
| Turnip    | Latest (Gen8+)   |
| DXVK      | Latest           |
| Winlator Bionic  | Vanilla / Ludashi |

---

## Credits

- [HansKristian-Work/vkd3d-proton](https://github.com/HansKristian-Work/vkd3d-proton) — upstream
- [Mesa / Turnip](https://gitlab.freedesktop.org/mesa/mesa) — Vulkan driver
- [FEX-Emu](https://github.com/FEX-Emu/FEX) — ARM64EC runtime
- [WinlatorCMOD](https://github.com/StevenMXZ/Winlator-Ludashi) — Android container
  
