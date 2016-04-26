import std.stdio;
import std.path;
import std.format;

string[] WATCHED_DIRS = [
    "./src/modules", "./assets"
];

void main (string[] args) {
    import ht.engine.fswatcher;

    auto collector = new FileWatcherEventCollector();
    auto watcher   = new FileWatcher(args[0].baseName.stripExtension, WATCHED_DIRS)
        .addListener(&collector.onEvent);
        //.addListener((FileChangeEvent evt) { writefln("Event!"); }); // called on fs thread

    collector.addListener((FileChangeEvent ev) {   // called on main thread
        if (ev.added.length)
            writefln("%d files added:\n\t%s", ev.added.length, ev.added.join("\n\t"));
        if (ev.modified.length)
            writefln("%d files changed:\n\t%s", ev.modified.length, ev.modified.join("\n\t"));
        if (ev.removed.length)
            writefln("%d files deleted:\n\t%s", ev.removed.length, ev.removed.join("\n\t"));
    });

    auto dmodules = new DModuleRunner();

    auto dhl = new DModuleHotloader(args[0].baseName.stripExtension, dmodules);
    collector.addListener(&dhl.onFSEvent);

    auto fsthread = new FileWatcherRunner(watcher).start();
    while (fsthread.isRunning) {
        collector.dispatchEvents();

        import core.thread;
        //Thread.sleep(dur!("msecs")(1000));
        Thread.sleep(dur!("msecs")(16));
    }
    dmodules.teardown();
}



class DModuleHotloader {
    import ht.engine.fswatcher;
    import std.algorithm: filter;
    import std.array;
    import std.range;
    import std.conv;
    import std.container.rbtree;

    string srcDir;
    string srcPat;

    DModuleRunner runner;

    this (string workingDir, DModuleRunner runner) {
        srcDir = chainPath(workingDir.absolutePath, "../src/modules/")
            .asNormalizedPath
            .to!string;
        if (srcDir[$-1] != '/')
            srcDir ~= '/';
        srcPat = srcDir ~ "/{*.d,*/*.d}";
        this.runner = runner;
    }


    // temporaries
    private auto tcmDirs = new RedBlackTree!string;
    private auto tcmFiles = new RedBlackTree!string;

