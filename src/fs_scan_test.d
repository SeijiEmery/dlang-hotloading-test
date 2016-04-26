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

    string srcDir;
    string srcPat;

    this (string workingDir) {
        srcDir = chainPath(workingDir.absolutePath, "../src/modules/")
            .asNormalizedPath
            .to!string;
        srcPat = srcDir ~ "/{*.d,*/*.d}";
    }

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
            writefln("DMHL: Changed source files: %s", modifiedFiles);
        if (removedFiles.length)
            writefln("DMHL: Removed source files: %s", removedFiles);
        else if (!modifiedFiles.length)
            writefln("DMHL: No changes (%s, %s)", srcDir, srcPat);
    }
}




