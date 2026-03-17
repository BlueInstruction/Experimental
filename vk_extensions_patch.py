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

    # Detect Extension() signature by finding class definition or existing calls
    # Mesa vk_extensions.py uses: Extension(name, ext_version, platform=None)
    # where ext_version can be True/False or a string like "DEVICE"
    # We need to match whatever format the file uses

    # Check __init__ signature to determine required args
    init_m = re.search(r'def __init__\s*\(self,\s*([^)]+)\)', c)
    num_required = 3  # default: name, ext_version, platform
    if init_m:
        params = [p.strip() for p in init_m.group(1).split(',')]
        # count params without default values (no '=')
        num_required = sum(1 for p in params if '=' not in p and p != 'self')

    # Find the format used in existing entries to copy
    existing_m = re.search(
        r'Extension\s*\(\s*"VK_\w+"(?:\s*,\s*[^,\n)]+){1,3}\s*\)',
        c,
        re.DOTALL
    )

    if existing_m and num_required >= 3:
        # Extract args from first existing Extension call
        inner = existing_m.group(0)
        args = re.findall(r',\s*([^,)]+)', inner)
        if len(args) >= 2:
            entry_args = ', '.join(a.strip() for a in args[:2])
        else:
            entry_args = 'True, None'
    elif num_required == 2:
        entry_args = '"DEVICE"'
    else:
        entry_args = 'True, None'

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
            entry = '\n    Extension("' + ext + '", ' + entry_args + '),'
            c = c[:ins] + entry + c[ins:]
            added.append(ext)
        else:
            c += "\n# auto-added: " + ext + "\n"
            added.append(ext)

    c += "\n# VK_MESA_EXT_TABLE_PATCHED\n"

    with open(vk_ext_py_path, "w") as f:
        f.write(c)
    print(f"[OK] vk_extensions.py: added {len(added)} entries (args: {entry_args}): {added}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 vk_extensions_patch.py <path/to/vk_extensions.py>")
        sys.exit(1)
    patch_vk_extensions(sys.argv[1])
