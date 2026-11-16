// Minimal newlib hooks: stdio on the AXI UART Lite, heap in cached DDR.
#include <errno.h>
#include <stdint.h>
#include <sys/stat.h>
#include "platform.h"

#ifdef QEMU
#define U8(off) (*(volatile uint8_t *)(UART16550 + (off)))
void uart_putc(char c) { while (!(U8(5) & 0x20)) ; U8(0) = (uint8_t)c; }
int uart_getc(void) { while (!(U8(5) & 0x01)) ; return U8(0); }
#else
#define UART_RX   (*(volatile uint32_t *)(UART_BASE + 0x0))
#define UART_TX   (*(volatile uint32_t *)(UART_BASE + 0x4))
#define UART_STAT (*(volatile uint32_t *)(UART_BASE + 0x8))

void uart_putc(char c) {
    while (UART_STAT & 0x8) ; // TX FIFO full
    UART_TX = (uint8_t)c;
}

int uart_getc(void) {
    while (!(UART_STAT & 0x1)) ; // RX FIFO empty
    return (int)(UART_RX & 0xFF);
}
#endif

int _write(int fd, const char *buf, int len) {
    (void)fd;
    for (int i = 0; i < len; i++) {
        if (buf[i] == '\n') uart_putc('\r');
        uart_putc(buf[i]);
    }
    return len;
}

int _read(int fd, char *buf, int len) {
    (void)fd;
    if (len <= 0) return 0;
    buf[0] = (char)uart_getc();
    return 1;
}

void *_sbrk(int incr) {
    static uintptr_t brk = HEAP_BASE;
    uintptr_t old = brk;
    if (brk + incr > HEAP_END) { errno = ENOMEM; return (void *)-1; }
    brk += incr;
    return (void *)old;
}

int _close(int fd) { (void)fd; return -1; }
int _fstat(int fd, struct stat *st) { (void)fd; st->st_mode = S_IFCHR; return 0; }
int _isatty(int fd) { (void)fd; return 1; }
int _lseek(int fd, int off, int whence) { (void)fd; (void)off; (void)whence; return 0; }
int _open(const char *p, int f, int m) { (void)p; (void)f; (void)m; errno = ENOENT; return -1; }
int _kill(int pid, int sig) { (void)pid; (void)sig; errno = EINVAL; return -1; }
int _getpid(void) { return 1; }
int _gettimeofday(void *tv, void *tz) { (void)tv; (void)tz; return -1; }
void _exit(int code) { (void)code; for (;;) __asm__ volatile("wfi"); }
