#ifndef AIRASSIST_IOKIT_BRIDGE_H
#define AIRASSIST_IOKIT_BRIDGE_H

#include <CoreFoundation/CoreFoundation.h>

// Private IOHIDEventSystem API — Apple Silicon thermal sensor enumeration.
// CF_RETURNS_RETAINED tells Swift these are +1 retained objects (Create/Copy rule),
// so they bridge to direct types instead of Unmanaged<T>.

extern CFTypeRef  IOHIDEventSystemClientCreate(CFAllocatorRef allocator)                                          CF_RETURNS_RETAINED;
extern void       IOHIDEventSystemClientSetMatchingMultiple(CFTypeRef client, CFArrayRef multiple);
extern CFArrayRef IOHIDEventSystemClientCopyServices(CFTypeRef client)                                            CF_RETURNS_RETAINED;

extern CFTypeRef  IOHIDServiceClientCopyProperty(CFTypeRef service, CFStringRef key)                              CF_RETURNS_RETAINED;
extern CFTypeRef  IOHIDServiceClientCopyEvent(CFTypeRef service, int64_t type, int32_t options, int64_t timeout)  CF_RETURNS_RETAINED;

extern double     IOHIDEventGetFloatValue(CFTypeRef event, int32_t field);
extern uint64_t   IOHIDServiceClientGetRegistryID(CFTypeRef service);

#endif // AIRASSIST_IOKIT_BRIDGE_H
