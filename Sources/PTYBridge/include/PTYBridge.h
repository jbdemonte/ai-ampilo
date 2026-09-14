#pragma once
#include <sys/types.h>
pid_t aiusage_spawn_pty(const char *binary, char *const argv[], char *const envp[], const char *cwd, int *master);
void aiusage_stop_pty(pid_t pid, int master);
