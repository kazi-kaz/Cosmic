# vkd3d-proton patches

Applied in numeric order by `build/vkd3d-proton/build.sh` (`patch -p1`) to upstream
vkd3d-proton `4522cc1a8b1347f1ab1b0f7b14a23ed9444d95d1` (v3.1; the first three were written against 750061ae2b and apply unchanged). All three come from NutsEmu
0.0.1 build 1382 (Evan Bolton, published corresponding source,
`patches/vkd3d-proton/`), LGPL-2.1-or-later like vkd3d-proton. Each file's header keeps
the origin and the dates NutsEmu gives. Madeira's copies (2026-10-12) change no code;
comments were reworded to leave out application names.

| Patch | First added (NutsEmu) | Summary |
|---|---|---|
| 0001-transform-feedback-and-texel-alignment-optional.patch | 2026-10-05 | No transform feedback or single-texel alignment: a warning instead of a device-creation failure (stream output then unavailable) |
| 0002-no-layered-api-properties.patch | 2026-10-05 | The VK_KHR_maintenance7 layered-API properties chain is not queried (winevulkan faulted converting it back) |
| 0003-kosmickrisp-shader-model-gates.patch | 2026-10-06 | On VK_DRIVER_ID_MESA_KOSMICKRISP only: feature level 12_0 without tiled resources, shader model past 6.0 without float32 denormal control, the compute-derivatives fallback for 6.6; plus one INFO line with the feature-level inputs (every driver) |
| 0004-kosmickrisp-small-occlusion-pool.patch | Madeira, 2026-11-20 | Smaller occlusion query pools (env MADEIRA_KK_OCCLUSION_POOL = 0 turns it off; 64-4096 sets the size) |
| 0005-placed-buffer-offset.patch | Madeira, 2026-11-20 | Placed buffers at the offset the heap needs (env MADEIRA_VKD3D_PLACED_BUFFER_OFFSET = 0 turns it off) |
