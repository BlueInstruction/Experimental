# vkd3d-proton-wcp

Custom builds of [VKD3D-Proton](https://github.com/HansKristian-Work/vkd3d-proton) packaged as `.wcp` files for Winlator.
Built from upstream with performance patches for Android-based Windows emulation environments.

---

## Builds

| Build | Target | CPU Runtime | Format |
|---|---|---|---|
| `vkd3d-proton` | x86_64 | Box64 | `.wcp` |
| `vkd3d-proton-arm64ec` | ARM64EC + x86_64 hybrid | FEXCore + WowBox64 | `.wcp` |

---

## Installation

1. Download the `.wcp` from [Releases](../../releases)
2. Open Winlator → **Contents Manager**
3. Tap **+** → **Import from file** → select the `.wcp`
4. Open container settings → **DX Wrapper** → set to `DXVK + VKD3D`
5. Under **VKD3D** → select the imported build

   Entries appear as:
   ```
   3.0b-20260405
   3.0b-20260405-arm64ec
   ```
6. Tap **Apply**

---

## WCP Structure

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

---

## Patches

> Patch list will be documented here.

---

## Required Stack

VKD3D-Proton does not ship DXGI. Inside Winlator, VKD3D and DXVK share a DXGI implementation and must be used together under the **DXVK + VKD3D** DX Wrapper. All components below should be kept up to date for correct behavior.

| Component | Role | Source |
|---|---|---|
| **DXVK** | DXGI + D3D9/10/11 translation | [doitsujin/dxvk](https://github.com/doitsujin/dxvk) |
| **WineProton** | Windows API → POSIX | Winlator Contents Manager |
| **Box64** | x86_64 → ARM64 (standard containers) | [ptitSeb/box64](https://github.com/ptitSeb/box64) |
| **FEXCore + WowBox64** | x86_64 + x86 → ARM64 (ARM64EC containers) | [FEX-Emu/FEX](https://github.com/FEX-Emu/FEX) |
| **Mesa Turnip** | Vulkan driver (Adreno) | Winlator Adrenotools Manager |

---

## Vulkan Requirements

| Requirement | Status |
|---|---|
| Vulkan 1.3 | Mandatory |
| Descriptor indexing (1M+ UpdateAfterBind) | Mandatory |
| `samplerMirrorClampToEdge` | Mandatory |
| `shaderDrawParameters` | Mandatory |
| `VK_EXT_robustness2` | Mandatory |
| `VK_KHR_push_descriptor` | Mandatory |
| `VK_EXT_descriptor_buffer` | Recommended |
| `VK_EXT_mutable_descriptor_type` | Recommended |
| `VK_EXT_image_view_min_lod` | Recommended |

---

## Environment Variables

The following must be set manually in container settings → **Environment Variables**.
Variables already present in Winlator's UI (e.g. `WINEESYNC`, `mesa_glthread`) should be configured there and are excluded here.

### VKD3D-Proton

```
VKD3D_CONFIG=dxr,dxr11
VKD3D_SHADER_MODEL=6_6
VKD3D_DEBUG=none
VKD3D_SWAPCHAIN_PRESENT_MODE=MAILBOX
VKD3D_FRAME_RATE=0
```

> `VKD3D_SHADER_MODEL=6_5` is preferred over 6_6 for mobile GPU targets. SM 6.6 requires Wave64 and typed UAV atomics not guaranteed across all Adreno revisions.

### DXVK

```
DXVK_LOG_LEVEL=none
DXVK_ASYNC=1
DXVK_CONFIG_FILE=./dxvk.conf
```

### Wine / System

```
WINE_LARGE_ADDRESS_AWARE=1
WINEESYNC=1
WINEFSYNC=0
vblank_mode=0
WRAPPER_MAX_IMAGE_COUNT=0
```

### Mesa / Shader Cache

```
MESA_DISK_CACHE_SIZE=512
```

### Box64 (standard containers only)

```
BOX64_DYNAREC_STRONGMEM=1
BOX64_DYNAREC_FASTNAN=1
BOX64_DYNAREC_FASTROUND=1
BOX64_DYNAREC_SAFEFLAGS=1
```

---

## Variables Available in Winlator UI

Set these inside Winlator's built-in interface, not in the environment variable field:

| Variable | Type | Notes |
|---|---|---|
| `TU_DEBUG` | Multi-select | Turnip debug flags |
| `DXVK_HUD` | Multi-select | Overlay (fps, memory, etc.) |
| `WINEESYNC` | Checkbox | ESync (0 / 1) |
| `MESA_SHADER_CACHE_DISABLE` | Checkbox | Disable Mesa shader cache |
| `mesa_glthread` | Checkbox | GL threading |
| `FD_DEV_FEATURES` | Multi-select | Freedreno device features |
| `ZINK_DESCRIPTORS` | Select | Zink descriptor mode |

---

## ARM64EC

ARM64EC (Emulation Compatible) is a hybrid execution model used in the `arm64ec` build:

- Native ARM64 code runs at full hardware speed
- x86_64 code is recompiled in real-time by FEXCore
- 32-bit (x86) code is handled by WowBox64, which bridges the 32-bit environment inside the 64-bit ARM64EC space, passing instruction translation back to FEXCore
- System libraries (Vulkan, Wine) run natively — no separate x86 rootfs required
- Eliminates the CPU bottleneck seen in pure Box64 emulation for DX12-heavy workloads

Reference: [FEX-Emu ARM64EC wiki](https://wiki.fex-emu.com/index.php/Development:ARM64EC)

---

## Debugging

Enable verbose VKD3D logging:
```
VKD3D_DEBUG=warn
VKD3D_LOG_FILE=./vkd3d.log.txt
```

Dump compiled shaders:
```
VKD3D_SHADER_DUMP_PATH=/storage/emulated/0/vkd3d-dumps
```

Disable a problematic Vulkan extension:
```
VKD3D_DISABLE_EXTENSIONS=VK_EXT_descriptor_buffer
```

Disable shader cache:
```
VKD3D_SHADER_CACHE_PATH=0
```

Enable GPU breadcrumb crash logging (requires `VK_AMD_buffer_marker` or `VK_NV_device_checkpoints`):
```
VKD3D_CONFIG=breadcrumbs
```

---

## Credits

- [HansKristian-Work/vkd3d-proton](https://github.com/HansKristian-Work/vkd3d-proton) — upstream VKD3D-Proton
- [doitsujin/dxvk](https://github.com/doitsujin/dxvk) — DXVK / shared DXGI
- [ptitSeb/box64](https://github.com/ptitSeb/box64) — x86_64 CPU runtime
- [FEX-Emu/FEX](https://github.com/FEX-Emu/FEX) — ARM64EC CPU runtime
- [StevenMXZ/Winlator-Ludashi](https://github.com/StevenMXZ/Winlator-Ludashi) — Winlator fork
