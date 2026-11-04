// iKVM-KeyPasta, macOS: starts Java inside this process (JLI_Launch, as packaged Java apps do). The
// Dock and Cmd-Tab name a program without an app bundle by its executable's file name ("java" for
// Java itself; Java's -Xdock:name reaches only the menu bar since OS X 10.9, OpenJDK JDK-8029440).
// So copies of this, named "IPMIView" and "iKVM Viewer", run IPMIView and the viewers: see
// ../java-name.sh. Two fixed copies: two firewall rules (e.g. LuLu), once.
//   KEYPASTA_JAVA_HOME   the Java to run (its Contents/Home): its libjli finds the rest
//   arguments            those of the java command (argv[0] is ignored)
// On macOS, JLI_Launch parks this thread for the window system and calls main() again on a new
// thread (MacOSXStartup), so main runs twice and KEYPASTA_JAVA_HOME must stay set; Java programs
// started from here (IPMIView's viewers, through java-name.sh) need it too.
// Built x86_64 by build.sh: the viewer's Java is Intel (Rosetta 2).
// Also carries the agent's native code for the Mac menu bar (see JNI_OnLoad_keypasta below).
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <dispatch/dispatch.h>
#include <objc/message.h>
#include <objc/runtime.h>

// libobjc's, not in its public headers: an autorelease pool around the work on the main queue
void *objc_autoreleasePoolPush(void);
void objc_autoreleasePoolPop(void *pool);

typedef int (*JLI_Launch_t)(int argc, char **argv, int jargc, const char **jargv, int appclassc,
                            const char **appclassv, const char *fullversion, const char *dotversion,
                            const char *pname, const char *lname, unsigned char javaargs,
                            unsigned char cpwildcard, unsigned char javaw, int ergo);
typedef void (*JLI_InitArgProcessing_t)(unsigned char hasJavaArgs, unsigned char disableArgFile);

// The agent's native code (keypasta.MacMenuBar), as a JNI library built into this program: Java 8+
// finds a "static" library in the running program by its JNI_OnLoad_<name> (System.loadLibrary
// ("keypasta")), and its native methods there too. So no file of its own. No JDK headers needed.
__attribute__((visibility("default"), used))
int32_t JNI_OnLoad_keypasta(void *vm, void *reserved) {
    (void) vm;
    (void) reserved;
    return 0x00010008;                          // JNI_VERSION_1_8: required for a built-in library
}

// The menu bar watch (keypasta.MacMenuBar.watch0, once per program). Java changes the menus in
// the menu bar whenever one of its windows becomes key (CMenuBar activate: the window's menus
// replace the previous ones, greyed while a dialog blocks the window), and macOS 27 doesn't redraw
// the menu bar for that: the menus show only once the pointer goes there. Setting the app's main
// menu again (nil, then back) has it redrawn (as FlatLaf does, its PR 1154). The agent used to
// guess when that was needed (focus back, after the start); here macOS says it: every item added
// to, removed from or changed in the main menu, the app coming to the front and a window becoming
// key or main ask for a check 50 ms later (a burst of changes: one check). A check redraws
// only if what the bar shows changed since the last one (the menus' titles, which are grey), or
// the app came to the front: no redraw for a change inside a menu, and none of the redraw's own
// doing. All on the main thread (AppKit's, where Java runs the window system).
//
// The menu bar's state (app in front, key and main window, the menus in the bar and which are
// grey) goes to the agent's log whenever it changes: kept here, taken by the agent once a second
// (takeLog0). Window classes and numbers only, no titles (the viewer's changes with every frame).

enum { MENUS = 1, FRONT = 2, WINDOW = 4, START = 8 };

static int checkPending, checkWhy, redrawing;
static long redraws;
static char lastBar[1536], lastState[2048];
static pthread_mutex_t logLock = PTHREAD_MUTEX_INITIALIZER;
static char logText[16384];                     // lines for the agent's log, not taken yet

static id send0(id o, const char *sel) {
    return ((id (*)(id, SEL)) objc_msgSend)(o, sel_registerName(sel));
}

static id sharedApp(void) {
    Class appClass = objc_getClass("NSApplication");
    return appClass == NULL ? NULL : send0((id) appClass, "sharedApplication");
}

