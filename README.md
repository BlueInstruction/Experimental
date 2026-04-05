# vkd3d-proton-wcp

Custom builds of [VKD3D-Proton](https://github.com/HansKristian-Work/vkd3d-proton) optimized for Android-based Windows emulation (Winlator, FEXCore/WowBox64).

---

## Overview

VKD3D-Proton is a Direct3D 12 to Vulkan translation layer used in Proton.
This repository provides builds tuned for:

- Android emulation environments (Winlator Vanilla/Bionic)
- ARM64EC hybrid execution via FEXCore
- Mobile GPU constraints (Adreno 7xx / 8xx, Mesa Turnip)

---

## Build Targets

| Architecture | Runtime  | Status      |
|--------------|----------|-------------|
| ARM64EC      | FEXCore  | Recommended |
| x86 (32-bit) | WowBox64 | Stable      |
| x86_64       | Box64    | Stable      |

---

## Key Patches

### RE Engine Integer Blend Fix
Prevents a GPU hang (`VK_ERROR_DEVICE_LOST`, `vr -4`) in RE Engine titles (Resident Evil Requiem, Dragon's Dogma 2) on Adreno / Turnip drivers.

The engine incorrectly requests blending on integer-format render targets (`DXGI_FORMAT_R32G32B32A32_UINT`). Desktop drivers silently discard this invalid state; strict mobile drivers crash after ~100 seconds of accumulated corrupt pipeline state.

**Fix:** Force-disable blend on integer-format RTs and break the inner loop instead of returning `E_INVALIDARG`.

```diff
-    ERR("Enabling blending on RT %u with format %s, but using integer format is not supported.\n", i, ...);
-    return E_INVALIDARG;
+    WARN("Force-disabling blending on RT %u (integer format %s), preventing GPU hang.\n", i, ...);
+    state->graphics.blend_attachments[i].blendEnable = VK_FALSE;
+    break;
```

### MFG X6 Swapchain Depth
Raises swapchain latency frames to 8 and command queue depth to 32, enabling multi-frame generation headroom for DLSS Enabler MFG X6.

### Render Pass (Tiled GPU)
Forces render pass path for clear and resolve operations, improving tile memory efficiency on Adreno (upstream PR #2856).

### UMA Host Cached Memory
Forces `host_cached` memory for all allocations, equivalent to `VKD3D_CONFIG=force_host_cached`. Reduces redundant cache flushes on Adreno UMA.

### Fsync / Timeline Semaphore
- Timeline semaphore forced for all fence operations
- Win32 fence disabled
- Fence spin count reduced to 128
- Shared timeline for cross-queue sync

### D3D12 Capability Spoofing
- GPU spoof: AMD Van Gogh (0x1002:0x163f) for compatibility
- Shader Model 6.8 / Feature Level 12_2 / SDK 619
- D3D12 Options 1-21 all maximized
- Descriptor limits: 1M+ update-after-bind

---

## Releases

Latest builds: https://github.com/BlueInstruction/vkd3d-proton-wcp/releases

Each release includes:
- `vkd3d-proton-{ver}-{commit}.wcp` — x64 + x86 build
- `vkd3d-proton-arm64ec-{ver}-{commit}.wcp` — ARM64EC + x86 build

---

## Installation (Winlator)

### Via Winlator Components (recommended)

1. Download the `.wcp` file from Releases
2. Open Winlator → **Components** tab
3. Tap **+** → **Import from file** → select the `.wcp`
4. Open your container settings → **VKD3D** → select the imported version

   The spinner displays entries as `{versionName}-{versionCode}`, for example:
   ```
   3.0b-21a49c9-20260405
   ```
5. Tap **Apply**

Winlator extracts the archive, validates `profile.json`, then copies the DLLs to the correct paths inside the container's Wine prefix automatically.

---

## WCP File Format

A `.wcp` file is a zstd-compressed tar archive with this structure:

```
my-build.wcp
├── profile.json
├── system32/
│   ├── d3d12.dll
│   └── d3d12core.dll
└── syswow64/
    ├── d3d12.dll
    └── d3d12core.dll
```

### profile.json

Winlator reads `profile.json` to validate and install the package. Required fields for `VKD3D` type:

```json
{
  "type": "VKD3D",
  "versionName": "3.0b-21a49c9",
  "versionCode": 20260405,
  "description": "VKD3D-Proton ARM64EC — MFG-X6 + RenderPass + UMA + Fsync",
  "files": [
    { "source": "system32/d3d12.dll",     "target": "${system32}/d3d12.dll" },
    { "source": "system32/d3d12core.dll", "target": "${system32}/d3d12core.dll" },
    { "source": "syswow64/d3d12.dll",     "target": "${syswow64}/d3d12.dll" },
    { "source": "syswow64/d3d12core.dll", "target": "${syswow64}/d3d12core.dll" }
  ]
}
```

Supported `type` values: `Wine`, `Proton`, `DXVK`, `VKD3D`, `Box64`, `WOWBox64`, `FEXCore`

### Path Templates

Winlator resolves these templates at install time:

| Template      | Resolved path                                        |
|---------------|------------------------------------------------------|
| `${system32}` | `imagefs/home/xuser/.wine/drive_c/windows/system32` |
| `${syswow64}` | `imagefs/home/xuser/.wine/drive_c/windows/syswow64` |
| `${libdir}`   | `imagefs/usr/lib`                                    |
| `${bindir}`   | `imagefs/usr/bin`                                    |
| `${sharedir}` | `imagefs/usr/share`                                  |

### Security

Winlator enforces a trusted file list per content type. For `VKD3D`, only these four targets are accepted:

```
${system32}/d3d12.dll
${system32}/d3d12core.dll
${syswow64}/d3d12.dll
${syswow64}/d3d12core.dll
```

Any other `target` path causes `ERROR_UNTRUSTPROFILE` and the install is rejected.

Install directory inside Winlator: `contents/VKD3D/{versionName}-{versionCode}/`

---

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
DXVK_LOG_LEVEL=none
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

## Known Issues

**Adreno 750:**
- Z-fighting / depth instability in some DX12 titles
- Missing distant geometry in open-world games

**ARM64EC:**
- Frame pacing inconsistency in some titles (timing desync between ARM and emulated threads)

**General:**
- Memory aliasing instability in descriptor-heavy scenes
- RE Engine GPU hang fixed by the integer blend patch (see above)

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
| Wine      | ARM64EC build    |
| FEXCore   | Latest stable    |
| Turnip    | Latest (Gen8+)   |
| DXVK      | Latest           |
| Winlator  | Vanilla / Bionic |

---

## Credits

- [HansKristian-Work/vkd3d-proton](https://github.com/HansKristian-Work/vkd3d-proton) — upstream
- [Mesa / Turnip](https://gitlab.freedesktop.org/mesa/mesa) — Vulkan driver
- [FEX-Emu](https://github.com/FEX-Emu/FEX) — ARM64EC runtime
- [Winlator](https://github.com/brunodev85/winlator) — Android container
- AndroEmu community — testing and validation
