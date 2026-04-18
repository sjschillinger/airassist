#ifndef AIRASSIST_IOKIT_BRIDGE_H
#define AIRASSIST_IOKIT_BRIDGE_H

#include <CoreFoundation/CoreFoundation.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <signal.h>

// Private IOHIDEventSystem API — Apple Silicon thermal sensor enumeration.
// CF_RETURNS_RETAINED tells Swift these are +1 retained objects (Create/Copy rule),
// so they bridge to direct types instead of Unmanaged<T>.
//
// A handful of these became public in the macOS 15 SDK with typed refs
// (IOHIDEventSystemClientRef, IOHIDServiceClientRef). The test target pulls
// those public headers in transitively, which conflicts with CFTypeRef
// redeclarations here. We guard the three public-in-15 decls with
// __has_include so we only supply them when the SDK doesn't.

extern CFTypeRef  IOHIDEventSystemClientCreate(CFAllocatorRef allocator)                                          CF_RETURNS_RETAINED;
extern void       IOHIDEventSystemClientSetMatchingMultiple(CFTypeRef client, CFArrayRef multiple);
extern CFTypeRef  IOHIDServiceClientCopyEvent(CFTypeRef service, int64_t type, int32_t options, int64_t timeout)  CF_RETURNS_RETAINED;
extern double     IOHIDEventGetFloatValue(CFTypeRef event, int32_t field);

#if !__has_include(<IOKit/hidsystem/IOHIDEventSystemClient.h>)
extern CFArrayRef IOHIDEventSystemClientCopyServices(CFTypeRef client)                                            CF_RETURNS_RETAINED;
#endif

#if !__has_include(<IOKit/hidsystem/IOHIDServiceClient.h>)
extern CFTypeRef  IOHIDServiceClientCopyProperty(CFTypeRef service, CFStringRef key)                              CF_RETURNS_RETAINED;
#endif

// The SDK 15 public header prototypes IOHIDServiceClientGetRegistryID as
// returning CFTypeRef, which is wrong — the real ABI returns uint64_t.
// We declare our own symbol (asm-aliased to the real one) so Swift sees the
// correct return type regardless of which SDK is active.
extern uint64_t AirAssist_IOHIDServiceClientGetRegistryID(CFTypeRef service) __asm("_IOHIDServiceClientGetRegistryID");

#endif // AIRASSIST_IOKIT_BRIDGE_H