static void redrawMenuBar(void) {
    id app = sharedApp();
    id menu = app == NULL ? NULL : send0(app, "mainMenu");
    if (menu == NULL)
        return;
    redrawing = 1;                              // what this posts isn't a change
    send0(menu, "retain");                      // NSApp lets go of it at nil
    ((void (*)(id, SEL, id)) objc_msgSend)(app, sel_registerName("setMainMenu:"), (id) NULL);
    ((void (*)(id, SEL, id)) objc_msgSend)(app, sel_registerName("setMainMenu:"), menu);
    send0(menu, "release");
    redrawing = 0;
    redraws++;
}

static void addLog(const char *line) {
    pthread_mutex_lock(&logLock);
    size_t used = strlen(logText), n = strlen(line);
    if (used + n + 2 < sizeof logText) {
        memcpy(logText + used, line, n);
        logText[used + n] = '\n';
        logText[used + n + 1] = '\0';
    }
    pthread_mutex_unlock(&logLock);
}

static void describeWindow(char *out, size_t size, const char *what, id w) {
    if (w == NULL) {
        snprintf(out, size, " %s=-", what);
        return;
    }
    long number = ((long (*)(id, SEL)) objc_msgSend)(w, sel_registerName("windowNumber"));
    snprintf(out, size, " %s=%s#%ld", what, object_getClassName(w), number);
}

// What the bar shows: "menus=5: iKVM Viewer, Options, Media (grey), ..."
static void barState(char *out, size_t size) {
    id app = sharedApp();
    id menu = app == NULL ? NULL : send0(app, "mainMenu");
    long n = menu == NULL ? -1 : ((long (*)(id, SEL)) objc_msgSend)(menu, sel_registerName("numberOfItems"));
    int len = snprintf(out, size, "menus=%ld", n);
    for (long i = 0; i < n && len > 0 && (size_t) len < size; i++) {
        id item = ((id (*)(id, SEL, long)) objc_msgSend)(menu, sel_registerName("itemAtIndex:"), i);
        id title = send0(item, "title");
        const char *t = title == NULL ? NULL : ((const char *(*)(id, SEL)) objc_msgSend)(title, sel_registerName("UTF8String"));
        signed char on = ((signed char (*)(id, SEL)) objc_msgSend)(item, sel_registerName("isEnabled"));
        len += snprintf(out + len, size - len, "%s%s%s", i == 0 ? ": " : ", ", t == NULL ? "?" : t, on ? "" : " (grey)");
    }
}

// "front=1 key=AWTWindow_Normal#123 main=same " and the bar
static void menuBarState(char *out, size_t size, const char *bar) {
    id app = sharedApp();
    if (app == NULL) {
        snprintf(out, size, "no NSApp");
        return;
    }
    signed char front = ((signed char (*)(id, SEL)) objc_msgSend)(app, sel_registerName("isActive"));
    id keyWin = send0(app, "keyWindow"), mainWin = send0(app, "mainWindow");
    char k[160], m[160];
    describeWindow(k, sizeof k, "key", keyWin);
    if (mainWin != NULL && mainWin == keyWin)
        snprintf(m, sizeof m, " main=same");
    else
        describeWindow(m, sizeof m, "main", mainWin);
    snprintf(out, size, "front=%d%s%s %s", front ? 1 : 0, k, m, bar);
}

static void checkNow(void *unused) {
    (void) unused;
    void *pool = objc_autoreleasePoolPush();
    int why = checkWhy;
    checkPending = checkWhy = 0;
    char bar[sizeof lastBar];
    barState(bar, sizeof bar);
    if ((why & (FRONT | START)) || strcmp(bar, lastBar) != 0)
        redrawMenuBar();
    strcpy(lastBar, bar);
    char state[sizeof lastState];
    menuBarState(state, sizeof state, bar);
    if (strcmp(state, lastState) != 0) {
        strcpy(lastState, state);
        char what[80] = "";
        const char *names[] = {"menu change", "app in front", "window change", "start"};
        for (int i = 0; i < 4; i++)
            if (why & (1 << i))
                snprintf(what + strlen(what), sizeof what - strlen(what), "%s%s", what[0] ? ", " : "", names[i]);
        char line[sizeof state + 160];
        snprintf(line, sizeof line, "Mac menu bar after %s (%ld redraws): %s", what, redraws, state);
        addLog(line);
    }
    objc_autoreleasePoolPop(pool);
}

static void check(int why) {
    checkWhy |= why;
    if (checkPending)
        return;
    checkPending = 1;
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), NULL, checkNow);
}

