/*
 * pd_inetd.c — minimal "tcp + pty + bash" daemon for PureDarwin.
 *
 * dropbear-on-the-image refuses to authenticate any user because no
 * Directory Services daemon (opendirectoryd / DirectoryService) is
 * running, so getpwnam("root") returns "nonexistent".  Until we either
 * port a DS daemon or rebuild dropbear without the lookup, this tiny
 * tool exposes a passwordless bash on a chosen TCP port so we can get
 * a real interactive PTY session over the SLIRP hostfwd.
 *
 * Per connection:
 *   posix_openpt → grantpt/unlockpt → fork
 *   child: setsid, open slave, TIOCSCTTY, dup2 to 0/1/2, exec bash -l
 *   parent: bi-directional copy between socket and pty master
 *
 * Usage: pd_inetd <port>
 *
 * Do NOT expose to a real network; there is no authentication.
 * Intended solely for local SLIRP / hostfwd development.
 *
 * Build: clang -o pd_inetd pd_inetd.c
 */

#define _DARWIN_C_SOURCE 1
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/select.h>
#include <sys/ioctl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <termios.h>
#include <util.h>          /* forkpty (Darwin libutil) */
#include <errno.h>

static void handle_client(int sock)
{
    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, NULL);
    if (pid < 0) {
        const char *e = "pd_inetd: forkpty failed\r\n";
        (void)!write(sock, e, strlen(e));
        close(sock);
        return;
    }

    if (pid == 0) {
        /* child: forkpty already wired stdin/stdout/stderr to slave */
        struct winsize ws = { 24, 80, 0, 0 };
        (void)ioctl(0, TIOCSWINSZ, &ws);
        setenv("HOME",    "/var/root", 1);
        setenv("USER",    "root",      1);
        setenv("LOGNAME", "root",      1);
        setenv("SHELL",   "/bin/bash", 1);
        setenv("PATH",    "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/pkg/bin", 1);
        setenv("TERM",    "xterm-256color", 1);
        char *args[] = { (char *)"-bash", NULL };
        execv("/bin/bash", args);
        perror("execv /bin/bash");
        _exit(127);
    }

    /* parent: pump bytes between socket and master pty */
    fcntl(sock,   F_SETFL, O_NONBLOCK);
    fcntl(master, F_SETFL, O_NONBLOCK);
    char buf[4096];
    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(sock,   &rfds);
        FD_SET(master, &rfds);
        int maxfd = sock > master ? sock : master;
        int n = select(maxfd + 1, &rfds, NULL, NULL, NULL);
        if (n < 0) { if (errno == EINTR) continue; break; }

        if (FD_ISSET(sock, &rfds)) {
            ssize_t r = read(sock, buf, sizeof(buf));
            if (r <= 0 && errno != EAGAIN) goto done;
            if (r > 0) { ssize_t w = write(master, buf, r); (void)w; }
        }
        if (FD_ISSET(master, &rfds)) {
            ssize_t r = read(master, buf, sizeof(buf));
            if (r <= 0 && errno != EAGAIN) goto done;
            if (r > 0) { ssize_t w = write(sock, buf, r); (void)w; }
        }
    }
done:
    close(master);
    close(sock);
    kill(pid, SIGHUP);
    waitpid(pid, NULL, WNOHANG);
}

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

    signal(SIGCHLD, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);

    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { perror("socket"); return 1; }
    int yes = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr = {0};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port        = htons(port);

    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("bind"); return 1; }
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
            close(s);
            handle_client(c);
            _exit(0);
        }
        close(c);
    }
    return 0;
}
