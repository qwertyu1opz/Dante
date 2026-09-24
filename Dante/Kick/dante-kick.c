

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define DANTE_BINARY "/Applications/Dante.app/Dante"
#define DANTE_ERRLOG "/tmp/dante_daemon.err"

int main(void) {
    if (setgid(0) != 0 || setuid(0) != 0) {
        fprintf(stderr, "dante-kick: нужен setuid root\n");
        return 1;
    }

    pid_t pid = fork();
    if (pid < 0) return 1;
    if (pid > 0) return 0;          

    setsid();
    if (fork() > 0) _exit(0);       

    chdir("/");
    int devnull = open("/dev/null", O_RDONLY);
    int err = open(DANTE_ERRLOG, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (devnull >= 0) dup2(devnull, STDIN_FILENO);
    if (err >= 0) {
        dup2(err, STDOUT_FILENO);
        dup2(err, STDERR_FILENO);
    }
    setenv("HOME", "/var/root", 1);

    execl(DANTE_BINARY, "Dante", "--daemon", (char *)NULL);
    _exit(127);
}
