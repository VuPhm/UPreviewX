#define GL_SILENCE_DEPRECATION 1
#include "mpv_shim.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <sys/time.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <string.h>

static void *gl_get_proc_address(void *ctx, const char *name) {
    (void)ctx;
    static void *gl_handle = NULL;
    if (!gl_handle) {
        gl_handle = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY | RTLD_LOCAL);
    }
    if (gl_handle) {
        void *sym = dlsym(gl_handle, name);
        if (sym) return sym;
    }
    return dlsym(RTLD_DEFAULT, name);
}

int cmpv_create_opengl_render_context(mpv_handle *mpv, mpv_render_context **out_ctx) {
    mpv_opengl_init_params gl_init = {
        .get_proc_address = gl_get_proc_address,
        .get_proc_address_ctx = NULL
    };
    int adv_control = 1;
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL },
        { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init },
        { MPV_RENDER_PARAM_ADVANCED_CONTROL, &adv_control },
        { MPV_RENDER_PARAM_INVALID, NULL }
    };
    return mpv_render_context_create(out_ctx, mpv, params);
}

int cmpv_render_opengl_fbo(mpv_render_context *ctx, int fbo, int width, int height, int skip_rendering) {
    mpv_opengl_fbo mpfbo = {
        .fbo = fbo,
        .w = width,
        .h = height,
        .internal_format = 0
    };
    int flip_y = 1;
    int block_for_target = 0;
    int skip = skip_rendering ? 1 : 0;
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_OPENGL_FBO, &mpfbo },
        { MPV_RENDER_PARAM_FLIP_Y, &flip_y },
        { MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block_for_target },
        { MPV_RENDER_PARAM_SKIP_RENDERING, &skip },
        { MPV_RENDER_PARAM_INVALID, NULL }
    };
    return mpv_render_context_render(ctx, params);
}

void cmpv_prefer_integrated_gpu(void *cgl_ctx, void *cgl_pix) {
    if (!cgl_ctx || !cgl_pix) return;
    CGLContextObj ctx = (CGLContextObj)cgl_ctx;
    CGLPixelFormatObj pix = (CGLPixelFormatObj)cgl_pix;
    GLint nScreens = 0;
    if (CGLDescribePixelFormat(pix, 0, kCGLPFAVirtualScreenCount, &nScreens) == kCGLNoError && nScreens > 1) {
        for (GLint i = 0; i < nScreens; i++) {
            if (CGLSetVirtualScreen(ctx, i) == kCGLNoError) {
                const char *renderer = (const char *)glGetString(GL_RENDERER);
                if (renderer && strstr(renderer, "Intel") != NULL) {
                    return;
                }
            }
        }
        CGLSetVirtualScreen(ctx, 0);
    }
}

const char *cmpv_current_gl_renderer(void) {
    const GLubyte *renderer = glGetString(GL_RENDERER);
    return renderer ? (const char *)renderer : "Unknown GPU";
}

void cmpv_get_process_usage(double *out_cpu_percent, double *out_rss_mb) {
    if (out_rss_mb) *out_rss_mb = 0.0;
    if (out_cpu_percent) *out_cpu_percent = 0.0;

    struct mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        if (out_rss_mb) {
            *out_rss_mb = (double)info.resident_size / (1024.0 * 1024.0);
        }
    }

    thread_array_t thread_list;
    mach_msg_type_number_t thread_count;
    if (task_threads(mach_task_self(), &thread_list, &thread_count) == KERN_SUCCESS) {
        double total_cpu = 0.0;
        for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
            thread_info_data_t thinfo;
            mach_msg_type_number_t thread_info_count = THREAD_INFO_MAX;
            if (thread_info(thread_list[i], THREAD_BASIC_INFO, (thread_info_t)thinfo, &thread_info_count) == KERN_SUCCESS) {
                thread_basic_info_t basic_info_th = (thread_basic_info_t)thinfo;
                if (!(basic_info_th->flags & TH_FLAGS_IDLE)) {
                    total_cpu += ((double)basic_info_th->cpu_usage / (double)TH_USAGE_SCALE) * 100.0;
                }
            }
            mach_port_deallocate(mach_task_self(), thread_list[i]);
        }
        vm_deallocate(mach_task_self(), (vm_address_t)thread_list, sizeof(thread_t) * thread_count);
        if (out_cpu_percent) {
            *out_cpu_percent = total_cpu;
        }
    }
}
