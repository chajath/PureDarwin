/*
 * pd_init.c — Minimal PID 1 init for PureDarwin
 *
 * Replaces launchd. Pure POSIX — no XPC, no Mach-specific IPC.
 * Designed to:
 *   1. Mount essential filesystems (/dev, devfs)
 *   2. Run /etc/rc boot scripts
 *   3. Spawn getty on console
 *   4. Reap orphaned children
 *   5. Handle shutdown signals
 *
 * Based on BSD init(8) / sinit design principles.
 */

#include <sys/types.h>
#include <sys/wait.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/reboot.h>

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <paths.h>
#include <sys/ioctl.h>
#include <sys/ttycom.h>

#define GETTY_PATH      "/usr/libexec/getty"
#define SHELL_PATH      "/bin/sh"
#define RC_SCRIPT       "/etc/rc"
#define CONSOLE_DEV     "/dev/console"
#define TTY_DEV         _PATH_CONSOLE

static volatile sig_atomic_t got_sigchld = 0;
static volatile sig_atomic_t got_sigterm = 0;
static volatile sig_atomic_t got_sighup  = 0;

static pid_t shell_pid = -1;

static void
sig_handler(int sig)
{
	switch (sig) {
	case SIGCHLD:
		got_sigchld = 1;
		break;
	case SIGTERM:
	case SIGINT:
		got_sigterm = 1;
		break;
	case SIGHUP:
		got_sighup = 1;
		break;
	}
}

static void
setup_signals(void)
{
	struct sigaction sa;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = sig_handler;
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = SA_RESTART;

	sigaction(SIGCHLD, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT,  &sa, NULL);
	sigaction(SIGHUP,  &sa, NULL);

	/* Ignore signals that could stop init */
	sa.sa_handler = SIG_IGN;
	sigaction(SIGTSTP, &sa, NULL);
	sigaction(SIGTTIN, &sa, NULL);
	sigaction(SIGTTOU, &sa, NULL);
}

static void
setup_console(void)
{
	int fd;

	/* Detach from any controlling terminal */
	(void)revoke(CONSOLE_DEV);

	fd = open(CONSOLE_DEV, O_RDWR);
	if (fd < 0) {
		/* Fallback: try /dev/tty */
		fd = open("/dev/tty", O_RDWR);
	}
	if (fd >= 0) {
		(void)dup2(fd, STDIN_FILENO);
		(void)dup2(fd, STDOUT_FILENO);
		(void)dup2(fd, STDERR_FILENO);
		if (fd > STDERR_FILENO)
			(void)close(fd);
	}

	(void)ioctl(STDIN_FILENO, TIOCSCTTY, NULL);
}

/*
 * Mount essential filesystems.
 * On Darwin, devfs is the primary one we need early.
 */
static void
mount_filesystems(void)
{
	struct stat st;

	/* Create /dev if it doesn't exist */
	if (stat("/dev", &st) != 0)
		(void)mkdir("/dev", 0755);

	/* Mount devfs on /dev */
	if (mount("devfs", "/dev", MNT_NOEXEC | MNT_NOSUID, NULL) != 0) {
		if (errno != EBUSY) /* already mounted is ok */
			fprintf(stderr, "pd_init: mount devfs: %s\n", strerror(errno));
	}

	/* Create /tmp if needed */
	if (stat("/tmp", &st) != 0)
		(void)mkdir("/tmp", 01777);
}

/*
 * Run /etc/rc boot script (single-user or multi-user).
 * Waits for it to complete before proceeding.
 */
static int
run_rc_script(void)
{
	pid_t pid;
	int status;

	if (access(RC_SCRIPT, X_OK) != 0) {
		fprintf(stderr, "pd_init: %s not found or not executable, skipping\n",
		    RC_SCRIPT);
		return 0;
	}

	pid = fork();
	if (pid < 0) {
		fprintf(stderr, "pd_init: fork: %s\n", strerror(errno));
		return -1;
	}

	if (pid == 0) {
		/* Child: exec the rc script */
		execl(SHELL_PATH, "sh", RC_SCRIPT, (char *)NULL);
		fprintf(stderr, "pd_init: exec %s: %s\n", RC_SCRIPT, strerror(errno));
		_exit(127);
	}

	/* Parent: wait for rc to finish */
	while (waitpid(pid, &status, 0) == -1) {
		if (errno != EINTR)
			break;
	}

	if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
		fprintf(stderr, "pd_init: %s exited with status %d\n",
		    RC_SCRIPT, WEXITSTATUS(status));
	}

	return 0;
}

