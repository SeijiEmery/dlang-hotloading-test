import std.file;
import std.path;
import std.stdio;
import std.format;
import std.datetime;
import std.algorithm: swap;
import std.conv;
import std.array: join, array;

string[] WATCHED_DIRS = [
    "./src/modules", "./assets"
];

class Watcher {
    SysTime[string] timestamps;
    string[] watchedDirs;
    string[] uniqueFiles;
    string[] lastUniqueFiles;

    this (string rel, string[] dirs) {
        foreach (dir; dirs)
            watchedDirs ~= dir
                .expandTilde
                .absolutePath
                .asNormalizedPath
                .to!string;
        rescan();
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

        if (newFiles.length)
            writefln("%d files added:\n\t%s", newFiles.length, newFiles.join("\n\t"));
        if (touchedFiles.length)
            writefln("%d files changed:\n\t%s", touchedFiles.length, touchedFiles.join("\n\t"));
        if (deletedFiles.length)
            writefln("%d files deleted:\n\t%s", deletedFiles.length, deletedFiles.join("\n\t"));
    }
}


void main (string[] args) {
    auto watcher = new Watcher(args[0].baseName.stripExtension, WATCHED_DIRS);
    while (1) {
        import core.thread;
        Thread.sleep(dur!("msecs")(100));
        watcher.rescan();
    }

}

