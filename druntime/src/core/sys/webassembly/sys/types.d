module core.sys.webassembly.sys.types;

version (WebAssembly)
{
    alias time_t = long; // TODO: not c_long?
}
