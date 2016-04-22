/*
This file is a part of my game engine,
but you can use it in your projects
without asking permission under MIT license terms.

Copyright (C) 2012 evilrat
*/

module util.sharedlib;
import std.string: toStringz;

// =========================
// LOADER
// =========================

// this is a class to allow reference counting and easy sharing library handle,
// if you don't like the idea of class overhead just remove unload method from
// destructor and make it struct, but remember about RAII.
// 
// note: loading D libraries should work properly only on windows
//   at this moment(DMD 2.061)
final class SharedLib
{
public:
    this (string libName) {
        load(libName);
    }

    ~this()
    {
        unload();
    }

    void load(string libName)
    {
        version(Posix)
            _handle = dlopen(libName.toStringz(), RTLD_NOW);
        else
            _handle = Runtime.loadLibrary(libName);
    }

    void unload()
    {
        if ( _handle !is null )
        {
            version(Posix)
                dlclose(_handle);
            else
                Runtime.unloadLibrary(_handle);
        }
    }

    T getSymbol(T = void*)(string symbolName)
    {
        version(Posix)
            return cast(T)dlsym(_handle, symbolName.toStringz());
        else
            return cast(T)GetProcAddress(cast(HMODULE)_handle, symbolName.toStringz());

        // should never reach this
        return null;
    }
    
    @property public SharedLibHandle handle() { return _handle; }
    private SharedLibHandle _handle;
}

// =========================
// PRIVATE IMPORTS AND DECLARATIONS
// =========================
private
{
    import core.runtime;

    // handle
    alias void* SharedLibHandle;

    version(Posix) {
        import core.sys.posix.dlfcn;
    }
    else version(Windows) {
        import std.c.windows.windows;
    }
}