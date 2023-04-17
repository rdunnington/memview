# memview
Memview is an experimental memory profiler and visualizer.

Written for the Handmade Network's [Visibility Jam](https://handmade.network/jam/visibility-2023/feed). Memview is an app that visualizes memory allocations within the address space of the program. You can select individual blocks to view the allocating callstack, and scrub through a timeline of the program history to see how the memory footprint changes over time. Current functionality is very limited since it's currently just a proof of concept.

## Requirements
You'll need Zig, preferably version `0.11.0-dev.2247+38ee46dda` since that's what I was using during development. Other 0.11.x master branch versions may also work.

## Example Usage
To run the simple test, run these commands. This will start the test program, which will connect to memview and tell it about a bunch of memory allocations it's making. You'll be able to browse the timeline and examine memory allocations.
```sh
git clone --recurse-submodules https://github.com/rdunnington/memview.git
cd memview
zig build
./zig-out/bin/test_host_zig &
./zig-out/bin/memview &
```

## Embedding in other applications
Memview was designed for use in non-zig programs. For this reason, an embeddable static library and C header for interop are provided in `zig-out/lib` and `zig-out/include`. However, due to bugs in the Zig compiler, this integration has problems:
* Windows: callstack symbols in non-zig modules are unable to be resolved
* Linux: memview_init() crashes on startup due to TLS info not being initialized in non-default _start scenarios

However, an example of this integration has been done with DOOM and is located at https://github.com/rdunnington/doomgeneric-memview in the `memview` branch.
