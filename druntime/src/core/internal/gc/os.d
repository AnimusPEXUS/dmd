/**
 * Contains OS-level routines needed by the garbage collector.
 *
 * Copyright: D Language Foundation 2005 - 2021.
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Walter Bright, David Friedman, Sean Kelly, Leandro Lucarella
 */
module core.internal.gc.os;


version (WebAssembly)
{
   nothrow:
   private __gshared void* wasmFreeList = null;
   __gshared void* wasmStart = null;
   enum WasmPageSize = 64*1024;

   // returns amount of 64Kb pages
   pragma(LDC_intrinsic, "llvm.wasm.memory.size.i32")
      private int _wasmMemorySize(int memIndex) @safe pure nothrow @nogc;

   pragma(inline, true) auto wasmMemorySize() @safe pure nothrow @nogc {
      return _wasmMemorySize(0);
   }

   // adjust memory according to delta (64Kb pages)
   pragma(LDC_intrinsic, "llvm.wasm.memory.grow.i32")
      int _wasmMemoryGrow(int memIndex, int delta) @safe pure nothrow @nogc;

   pragma(inline, true)
      auto wasmMemoryGrow(int delta) @safe pure nothrow @nogc {
      return _wasmMemoryGrow(0, delta);
   }
} else version (Windows)
{
    import core.sys.windows.winbase : GetCurrentThreadId, VirtualAlloc, VirtualFree;
    import core.sys.windows.winnt : MEM_COMMIT, MEM_RELEASE, MEM_RESERVE, PAGE_READWRITE;

    alias int pthread_t;

    pthread_t pthread_self() nothrow
    {
        return cast(pthread_t) GetCurrentThreadId();
    }

    //version = GC_Use_Alloc_Win32;
}
else version (Posix)
{
    version (OSX)
        version = Darwin;
    else version (iOS)
        version = Darwin;
    else version (TVOS)
        version = Darwin;
    else version (WatchOS)
        version = Darwin;

    import core.sys.posix.sys.mman;
    import core.stdc.stdlib;


    /// Possible results for the wait_pid() function.
    enum ChildStatus
    {
        done, /// The process has finished successfully
        running, /// The process is still running
        error /// There was an error waiting for the process
    }

    /**
     * Wait for a process with PID pid to finish.
     *
     * If block is false, this function will not block, and return ChildStatus.running if
     * the process is still running. Otherwise it will return always ChildStatus.done
     * (unless there is an error, in which case ChildStatus.error is returned).
     */
    ChildStatus wait_pid(pid_t pid, bool block = true) nothrow @nogc
    {
        import core.exception : onForkError;

        int status = void;
        pid_t waited_pid = void;
        // In the case where we are blocking, we need to consider signals
        // arriving while we wait, and resume the waiting if EINTR is returned
        do {
            errno = 0;
            waited_pid = waitpid(pid, &status, block ? 0 : WNOHANG);
        }
        while (waited_pid == -1 && errno == EINTR);
        if (waited_pid == 0)
            return ChildStatus.running;
        else if (errno ==  ECHILD)
            return ChildStatus.done; // someone called posix.syswait
        else if (waited_pid != pid || status != 0)
        {
            onForkError();
            return ChildStatus.error;
        }
        return ChildStatus.done;
    }

    public import core.sys.posix.unistd: pid_t, fork;
    import core.sys.posix.sys.wait: waitpid, WNOHANG;
    import core.stdc.errno: errno, EINTR, ECHILD;

    //version = GC_Use_Alloc_MMap;
}
else
{
    import core.stdc.stdlib;

    //version = GC_Use_Alloc_Malloc;
}

/+
static if (is(typeof(VirtualAlloc)))
    version = GC_Use_Alloc_Win32;
else static if (is(typeof(mmap)))
    version = GC_Use_Alloc_MMap;
else static if (is(typeof(valloc)))
    version = GC_Use_Alloc_Valloc;
else static if (is(typeof(malloc)))
    version = GC_Use_Alloc_Malloc;
else static assert(false, "No supported allocation methods available.");
+/

