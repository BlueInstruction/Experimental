import sys, re, os

fp = sys.argv[1]
with open(fp) as f: c = f.read()

# Auto-detect Vulkan patch version from headers
def detect_vk_patch(mesa_dir):
    candidates = [
        os.path.join(mesa_dir, "include", "vulkan", "vulkan_core.h"),
        os.path.join(mesa_dir, "include", "vulkan", "vulkan.h"),
        os.path.join(mesa_dir, "src", "vulkan", "registry", "vk.xml"),
    ]
    for path in candidates:
        if not os.path.exists(path):
            continue
        with open(path, errors='ignore') as f:
            text = f.read()
        m = re.search(r'VK_HEADER_VERSION_COMPLETE\s+VK_MAKE_API_VERSION\(\s*0\s*,\s*1\s*,\s*4\s*,\s*(\d+)', text)
        if m:
            return int(m.group(1))
        m = re.search(r'#define\s+VK_HEADER_VERSION\s+(\d+)', text)
        if m:
            return int(m.group(1))
        m = re.search(r'<enum\s+value="(\d+)"\s+name="VK_HEADER_VERSION"', text)
        if m:
            return int(m.group(1))
    return None

mesa_dir = os.path.dirname(os.path.dirname(os.path.dirname(fp)))
patch_ver = detect_vk_patch(mesa_dir)
if patch_ver is None:
    patch_ver = 347

api_str = f"VK_MAKE_API_VERSION(0, 1, 4, {patch_ver}) /* VK14_PROMOTION_APPLIED */"

n_api = 0
for pat in [
    r'(\.apiVersion\s*=\s*)VK_MAKE_API_VERSION\([^)]+\)',
    r'(apiVersion\s*=\s*)VK_MAKE_API_VERSION\([^)]+\)',
    r'(props->apiVersion\s*=\s*)VK_MAKE_API_VERSION\([^)]+\)',
]:
    c, k = re.subn(pat, r'\1' + api_str, c)
    n_api += k

for pat in [
    r'(\.KHR_maintenance5\s*=\s*)false',
    r'(\.KHR_maintenance5\s*=\s*)None',
]:
    c = re.sub(pat, r'\1true', c)

for pat in [
    r'(\.KHR_maintenance6\s*=\s*)false',
    r'(\.KHR_maintenance6\s*=\s*)None',
]:
    c = re.sub(pat, r'\1true', c)

FORCE_TRUE_13 = [
    'dynamicRendering',
    'synchronization2',
    'maintenance4',
    'shaderIntegerDotProduct',
    'pipelineCreationCacheControl',
    'privateData',
    'shaderDemoteToHelperInvocation',
    'subgroupSizeControl',
    'computeFullSubgroups',
    'inlineUniformBlock',
    'descriptorIndexing',
    'shaderZeroInitializeWorkgroupMemory',
]
n_feat = 0
for field in FORCE_TRUE_13:
    pat = rf'(features->{re.escape(field)}\s*=\s*)false'
    c, k = re.subn(pat, r'\1true', c)
    n_feat += k

FORCE_TRUE_14 = [
    'maintenance5',
    'maintenance6',
    'maintenance7',
    'maintenance8',
    'maintenance9',
    'maintenance10',
    'pushDescriptor',
    'dynamicRenderingLocalRead',
    'shaderExpectAssume',
    'shaderFloatControls2',
    'globalPriorityQuery',
    'cooperativeMatrix',
    'cooperativeMatrixRobustBufferAccess',
    'unifiedImageLayouts',
    'shaderBFloat16',
    'zeroInitializeDeviceMemory',
    'deviceAddressCommands',
]
for field in FORCE_TRUE_14:
    pat = rf'(features->{re.escape(field)}\s*=\s*)false'
    c, k = re.subn(pat, r'\1true', c)
    n_feat += k

with open(fp, 'w') as f: f.write(c)
print(f"[OK] apiVersion patched: {n_api} sites → 1.4.{patch_ver}, features forced: {n_feat}")
