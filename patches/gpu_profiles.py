from typing import Dict, List, Tuple
from .core import mk_asgn

PT = Tuple[str, str, str]


class GPUCfg:
    def __init__(self, n: str, vid: str, did: str, desc: str, mem: int = 16384):
        self.n = n
        self.vid = vid
        self.did = did
        self.desc = desc
        self.mem = mem

    def patches(self) -> List[PT]:
        return [
            (mk_asgn('adapter_id.vendor_id'), rf'\g<1>{self.vid};', 'g0'),
            (mk_asgn('adapter_id.device_id'), rf'\g<1>{self.did};', 'g1'),
            (r'(VendorId\s*=\s*)[^;]+;', rf'\g<1>{self.vid};', 'g2'),
            (r'(DeviceId\s*=\s*)[^;]+;', rf'\g<1>{self.did};', 'g3'),
            (r'(SharedSystemMemory\s*=\s*)[^;]+;', rf'\g<1>{self.mem} * 1024 * 1024;', 'g4'),
        ]

    def to_dict(self) -> Dict:
        return {'n': self.n, 'vid': self.vid, 'did': self.did, 'desc': self.desc, 'mem': self.mem}


D3MU = GPUCfg("D3MU", "0x1002", "0x163f", "ACG0405", 16384)

GPU_CFG: Dict[str, GPUCfg] = {'d3mu': D3MU}

DEFAULT_CFG = D3MU