static void checkOnMain(void *why) {
    check((int) (intptr_t) why);
}

// From any thread (notifications are posted on the thread that caused them, AppKit's here)
static void checkFrom(int why) {
    if (pthread_main_np())
        check(why);
    else
        dispatch_async_f(dispatch_get_main_queue(), (void *) (intptr_t) why, checkOnMain);
}

static void menuChanged(id self, SEL cmd, id note) {
    (void) self;
    (void) cmd;
    if (!pthread_main_np()) {
        checkFrom(MENUS);
        return;
    }
    if (redrawing)
        return;
    id app = sharedApp();
    if (app != NULL && send0(note, "object") == send0(app, "mainMenu"))   // the bar, not a menu in it
        check(MENUS);
}

static void appFront(id self, SEL cmd, id note) {
    (void) self;
    (void) cmd;
    (void) note;
    checkFrom(FRONT);
}

static void windowChanged(id self, SEL cmd, id note) {
    (void) self;
    (void) cmd;
    (void) note;
    checkFrom(WINDOW);
}

static id nsString(const char *s) {
    return ((id (*)(id, SEL, const char *)) objc_msgSend)((id) objc_getClass("NSString"),
                                                           sel_registerName("stringWithUTF8String:"), s);
}

// AppKit's constant for a notification name; its text is the name itself, should it be missing
static id notificationName(const char *name) {
    void *appKit = dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY | RTLD_NOLOAD);
    id *constant = appKit == NULL ? NULL : (id *) dlsym(appKit, name);
    return constant != NULL && *constant != NULL ? *constant : nsString(name);
}

static void observe(id center, id watcher, const char *selector, const char *name) {
    ((void (*)(id, SEL, id, SEL, id, id)) objc_msgSend)(center, sel_registerName("addObserver:selector:name:object:"),
                                                        watcher, sel_registerName(selector), notificationName(name), (id) NULL);
}

static void installWatch(void *unused) {
    (void) unused;
    static int installed;
    if (installed)
        return;
    installed = 1;
    void *pool = objc_autoreleasePoolPush();
    Class base = objc_getClass("NSObject");
    Class cls = base == NULL ? Nil : objc_allocateClassPair(base, "KeyPastaMenuBarWatch", 0);
    id center = send0((id) objc_getClass("NSNotificationCenter"), "defaultCenter");
    if (cls == Nil || center == NULL) {
        addLog("Mac menu bar not watched: no NSObject/NSNotificationCenter");
        objc_autoreleasePoolPop(pool);
        return;
    }
    class_addMethod(cls, sel_registerName("menuChanged:"), (IMP) menuChanged, "v@:@");
    class_addMethod(cls, sel_registerName("appFront:"), (IMP) appFront, "v@:@");
    class_addMethod(cls, sel_registerName("windowChanged:"), (IMP) windowChanged, "v@:@");
    objc_registerClassPair(cls);
    id watcher = send0(send0((id) cls, "alloc"), "init");                   // kept for good
    observe(center, watcher, "menuChanged:", "NSMenuDidAddItemNotification");
    observe(center, watcher, "menuChanged:", "NSMenuDidRemoveItemNotification");
    observe(center, watcher, "menuChanged:", "NSMenuDidChangeItemNotification");
    observe(center, watcher, "appFront:", "NSApplicationDidBecomeActiveNotification");
    observe(center, watcher, "windowChanged:", "NSApplicationDidResignActiveNotification");
    observe(center, watcher, "windowChanged:", "NSWindowDidBecomeKeyNotification");
    observe(center, watcher, "windowChanged:", "NSWindowDidBecomeMainNotification");
    check(START);
    objc_autoreleasePoolPop(pool);
}

// keypasta.MacMenuBar.watch0()
__attribute__((visibility("default"), used))
void Java_keypasta_MacMenuBar_watch0(void *env, void *cls) {
    (void) env;
    (void) cls;
    dispatch_async_f(dispatch_get_main_queue(), NULL, installWatch);
}

// keypasta.MacMenuBar.takeLog0(): the lines since the last call, or null. JNIEnv's NewStringUTF
// is entry 167 of its function table (stable since JNI 1.1; no JDK headers here).
__attribute__((visibility("default"), used))
void *Java_keypasta_MacMenuBar_takeLog0(void *env, void *cls) {
    (void) cls;
    char text[sizeof logText];
    pthread_mutex_lock(&logLock);
    strcpy(text, logText);
    logText[0] = '\0';
    pthread_mutex_unlock(&logLock);
    if (text[0] == '\0')
        return NULL;
    typedef void *(*NewStringUTF_t)(void *env, const char *utf);
    NewStringUTF_t newStringUTF = (NewStringUTF_t) (*(void ***) env)[167];
    return newStringUTF(env, text);
}

