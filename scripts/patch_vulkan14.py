import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

# Force VK_API_VERSION_1_4 in apiVersion
n_api = 0
for pat in [
    r'(\.apiVersion\s*=\s*)VK_MAKE_API_VERSION\([^)]+\)',
    r'(apiVersion\s*=\s*)VK_MAKE_API_VERSION\([^)]+\)',
    r'(props->apiVersion\s*=\s*)VK_MAKE_API_VERSION\([^)]+\)',
]:
    c, k = re.subn(pat, r'\1VK_MAKE_API_VERSION(0, 1, 4, 344) /* VK14_PROMOTION_APPLIED */', c)
    n_api += k

# Enable KHR_maintenance5
for pat in [
    r'(\.KHR_maintenance5\s*=\s*)false',
    r'(\.KHR_maintenance5\s*=\s*)None',
]:
    c = re.sub(pat, r'\1true', c)

# Enable KHR_maintenance6
for pat in [
    r'(\.KHR_maintenance6\s*=\s*)false',
    r'(\.KHR_maintenance6\s*=\s*)None',
]:
    c = re.sub(pat, r'\1true', c)

# Force Vulkan13Features that a750 supports but may not advertise
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

# Force Vulkan14Features (maintenance5/6 core)
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
print(f"[OK] apiVersion patched: {n_api} sites, features forced: {n_feat}")
