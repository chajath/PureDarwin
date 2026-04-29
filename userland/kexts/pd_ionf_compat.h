/*
 * PureDarwin compatibility stubs for building IONetworkingFamily
 * against the public macOS 10.13 SDK.
 * These definitions are normally in XNU private headers.
 */

#ifndef _PD_IONF_COMPAT_H_
#define _PD_IONF_COMPAT_H_

/* From bsd/net/if_var.h (private) */
#ifndef IFNET_SUBFAMILY_ANY
#define IFNET_SUBFAMILY_ANY 0
#endif
#ifndef IFNET_SUBFAMILY_USB
#define IFNET_SUBFAMILY_USB 4
#endif
#ifndef IFNET_SUBFAMILY_BLUETOOTH
#define IFNET_SUBFAMILY_BLUETOOTH 5
#endif
#ifndef IFNET_SUBFAMILY_WIFI
#define IFNET_SUBFAMILY_WIFI 6
#endif
#ifndef IFNET_SUBFAMILY_THUNDERBOLT
#define IFNET_SUBFAMILY_THUNDERBOLT 7
#endif
#ifndef IFNET_SUBFAMILY_RESERVED
#define IFNET_SUBFAMILY_RESERVED 8
#endif
#ifndef IFNET_SUBFAMILY_INTCOPROC
#define IFNET_SUBFAMILY_INTCOPROC 9
#endif
#ifndef IFNET_SUBFAMILY_SIMCELL
#define IFNET_SUBFAMILY_SIMCELL 10
#endif

/* From bsd/sys/sockio.h (private) */
#ifndef SIOCSIFDEVMTU
#define SIOCSIFDEVMTU _IOWR('i', 104, struct ifreq)
#endif

/* From osfmk/mach/thread_policy.h (private) */
#ifndef MACHINE_NETWORK_GROUP
#define MACHINE_NETWORK_GROUP 2
#endif
#ifndef MACHINE_GROUP
#define MACHINE_GROUP 1
#endif
#ifndef MACHINE_NETWORK_WORKLOOP
#define MACHINE_NETWORK_WORKLOOP 3
#endif

/* From osfmk/kern/zalloc.h - FailedAllocate is a goto label, not a macro */

/* From AssertMacros.h (private in some configurations) */
#ifndef require
#define require(assertion, exceptionLabel) do { if (!(assertion)) goto exceptionLabel; } while (0)
#endif
#ifndef require_action
#define require_action(assertion, exceptionLabel, action) do { if (!(assertion)) { action; goto exceptionLabel; } } while (0)
#endif

/* From bsd/net/if_var.h link quality metrics (private) */
#ifndef IFNET_LQM_THRESH_GOOD
#define IFNET_LQM_THRESH_GOOD 50
#endif
#ifndef IFNET_LQM_THRESH_POOR
#define IFNET_LQM_THRESH_POOR 20
#endif
#ifndef IFNET_LQM_THRESH_OFF
#define IFNET_LQM_THRESH_OFF (-1)
#endif
#ifndef IFNET_LQM_THRESH_UNKNOWN
#define IFNET_LQM_THRESH_UNKNOWN (-2)
#endif

/* From bsd/net/if_var.h input poll model (private) */
#ifndef IFNET_MODEL_INPUT_POLL_OFF
#define IFNET_MODEL_INPUT_POLL_OFF 0
#endif

/* More bsd/net/if_var.h private symbols */
#ifndef IFNET_CSUM_SUM16
#define IFNET_CSUM_SUM16 0x1000
#endif
#ifndef MBUF_CSUM_TCP_SUM16
#define MBUF_CSUM_TCP_SUM16 0x1000
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Private types */
typedef struct { unsigned long long max_bw; unsigned long long eff_bw; } if_bandwidths_t;

/* Stub functions for private kernel APIs */
static inline int ifnet_set_link_quality(void *ifp, int q) { return 0; }
static inline int ml_thread_policy(void *thread, int group, int flags) { return 0; }
static inline void ifnet_input_extended(void *ifp, void *first, void *last, const void *stats) {}
static inline int ifnet_set_bandwidths(void *ifp, const if_bandwidths_t *output, const if_bandwidths_t *input) { return 0; }

#ifdef __cplusplus
}
#endif

/* From bsd/net/if_var.h (private) */
#ifdef __cplusplus
extern "C" {
#endif

#ifndef ifnet_normalise_unsent_data
static inline void ifnet_normalise_unsent_data(void) {}
#endif

#ifdef __cplusplus
}
#endif

#endif /* _PD_IONF_COMPAT_H_ */
