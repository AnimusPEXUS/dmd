module core.sys.webassembly.time;

// public import core.sys.posix.time;
// public import core.sys.posix.sys.time;

version (WebAssembly) 
{
alias time_t = long;
}
