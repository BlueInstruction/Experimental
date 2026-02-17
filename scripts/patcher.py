#!/usr/bin/env python3

import os
import sys
import re
import glob
import json
import logging
from typing import List, Tuple, Dict
from datetime import datetime

logging.basicConfig(level=logging.INFO, format='[%(levelname)s] %(message)s')
log = logging.getLogger(__name__)

PT = Tuple[str, str, str]

def mk_asgn(var: str) -> str:
    esc = re.escape(var)
    return rf'(\b{esc}\s*=\s*)([^;]+);'

GPU_P: List[PT] = [
    (mk_asgn('adapter_id.vendor_id'), r'\g<1>0x1002;', 'gpu_vid'),
    (mk_asgn('adapter_id.device_id'), r'\g<1>0x73DF;', 'gpu_did'),
    (r'(VendorId\s*=\s*)[^;]+;', r'\g<1>0x1002;', 'gpu_vid2'),
    (r'(DeviceId\s*=\s*)[^;]+;', r'\g<1>0x73DF;', 'gpu_did2'),
    (r'(SharedSystemMemory\s*=\s*)[^;]+;', r'\g<1>16384ULL * 1024 * 1024;', 'gpu_mem'),
]

SM_P: List[PT] = [
    (mk_asgn('data->HighestShaderModel'), r'\g<1>D3D_SHADER_MODEL_6_8;', 'sm'),
    (mk_asgn('info.HighestShaderModel'), r'\g<1>D3D_SHADER_MODEL_6_8;', 'sm_info'),
]

WV_P: List[PT] = [
    (mk_asgn('options1.WaveOps'), r'\g<1>TRUE;', 'wv0'),
    (mk_asgn('options1.WaveLaneCountMin'), r'\g<1>32;', 'wv1'),
    (mk_asgn('options1.WaveLaneCountMax'), r'\g<1>128;', 'wv2'),
]

RB_P: List[PT] = [
    (mk_asgn('options.ResourceBindingTier'), r'\g<1>D3D12_RESOURCE_BINDING_TIER_3;', 'rb0'),
    (mk_asgn('options.TiledResourcesTier'), r'\g<1>D3D12_TILED_RESOURCES_TIER_4;', 'rb1'),
    (mk_asgn('options.ResourceHeapTier'), r'\g<1>D3D12_RESOURCE_HEAP_TIER_2;', 'rb2'),
]

SO_P: List[PT] = [
    (mk_asgn('options.DoublePrecisionFloatShaderOps'), r'\g<1>TRUE;', 'so0'),
    (mk_asgn('options1.Int64ShaderOps'), r'\g<1>TRUE;', 'so1'),
    (mk_asgn('options4.Native16BitShaderOpsSupported'), r'\g<1>TRUE;', 'so2'),
]

MS_P: List[PT] = [
    (mk_asgn('options7.MeshShaderTier'), r'\g<1>D3D12_MESH_SHADER_TIER_1;', 'ms0'),
    (mk_asgn('options12.EnhancedBarriersSupported'), r'\g<1>TRUE;', 'ms7'),
]

RT_P: List[PT] = [
    (mk_asgn('options5.RaytracingTier'), r'\g<1>D3D12_RAYTRACING_TIER_1_1;', 'rt0'),
    (mk_asgn('options5.RenderPassesTier'), r'\g<1>D3D12_RENDER_PASS_TIER_2;', 'rt1'),
    (mk_asgn('options6.VariableShadingRateTier'), r'\g<1>D3D12_VARIABLE_SHADING_RATE_TIER_2;', 'rt2'),
    (mk_asgn('options6.ShadingRateImageTileSize'), r'\g<1>8;', 'rt3'),
    (mk_asgn('options6.BackgroundProcessingSupported'), r'\g<1>TRUE;', 'rt4'),
]

SF_P: List[PT] = [
    (mk_asgn('options7.SamplerFeedbackTier'), r'\g<1>D3D12_SAMPLER_FEEDBACK_TIER_1_0;', 'sf0'),
    (mk_asgn('options2.DepthBoundsTestSupported'), r'\g<1>TRUE;', 'sf1'),
]

TX_P: List[PT] = [
    (mk_asgn('options8.UnalignedBlockTexturesSupported'), r'\g<1>TRUE;', 'tx0'),
]