    void onFSEvent (FileChangeEvent ev) {
        import std.string;
        import std.algorithm;


        auto filterModulePaths (S,R)(S basePath, R paths) {
            return paths
                .map!((string s) {
                    auto i = s.indexOf(basePath);
                    return i >= 0 && globMatch(s, "*.d") ?
                        s[i + basePath.length .. $] :
                        "";
                })
                .filter!((string s) => s.length != 0);
        }

        auto modifiedFiles = filterModulePaths(srcDir, chain(ev.added, ev.modified)).array;
        auto removedFiles  = filterModulePaths(srcDir, ev.removed).array;

        if (modifiedFiles.length)
            writefln("D htl: Changed source files: %s", modifiedFiles);
        if (removedFiles.length)
            writefln("D htl: Removed source files: %s", removedFiles);
        else if (!modifiedFiles.length)
            writefln("D htl: No changes (%s, %s)", srcDir, srcPat);

        tcmDirs.clear();
        tcmFiles.clear();

        auto paths = filterModulePaths(srcDir, chain(ev.added, ev.modified, ev.removed));
        foreach (path; paths) {
            auto i = path.indexOf("/");
            if (i >= 0) {
                writefln("%s => %s", path, path[0 .. i]);
                tcmDirs.insert(path[0 .. i]);
            } else {
                writefln("%s => %s", path, path);
                tcmFiles.insert(path);
            }
        }

        auto changedModules = chain(tcmDirs.array, tcmFiles.array).array;
        if (changedModules.length) {
            writefln("D htl: Changed Modules: %s", changedModules);

            struct ModuleDefn { string name; string[] files; }
            ModuleDefn[] modulesToReload;
            foreach (name; tcmDirs) {
                import std.file;
                auto path = chainPath(srcDir, name).to!string;
                auto srcFiles = dirEntries(path, "*.d", SpanMode.depth)
                    .map!"a.name";
                modulesToReload ~= ModuleDefn(name, srcFiles.array);
            }
            foreach (file; tcmFiles) {
                import std.regex;
                string name = matchFirst(file, ctRegex!`(\w+)\.d`)[1];
                string path = chainPath(srcDir, file).to!string;
                modulesToReload ~= ModuleDefn( name, [ path ] );
            }
            //auto modulesToReload = chain(
            //    tcmDirs.map!((string name) {
            //        return ModuleDefn(name, []);
            //    }),
            //    tcmFiles.map!((string file) {
            //        import std.regex;
            //        return ModuleDefn(
            //            matchFirst(file, regex(`(\w)+\.d`)).hit.to!string,
            //            [ file ]
            //        );
            //    })
            //);

            auto BUILD_DIR = "~/Library/Application Support/gsb_htest/cache/build/d/"
                .expandTilde.absolutePath.to!string;
            auto LIB_DIR   = "~/Library/Application Support/gsb_htest/cache/lib/d/"
                .expandTilde.absolutePath.to!string;

            auto CACHE_DIR = "~/Library/Application Support/gsb_htest/cache".expandTilde;
            auto toCacheRelPath (string path) { 
                return path.relativePath(CACHE_DIR);
            }

            auto buildPath (string name) { return chainPath(BUILD_DIR, name).to!string; }
            auto libPath   (string name) { return chainPath(LIB_DIR, name).to!string; }

            import std.typecons;
            Tuple!(string,string)[] recompiledModules;   // name, absolute-path-to-lib
            Tuple!(string,string)[] failedModules;       // name, error(s)

            foreach (m; modulesToReload) {
                writefln("Reloading d-module '%s':\n\t%s\n", m.name, m.files.join("\n\t"));

                auto cmd1 = format("dmd -c -fPIC %s",
                    m.files.join(" ")
                );
                auto buildDir = chainPath(BUILD_DIR, m.name).to!string;

                auto libname = format("lib%s.so", m.name);
                auto cmd2 = format("dmd -of%s %s/*.o -shared -defaultlib=libphobos2.so",
                    libname, buildDir.replace(" ", "\\ "));
                auto libDir = chainPath(LIB_DIR, m.name).to!string;

                import std.file;
                import std.process;

                string lastErr;
                bool runCmd (string cmd, string workingDir) {
                    if (!workingDir.exists) {
                        writefln("making dir %s", workingDir);
                        workingDir.mkdirRecurse();
                    }
                    writefln("cd %s && %s", workingDir, cmd);
                    auto result = executeShell(cmd, null, Config.none, size_t.max, workingDir);
                    if (result.status != 0)
                        return writeln(lastErr = result.output), false;
                    return true;
                }
                auto success = 
                    runCmd(cmd1, buildDir) &&
                    runCmd(cmd2, libDir);

                if (success) {
                    writefln("Produced %s (%s)\n", libname, chainPath(libDir, libname).to!string);
                    recompiledModules ~= tuple(m.name, chainPath(libDir, libname).to!string);
                } else {
                    failedModules ~= tuple(m.name, lastErr);
                }
            }
            writefln("Recompiled %d modules: %s", recompiledModules.length, recompiledModules.map!("a[0]"));
            writefln("%d failed: %s", failedModules.length, failedModules.map!("a[0]"));
            foreach (err; failedModules)
                writefln("\t%s", err[1]);


            foreach (m; recompiledModules)
                runner.load(m[0], m[1]);
        }
    }
}


class DModuleRunner {
    import util.sharedlib;
    import core.sys.posix.dlfcn;

    private static class HotModule {
        string name, path;
        SharedLib lib = null;

        private void function() module_init = null;
        private void function() module_teardown = null;
        private void function(double) module_update = null;
        private bool loaded = false;

        this (string name, string path) {
            this.name = name; this.path = path;
        }
        ~this () { if (lib) unload(); }

        void load () {
            if (lib) unload();

            loaded = false;
            lib = new SharedLib(path);

            T link (T)(string symbolName, T* fcn) {
                auto f = lib.getSymbol!T(symbolName);
                if (!f) throw new Exception(
                    format("Failed to link '%s':\n\t%s", 
                    symbolName, dlerror()));
                return *fcn = f;
            }

            writefln("---  Loading '%s' ---", name);
            if (lib.handle) {
                try {
                    link("initModule", &module_init);

                    writefln("--- Initializing '%s' ---", name);

                    module_init();

                    writefln("--- Module '%s' OK ---", name);
                    loaded = true;
                } catch (Exception e) {
                    writefln("Error while loading module: %s", e);
                }
            }
        }
        void unload () {
            assert(lib);
            if (lib && loaded) {
                try {
                    writefln("--- Unloading '%s' ---", name);
                    if (module_teardown)
                        module_teardown();
                    writefln("--- Module unload OK ---", name);
                } catch (Exception e) {
                    writefln("Error while unloading module: %s", e);
                }
            }
            lib.unload();
            lib = null;
            loaded = false;
        }
    }


    HotModule[string] modules;

    ~this () {
        teardown();
    }

    void load (string name, string path) {
        if (name in modules) {
            modules[name].path = path;
            modules[name].load();
        } else {
            modules[name] = new HotModule(name, path);
            modules[name].load();
        }
    }

    void teardown () {
        foreach (k, v; modules) {
            v.unload();
            modules.remove(k);
        }
    }
}

