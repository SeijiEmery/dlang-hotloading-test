module ht_modules.foo.sheep;

import std.stdio;

shared static this () {
    writefln("Loading..."); // These don't get called on osx
}
shared static ~this () {
    writefln("Unloading...");
}


extern (C) {

public void moduleInit () { // But this does
    writefln("Baaaaaaaa");
}
public void moduleTeardown () {
    writefln("...");
}

}