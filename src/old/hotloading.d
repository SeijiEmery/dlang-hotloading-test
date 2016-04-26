
module ht.engine.hotloading;
import util.sharedlib;
import core.sys.posix.dlfcn;
import std.format;
import std.stdio;
import std.string;

private __gshared string g_buildDir = "./cache/build/";
private __gshared string g_libDir   = "./cache/libs/";

class ISharedLib {
    SLRunState state = SLRunState.INACTIVE;
    string     srcPath, libPath;
    Exception  exc = null; // set if error

    @property bool running () { return state == SLRunState.RUNNING; }
    @property bool paused  () { return state == SLRunState.PAUSED; }
    @property bool active  () { return running || paused; }
    @property bool inactive () { return !active; }

    abstract void reload ();  // try reload immediate (should call dtors, then ctors)
    abstract void kill   ();  // kill if running      (should call dtors)
    abstract void pause  ();  // pause temporarily
    abstract void resume ();  // resume if paused

    abstract void update ();
}

enum SLRunState {
    INACTIVE = 0,
    COMPILE_FAILED = 1,
    LINK_FAILED    = 2,
    COMPILING      = 3,
    RUNTIME_EXCEPTION = 4,
    RUNNING           = 5,
    PAUSED            = 6
}

// hotloaded lib with (hopefully) full D runtime support
final class DSharedLib : ISharedLib {
    SharedLib _lib = null;
    ModuleInterface _moduleInterface;

    struct ModuleInterface {
        void function() init     = null;
        void function() teardown = null;
        void function(double) update = null;
    }

    this (string path) {}

    private auto resolvePath (string basePath, string relPath) {
        return relPath;
    }

    private void load () {
        if (state < SLRunState.COMPILING) {
            state = SLRunState.COMPILING;

            import std.process;
            auto result = executeShell(
                format("dmd -c %s -fPIC && dmd -of%s *.o -shared -defaultlib=libphobos2.so",
                    resolvePath(g_buildDir, srcPath), resolvePath(g_buildDir, libPath)),
                null,        // env
                Config.none, // config
                size_t.max,  // max output bytes
                g_buildDir   // working dir
            );
            if (result.status != 0) {
                state = SLRunState.COMPILE_FAILED;
                writefln("[compilation failed '%s']: %s", libPath, result.output);
                return;
            }

            auto newLib = new SharedLib(libPath);
            ModuleInterface newInterface;

            T link (T)(string symbolName, T* fcn) {
                return *fcn = newLib.getSymbol!T(symbolName);
            }

            if (!newLib.handle || !link("initModule", &newInterface.init) || !link("teardownModule", &newInterface.teardown)) {
                state = SLRunState.LINK_FAILED;
                writefln("[link failed '%s']: %s", libPath, dlerror());
                return;
            }

            if (_lib) unload();
            _lib = newLib;
            _moduleInterface = newInterface;

            try {
                _moduleInterface.init();
            } catch (Exception e) {
                state = SLRunState.RUNTIME_EXCEPTION;
                writefln("[init failed '%s']: %s", libPath, e);
                exc = e;
                return;
            }

            state = SLRunState.RUNNING;
        }
    }

    private void unload () {
        if (_lib) {
            try {
                _moduleInterface.teardown();
            } catch (Throwable e) {
                writefln("[teardown failed '%s']: %s", libPath, e);
            }
            _moduleInterface = ModuleInterface();
            _lib = null;
            exc  = null;

            if (state > SLRunState.COMPILING)
                state = SLRunState.INACTIVE;
        }
    }

    override void reload () { load(); assert(state != SLRunState.INACTIVE); }
    override void kill () { unload(); assert(state == SLRunState.INACTIVE); }
    override void pause () {
        if (state == SLRunState.RUNNING)
            state = SLRunState.PAUSED;
    }
    override void resume () {
        if (state == SLRunState.PAUSED)
            state = _lib ? exc ? SLRunState.RUNTIME_EXCEPTION : SLRunState.RUNNING : SLRunState.INACTIVE;
    }
}

// hotloaded lib built against the C interface
final class CSharedLib : ISharedLib {

}

// Other libs could include lua, etc.
