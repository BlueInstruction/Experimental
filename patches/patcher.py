#!/usr/bin/env python3

import os
import re
import glob
import json
import logging
from typing import List, Tuple, Dict, Any, Optional
from datetime import datetime

from .core import PatchResult, PatchProfile
from .profiles import SM_P, WV_P, RB_P, SO_P, MS_P, RT_P, SF_P, TX_P, RN_P, PF_P, CP_P
from .gpu_profiles import GPUCfg, DEFAULT_CFG, GPU_CFG

logging.basicConfig(level=logging.INFO, format='[%(levelname)s] %(message)s')
log = logging.getLogger(__name__)

PT = Tuple[str, str, str]


class V3XPatcher:
    CAP_F = ['device.c']
    EX_D = ['tests', 'demos', 'include', '.git']
    VER = "2.0.0"

    def __init__(self, profile: PatchProfile = PatchProfile.P7, gpu: Optional[GPUCfg] = None, dry: bool = False, verb: bool = False):
        self.profile = profile
        self.gpu = gpu or DEFAULT_CFG
        self.dry = dry
        self.verb = verb
        self.result = PatchResult()
        if verb:
            logging.getLogger().setLevel(logging.DEBUG)

    def _get_patches(self) -> List[List[PT]]:
        base = [SM_P, WV_P, RB_P, SO_P]
        if self.profile == PatchProfile.P3:
            return base
        ext = [MS_P, RT_P, SF_P, TX_P]
        if self.profile == PatchProfile.P7:
            return base + ext
        if self.profile == PatchProfile.P9:
            return base + ext + [RN_P]
        return base

    def _apply_content(self, content: str, patches: List[PT]) -> Tuple[str, int, int, List[Dict]]:
        applied = 0
        skipped = 0
        changes = []
        for pattern, repl, name in patches:
            try:
                rgx = re.compile(pattern, re.MULTILINE)
                m = len(rgx.findall(content))
                if m > 0:
                    if not self.dry:
                        content = rgx.sub(repl, content)
                    applied += m
                    changes.append({'n': name, 'c': m})
                else:
                    skipped += 1
            except re.error as e:
                self.result.errors.append(f"RE:{name}:{e}")
        return content, applied, skipped, changes

    def _apply_file(self, fp: str, patches: List[PT]) -> None:
        if not os.path.exists(fp):
            return
        try:
            with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
        except Exception as e:
            self.result.errors.append(f"R:{fp}:{e}")
            return
        orig = content
        content, applied, skipped, changes = self._apply_content(content, patches)
        self.result.applied += applied
        self.result.skipped += skipped
        if changes:
            self.result.details.append({'f': os.path.basename(fp), 'p': fp, 'ch': changes})
        if content != orig and not self.dry:
            try:
                with open(fp, 'w', encoding='utf-8') as f:
                    f.write(content)
            except Exception as e:
                self.result.errors.append(f"W:{fp}:{e}")
                self.result.failed += 1

    def _find_files(self, src: str, pat: str) -> List[str]:
        files = glob.glob(os.path.join(src, '**', pat), recursive=True)
        return [f for f in files if not any(ex in f for ex in self.EX_D)]

    def _find_vkd3d(self, src: str) -> str:
        for c in [os.path.join(src, 'libs', 'vkd3d'), os.path.join(src, 'src'), src]:
            if os.path.isdir(c):
                if glob.glob(os.path.join(c, '**', 'device.c'), recursive=True):
                    return c
        return src

    def apply(self, src: str) -> PatchResult:
        log.info(f"V3X v{self.VER}")
        log.info(f"S:{src}")
        log.info(f"P:{self.profile.value}")
        log.info(f"G:{self.gpu.n}")
        log.info(f"M:{'dry' if self.dry else 'apply'}")

        vkd3d = self._find_vkd3d(src)
        log.info(f"D:{vkd3d}")

        cap_files = []
        for cf in self.CAP_F:
            cap_files.extend(self._find_files(vkd3d, cf))
        log.info(f"CF:{len(cap_files)}")

        patches = self._get_patches()
        for fp in cap_files:
            log.info(f"P:{os.path.basename(fp)}")
            for pg in patches:
                self._apply_file(fp, pg)
            if self.gpu:
                self._apply_file(fp, self.gpu.patches())

        all_c = self._find_files(src, '*.[ch]')
        log.info(f"TF:{len(all_c)}")

        for fp in all_c:
            self._apply_file(fp, CP_P)
            self._apply_file(fp, PF_P)

        log.info(f"A:{self.result.applied}")
        log.info(f"S:{self.result.skipped}")
        log.info(f"E:{len(self.result.errors)}")

        if self.result.errors:
            for err in self.result.errors[:10]:
                log.error(err)

        return self.result

    def report(self, out: str) -> None:
        r = {
            'v': self.VER,
            't': datetime.utcnow().isoformat(),
            'bn': 'd3mu',
            'cfg': {'p': self.profile.value, 'g': self.gpu.to_dict() if self.gpu else None, 'd': self.dry},
            'f': {
                'sm': '6.9', 'fl': '12_2', 'gs': '0x1002:0x163f',
                'ext': {
                    'ms': self.profile in [PatchProfile.P7, PatchProfile.P9],
                    'rt': self.profile in [PatchProfile.P7, PatchProfile.P9],
                    'sf': self.profile in [PatchProfile.P7, PatchProfile.P9],
                    'wg': True, 'vrs': True, 'eb': True,
                },
            },
            'st': {'a': self.result.applied, 's': self.result.skipped, 'f': self.result.failed, 'e': len(self.result.errors)},
            'd': self.result.details,
            'err': self.result.errors,
            'w': self.result.warnings,
        }
        with open(out, 'w', encoding='utf-8') as f:
            json.dump(r, f, indent=2)
        log.info(f"R:{out}")


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description='V3X Patcher')
    parser.add_argument('src', help='Source directory')
    parser.add_argument('--profile', choices=['p3', 'p7', 'p9'], default='p7')
    parser.add_argument('--no-gpu', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--verbose', '-v', action='store_true')
    parser.add_argument('--report', action='store_true')

    args = parser.parse_args()

    if not os.path.isdir(args.src):
        log.error(f"NF:{args.src}")
        return 1

    pm = {'p3': PatchProfile.P3, 'p7': PatchProfile.P7, 'p9': PatchProfile.P9}
    gpu = None if args.no_gpu else DEFAULT_CFG

    patcher = V3XPatcher(profile=pm[args.profile], gpu=gpu, dry=args.dry_run, verb=args.verbose)
    result = patcher.apply(args.src)

    if args.report:
        patcher.report('patch-report.json')

    return 0 if result.success else 1


if __name__ == '__main__':
    exit(main())