// The viewer's menus without Cmd+Q: macOS's menus take a key equivalent before the window gets the
// key, so Cmd+Q quit the viewer instead of reaching the remote (as Win+Q, or Alt+Q with Alt and
// Command swapped). Every item with exactly Cmd+Q (the app menu's Quit) loses its shortcut;
// clicking it still quits.
static void removeQuitShortcut(void *unused) {
    (void) unused;
    Class appClass = objc_getClass("NSApplication");
    Class strClass = objc_getClass("NSString");
    if (appClass == NULL || strClass == NULL)
        return;
    id app = ((id (*)(id, SEL)) objc_msgSend)((id) appClass, sel_registerName("sharedApplication"));
    id menu = ((id (*)(id, SEL)) objc_msgSend)(app, sel_registerName("mainMenu"));
    if (menu == NULL)
        return;
    SEL count = sel_registerName("numberOfItems"), at = sel_registerName("itemAtIndex:");
    SEL utf8 = sel_registerName("stringWithUTF8String:");
    id q = ((id (*)(id, SEL, const char *)) objc_msgSend)((id) strClass, utf8, "q");
    id none = ((id (*)(id, SEL, const char *)) objc_msgSend)((id) strClass, utf8, "");
    long n = ((long (*)(id, SEL)) objc_msgSend)(menu, count);
    for (long i = 0; i < n; i++) {
        id item = ((id (*)(id, SEL, long)) objc_msgSend)(menu, at, i);
        id sub = ((id (*)(id, SEL)) objc_msgSend)(item, sel_registerName("submenu"));
        if (sub == NULL)
            continue;
        long m = ((long (*)(id, SEL)) objc_msgSend)(sub, count);
        for (long j = 0; j < m; j++) {
            id it = ((id (*)(id, SEL, long)) objc_msgSend)(sub, at, j);
            id key = ((id (*)(id, SEL)) objc_msgSend)(it, sel_registerName("keyEquivalent"));
            unsigned long mask = ((unsigned long (*)(id, SEL)) objc_msgSend)(it, sel_registerName("keyEquivalentModifierMask"));
            if (key == NULL || (mask & 0xffff0000UL) != (1UL << 20))     // device-independent flags: Command only
                continue;
            if (((signed char (*)(id, SEL, id)) objc_msgSend)(key, sel_registerName("isEqualToString:"), q))
                ((void (*)(id, SEL, id)) objc_msgSend)(it, sel_registerName("setKeyEquivalent:"), none);
        }
    }
}

// keypasta.MacMenuBar.noQuitShortcut0()
__attribute__((visibility("default"), used))
void Java_keypasta_MacMenuBar_noQuitShortcut0(void *env, void *cls) {
    (void) env;
    (void) cls;
    dispatch_async_f(dispatch_get_main_queue(), NULL, removeQuitShortcut);
}

// An IOKit object (io_object_t), for MacHid below.
typedef uint32_t io_object_k;

// keypasta.MacHid.guard0(): keeps iKVM's macOS library (libiKVM*.jnilib) from quitting the viewer.
// Its LED code (manipulate_led: for every lock key, getLEDstate, setLEDstate, changeLEDstate) opens
// the keyboard as a HID device: IOCreatePlugInInterfaceForService, the device interface, then its
// elements (find_led_cookies), and calls exit(1) when that last call fails, as it does without the
// Input Monitoring permission. A failure of the first call it takes quietly (as for a Mac without
// a keyboard): no LED read, the lock state taken as off. So its import of that first call (used for
// nothing else in it) is pointed here: the same steps as the library's, and when the elements are
// refused, the plug-in released and kIOReturnNotPermitted. Everything else as before. The library
// is found by its viewer function among the loaded images, now and as it loads (dyld calls back).
// 0 done, -1 IOKit not found.

typedef struct { uint8_t bytes[16]; } uuid_k;  // CFUUIDBytes, passed by value as COM's REFIID
typedef int (*IOCreatePlugIn_t)(io_object_k service, const void *pluginType, const void *interfaceType,
                                void ***plugin, int32_t *score);
