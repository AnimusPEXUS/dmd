/**
 * Written in the D programming language.
 * This module provides WebAssembly support for sections.
 *
 * Copyright: Copyright Martin Nowak 2012-2013.
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Martin Nowak
 * Source: $(DRUNTIMESRC rt/_sections_wasm.d)
 */

module rt.sections_wasm;

version (WebAssembly):

// debug = PRINTF;
debug(PRINTF) import core.stdc.stdio;
import core.sys.posix.pthread;
import core.stdc.stdlib : calloc, malloc, free;
import core.stdc.string : memcpy;
import rt.deh;
import rt.minfo;
import rt.util.utility : safeAssert;

struct SectionGroup
{
    static int opApply(scope int delegate(ref SectionGroup) dg)
    {
        return dg(_sections);
    }

    static int opApplyReverse(scope int delegate(ref SectionGroup) dg)
    {
        return dg(_sections);
    }

    @property immutable(ModuleInfo*)[] modules() const nothrow @nogc
    {
        return _moduleGroup.modules;
    }

    @property ref inout(ModuleGroup) moduleGroup() inout nothrow @nogc
    {
        return _moduleGroup;
    }

    // version (DigitalMars)
    // @property immutable(FuncTable)[] ehTables() const nothrow @nogc
    // {
    //     auto pbeg = cast(immutable(FuncTable)*)&__start_deh;
    //     auto pend = cast(immutable(FuncTable)*)&__stop_deh;
    //     return pbeg[0 .. pend - pbeg];
    // }

    @property inout(void[])[] gcRanges() inout nothrow @nogc
    {
        return _gcRanges[];
    }

private:
    ModuleGroup _moduleGroup;
    void[][1] _gcRanges;
}

void initSections() nothrow @nogc
{
    // pthread_key_create(&_tlsKey, null);

    // SharedObject object;
    // const success = SharedObject.findForAddress(&_sections, object);
    // safeAssert(success, "cannot find ELF object");

    // _staticTLSRange = getStaticTLSRange(object, _tlsAlignment);
    // // prevent the linker from stripping the TLS alignment symbols
    // if (_staticTLSRange is null) // should never happen
    //     safeAssert(alignmentForTDATA == alignmentForTBSS, "unreachable");

    version (LDC)
    {
        auto mbeg = cast(immutable ModuleInfo**)&__start___minfo;
        auto mend = cast(immutable ModuleInfo**)&__stop___minfo;
    }
    else
    {
        auto mbeg = cast(immutable ModuleInfo**)&__start_minfo;
        auto mend = cast(immutable ModuleInfo**)&__stop_minfo;
    }
    _sections.moduleGroup = ModuleGroup(mbeg[0 .. mend - mbeg]);
    auto dataStart = cast(void*)1024;
    auto dataEnd = cast(void*)&__data_end;

    _sections._gcRanges[0] = dataStart[0 .. (dataEnd - dataStart)];

    // // iterate over ELF segments to determine data segment range
    // import core.sys.linux.elf;
    // foreach (ref phdr; object)
    // {
    //     if (phdr.p_type == PT_LOAD && (phdr.p_flags & PF_W)) // writeable data segment
    //     {
    //         safeAssert(_sections._gcRanges[0] is null, "expected a single data segment");

    //         void* start = object.baseAddress + phdr.p_vaddr;
    //         void* end = start + phdr.p_memsz;
    //         debug(PRINTF) printf("data segment: %p - %p\n", start, end);

    //         // pointer-align up
    //         enum mask = size_t.sizeof - 1;
    //         start = cast(void*) ((cast(size_t)start + mask) & ~mask);

    //         _sections._gcRanges[0] = start[0 .. end-start];
    //     }
    // }
}

void finiSections() nothrow @nogc
{
}

void[] initTLSRanges() nothrow @nogc
{
    return [];
}

void finiTLSRanges(void[] rng) nothrow @nogc
{
}

void scanTLSRanges(void[] rng, scope void delegate(void* pbeg, void* pend) nothrow dg) nothrow
{
}

extern(C)
{
    /* Symbols created by the linker and inserted into the object file that
     * 'bracket' sections.
     */
    extern __gshared
        {
            version (LDC)
                {
                    void* __start___minfo;
                    void* __stop___minfo;
                    void* __data_end;
                    void* __heap_base;
                }
            else
                {
                    static assert("Unsupported Compiler");
                    // void* __start_deh;
                    // void* __stop_deh;
                    // void* __start_minfo;
                    // void* __stop_minfo;
                }
        }
}

private:

__gshared void[] _staticTLSRange;
__gshared uint _tlsAlignment;
__gshared SectionGroup _sections;