RN_P: List[PT] = [
    (mk_asgn('options15.TriangleFanSupported'), r'\g<1>TRUE;', 'rn4'),
]

class Vkd3dPatcher:
    CAP_F = ['device.c']
    EX_D = ['tests', 'demos', 'include', '.git']
    VER = "3.2.0"

    def __init__(self, profile: str = 'p7', gpu: bool = True, dry: bool = False, verb: bool = False):
        self.profile = profile
        self.gpu = gpu
        self.dry = dry
        self.verb = verb
        self.applied = 0
        self.skipped = 0
        self.failed = 0
        self.errors: List[str] = []
        self.details: List[Dict] = []
        if verb:
            logging.getLogger().setLevel(logging.DEBUG)

    def _get_patches(self) -> List[List[PT]]:
        base = [SM_P, WV_P, RB_P, SO_P]
        ext = [MS_P, RT_P, SF_P, TX_P, RN_P]
        if self.profile == 'p3':
            return base
        if self.profile in ['p7','p9']:
            return base + ext
        if self.profile == 'high':
            return base + ext + [GPU_P]
        return base

    def _apply_content(self, content: str, patches: List[PT]) -> Tuple[str,int,int,List[Dict]]:
        applied = 0
        skipped = 0
        changes = []
        for patch_group in patches:
            for pattern, repl, name in patch_group:
                try:
                    rgx = re.compile(pattern, re.MULTILINE)
                    count = len(rgx.findall(content))
                    if count:
                        if not self.dry:
                            content = rgx.sub(repl, content)
                        applied += count
                        changes.append({'patch': name, 'count': count})
                    else:
                        skipped += 1
                except re.error as e:
                    self.errors.append(f"RE:{name}:{e}")
        return content, applied, skipped, changes

    def _find_files(self, src: str, pat: str) -> List[str]:
        files = glob.glob(os.path.join(src, '**', pat), recursive=True)
        return [f for f in files if not any(ex in f for ex in self.EX_D)]

    def _find_vkd3d(self, src: str) -> str:
        for c in [os.path.join(src, 'libs', 'vkd3d'), os.path.join(src, 'src'), src]:
            if os.path.isdir(c):
                if glob.glob(os.path.join(c, '**', 'device.c'), recursive=True):
                    return c
        return src

    def apply(self, src: str) -> bool:
        vkd3d = self._find_vkd3d(src)
        cap_files = []
        for cf in self.CAP_F:
            cap_files.extend(self._find_files(vkd3d, cf))

        patches = self._get_patches()

        for fp in cap_files:
            with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
            content_new, a, s, changes = self._apply_content(content, patches)
            if not self.dry:
                with open(fp, 'w', encoding='utf-8') as f:
                    f.write(content_new)
            self.applied += a
            self.skipped += s
            if changes:
                self.details.append({'file': fp, 'changes': changes})
            if self.verb:
                log.info(f"Patched {fp}: applied={a}, skipped={s}")

        log.info(f"Total applied: {self.applied}, skipped: {self.skipped}, errors: {len(self.errors)}")
        if self.errors:
            for err in self.errors[:10]:
                log.error(err)

        return self.failed == 0 and len(self.errors) == 0

    def report(self, out: str = 'patch-report.json') -> None:
        r = {
            'v': self.VER,
            'profile': self.profile,
            'applied': self.applied,
            'skipped': self.skipped,
            'errors': self.errors,
            'details': self.details,
            'timestamp': datetime.utcnow().isoformat()
        }
        with open(out, 'w', encoding='utf-8') as f:
            json.dump(r, f, indent=2)
        log.info(f"Report saved: {out}")

def main() -> int:
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('src')
    parser.add_argument('--profile', choices=['p3','p7','p9','high'], default='high')
    parser.add_argument('--no-gpu', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--verbose','-v', action='store_true')
    parser.add_argument('--report', action='store_true')
    args = parser.parse_args()

    patcher = Vkd3dPatcher(profile=args.profile, gpu=not args.no_gpu, dry=args.dry_run, verb=args.verbose)
    success = patcher.apply(args.src)

    if args.report:
        patcher.report()

    return 0 if success else 1

if __name__ == '__main__':
    sys.exit(main())
