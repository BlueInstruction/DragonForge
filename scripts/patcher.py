#!/usr/bin/env python3

import os
import sys
import re
import glob
import logging
from typing import List, Tuple

logging.basicConfig(level=logging.INFO, format='[%(levelname)s] %(message)s')
log = logging.getLogger(__name__)

PT = Tuple[str, str, str]

def mk_asgn(var: str) -> str:
    esc = re.escape(var)
    return rf'(\b{esc}\s*=\s*)([^;]+);'

# GPU spoofing: AMD RX 6700 XT reference IDs
GPU_P: List[PT] = [
    (mk_asgn('adapter_id.vendor_id'), r'\g<1>0x1002;', 'gpu_vid'),         # AMD vendor
    (mk_asgn('adapter_id.device_id'), r'\g<1>0x73DF;', 'gpu_did'),         # RX 6700 XT
    (r'(SharedSystemMemory\s*=\s*)[^;]+;', r'\g<1>16384ULL * 1024 * 1024;', 'gpu_mem'),  # 16GB system mem
]

# Shader Model
SM_P: List[PT] = [
    (mk_asgn('data->HighestShaderModel'), r'\g<1>D3D_SHADER_MODEL_6_7;', 'sm'),
    (mk_asgn('info.HighestShaderModel'), r'\g<1>D3D_SHADER_MODEL_6_7;', 'sm_info'),
]

# Wave ops
WV_P: List[PT] = [
    (mk_asgn('options1.WaveOps'), r'\g<1>TRUE;', 'wv0'),
    (mk_asgn('options1.WaveLaneCountMin'), r'\g<1>32;', 'wv1'),
    (mk_asgn('options1.WaveLaneCountMax'), r'\g<1>128;', 'wv2'),
]

# Resource & tiled resources
RB_P: List[PT] = [
    (mk_asgn('options.ResourceBindingTier'), r'\g<1>D3D12_RESOURCE_BINDING_TIER_3;', 'rb0'),
    (mk_asgn('options.TiledResourcesTier'), r'\g<1>D3D12_TILED_RESOURCES_TIER_4;', 'rb1'),
    (mk_asgn('options.ResourceHeapTier'), r'\g<1>D3D12_RESOURCE_HEAP_TIER_2;', 'rb2'),
]

# Shader ops
SO_P: List[PT] = [
    (mk_asgn('options.DoublePrecisionFloatShaderOps'), r'\g<1>TRUE;', 'so0'),
    (mk_asgn('options1.Int64ShaderOps'), r'\g<1>TRUE;', 'so1'),
    (mk_asgn('options4.Native16BitShaderOpsSupported'), r'\g<1>TRUE;', 'so2'),
]

# Mesh shaders
MS_P: List[PT] = [
    (mk_asgn('options7.MeshShaderTier'), r'\g<1>D3D12_MESH_SHADER_TIER_1;', 'ms0'),
    (mk_asgn('options12.EnhancedBarriersSupported'), r'\g<1>TRUE;', 'ms7'),
]

# Ray tracing
RT_P: List[PT] = [
    (mk_asgn('options5.RaytracingTier'), r'\g<1>D3D12_RAYTRACING_TIER_1_1;', 'rt0'),
    (mk_asgn('options5.RenderPassesTier'), r'\g<1>D3D12_RENDER_PASS_TIER_2;', 'rt1'),
    (mk_asgn('options6.VariableShadingRateTier'), r'\g<1>D3D12_VARIABLE_SHADING_RATE_TIER_2;', 'rt2'),
    (mk_asgn('options6.ShadingRateImageTileSize'), r'\g<1>8;', 'rt3'),
    (mk_asgn('options6.BackgroundProcessingSupported'), r'\g<1>TRUE;', 'rt4'),
]

# Sampler Feedback
SF_P: List[PT] = [
    (mk_asgn('options7.SamplerFeedbackTier'), r'\g<1>D3D12_SAMPLER_FEEDBACK_TIER_1_0;', 'sf0'),
    (mk_asgn('options2.DepthBoundsTestSupported'), r'\g<1>TRUE;', 'sf1'),
]

# Textures
TX_P: List[PT] = [
    (mk_asgn('options8.UnalignedBlockTexturesSupported'), r'\g<1>TRUE;', 'tx0'),
]

# Triangle fan
RN_P: List[PT] = [
    (mk_asgn('options15.TriangleFanSupported'), r'\g<1>TRUE;', 'rn4'),
]

class HighPatcher:
    CAP_F = ['device.c']
    EX_D = ['tests', 'demos', 'include', '.git']
    VER = "3.0.0"

    def __init__(self, profile: str = 'high'):
        self.profile = profile

    def _find_files(self, src: str, pat: str) -> list[str]:
        files = glob.glob(os.path.join(src, '**', pat), recursive=True)
        return [f for f in files if not any(ex in f for ex in self.EX_D)]

    def _apply_content(self, content: str, patches: list[PT]) -> str:
        for pattern, repl, _ in patches:
            content = re.sub(pattern, repl, content, flags=re.MULTILINE)
        return content

    def apply(self, src: str) -> int:
        vkd3d_dirs = [os.path.join(src, 'libs', 'vkd3d'), os.path.join(src, 'src'), src]
        target_dir = next((d for d in vkd3d_dirs if os.path.isdir(d) and glob.glob(os.path.join(d, '**', 'device.c'), recursive=True)), src)

        cap_files = []
        for cf in self.CAP_F:
            cap_files.extend(self._find_files(target_dir, cf))

        if self.profile == 'high':
            patches = GPU_P + SM_P + WV_P + RB_P + SO_P + MS_P + RT_P + SF_P + TX_P + RN_P
        else:
            patches = GPU_P  # fallback minimal

        for fp in cap_files:
            with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
            content = self._apply_content(content, patches)
            with open(fp, 'w', encoding='utf-8') as f:
                f.write(content)
            log.info(f"Patched: {fp}")

        return 0

def main() -> int:
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('src')
    parser.add_argument('--profile', choices=['high'], default='high')
    args = parser.parse_args()

    return HighPatcher(args.profile).apply(args.src)

if __name__ == '__main__':
    sys.exit(main())
