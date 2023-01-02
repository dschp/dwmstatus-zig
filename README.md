# dwmstatus
DWM Status Updater written in Zig

## How I build
Tested with zig-linux-x86_64-0.11.0-dev.1026+4172c2916

- zig build-exe dwmstatus.zig libx.c -lX11 -lc
- zig build-exe mailstatus.zig libmail.c -ltls -I/opt/libressl/include -L/opt/libressl/gnu/lib64 -lc