/*
 * Spawn a login shell on the console.
 * If getty is available, use it; otherwise fall back to a bare shell.
 */
static pid_t
spawn_shell(void)
{
	pid_t pid;

	pid = fork();
	if (pid < 0) {
		fprintf(stderr, "pd_init: fork: %s\n", strerror(errno));
		return -1;
	}

	if (pid == 0) {
		/* Child: new session */
		(void)setsid();
		setup_console();

		/* Set minimal environment */
		setenv("HOME", "/root", 1);
		setenv("PATH", "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", 1);
		setenv("TERM", "vt100", 1);
		setenv("SHELL", SHELL_PATH, 1);
		setenv("USER", "root", 1);
		setenv("LOGNAME", "root", 1);

		/* Try getty first, then fall back to shell */
		if (access(GETTY_PATH, X_OK) == 0) {
			execl(GETTY_PATH, "getty", "console", "vt100", (char *)NULL);
		}

		/* Fallback: direct shell */
		fprintf(stderr, "\npd_init: starting shell on console\n");
		execl(SHELL_PATH, "-sh", (char *)NULL);

		fprintf(stderr, "pd_init: exec %s: %s\n", SHELL_PATH, strerror(errno));
		_exit(127);
	}

	return pid;
}

/*
 * Reap all zombie children.
 */
static void
reap_children(void)
{
	int status;
	pid_t pid;

	while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
		if (pid == shell_pid) {
			/* Console shell died — respawn it */
			shell_pid = -1;
		}
	}
}

/*
 * Shutdown: kill all processes, sync, reboot/halt.
 */
static void
do_shutdown(int how)
{
	pid_t pid;

	fprintf(stderr, "pd_init: shutting down...\n");

	/* Send SIGTERM to all processes */
	kill(-1, SIGTERM);
	sleep(2);

	/* Send SIGKILL to stragglers */
	kill(-1, SIGKILL);

	/* Reap everything */
	while ((pid = waitpid(-1, NULL, WNOHANG)) > 0)
		;

	sync();

	reboot(how);

	/* If reboot fails, halt */
	fprintf(stderr, "pd_init: reboot failed: %s\n", strerror(errno));
	for (;;)
		sleep(3600);
}

int
main(int argc __attribute__((unused)), char *argv[] __attribute__((unused)))
{
	/* Verify we are PID 1 */
	if (getpid() != 1) {
		fprintf(stderr, "pd_init: must be run as PID 1\n");
		return 1;
	}

	fprintf(stderr, "\npd_init: PureDarwin init starting\n");

	setup_signals();
	mount_filesystems();
	setup_console();

	fprintf(stderr, "pd_init: running boot scripts\n");
	run_rc_script();

	fprintf(stderr, "pd_init: spawning console shell\n");
	shell_pid = spawn_shell();

	/* Main loop: reap children, respawn shell, handle signals */
	for (;;) {
		sigset_t mask;

		sigemptyset(&mask);
		sigsuspend(&mask);   /* wait for any signal */

		if (got_sigchld) {
			got_sigchld = 0;
			reap_children();

			/* Respawn shell if it died */
			if (shell_pid == -1) {
				sleep(1);  /* brief delay to avoid spin */
				shell_pid = spawn_shell();
			}
		}

		if (got_sigterm) {
			got_sigterm = 0;
			do_shutdown(RB_AUTOBOOT);
			/* NOTREACHED */
		}

		if (got_sighup) {
			got_sighup = 0;
			/* Re-read configuration / respawn */
			if (shell_pid > 0) {
				kill(shell_pid, SIGHUP);
			}
		}
	}

	/* NOTREACHED */
	return 0;
}