typedef int32_t (*QueryInterface_t)(void *self, uuid_k iid, void **out);
typedef uint32_t (*ReleaseCOM_t)(void *self);
typedef int (*CopyMatchingElements_t)(void *self, const void *matching, const void **elements);
static IOCreatePlugIn_t realCreatePlugIn;
static void (*cfRelease)(const void *object);
static int hidRefusedLogged;

static void **comTable(void *handle) {
    return *(void ***) handle;                  // an IOKit COM handle points to its function table
}

static int guardedCreatePlugIn(io_object_k service, const void *pluginType, const void *interfaceType,
                               void ***plugin, int32_t *score) {
    int r = realCreatePlugIn(service, pluginType, interfaceType, plugin, score);
    if (r != 0 || plugin == NULL || *plugin == NULL)
        return r;
    // kIOHIDDeviceInterfaceID, as the library asks for it (create_hid_interface)
    static const uuid_k deviceInterface = {{0x78, 0xBD, 0x42, 0x0C, 0x6F, 0x14, 0x11, 0xD4,
                                            0x94, 0x74, 0x00, 0x05, 0x02, 0x8F, 0x18, 0xD5}};
    void *plug = *plugin, *device = NULL;
    if (((QueryInterface_t) comTable(plug)[1])(plug, deviceInterface, &device) != 0 || device == NULL)
        return r;                               // the library fails there itself, quietly
    const void *elements = NULL;
    // copyMatchingElements: entry 20 (offset 0xa0, as the library calls it), Release entry 3
    int refused = ((CopyMatchingElements_t) comTable(device)[20])(device, NULL, &elements);
    if (elements != NULL && cfRelease != NULL)
        cfRelease(elements);
    ((ReleaseCOM_t) comTable(device)[3])(device);
    if (refused == 0)
        return r;
    ((ReleaseCOM_t) comTable(plug)[3])(plug);   // what IODestroyPlugInInterface does
    *plugin = NULL;
    if (!hidRefusedLogged) {
        hidRefusedLogged = 1;
        char line[160];
        snprintf(line, sizeof line, "keyboard LEDs not readable (HID error 0x%x, no Input Monitoring): the viewer goes on without them", (unsigned) refused);
        addLog(line);
    }
    return (int) 0xe00002e2;                    // kIOReturnNotPermitted
}

static void guardImage(const struct mach_header *header, intptr_t slide) {
    Dl_info info;                               // macOS' own libraries: not scanned
    if (header->magic != MH_MAGIC_64 || (dladdr(header, &info) != 0 && info.dli_fname != NULL
            && (strncmp(info.dli_fname, "/System/", 8) == 0 || strncmp(info.dli_fname, "/usr/lib/", 9) == 0)))
        return;
    const struct mach_header_64 *h = (const struct mach_header_64 *) header;
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct load_command *lc = (const struct load_command *) (h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++, lc = (const struct load_command *) ((const char *) lc + lc->cmdsize)) {
        if (lc->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *) lc)->segname, SEG_LINKEDIT) == 0)
            linkedit = (const struct segment_command_64 *) lc;
        else if (lc->cmd == LC_SYMTAB)
            symtab = (const struct symtab_command *) lc;
        else if (lc->cmd == LC_DYSYMTAB)
            dysymtab = (const struct dysymtab_command *) lc;
    }
    if (linkedit == NULL || symtab == NULL || dysymtab == NULL || dysymtab->nindirectsyms == 0)
        return;
    const char *base = (const char *) (slide + linkedit->vmaddr - linkedit->fileoff);
    const struct nlist_64 *symbols = (const struct nlist_64 *) (base + symtab->symoff);
    const char *names = base + symtab->stroff;
    const uint32_t *indirect = (const uint32_t *) (base + dysymtab->indirectsymoff);
    int viewer = 0;                             // iKVM's library: it defines the viewer's keyboard function
    for (uint32_t i = 0; i < symtab->nsyms && !viewer; i++)
        viewer = (symbols[i].n_type & N_TYPE) == N_SECT
            && strcmp(names + symbols[i].n_un.n_strx, "_Java_tw_com_aten_ikvm_ui_RemoteVideo_keyboardAction") == 0;
    if (!viewer)
        return;
    lc = (const struct load_command *) (h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++, lc = (const struct load_command *) ((const char *) lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64)
            continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *) lc;
        const struct section_64 *sect = (const struct section_64 *) (seg + 1);
        for (uint32_t s = 0; s < seg->nsects; s++, sect++) {
            uint32_t type = sect->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS)
                continue;
            void **slots = (void **) (slide + sect->addr);
            for (uint64_t k = 0; k < sect->size / sizeof(void *); k++) {
                uint32_t sym = indirect[sect->reserved1 + k];
                if (sym & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL) || sym >= symtab->nsyms)
                    continue;
                if (strcmp(names + symbols[sym].n_un.n_strx, "_IOCreatePlugInInterfaceForService") != 0)
                    continue;
                if (!(seg->initprot & VM_PROT_WRITE)) {     // __DATA_CONST in newer libraries
                    long page = sysconf(_SC_PAGESIZE);
                    uintptr_t start = (uintptr_t) &slots[k] & ~(uintptr_t) (page - 1);
                    if (mprotect((void *) start, (size_t) page, PROT_READ | PROT_WRITE) != 0)
                        continue;
                }
                slots[k] = (void *) guardedCreatePlugIn;
                addLog("iKVM's keyboard LED code guarded (no exit without Input Monitoring)");
            }
        }
    }
}

