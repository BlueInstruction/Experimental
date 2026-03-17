import sys, re, os

def patch_vk_extensions(vk_ext_py_path):
    if not os.path.exists(vk_ext_py_path):
        print(f"[WARN] {vk_ext_py_path} not found")
        return

    with open(vk_ext_py_path) as f:
        c = f.read()

    if "VK_MESA_EXT_TABLE_PATCHED" in c:
        print("[OK] vk_extensions.py already patched")
        return

    # Detect the Extension() call signature from existing entries
    # Pattern 1: Extension("VK_FOO", True, None)        -> 3 args (name, supported, platform)
    # Pattern 2: Extension("VK_FOO", "DEVICE")          -> 2 args (name, ext_type)
    # Pattern 3: Extension("VK_FOO", "DEVICE", version) -> 3 args with version
    m_sig = re.search(
        r'Extension\s*\(\s*"VK_\w+"\s*,\s*([^)]+)\)',
        c
    )

    entry_template = None
    if m_sig:
        args = m_sig.group(1).strip()
        arg_parts = [a.strip() for a in args.split(',')]
        if len(arg_parts) == 1:
            entry_template = '"DEVICE"'
        elif len(arg_parts) == 2:
            entry_template = arg_parts[0] + ', ' + arg_parts[1]
        else:
            entry_template = ', '.join(arg_parts)
    else:
        entry_template = '"DEVICE"'

    MISSING = [
        "VK_KHR_unified_image_layouts",
        "VK_KHR_cooperative_matrix",
        "VK_KHR_shader_bfloat16",
        "VK_KHR_maintenance7",
        "VK_KHR_maintenance8",
        "VK_KHR_maintenance9",
        "VK_KHR_maintenance10",
        "VK_KHR_device_address_commands",
        "VK_EXT_zero_initialize_device_memory",
        "VK_VALVE_video_encode_rgb_conversion",
        "VK_VALVE_fragment_density_map_layered",
        "VK_VALVE_shader_mixed_float_dot_product",
        "VK_QCOM_cooperative_matrix_conversion",
        "VK_QCOM_data_graph_model",
        "VK_QCOM_rotated_copy_commands",
        "VK_QCOM_tile_memory_heap",
        "VK_QCOM_tile_shading",
    ]

    added = []
    for ext in MISSING:
        if ext in c:
            continue
        m = re.search(r"(DEVICE_EXTENSIONS\s*=\s*\[)", c)
        if not m:
            m = re.search(r"(device_extensions\s*=\s*\[)", c)
        if not m:
            m = re.search(r"(extensions\s*=\s*\[)", c)
        if m:
            ins = c.find("\n", m.end())
            entry = '\n    Extension("' + ext + '", ' + entry_template + '),'
            c = c[:ins] + entry + c[ins:]
            added.append(ext)
        else:
            c += "\n# auto-added: " + ext + "\n"
            added.append(ext)

    c += "\n# VK_MESA_EXT_TABLE_PATCHED\n"

    with open(vk_ext_py_path, "w") as f:
        f.write(c)
    print(f"[OK] vk_extensions.py: added {len(added)} entries (template: {entry_template}): {added}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 vk_extensions_patch.py <path/to/vk_extensions.py>")
        sys.exit(1)
    patch_vk_extensions(sys.argv[1])
