module ht.engine.fs_scan;
import std.file;
import std.path;
import std.stdio;
import std.format:    format;
import std.exception: enforce;
import std.array:     array, join;
import std.typecons:  Tuple, tuple;
import std.conv:      to;
import std.datetime:  SysTime;

immutable string PROJECT_NAME = "gsb_htest";

version (OSX) {
    immutable string BASE_DIR = "~/Library/Application Support/"~PROJECT_NAME~"/";
} else {
    immutable string BASE_DIR = "~/.config/"~PROJECT_NAME~"/";
}

immutable string BUILD_DIR = BASE_DIR ~ "cache/build/";
immutable string LIB_DIR   = BASE_DIR ~ "cache/lib/";
immutable string REL_SRC_PATH = "src/modules/";


class FSScanner {
    string srcDir, buildDir, libDir;

    this (string srcBaseDir, string buildDir = null, string libDir = null) {


        string rel = REL_SRC_PATH;

        this.srcDir   = chainPath(srcBaseDir, rel).array;
        this.buildDir = buildDir ? buildDir : BUILD_DIR;
        this.libDir   = libDir   ? libDir   : LIB_DIR;

        enforce( srcDir.exists && srcDir.isDir, format("Invalid src path '%s'", srcDir) );

        if (!this.buildDir.exists)
            this.buildDir.mkdirRecurse();
        enforce( this.buildDir.isDir, format("'%s' is not a directory", this.buildDir));

        if (!this.libDir.exists)
            this.libDir.mkdirRecurse();
        enforce( this.libDir.isDir, format("'%s' is not a directory", this.libDir));

        rescan();
    }

    void rescan () {
        Tuple!(string,string)[] dirtySrcFiles;
        Tuple!(string,string)[] dirtyLibs;
        string[] missingPaths;

        // temporary
        string[] objPaths;

        if (!buildDir.exists) missingPaths ~= buildDir;
        if (!libDir.exists)   missingPaths ~= libDir;

        // Rescan D source files + update libs.
        foreach (DirEntry e; srcDir.dirEntries(SpanMode.shallow)) {
            if (e.isDir && e.name.chainPath("package.d").exists) {

                objPaths.length = 0;
                bool dirtyObjs = false;

                foreach (DirEntry src; e.name.dirEntries("*.d", SpanMode.depth)) {
                    auto relPath = src.name.relativePath(srcDir);
                    auto objPath = chainPath(buildDir, relPath.stripExtension ~ ".o").to!string.expandTilde;

                    if (!objPath.exists) {
                        if (!objPath.dirName.exists)
                            missingPaths ~= objPath.dirName.to!string;
                        dirtySrcFiles ~= tuple(src.name, objPath);
                        dirtyObjs = true;
                    } else if (timeLastModified(src.name) >= timeLastModified(objPath, SysTime.min)) {
                        dirtySrcFiles ~= tuple(src.name, objPath);
                        dirtyObjs = true;
                    }
                    objPaths ~= objPath.to!string;
                }

                auto libPath = chainPath(libDir, e.name.baseName ~ ".so").to!string.expandTilde;
                if (dirtyObjs || !libPath.exists) {
                    if (!libPath.dirName.exists)
                        missingPaths ~= libPath.dirName.to!string;
                    dirtyLibs ~= tuple(libPath, objPaths.join(" "));
                }
            }
        }
        foreach (DirEntry e; srcDir.dirEntries("*.d", SpanMode.shallow)) {
            auto objPath = chainPath(buildDir, e.name.baseName.stripExtension ~ ".o").to!string.expandTilde;
            auto libPath = chainPath(libDir,   e.name.baseName.stripExtension ~ ".so").to!string.expandTilde;

            if (!objPath.exists || timeLastModified(e.name) >= timeLastModified(objPath, SysTime.min))
                dirtySrcFiles ~= tuple(e.name, objPath);
            if (!libPath.exists || timeLastModified(objPath) >= timeLastModified(libPath, SysTime.min))
                dirtyLibs ~= tuple(libPath, objPath);
        }


        if (missingPaths.length) {
            writefln("making %d paths: ", missingPaths.length);
            foreach (path; missingPaths) {
                path.mkdirRecurse();
                writefln("%s", path);
            }
        }

        if (dirtySrcFiles) {
            writefln("%d dirty source files: ", dirtySrcFiles.length);

            import std.process;
            //auto result = executeShell("dmd -c %s", dirtySrcFiles.map!("a[0]").join(" "));
            foreach (p; dirtySrcFiles) {
                writefln("%s => %s", p[0], p[1]);
                auto result = executeShell(format("dmd -c %s", p[0]));
                if (result.status != 0)
                    writefln("%s", result.output);
            }
        }
        if (dirtyLibs) {
            writefln("%d dirty libs: ", dirtyLibs.length);
            foreach (p; dirtyLibs) {
                writefln("%s <= %s", p[0], p[1]);
            }
        }
    }
}

