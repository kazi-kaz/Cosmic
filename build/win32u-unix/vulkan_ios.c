/* LGPL-2.1-or-later: part of the Wine unix side (see docs/LICENSING.md). */
/*
 * win32u's Vulkan layer on iOS: upstream dlls/win32u/vulkan.c, plus the winios
 * driver's Vulkan surface (VK_EXT_metal_surface on the window's CAMetalLayer).
 *
 * Off unless the session asks for Vulkan. WineProcessBridge.m sets
 * MADEIRA_VULKAN_LIBRARY to the bundled Vulkan library (madeira.cfg
 * `vulkan = moltenvk|kosmickrisp`, or `d3d12 = vkd3d`); without it the dlopen
 * below returns NULL and win32u behaves exactly as when it was built without
 * Vulkan (no Vulkan GPUs, __wine_get_vulkan_driver() == NULL, winevulkan's init
 * fails). The library is loaded by full path, like the GL driver's Zink
 * (opengl_ios.c), so MoltenVK is the same image Zink uses when both run.
 *
 * Re-entrancy: Vulkan's set-up (vulkan_init_once) loads the display driver,
 * which can update the display devices, which list Vulkan's GPUs through
 * D3DKMT's Vulkan instance, which calls __wine_get_vulkan_driver() again on the
 * same thread, inside its own pthread_once. Apple's pthread_once traps on that.
 * While one of this file's pthread_once calls runs on a thread, D3DKMT's
 * instance is NULL on that thread (d3dkmt_ios.c), and that nested GPU listing
 * goes without Vulkan GPUs. The same idea as NutsEmu's Wine patch 0083
 * (no-vulkan-gpu-listing-inside-vulkan-setup), written for this tree.
 */

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#if MADEIRA_MOLTENVK
extern void *madeira_vulkan_symbol(const char *name);
#endif

int madeira_vulkan_static_available(void)
{
#if MADEIRA_MOLTENVK
    return 1;
#else
    return 0;
#endif
}
static char ios_vulkan_token;
static void *ios_vulkan_open(const char *name, int flags)
{
    if (strcmp(name, "madeira-static-moltenvk")) return dlopen(name, flags);
#if !MADEIRA_MOLTENVK
    return NULL;
#else
    fprintf(stderr, "[vk-win32u] binding statically linked MoltenVK backend\n");
    return &ios_vulkan_token;
#endif
}
static void *ios_vulkan_sym(void *handle, const char *name)
{
    if (handle != &ios_vulkan_token) return dlsym(handle, name);
#if MADEIRA_MOLTENVK
    return madeira_vulkan_symbol(name);
#else
    return NULL;
#endif
}
static int ios_vulkan_close(void *handle)
{
    return handle == &ios_vulkan_token ? 0 : dlclose(handle);
}

static void *madeira_vulkan_dlopen( const char *name, int flags );
static int madeira_vulkan_pthread_once( pthread_once_t *once, void (*init)(void) );

/* config_ios.h #undefs it for every translation unit; this one loads the library
 * itself (madeira_vulkan_dlopen), so the name is only what the ERR line prints. */
#undef SONAME_LIBVULKAN
#define SONAME_LIBVULKAN "MADEIRA_VULKAN_LIBRARY"
#define dlopen( name, flags ) madeira_vulkan_dlopen( name, flags )
#define dlsym ios_vulkan_sym
#define dlclose ios_vulkan_close
#define pthread_once( once, init ) madeira_vulkan_pthread_once( once, init )
#include "../../wine/dlls/win32u/vulkan.c"
#undef dlsym
#undef dlclose
#undef dlopen
#undef pthread_once

/* nonzero while one of vulkan.c's pthread_once calls runs on this thread */
static __thread int madeira_vulkan_init_depth;

int madeira_vulkan_init_on_this_thread( void )
{
    return madeira_vulkan_init_depth != 0;
}

static int madeira_vulkan_pthread_once( pthread_once_t *once, void (*init)(void) )
{
    int ret;

    madeira_vulkan_init_depth++;
    ret = pthread_once( once, init );
    madeira_vulkan_init_depth--;
    return ret;
}


/* [vk-bc-probe] diagnostic only: does this session's Vulkan driver report
 * block-compressed (BC) texture support? Godot 4 picks its s3tc/bptc texture
 * variant only when the GPU reports BC; Buckshot Roulette on an A14 fails every
 * texture load (Nov 15). Makes one throw-away instance, reads features and BC
 * format properties of each GPU, logs them, destroys it. No behaviour change.
 * Off with env.MADEIRA_VK_BC_PROBE = 0. */
