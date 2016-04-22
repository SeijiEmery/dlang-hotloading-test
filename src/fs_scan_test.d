import std.file;
import std.path;
import std.stdio;
import std.format;
import std.datetime;
import std.algorithm: swap;
import std.conv;
import std.array: join, array;
import core.thread;

string[] WATCHED_DIRS = [
    "./src/modules", "./assets"
];

struct FileChangeEvent {
    string[] added, modified, removed;
}
alias FileChangeListener = void delegate(FileChangeEvent);


// Basic utility that watches a list of directories + produces a list of file change
// events via polling. Not thread safe (see FileWatcherRunner, FileWatcherEventCollector).
class FileWatcher {
    private SysTime[string] timestamps;
    private string[] watchedDirs;
    private string[] uniqueFiles;
    private string[] lastUniqueFiles;

    public FileChangeListener[] listeners;

    this (string rel, string[] dirs) {
        foreach (dir; dirs)
            watchedDirs ~= dir
                .expandTilde
                .absolutePath
                .asNormalizedPath
                .to!string;
    }
    public auto addListener (FileChangeListener listener) {
        listeners ~= listener;
        return this;
    }

    private string[] newFiles, touchedFiles, deletedFiles;

    void rescan () {
        swap(uniqueFiles, lastUniqueFiles);
        uniqueFiles.length = 0;

        newFiles.length = 0;
        touchedFiles.length = 0;
        deletedFiles.length = 0;

        foreach (dir; watchedDirs) {
            foreach (DirEntry entry; dir.dirEntries(SpanMode.depth)) {
                if (entry.name !in timestamps) {
                    timestamps[entry.name] = entry.timeLastModified;
                    newFiles ~= entry.name;
                } else if (entry.timeLastModified > timestamps[entry.name]) {
                    timestamps[entry.name] = entry.timeLastModified;
                    touchedFiles ~= entry.name;
                }
                uniqueFiles ~= entry.name;
            }
        }
        import std.algorithm: sort, setDifference, equal;

        sort(uniqueFiles);
        deletedFiles = setDifference(lastUniqueFiles, uniqueFiles).array;
        foreach (file; deletedFiles) 
            timestamps.remove(file);

        //sort(newFiles);
        //assert(equal(newFiles, setDifference(uniqueFiles, lastUniqueFiles)), format(" => \n\t%s\n != %s",
        //    newFiles.join("\n\t"), setDifference(uniqueFiles, lastUniqueFiles).array.join("\n\t")));

        if (newFiles.length || touchedFiles.length || deletedFiles.length) {
            auto evt = FileChangeEvent(newFiles, touchedFiles, deletedFiles);
            foreach (cb; listeners)
                cb(evt);
        }
    }
}

// Runs a FileWatcher on an async thread, with controls to kill, etc the running thread.
class FileWatcherRunner : Thread {
    public Duration pollingInterval = dur!("msecs")(100);

    private bool shouldDie = false;

    public Exception exc = null;  // set if terminated unexpectedly
    public FileWatcher watcher;

    this (FileWatcher watcher) {
        this.watcher = watcher;
        super(&run);
    }
    ~this () { kill(); }

    void kill () { shouldDie = true; }

    private void run () {
        while (!shouldDie) {
            watcher.rescan();
            sleep(pollingInterval);
        }
    }
}

// Collects events from a FileWatcher running concurrently and enables them to be collected +
// resent from a given thread (ie. the main thread).
class FileWatcherEventCollector {
    private FileChangeEvent[] pendingEvts, processedEvts;
    public FileChangeListener[] listeners;

    import core.sync.mutex;
    private Mutex mutex;
    this () { mutex = new Mutex(); }

    auto addListener (FileChangeListener listener) {
        return listeners ~= listener, this;
    }

    // Use this as a FileWatcher listener (should only be called by FileWatcher)
    void onEvent (FileChangeEvent evt) {
        synchronized (mutex) {
            pendingEvts ~= evt;
        }
    }

    // Dispatches pending events to listeners on the thread it's called from.
    // This should get called on the main thread once every frame or something.
    void dispatchEvents () {
        synchronized (mutex) {
            if (pendingEvts.length) {
                swap(pendingEvts, processedEvts);
            }
        }

        if (processedEvts.length) {
            foreach (evt; processedEvts[1..$]) {
                processedEvts[0].added   ~= evt.added;
                processedEvts[0].removed ~= evt.removed;
                processedEvts[0].modified ~= evt.modified;
            }

            foreach (cb; listeners)
                cb(processedEvts[0]);
            processedEvts.length = 0;
        }
    }
}  


void main (string[] args) {
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
        //Thread.sleep(dur!("msecs")(1000));
        Thread.sleep(dur!("msecs")(16));
    }
}

