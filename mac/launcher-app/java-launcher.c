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
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <dispatch/dispatch.h>
#include <objc/message.h>
#include <objc/runtime.h>

typedef int (*JLI_Launch_t)(int argc, char **argv, int jargc, const char **jargv, int appclassc,
                            const char **appclassv, const char *fullversion, const char *dotversion,
                            const char *pname, const char *lname, unsigned char javaargs,
                            unsigned char cpwildcard, unsigned char javaw, int ergo);
typedef void (*JLI_InitArgProcessing_t)(unsigned char hasJavaArgs, unsigned char disableArgFile);

// The agent's native code (keypasta.MacMenuBar), as a JNI library built into this program: Java 8+
// finds a "static" library in the running program by its JNI_OnLoad_<name> (System.loadLibrary
// ("keypasta")), and its native methods there too. So no file of its own. No JDK headers needed.
//
// macOS 27 doesn't redraw the menu bar when an app changes the menus in it (Java does that item by
// item whenever a window becomes key): they show only once the pointer goes to the menu bar.
// Setting the app's main menu again (nil, then back) has it redrawn (as FlatLaf does, its PR 1154).
// On the main thread (AppKit's, where Java runs the window system), after what is queued there.
__attribute__((visibility("default"), used))
int32_t JNI_OnLoad_keypasta(void *vm, void *reserved) {
    (void) vm;
    (void) reserved;
    return 0x00010008;                          // JNI_VERSION_1_8: required for a built-in library
}

static void redrawMenuBar(void *unused) {
    (void) unused;
    Class appClass = objc_getClass("NSApplication");
    if (appClass == NULL)
        return;
    id app = ((id (*)(id, SEL)) objc_msgSend)((id) appClass, sel_registerName("sharedApplication"));
    id menu = ((id (*)(id, SEL)) objc_msgSend)(app, sel_registerName("mainMenu"));
    if (menu == NULL)
        return;
    ((id (*)(id, SEL)) objc_msgSend)(menu, sel_registerName("retain"));      // NSApp lets go of it at nil
    ((void (*)(id, SEL, id)) objc_msgSend)(app, sel_registerName("setMainMenu:"), (id) NULL);
    ((void (*)(id, SEL, id)) objc_msgSend)(app, sel_registerName("setMainMenu:"), menu);
    ((void (*)(id, SEL)) objc_msgSend)(menu, sel_registerName("release"));
}

// keypasta.MacMenuBar.redraw0()
__attribute__((visibility("default"), used))
void Java_keypasta_MacMenuBar_redraw0(void *env, void *cls) {
    (void) env;
    (void) cls;
    dispatch_async_f(dispatch_get_main_queue(), NULL, redrawMenuBar);
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