static if (is(typeof(VirtualAlloc))) // version (GC_Use_Alloc_Win32)
{
    /**
    * Indicates if an implementation supports fork().
    *
    * The value shown here is just demostrative, the real value is defined based
    * on the OS it's being compiled in.
    * enum HaveFork = true;
    */
    enum HaveFork = false;

    /**
     * Map memory.
     */
    void *os_mem_map(size_t nbytes) nothrow @nogc
    {
        return VirtualAlloc(null, nbytes, MEM_RESERVE | MEM_COMMIT,
                PAGE_READWRITE);
    }


    /**
     * Unmap memory allocated with os_mem_map().
     * Returns:
     *      0       success
     *      !=0     failure
     */
    int os_mem_unmap(void *base, size_t nbytes) nothrow @nogc
    {
        return cast(int)(VirtualFree(base, 0, MEM_RELEASE) == 0);
    }
}
else static if (is(typeof(mmap)))  // else version (GC_Use_Alloc_MMap)
{
    enum HaveFork = true;

    void *os_mem_map(size_t nbytes, bool share = false) nothrow @nogc
    {   void *p;

        auto map_f = share ? MAP_SHARED : MAP_PRIVATE;
        p = mmap(null, nbytes, PROT_READ | PROT_WRITE, map_f | MAP_ANON, -1, 0);
        return (p == MAP_FAILED) ? null : p;
    }


    int os_mem_unmap(void *base, size_t nbytes) nothrow @nogc
    {
        return munmap(base, nbytes);
    }
}
else static if (is(typeof(valloc))) // else version (GC_Use_Alloc_Valloc)
{
    enum HaveFork = false;

    void *os_mem_map(size_t nbytes) nothrow @nogc
    {
        return valloc(nbytes);
    }


    int os_mem_unmap(void *base, size_t nbytes) nothrow @nogc
    {
        free(base);
        return 0;
    }
}
else static if (is(typeof(malloc))) // else version (GC_Use_Alloc_Malloc)
{
    // NOTE: This assumes malloc granularity is at least (void*).sizeof.  If
    //       (req_size + PAGESIZE) is allocated, and the pointer is rounded up
    //       to PAGESIZE alignment, there will be space for a void* at the end
    //       after PAGESIZE bytes used by the GC.

    enum HaveFork = false;

    import core.internal.gc.impl.conservative.gc;


    const size_t PAGE_MASK = PAGESIZE - 1;


    void *os_mem_map(size_t nbytes) nothrow @nogc
    {   byte *p, q;
        p = cast(byte *) malloc(nbytes + PAGESIZE);
        if (!p)
            return null;
        q = p + ((PAGESIZE - ((cast(size_t) p & PAGE_MASK))) & PAGE_MASK);
        * cast(void**)(q + nbytes) = p;
        return q;
    }


    int os_mem_unmap(void *base, size_t nbytes) nothrow @nogc
    {
        free( *cast(void**)( cast(byte*) base + nbytes ) );
        return 0;
    }
}
else version (WebAssembly)
{
    // NOTE: a very simple allocater with a coalescing freelist
    private __gshared void* freelist = null;
    struct FreeListItem {
        size_t bytes;
        FreeListItem* next;
    }
    private void push(void* base, size_t nbytes) nothrow @trusted {
        // insert the item and maintains a sorted freelist
        // returns the item before the insertion (or the first)
        static FreeListItem* insert(FreeListItem* item) nothrow @trusted {
            // if it should be first
            if (item < freelist) {
                item.next = cast(FreeListItem*)freelist;
                freelist = cast(void*)item;
                return item;
            }
            // insert sorted on address
            auto p = cast(FreeListItem*)freelist;
            for(;;) {
                if (!p.next) {
                    p.next = item;
                    return p;
                }
                if (item < p.next) {
                    item.next = p.next;
                    p.next = item;
                    return p;
                }
                p = p.next;
            }
            assert(0);
        }
        static void coalesce(FreeListItem* item) nothrow @trusted {
            for (;;) {
                if (!item.next)
                    return;
                if (cast(void*)item + item.bytes !is item.next)
                    return;
                item.bytes += item.next.bytes;
                item.next = item.next.next;
            }
        }
        auto item = cast(FreeListItem*)(base);
        item.bytes = nbytes;
        if (freelist is null) {
            freelist = cast(void*)item;
            item.next = null;
        } else {
            coalesce(insert(item));
        }
    }
    private void[] pop(size_t nbytes) nothrow @trusted {
        if (freelist is null)
            return [];
        auto prev = cast(FreeListItem**)&freelist;
        auto p = cast(FreeListItem*)freelist;
        for (;;) {
            if (p.bytes >= nbytes) {
                auto mem = (cast(void*)p)[0..nbytes];
                if (p.bytes - nbytes > 0) {
                    auto newItem = cast(FreeListItem*)(cast(void*)p + nbytes);
                    newItem.bytes = p.bytes - nbytes;
                    (*prev) = newItem;
                } else
                    (*prev) = p.next;
                return mem;
            }
            if (p.next is null)
                return [];
            prev = &p.next;
            p = p.next;
        }
    }

    void *os_mem_map(size_t nbytes) nothrow @trusted
    {
        if (wasmStart is null)
            wasmStart = cast(void*)(wasmMemorySize() * WasmPageSize);
        auto mem = pop(nbytes);
        if (mem == null || mem.length == 0) {
            int pages = cast(int)((nbytes + WasmPageSize - 1) >> 16);
            auto currentPages = wasmMemoryGrow(pages);
            auto addr = cast(void*)(currentPages * WasmPageSize);
            mem = addr[0 .. pages * WasmPageSize];
        } else {
        }
        if (mem.length > nbytes) {
            push(&mem[0] + nbytes, mem.length - nbytes);
        }
        return &mem[0];
    }

    int os_mem_unmap(void *base, size_t nbytes) nothrow @safe
    {
        push(base, nbytes);
        return 0;
    }

} else
      static assert(false, "No supported allocation methods available.");

