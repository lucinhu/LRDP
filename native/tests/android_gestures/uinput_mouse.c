/* Private-emulator test device. Kept out of the application and native bridge. */
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

static int event(int fd, unsigned short type, unsigned short code, int value) {
  struct input_event input = {0};
  input.type = type; input.code = code; input.value = value;
  return write(fd, &input, sizeof(input)) == sizeof(input);
}
int main(void) {
  int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
  if (fd < 0) { perror("open uinput"); return 1; }
  if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0 || ioctl(fd, UI_SET_EVBIT, EV_REL) < 0 ||
      ioctl(fd, UI_SET_EVBIT, EV_SYN) < 0 || ioctl(fd, UI_SET_KEYBIT, BTN_LEFT) < 0 ||
      ioctl(fd, UI_SET_KEYBIT, BTN_RIGHT) < 0 || ioctl(fd, UI_SET_KEYBIT, BTN_MIDDLE) < 0 ||
      ioctl(fd, UI_SET_RELBIT, REL_X) < 0 || ioctl(fd, UI_SET_RELBIT, REL_Y) < 0 ||
      ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_POINTER) < 0) {
    perror("configure uinput"); close(fd); return 1;
  }
  struct uinput_setup setup = {0};
  setup.id.bustype = BUS_VIRTUAL; setup.id.vendor = 0x4c52;
  setup.id.product = 0x4450; setup.id.version = 1;
  strcpy(setup.name, "LRDP gesture test mouse");
  if (ioctl(fd, UI_DEV_SETUP, &setup) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
    perror("create uinput mouse"); close(fd); return 1;
  }
  puts("READY"); fflush(stdout);
  char line[128]; int failed = 0;
  while (fgets(line, sizeof(line), stdin)) {
    int dx, dy; char trailing;
    if (sscanf(line, "M %d %d %c", &dx, &dy, &trailing) != 2 ||
        dx < -4096 || dx > 4096 || dy < -4096 || dy > 4096) { failed = 1; break; }
    int distance = abs(dx) > abs(dy) ? abs(dx) : abs(dy);
    int steps = (distance + 3) / 4, previous_x = 0, previous_y = 0;
    for (int step = 1; step <= steps; step++) {
      int x = dx * step / steps, y = dy * step / steps;
      if (!event(fd, EV_REL, REL_X, x - previous_x) || !event(fd, EV_REL, REL_Y, y - previous_y) ||
          !event(fd, EV_SYN, SYN_REPORT, 0)) { failed = 1; break; }
      previous_x = x; previous_y = y;
      struct timespec delay = {0, 20000000};
      while (nanosleep(&delay, &delay) != 0 && errno == EINTR) { }
    }
    if (failed) break;
    puts("OK"); fflush(stdout);
  }
  (void)ioctl(fd, UI_DEV_DESTROY); close(fd);
  return failed ? 1 : 0;
}
