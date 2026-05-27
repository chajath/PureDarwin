/*
 * pd_net_attach.c — minimal stand-in for configd's BSD-attach signal.
 *
 * IONetworkStack will not assign a BSD name (en0, en1, …) to a newly
 * registered IONetworkInterface until something tells it to.  In a
 * normal macOS userland that's configd's job, issued via
 * IORegistryEntrySetCFProperties on the IONetworkStack node with
 * { kIONetworkStackUserCommandKey: kIONetworkStackRegisterInterfaceAll }.
 *
 * PureDarwin's image has no configd, so newly registered network
 * interfaces sit in the "named-but-not-attached" limbo and `ifconfig`
 * never sees them.  Running this tool once tells the stack to attach
 * every pending interface to BSD, after which `ifconfig en0` works.
 *
 * Build: clang -o pd_net_attach pd_net_attach.c -framework IOKit -framework CoreFoundation
 */

#include <stdio.h>
#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

/* Pulled from IONetworking sources (IONetworkStack.h / IONetworkInterface.h) */
#define kIONetworkStackUserCommandKey         "IONetworkStackUserCommand"
#define kIONetworkStackRegisterInterfaceAll   2   /* enum value */

int main(int argc, char **argv)
{
    (void)argc; (void)argv;

    io_service_t stack = IOServiceGetMatchingService(
        kIOMasterPortDefault, IOServiceMatching("IONetworkStack"));
    if (!stack) {
        fprintf(stderr, "pd_net_attach: IONetworkStack not found\n");
        return 1;
    }

    int32_t cmd = kIONetworkStackRegisterInterfaceAll;
    CFNumberRef num = CFNumberCreate(NULL, kCFNumberSInt32Type, &cmd);
    if (!num) { IOObjectRelease(stack); return 2; }

    const void *keys[]   = { CFSTR(kIONetworkStackUserCommandKey) };
    const void *vals[]   = { num };
    CFDictionaryRef props = CFDictionaryCreate(NULL, keys, vals, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    kern_return_t kr = IORegistryEntrySetCFProperties(stack, props);
    CFRelease(props);
    CFRelease(num);
    IOObjectRelease(stack);

    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "pd_net_attach: IORegistryEntrySetCFProperties failed: 0x%x\n", kr);
        return 3;
    }

    printf("pd_net_attach: registerAllNetworkInterfaces requested\n");
    return 0;
}