__attribute__((visibility("default"), used))
int32_t Java_keypasta_MacHid_guard0(void *env, void *cls) {
    (void) env;
    (void) cls;
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    void *cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW);
    realCreatePlugIn = iokit == NULL ? NULL : (IOCreatePlugIn_t) dlsym(iokit, "IOCreatePlugInInterfaceForService");
    cfRelease = cf == NULL ? NULL : (void (*)(const void *)) dlsym(cf, "CFRelease");
    if (realCreatePlugIn == NULL)
        return -1;
    _dyld_register_func_for_add_image(guardImage);  // called for every image already loaded, too
    return 0;
}

// keypasta.MacCapsKey: the Caps Lock key itself, down and up, for the Toggle keys mode Passthrough.
// AppKit reports Caps Lock only as the lock changing (Java: a press when it goes on, a release when
// it goes off), never the key going up. The keyboard's own reports have it (as Karabiner's
// EventViewer shows): an IOHIDManager on every keyboard (generic desktop page 1, usage 6), on a
// thread with its own run loop, keeps the keyboard page's Caps Lock (page 7, usage 0x39) changes in
// a queue the agent takes them from (next0, blocking). macOS allows this only with the Input
// Monitoring permission (the Mac app asks for it, not this). The agent sends the keys only while a
// viewer has the focus; the reports come whatever program is in front, nothing else is kept or
// logged. All IOKit and CoreFoundation calls through dlsym, as above (no SDK headers, no linking).

typedef void (*HIDValueCallback_t)(void *context, int result, void *sender, void *value);
static struct {
    void *(*managerCreate)(const void *allocator, uint32_t options);
    void (*setDeviceMatching)(void *manager, const void *matching);
    void (*registerInputValueCallback)(void *manager, HIDValueCallback_t callback, void *context);
    void (*scheduleWithRunLoop)(void *manager, void *runLoop, const void *mode);
    int (*open)(void *manager, uint32_t options);
    void *(*valueGetElement)(void *value);
    long (*valueGetIntegerValue)(void *value);
    uint32_t (*elementGetUsagePage)(void *element);
    uint32_t (*elementGetUsage)(void *element);
    int (*checkAccess)(int requestType);
    int (*requestAccess)(int requestType);
    void *(*dictionaryCreateMutable)(const void *allocator, long capacity, const void *keyCallBacks,
                                     const void *valueCallBacks);
    void (*dictionarySetValue)(void *dict, const void *key, const void *value);
    void *(*numberCreate)(const void *allocator, long type, const void *valuePtr);
    void *(*stringCreate)(const void *allocator, const char *text, uint32_t encoding);
    void *(*runLoopGetCurrent)(void);
    void (*runLoopRun)(void);
    const void *keyCallBacks, *valueCallBacks, *defaultMode;
} hid;
static pthread_mutex_t capsLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t capsCond = PTHREAD_COND_INITIALIZER;
static int capsQueue[64], capsHead, capsCount;
enum { CAPS_STARTING = 0x7fffffff };
static int capsState = CAPS_STARTING;           // then 0 open, else why not (see start0)
static int capsStarted;

