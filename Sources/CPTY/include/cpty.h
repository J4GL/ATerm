#ifndef ATERM_CPTY_H
#define ATERM_CPTY_H

#include <sys/types.h>

/// Forks a child attached to a new pseudo-terminal of the given size, resets its
/// signal handling, closes every descriptor above 2, changes to `cwd` (when not
/// NULL) and executes `path` with `argv` and `envp`.
/// Returns the child pid and stores the master descriptor (close-on-exec) in
/// `*master_fd`, or returns -1 with errno set.
pid_t aterm_pty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                     unsigned short cols, unsigned short rows,
                     unsigned short pixel_width, unsigned short pixel_height,
                     int *master_fd);

/// Sets the window size of the pseudo-terminal behind `master_fd` (the kernel
/// then sends SIGWINCH to its foreground process group). Returns 0 or -1.
int aterm_pty_set_size(int master_fd, unsigned short cols, unsigned short rows,
                      unsigned short pixel_width, unsigned short pixel_height);

/// Starts `path` with `argv` and `envp` in a new process group, with default
/// signal handlers and an empty signal mask, `stdin_fd` as its standard input
/// and `output_fd` as both its standard output and error; no other descriptor
/// is inherited. Returns the pid (also the process group id), or -1 with errno
/// set.
pid_t aterm_spawn(const char *path, char *const argv[], char *const envp[], int stdin_fd, int output_fd);

#endif
