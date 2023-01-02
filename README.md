# dwmstatus
DWM Status Updater written in Zig

## How I build
zig build-exe dwmstatus.zig libx.c -lX11 -lc

zig build-exe mailstatus.zig libmail.c -ltls -I/opt/libressl/include -L/opt/libressl/gnu/lib64 -lc