static void capsValue(void *context, int result, void *sender, void *value) {
    (void) context;
    (void) result;
    (void) sender;
    void *element = hid.valueGetElement(value);
    if (element == NULL || hid.elementGetUsagePage(element) != 7 || hid.elementGetUsage(element) != 0x39)
        return;
    pthread_mutex_lock(&capsLock);
    if (capsCount < (int) (sizeof capsQueue / sizeof capsQueue[0])) {
        capsQueue[(capsHead + capsCount) % (sizeof capsQueue / sizeof capsQueue[0])] = hid.valueGetIntegerValue(value) != 0;
        capsCount++;
        pthread_cond_broadcast(&capsCond);
    }
    pthread_mutex_unlock(&capsLock);
}

static void *capsThread(void *unused) {
    (void) unused;
    void *manager = hid.managerCreate(NULL, 0);
    void *match = hid.dictionaryCreateMutable(NULL, 0, hid.keyCallBacks, hid.valueCallBacks);
    int page = 1, usage = 6;                    // generic desktop, keyboard
    hid.dictionarySetValue(match, hid.stringCreate(NULL, "DeviceUsagePage", 0x08000100),
                           hid.numberCreate(NULL, 9, &page));       // kCFNumberIntType, UTF-8
    hid.dictionarySetValue(match, hid.stringCreate(NULL, "DeviceUsage", 0x08000100),
                           hid.numberCreate(NULL, 9, &usage));
    hid.setDeviceMatching(manager, match);
    hid.registerInputValueCallback(manager, capsValue, NULL);
    hid.scheduleWithRunLoop(manager, hid.runLoopGetCurrent(), hid.defaultMode);
    int r = hid.open(manager, 0);
    pthread_mutex_lock(&capsLock);
    capsState = r == 0 ? 0 : r;
    pthread_cond_broadcast(&capsCond);
    pthread_mutex_unlock(&capsLock);
    // kIOReturnExclusiveAccess: a keyboard is seized by another program (Karabiner-Elements does
    // that to every physical one); the others (its virtual keyboard among them) are open and report
    if (r == 0 || r == (int) 0xe00002c5)
        hid.runLoopRun();                       // for good: the reports come here
    return NULL;
}

// keypasta.MacCapsKey.start0(): 0 the keyboards are open, 1 Input Monitoring not granted (not
// asked for here: the app does), -1 IOKit not usable, else IOHIDManagerOpen's error (0xe00002c5: some
// keyboards held by another program, the others read). Once per program,
// later calls answer the same.
__attribute__((visibility("default"), used))
int32_t Java_keypasta_MacCapsKey_start0(void *env, void *cls) {
    (void) env;
    (void) cls;
    pthread_mutex_lock(&capsLock);
    if (capsStarted) {
        while (capsState == CAPS_STARTING)
            pthread_cond_wait(&capsCond, &capsLock);
        int r = capsState;
        pthread_mutex_unlock(&capsLock);
        return r;
    }
    capsStarted = 1;
    pthread_mutex_unlock(&capsLock);
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    void *cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW);
    int r = -1;
    if (iokit != NULL && cf != NULL) {
        *(void **) &hid.managerCreate = dlsym(iokit, "IOHIDManagerCreate");
        *(void **) &hid.setDeviceMatching = dlsym(iokit, "IOHIDManagerSetDeviceMatching");
        *(void **) &hid.registerInputValueCallback = dlsym(iokit, "IOHIDManagerRegisterInputValueCallback");
        *(void **) &hid.scheduleWithRunLoop = dlsym(iokit, "IOHIDManagerScheduleWithRunLoop");
        *(void **) &hid.open = dlsym(iokit, "IOHIDManagerOpen");
        *(void **) &hid.valueGetElement = dlsym(iokit, "IOHIDValueGetElement");
        *(void **) &hid.valueGetIntegerValue = dlsym(iokit, "IOHIDValueGetIntegerValue");
        *(void **) &hid.elementGetUsagePage = dlsym(iokit, "IOHIDElementGetUsagePage");
        *(void **) &hid.elementGetUsage = dlsym(iokit, "IOHIDElementGetUsage");
        *(void **) &hid.checkAccess = dlsym(iokit, "IOHIDCheckAccess");
        *(void **) &hid.requestAccess = dlsym(iokit, "IOHIDRequestAccess");
        *(void **) &hid.dictionaryCreateMutable = dlsym(cf, "CFDictionaryCreateMutable");
        *(void **) &hid.dictionarySetValue = dlsym(cf, "CFDictionarySetValue");
        *(void **) &hid.numberCreate = dlsym(cf, "CFNumberCreate");
        *(void **) &hid.stringCreate = dlsym(cf, "CFStringCreateWithCString");
        *(void **) &hid.runLoopGetCurrent = dlsym(cf, "CFRunLoopGetCurrent");
        *(void **) &hid.runLoopRun = dlsym(cf, "CFRunLoopRun");
        hid.keyCallBacks = dlsym(cf, "kCFTypeDictionaryKeyCallBacks");
        hid.valueCallBacks = dlsym(cf, "kCFTypeDictionaryValueCallBacks");
        const void **mode = (const void **) dlsym(cf, "kCFRunLoopDefaultMode");
        hid.defaultMode = mode == NULL ? NULL : *mode;
        if (hid.managerCreate && hid.setDeviceMatching && hid.registerInputValueCallback && hid.scheduleWithRunLoop
                && hid.open && hid.valueGetElement && hid.valueGetIntegerValue && hid.elementGetUsagePage
                && hid.elementGetUsage && hid.dictionaryCreateMutable && hid.dictionarySetValue && hid.numberCreate
                && hid.stringCreate && hid.runLoopGetCurrent && hid.runLoopRun && hid.keyCallBacks
                && hid.valueCallBacks && hid.defaultMode)
            r = 0;
    }
    // kIOHIDRequestTypeListenEvent 1; access: 0 granted, 1 denied, 2 never answered
    // never asked from here: the Mac app asks, once per version of it (the user: not at every start)
    if (r == 0 && hid.checkAccess != NULL && hid.checkAccess(1) != 0)
        r = 1;
    pthread_t thread;
    if (r == 0 && pthread_create(&thread, NULL, capsThread, NULL) != 0)
        r = -1;
    pthread_mutex_lock(&capsLock);
    if (r != 0)
        capsState = r;
    while (capsState == CAPS_STARTING)
        pthread_cond_wait(&capsCond, &capsLock);
    r = capsState;
    pthread_mutex_unlock(&capsLock);
    return r;
}

