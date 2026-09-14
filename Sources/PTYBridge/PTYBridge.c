#include "PTYBridge.h"
#include <util.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <errno.h>

pid_t aiusage_spawn_pty(const char *binary, char *const argv[], char *const envp[], const char *cwd, int *master) {
    struct winsize size = {.ws_row = 40, .ws_col = 120};
    int descriptor_limit = getdtablesize();
    pid_t pid = forkpty(master, NULL, NULL, &size);
    if (pid == 0) {
        // No Swift/Foundation work, allocation, or locks after fork in a multithreaded app.
        // Inherited pipe ends would keep unrelated CLI requests waiting for EOF.
        for (int fd = 3; fd < descriptor_limit; fd++) close(fd);
        if (chdir(cwd) != 0) _exit(126);
        execve(binary, argv, envp);
        _exit(127);
    }
    if (pid > 0) fcntl(*master, F_SETFL, O_NONBLOCK);
    return pid;
}
void aiusage_stop_pty(pid_t pid, int master) {
    close(master);
    kill(-pid, SIGTERM);
    int status;
    for (int i = 0; i < 150; i++) {
        pid_t result = waitpid(pid, &status, WNOHANG);
        if (result == pid || (result < 0 && errno == ECHILD)) return;
        usleep(20000);
    }
    kill(-pid, SIGKILL);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
}
