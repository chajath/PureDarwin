/*
 * pd_inetd.c — minimal "tcp + exec bash" daemon for PureDarwin.
 *
 * dropbear-on-the-image refuses to authenticate any user because no
 * Directory Services daemon (opendirectoryd / DirectoryService) is
 * running, so getpwnam("root") returns "nonexistent".  Until we either
 * port a DS daemon or rebuild dropbear without the lookup, this tiny
 * tool exposes a passwordless bash on a chosen TCP port so we can get
 * a real interactive PTY-like session over the SLIRP hostfwd.
 *
 * Usage: pd_inetd <port>
 *   listens on 0.0.0.0:<port>, accepts one client at a time, forks,
 *   wires the client socket to stdin/stdout/stderr, execs /bin/bash -i.
 *
 * Do NOT expose to a real network; there's no authentication.  Intended
 * solely for local SLIRP / hostfwd development.
 *
 * Build: clang -o pd_inetd pd_inetd.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <port>\n", argv[0]);
        return 2;
    }
    int port = atoi(argv[1]);
    if (port <= 0 || port > 65535) {
        fprintf(stderr, "bad port %s\n", argv[1]);
        return 2;
    }

    /* reap children automatically */
    signal(SIGCHLD, SIG_IGN);

    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { perror("socket"); return 1; }
    int yes = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr = {0};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port        = htons(port);

    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); return 1;
    }
    if (listen(s, 4) < 0) { perror("listen"); return 1; }
    fprintf(stderr, "pd_inetd: listening on 0.0.0.0:%d\n", port);

    for (;;) {
        struct sockaddr_in cli;
        socklen_t cl = sizeof(cli);
        int c = accept(s, (struct sockaddr *)&cli, &cl);
        if (c < 0) {
            if (errno == EINTR) continue;
            perror("accept"); break;
        }
        fprintf(stderr, "pd_inetd: connection from %s:%d\n",
                inet_ntoa(cli.sin_addr), ntohs(cli.sin_port));

        pid_t pid = fork();
        if (pid < 0) { perror("fork"); close(c); continue; }
        if (pid == 0) {
            /* child */
            close(s);
            dup2(c, 0); dup2(c, 1); dup2(c, 2);
            close(c);
            setenv("HOME",  "/var/root", 1);
            setenv("USER",  "root",      1);
            setenv("LOGNAME", "root",    1);
            setenv("PATH",  "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/pkg/bin", 1);
            setenv("TERM",  "xterm-256color", 1);
            char *args[] = { "/bin/bash", "-i", NULL };
            execv("/bin/bash", args);
            perror("execv /bin/bash");
            _exit(127);
        }
        /* parent */
        close(c);
    }
    return 0;
}
