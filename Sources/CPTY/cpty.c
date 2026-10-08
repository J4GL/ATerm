#include "cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

/// Cooked mode with UTF-8 aware line editing and the usual control characters.
static void aterm_default_termios(struct termios *t) {
    memset(t, 0, sizeof *t);
    t->c_iflag = ICRNL | IXON | IXANY | IMAXBEL | BRKINT | IUTF8;
    t->c_oflag = OPOST | ONLCR;
    t->c_cflag = CREAD | CS8 | HUPCL;
    t->c_lflag = ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL;
    t->c_cc[VEOF] = 0x04;      /* ^D */
    t->c_cc[VEOL] = _POSIX_VDISABLE;
    t->c_cc[VEOL2] = _POSIX_VDISABLE;
    t->c_cc[VERASE] = 0x7F;    /* DEL */
    t->c_cc[VWERASE] = 0x17;   /* ^W */
    t->c_cc[VKILL] = 0x15;     /* ^U */
    t->c_cc[VREPRINT] = 0x12;  /* ^R */
    t->c_cc[VINTR] = 0x03;     /* ^C */
    t->c_cc[VQUIT] = 0x1C;     /* ^\ */
    t->c_cc[VSUSP] = 0x1A;     /* ^Z */
    t->c_cc[VDSUSP] = 0x19;    /* ^Y */
    t->c_cc[VSTART] = 0x11;    /* ^Q */
    t->c_cc[VSTOP] = 0x13;     /* ^S */
    t->c_cc[VLNEXT] = 0x16;    /* ^V */
    t->c_cc[VDISCARD] = 0x0F;  /* ^O */
    t->c_cc[VSTATUS] = 0x14;   /* ^T */
    t->c_cc[VMIN] = 1;
    t->c_cc[VTIME] = 0;
    cfsetispeed(t, B38400);
    cfsetospeed(t, B38400);
}

pid_t aterm_pty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                     unsigned short cols, unsigned short rows,
                     unsigned short pixel_width, unsigned short pixel_height,
                     int *master_fd) {
    struct winsize size = { .ws_row = rows, .ws_col = cols, .ws_xpixel = pixel_width, .ws_ypixel = pixel_height };
    struct termios settings;
    aterm_default_termios(&settings);

    // Keep signals blocked across fork so the child never runs a parent handler.
    sigset_t all, previous;
    sigfillset(&all);
    pthread_sigmask(SIG_SETMASK, &all, &previous);

    int master = -1;
    pid_t pid = forkpty(&master, NULL, &settings, &size);
    if (pid == 0) {
        // Child: only async-signal-safe calls from here on.
        struct sigaction dfl;
        memset(&dfl, 0, sizeof dfl);
        dfl.sa_handler = SIG_DFL;
        sigemptyset(&dfl.sa_mask);
        for (int sig = 1; sig < NSIG; sig++) {
            sigaction(sig, &dfl, NULL);
        }
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);

        int limit = getdtablesize();
        if (limit > 65536) limit = 65536;
        for (int fd = 3; fd < limit; fd++) {
            close(fd);
        }

        if (cwd != NULL && chdir(cwd) != 0) {
            (void)chdir("/");
        }
        execve(path, argv, envp);

        static const char message[] = "aterm: cannot execute the shell\r\n";
        (void)write(STDERR_FILENO, message, sizeof message - 1);
        _exit(127);
    }

    int saved_errno = errno;
    pthread_sigmask(SIG_SETMASK, &previous, NULL);
    if (pid < 0) {
        errno = saved_errno;
        return -1;
    }
    fcntl(master, F_SETFD, FD_CLOEXEC);
    *master_fd = master;
    return pid;
}

int aterm_pty_set_size(int master_fd, unsigned short cols, unsigned short rows,
                      unsigned short pixel_width, unsigned short pixel_height) {
    struct winsize size = { .ws_row = rows, .ws_col = cols, .ws_xpixel = pixel_width, .ws_ypixel = pixel_height };
    return ioctl(master_fd, TIOCSWINSZ, &size);
}

pid_t aterm_spawn(const char *path, char *const argv[], char *const envp[], int stdin_fd, int output_fd) {
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    int result = posix_spawnattr_init(&attributes);
    if (result != 0) {
        errno = result;
        return -1;
    }
    result = posix_spawn_file_actions_init(&actions);
    if (result != 0) {
        posix_spawnattr_destroy(&attributes);
        errno = result;
        return -1;
    }

    /* The app ignores SIGPIPE; an ignored signal would survive exec. */
    sigset_t defaults, empty;
    sigfillset(&defaults);
    sigdelset(&defaults, SIGKILL);
    sigdelset(&defaults, SIGSTOP);
    sigemptyset(&empty);
    posix_spawnattr_setsigdefault(&attributes, &defaults);
    posix_spawnattr_setsigmask(&attributes, &empty);
    posix_spawnattr_setpgroup(&attributes, 0);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP
                                              | POSIX_SPAWN_CLOEXEC_DEFAULT);
    posix_spawn_file_actions_adddup2(&actions, stdin_fd, STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, output_fd, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, output_fd, STDERR_FILENO);

    pid_t pid = -1;
    result = posix_spawn(&pid, path, &actions, &attributes, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    if (result != 0) {
        errno = result;
        return -1;
    }
    return pid;
}
