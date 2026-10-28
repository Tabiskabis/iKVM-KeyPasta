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
