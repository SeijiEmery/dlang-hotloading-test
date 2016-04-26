import std.stdio;
import std.path;

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

    auto dhl = new DModuleHotloader(args[0].baseName.stripExtension);
    collector.addListener(&dhl.onFSEvent);

    auto fsthread = new FileWatcherRunner(watcher).start();
    while (fsthread.isRunning) {
        collector.dispatchEvents();

        import core.thread;
        //Thread.sleep(dur!("msecs")(1000));
        Thread.sleep(dur!("msecs")(16));
    }
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

    this (string workingDir) {
        srcDir = chainPath(workingDir.absolutePath, "../src/modules/")
            .asNormalizedPath
            .to!string;
        if (srcDir[$-1] != '/')
            srcDir ~= '/';
        srcPat = srcDir ~ "/{*.d,*/*.d}";
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
            foreach (m; modulesToReload) {
                writefln("Reloading d-module '%s':\n\t%s", m.name, m.files.join("\n\t"));
            }

        }
    }
}