// keypasta.MacCapsKey.next0(): waits for the next Caps Lock report: 1 down, 0 up.
__attribute__((visibility("default"), used))
int32_t Java_keypasta_MacCapsKey_next0(void *env, void *cls) {
    (void) env;
    (void) cls;
    pthread_mutex_lock(&capsLock);
    while (capsCount == 0)
        pthread_cond_wait(&capsCond, &capsLock);
    int down = capsQueue[capsHead];
    capsHead = (capsHead + 1) % (int) (sizeof capsQueue / sizeof capsQueue[0]);
    capsCount--;
    pthread_mutex_unlock(&capsLock);
    return down;
}

int main(int argc, char **argv) {
    const char *home = getenv("KEYPASTA_JAVA_HOME");
    if (home == NULL || *home == '\0') {
        fprintf(stderr, "java-launcher: KEYPASTA_JAVA_HOME not set\n");
        return 1;
    }
    // Java 9+: lib/jli; Java 8: jre/lib/jli
    const char *layouts[] = {"%s/lib/jli/libjli.dylib", "%s/jre/lib/jli/libjli.dylib"};
    void *jli = NULL;
    char path[4096];
    for (int i = 0; jli == NULL && i < 2; i++) {
        snprintf(path, sizeof path, layouts[i], home);
        jli = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    }
    if (jli == NULL) {
        // e.g. a Java for the other CPU architecture: run its java instead (the Dock shows "java")
        fprintf(stderr, "java-launcher: no usable libjli in %s (%s): running its java\n", home, dlerror());
        snprintf(path, sizeof path, "%s/bin/java", home);
        argv[0] = path;
        execv(path, argv);
        perror("java-launcher: java");
        return 1;
    }
    JLI_Launch_t launch = (JLI_Launch_t) dlsym(jli, "JLI_Launch");
    if (launch == NULL) {
        fprintf(stderr, "java-launcher: no JLI_Launch in %s\n", path);
        return 1;
    }
    JLI_InitArgProcessing_t initArgs = (JLI_InitArgProcessing_t) dlsym(jli, "JLI_InitArgProcessing");
    if (initArgs != NULL)
        initArgs(0, 0);                         // as the java launcher does (Java 9+)
    argv[0] = "java";
    return launch(argc, argv, 0, NULL, 0, NULL, "", "", "java", "java", 0, 1, 0, 0);
}
