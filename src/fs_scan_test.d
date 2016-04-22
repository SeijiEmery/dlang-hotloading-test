import std.stdio;
import std.path;

string[] WATCHED_DIRS = [
    "./src/modules", "./assets"
];

void main (string[] args) {
    import ht.engine.fswatcher;

    auto collector = new FileWatcherEventCollector();
    auto watcher   = new FileWatcher(args[0].baseName.stripExtension, WATCHED_DIRS)
        .addListener(&collector.onEvent)
        .addListener((FileChangeEvent evt) { writefln("Event!"); }); // called on fs thread

    collector.addListener((FileChangeEvent ev) {   // called on main thread
        if (ev.added.length)
            writefln("%d files added:\n\t%s", ev.added.length, ev.added.join("\n\t"));
        if (ev.modified.length)
            writefln("%d files changed:\n\t%s", ev.modified.length, ev.modified.join("\n\t"));
        if (ev.removed.length)
            writefln("%d files deleted:\n\t%s", ev.removed.length, ev.removed.join("\n\t"));
    });

    auto fsthread = new FileWatcherRunner(watcher).start();
    while (fsthread.isRunning) {
        collector.dispatchEvents();

        import core.thread;
        //Thread.sleep(dur!("msecs")(1000));
        Thread.sleep(dur!("msecs")(16));
    }
}

