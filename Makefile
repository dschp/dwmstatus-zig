include config.mk

all: dwmstatus mailstatus

dwmstatus: dwmstatus.zig lib.zig libx.c
	zig build-exe dwmstatus.zig libx.c -lX11 -lc $(ZIG_OPTS)

mailstatus: mailstatus.zig libmail.zig libmail.c
	zig build-exe mailstatus.zig libmail.c -ltls -I$(LIBRESSL_INC) -L$(LIBRESSL_LIB) -lc $(ZIG_OPTS)

clean:
	rm -f *.o dwmstatus mailstatus
