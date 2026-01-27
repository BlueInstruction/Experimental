from dataclasses import dataclass, field
from enum import Enum
from typing import List, Dict, Any
import re


class PatchProfile(Enum):
    P3 = "p3"
    P7 = "p7"
    P9 = "p9"


@dataclass
class PatchResult:
    applied: int = 0
    skipped: int = 0
    failed: int = 0
    errors: List[str] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)
    details: List[Dict[str, Any]] = field(default_factory=list)

    def merge(self, other: 'PatchResult') -> None:
        self.applied += other.applied
        self.skipped += other.skipped
        self.failed += other.failed
        self.errors.extend(other.errors)
        self.warnings.extend(other.warnings)
        self.details.extend(other.details)

    @property
    def success(self) -> bool:
        return self.failed == 0 and len(self.errors) == 0


@dataclass
class PatchDef:
    pattern: str
    replacement: str
    name: str
    desc: str = ""
    req: bool = False

    def compile(self) -> re.Pattern:
        return re.compile(self.pattern, re.MULTILINE)


def mk_asgn(var: str) -> str:
    esc = re.escape(var)
    return rf'(?<![=!<>])(\b{esc}\s*=\s*)(?![=])([^;]+);'


def mk_def(macro: str) -> str:
    return rf'#define\s+{re.escape(macro)}\s+\d+'
