import std.stdio;
import ht.engine;

import core.sys.posix.dlfcn;
import std.string;

struct IHoloadedModule {
    void* handle;
    void function() init     = null;
    void function() teardown = null;
}

IHoloadedModule loadModule (string libPath) {
    auto cpath = toStringz(libPath);
    void* lh = dlopen(cpath, RTLD_LAZY);
    if (!lh)
        throw new Exception(format("dlopen error: %s", dlerror()));
    writefln("%s loaded", libPath);

    auto loadFcn (F)(const(char)* name) {
        auto result = cast(F)dlsym(lh, name);
        auto err = dlerror();
        if (err) {
            writefln("dlsym error: %s (%s in '%s')\n", err, name, cpath);
            return null;
        }
        return result;
    }

    return IHoloadedModule(lh, 
        loadFcn!(typeof(IHoloadedModule.init))("moduleInit"),
        loadFcn!(typeof(IHoloadedModule.teardown))("moduleTeardown")
    );
}


void main (string[] args) {
    writefln("Hello world!");

    auto sheep = loadModule("libfoo.so");
    if (sheep.init) { sheep.init(); }
    if (sheep.teardown) { sheep.teardown(); }
    if (sheep.handle) { dlclose(sheep.handle); sheep.handle = null; }

}