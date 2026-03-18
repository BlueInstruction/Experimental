import sys, re, os

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

def patch_vk_xml(vk_xml_path):
    if not os.path.exists(vk_xml_path):
        print(f"[WARN] vk.xml not found at {vk_xml_path}")
        return
    with open(vk_xml_path) as f:
        c = f.read()
    added = []
    for ext in MISSING:
        if f'name="{ext}"' in c:
            continue
        vendor = ext.split("_")[1]
        ext_lower = ext[len("VK_"):].lower()
        xml_entry = (
            f'\n    <extension name="{ext}" number="9999" type="device"'
            f' author="{vendor}" contact="Mesa patched"'
            f' supported="vulkan" ratified="vulkan">\n'
            f'      <require>\n'
            f'        <enum value="1" name="{ext}_SPEC_VERSION"/>\n'
            f'        <enum value="&quot;{ext[3:]}&quot;" name="{ext}_EXTENSION_NAME"/>\n'
            f'      </require>\n'
            f'    </extension>'
        )
        anchor = c.rfind("</extensions>")
        if anchor != -1:
            c = c[:anchor] + xml_entry + "\n" + c[anchor:]
            added.append(ext)
    if added:
        with open(vk_xml_path, "w") as f:
            f.write(c)
        print(f"[OK] vk.xml: added {len(added)} extension entries: {added}")
    else:
        print("[OK] vk.xml: all extensions already present")

def patch_vk_extensions(vk_ext_py_path):
    if not os.path.exists(vk_ext_py_path):
        print(f"[WARN] {vk_ext_py_path} not found")
        return
    with open(vk_ext_py_path) as f:
        c = f.read()
    if "VK_MESA_EXT_TABLE_PATCHED" in c:
        print("[OK] vk_extensions.py already patched")
        return

    # Fix __init__ to handle None ext_version
    if "self.ext_version = int(ext_version)" in c:
        c = c.replace(
            "self.ext_version = int(ext_version)",
            "self.ext_version = int(ext_version) if ext_version is not None else 0"
        )
        print("[OK] Fixed ext_version None handling in __init__")

    needs_int = bool(re.search(r'self\.ext_version\s*=\s*int\(', c))
    existing_m = re.search(
        r'Extension\s*\(\s*"VK_\w+"\s*,\s*(\d+|True|False)\s*(?:,\s*([^)]+))?\s*\)',
        c
    )
    if needs_int:
        entry_args = "1, None"
        if existing_m:
            ver = existing_m.group(1)
            try:
                int(ver)
                entry_args = ver + ", None"
            except ValueError:
                pass
    else:
        entry_args = "True, None"
        if existing_m:
            ver = existing_m.group(1)
            extra = existing_m.group(2)
            entry_args = ver + (", " + extra.strip() if extra else "")

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
        print("Usage: python3 vk_extensions_patch.py <vk_extensions.py> [vk.xml]")
        sys.exit(1)
    patch_vk_extensions(sys.argv[1])
    if len(sys.argv) >= 3:
        patch_vk_xml(sys.argv[2])
    else:
        # Auto-detect vk.xml relative to vk_extensions.py
        base = os.path.dirname(sys.argv[1])
        xml_candidates = [
            os.path.join(base, "..", "..", "registry", "vk.xml"),
            os.path.join(base, "..", "registry", "vk.xml"),
            os.path.join(base, "registry", "vk.xml"),
        ]
        for xml_path in xml_candidates:
            xml_path = os.path.normpath(xml_path)
            if os.path.exists(xml_path):
                patch_vk_xml(xml_path)
                break
        else:
            print("[WARN] vk.xml not found automatically — extensions may not appear in VkExtensionProperties")
