# Third-Party Licenses & Distribution Audit

UPreviewX links dynamically against `libmpv` (`libmpv.2.dylib`) and its transitive multimedia decoding and rendering dependencies located in `UPreviewX.app/Contents/Frameworks/`.

## 1. Distribution & License Compliance Summary

Because the bundled `libmpv.2.dylib` and `FFmpeg` (`libavcodec.61.dylib`, `libavformat.61.dylib`, `libavfilter.10.dylib`, `libavutil.59.dylib`, `libswscale.8.dylib`, `libswresample.5.dylib`, `libpostproc.58.dylib`) builds are compiled with `--enable-gpl` and `--enable-version3`:

1. **Aggregate Distribution License**: Any binary distribution of `UPreviewX.app` that bundles these GPL-configured dynamic libraries must comply with the **GNU General Public License v2.0 or later (GPLv2+ / GPLv3)**.
2. **Dynamic Linking Architecture**: All third-party libraries are kept as separate Mach-O dynamic libraries (`.dylib`) in `Contents/Frameworks/` loaded via `@rpath` (`@executable_path/../Frameworks`), allowing end users to inspect or replace any bundled library.
3. **Source Code Availability**: Distributing `UPreviewX.app` binaries alongside these bundled `.dylib` files requires providing the complete corresponding source code of UPreviewX and offering or pointing to the exact upstream source revisions of `mpv` and `FFmpeg` (listed below).
4. **Optional LGPL-Only Commercial Build Path**: If a future proprietary distribution is desired without GPL obligations, `libmpv` and `FFmpeg` must be recompiled without `--enable-gpl` (disabling `libx264`, `libx265`, `libvidstab`, `librubberband`, and `frei0r`, while retaining LGPLv2.1+ decoders, `VideoToolbox` hardware acceleration, and BSD-licensed `libdav1d`).

---

## 2. Primary Bundled Libraries

| Component | Dylib(s) | Version / Revision | License | Purpose |
|-----------|----------|--------------------|---------|---------|
| **libmpv** | `libmpv.2.dylib` | `0.38.0` (`mpv-iina/HEAD-c0dd2b3`) | GPLv2+ / LGPLv2.1+ (built with `gpl`) | Core media playback & OpenGL render context engine |
| **FFmpeg** | `libavcodec.61.dylib`, `libavformat.61.dylib`, `libavutil.59.dylib`, `libavfilter.10.dylib`, `libswscale.8.dylib`, `libswresample.5.dylib` | `7.0.1` | GPLv3+ (built with `--enable-gpl --enable-version3`) | Demuxing, VideoToolbox integration, software decode fallback (HEVC 4:2:2, ProRes, DNxHR, VP9) |
| **dav1d** | `libdav1d.7.dylib` | `1.4.x` | BSD 2-Clause | High-performance multi-threaded AV1 software decoder |
| **libplacebo** | `libplacebo.338.dylib` | `6.338.x` | LGPLv2.1+ | GPU color management and tone-mapping primitives |
| **Little CMS** | `liblcms2.2.dylib` | `2.16` | MIT | ICC color profile management |
| **zimg** | `libzimg.2.dylib` | `3.0.5` | WTFPL / Public Domain | High-precision colorspace conversion |
| **libass** | `libass.9.dylib` | `0.17.x` | ISC | Subtitle rendering support in `libmpv` |
| **LuaJIT / MuJS** | `libluajit-5.1.2.dylib`, `libmujs.dylib` | `2.1` / `1.3` | MIT / ISC | Linked by `libmpv` runtime (scripts disabled at launch via `load-scripts=no`) |
| **GnuTLS / Nettle / GMP** | `libgnutls.30.dylib`, `libnettle.8.dylib`, `libhogweed.6.dylib`, `libgmp.10.dylib` | `3.8.x` | LGPLv2.1+ / LGPLv3+ | Transport layer security dependencies of `libavformat` |
| **Compression & Utility Libs** | `libzstd.1.dylib`, `liblz4.1.dylib`, `liblzma.5.dylib`, `libbrotli*.dylib`, `libarchive.13.dylib` | Various | BSD / MIT / Public Domain | Container & archive decompression support |