static void madeira_vk_bc_probe( void *handle )
{
    static int done;
    PFN_vkGetInstanceProcAddr gipa;
    PFN_vkCreateInstance create_instance;
    PFN_vkEnumerateInstanceExtensionProperties enum_ext;
    PFN_vkDestroyInstance destroy_instance;
    PFN_vkEnumeratePhysicalDevices enum_gpu;
    PFN_vkGetPhysicalDeviceFeatures get_features;
    PFN_vkGetPhysicalDeviceProperties get_props;
    PFN_vkGetPhysicalDeviceFormatProperties get_fmt;
    VkInstanceCreateInfo ci = {0};
    VkApplicationInfo app = {0};
    VkExtensionProperties exts[128];
    const char *enabled[1];
    VkPhysicalDevice gpus[8];
    VkInstance inst;
    uint32_t n_ext = 128, n_gpu = 8, i, f;
    VkResult res;
    static const struct { VkFormat fmt; const char *name; } fmts[] =
    {
        { VK_FORMAT_BC1_RGBA_UNORM_BLOCK, "BC1" }, { VK_FORMAT_BC3_UNORM_BLOCK, "BC3" },
        { VK_FORMAT_BC5_UNORM_BLOCK, "BC5" }, { VK_FORMAT_BC6H_UFLOAT_BLOCK, "BC6H" },
        { VK_FORMAT_BC7_UNORM_BLOCK, "BC7" },
        { VK_FORMAT_ETC2_R8G8B8A8_UNORM_BLOCK, "ETC2" }, { VK_FORMAT_ASTC_4x4_UNORM_BLOCK, "ASTC4x4" },
    };

    if (done) return;
    done = 1;
    {
        const char *v = getenv( "MADEIRA_VK_BC_PROBE" );
        if (v && v[0] == '0') return;
    }
    if (!(gipa = (PFN_vkGetInstanceProcAddr)ios_vulkan_sym( handle, "vkGetInstanceProcAddr" ))) return;
    create_instance = (PFN_vkCreateInstance)gipa( NULL, "vkCreateInstance" );
    enum_ext = (PFN_vkEnumerateInstanceExtensionProperties)gipa( NULL, "vkEnumerateInstanceExtensionProperties" );
    if (!create_instance || !enum_ext) return;

    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.apiVersion = VK_API_VERSION_1_1;
    ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ci.pApplicationInfo = &app;
    if (enum_ext( NULL, &n_ext, exts ) >= 0)
        for (i = 0; i < n_ext; i++)
            if (!strcmp( exts[i].extensionName, "VK_KHR_portability_enumeration" ))
            {
                enabled[0] = "VK_KHR_portability_enumeration";
                ci.enabledExtensionCount = 1;
                ci.ppEnabledExtensionNames = enabled;
                ci.flags = 0x1; /* VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR */
                break;
            }
    if ((res = create_instance( &ci, NULL, &inst )) < 0)
    {
        dprintf( 2, "[vk-bc-probe] vkCreateInstance failed (%d)\n", (int)res );
        return;
    }
    destroy_instance = (PFN_vkDestroyInstance)gipa( inst, "vkDestroyInstance" );
    enum_gpu = (PFN_vkEnumeratePhysicalDevices)gipa( inst, "vkEnumeratePhysicalDevices" );
    get_features = (PFN_vkGetPhysicalDeviceFeatures)gipa( inst, "vkGetPhysicalDeviceFeatures" );
    get_props = (PFN_vkGetPhysicalDeviceProperties)gipa( inst, "vkGetPhysicalDeviceProperties" );
    get_fmt = (PFN_vkGetPhysicalDeviceFormatProperties)gipa( inst, "vkGetPhysicalDeviceFormatProperties" );
    if (enum_gpu && get_features && get_props && get_fmt && enum_gpu( inst, &n_gpu, gpus ) >= 0)
    {
        for (i = 0; i < n_gpu; i++)
        {
            VkPhysicalDeviceFeatures feat;
            VkPhysicalDeviceProperties props;
            char line[256];
            int len;

            get_features( gpus[i], &feat );
            get_props( gpus[i], &props );
            len = snprintf( line, sizeof(line), "[vk-bc-probe] gpu #%u \"%s\" api=%u.%u.%u textureCompressionBC=%u formats(sampled):",
                            i, props.deviceName, (unsigned)VK_API_VERSION_MAJOR( props.apiVersion ),
                            (unsigned)VK_API_VERSION_MINOR( props.apiVersion ),
                            (unsigned)VK_API_VERSION_PATCH( props.apiVersion ), (unsigned)feat.textureCompressionBC );
            for (f = 0; f < sizeof(fmts) / sizeof(fmts[0]) && len > 0 && len < (int)sizeof(line) - 16; f++)
            {
                VkFormatProperties fp;
                get_fmt( gpus[i], fmts[f].fmt, &fp );
                len += snprintf( line + len, sizeof(line) - len, " %s=%u", fmts[f].name,
                                 !!(fp.optimalTilingFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT) );
            }
            dprintf( 2, "%s\n", line );
        }
    }
    if (destroy_instance) destroy_instance( inst, NULL );
}

static void *madeira_vulkan_dlopen( const char *name, int flags )
{
    const char *path = getenv( "MADEIRA_VULKAN_LIBRARY" );
    void *handle;

    if (!path || !*path)
    {
        dprintf( 2, "[winios-vk] Vulkan is off for this session (madeira.cfg vulkan / d3d12 = vkd3d "
                    "not set, or the library is not bundled)\n" );
        return NULL;
    }
    /* MoltenVK: errors only, as for Zink (opengl_ios.c); madeira.cfg env.MVK_* wins */
    setenv( "MVK_CONFIG_LOG_LEVEL", "1", 0 );
    if (!(handle = ios_vulkan_open( path, flags )))
        dprintf( 2, "[winios-vk] cannot load %s: %s\n", path, dlerror() );
    else
    {
        dprintf( 2, "[winios-vk] Vulkan library %s loaded\n", path );
        madeira_vk_bc_probe( handle );
    }
    return handle;
}



#include "vulkan_surface_ios.c"
