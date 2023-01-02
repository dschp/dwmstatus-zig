#include <X11/Xlib.h>

Display *getDisplay(char *display) {
   return XOpenDisplay(display);
}

Window getRootWindow(Display *dpy) {
   return DefaultRootWindow(dpy);
}

void setRootName(Display *dpy, Window win, char *input) {
   XStoreName(dpy, win, input);
   XFlush(dpy);
}