/**
   Check for any kind of memory pressure.

   Params:
      mapped = the amount of memory mapped by the GC in bytes
   Returns:
       true if memory is scarce
*/
// TODO: get virtual mem sizes and current usage from OS
// TODO: compare current RSS and avail. physical memory
bool isLowOnMem(size_t mapped) nothrow @nogc
{
    version (Windows)
    {
        import core.sys.windows.winbase : GlobalMemoryStatusEx, MEMORYSTATUSEX;

        MEMORYSTATUSEX stat;
        stat.dwLength = stat.sizeof;
        const success = GlobalMemoryStatusEx(&stat) != 0;
        assert(success, "GlobalMemoryStatusEx() failed");
        if (!success)
            return false;

        // dwMemoryLoad is the 'approximate percentage of physical memory that is in use'
        // https://docs.microsoft.com/en-us/windows/win32/api/sysinfoapi/ns-sysinfoapi-memorystatusex
        const percentPhysicalRAM = stat.ullTotalPhys / 100;
        return (stat.dwMemoryLoad >= 95 && mapped > percentPhysicalRAM)
            || (stat.dwMemoryLoad >= 90 && mapped > 10 * percentPhysicalRAM);
    }
    else
    {
        enum GB = 2 ^^ 30;
        version (D_LP64)
            return false;
        else version (Darwin)
        {
            // 80 % of available 4GB is used for GC (excluding malloc and mmap)
            enum size_t limit = 4UL * GB * 8 / 10;
            return mapped > limit;
        }
        else
        {
            // be conservative and assume 3GB
            enum size_t limit = 3UL * GB * 8 / 10;
            return mapped > limit;
        }
    }
}

/**
   Get the size of available physical memory

   Returns:
       size of installed physical RAM
*/
version (Windows)
{
    ulong os_physical_mem() nothrow @nogc
    {
        import core.sys.windows.winbase : GlobalMemoryStatus, MEMORYSTATUS;
        MEMORYSTATUS stat;
        GlobalMemoryStatus(&stat);
        return stat.dwTotalPhys; // limited to 4GB for Win32
    }
}
else version (Darwin)
{
    extern (C) int sysctl(const int* name, uint namelen, void* oldp, size_t* oldlenp, const void* newp, size_t newlen) @nogc nothrow;
    ulong os_physical_mem() nothrow @nogc
    {
        enum
        {
            CTL_HW = 6,
            HW_MEMSIZE = 24,
        }
        int[2] mib = [ CTL_HW, HW_MEMSIZE ];
        ulong system_memory_bytes;
        size_t len = system_memory_bytes.sizeof;
        if (sysctl(mib.ptr, 2, &system_memory_bytes, &len, null, 0) != 0)
            return 0;
        return system_memory_bytes;
    }
}
else version (Posix)
{
    ulong os_physical_mem() nothrow @nogc
    {
        import core.sys.posix.unistd : sysconf, _SC_PAGESIZE, _SC_PHYS_PAGES;
        const pageSize = sysconf(_SC_PAGESIZE);
        const pages = sysconf(_SC_PHYS_PAGES);
        return pageSize * pages;
    }
}
