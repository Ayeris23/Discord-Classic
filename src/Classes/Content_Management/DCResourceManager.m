//
//  DCResourceManager.m
//  Discord Classic
//

#import "DCResourceManager.h"

#include <mach/mach.h>
#include <sys/sysctl.h>

static const uint64_t DCMegabyte = 1024ULL * 1024ULL;

static NSUInteger DCMB(NSUInteger megabytes) {
    return megabytes * 1024U * 1024U;
}

@implementation DCResourceManager {
    uint64_t _physicalMemoryBytes;
    DCDeviceMemoryClass _memoryClass;
    NSUInteger _memoryWarningCount;
}

+ (instancetype)sharedManager {
    static DCResourceManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[DCResourceManager alloc] init];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _physicalMemoryBytes = [self dc_detectPhysicalMemoryBytes];
    _memoryClass = [self dc_memoryClassForPhysicalBytes:_physicalMemoryBytes];
    _memoryWarningCount = 0;
    return self;
}

- (uint64_t)physicalMemoryBytes {
    return _physicalMemoryBytes;
}

- (DCDeviceMemoryClass)memoryClass {
    return _memoryClass;
}

- (uint64_t)dc_detectPhysicalMemoryBytes {
    uint64_t bytes = 0;
    size_t size = sizeof(bytes);

    /* hw.memsize is the preferred 64-bit value and exists on the old Darwin
     * kernels used by iOS 5/6. */
    if (sysctlbyname("hw.memsize", &bytes, &size, NULL, 0) == 0 && bytes > 0) {
        return bytes;
    }

    /* Conservative old-kernel fallback.  All devices Discord Classic targets
     * through iOS 6 fit in 32 bits of physical RAM. */
    int mib[2] = { CTL_HW, HW_PHYSMEM };
    uint32_t bytes32 = 0;
    size = sizeof(bytes32);
    if (sysctl(mib, 2, &bytes32, &size, NULL, 0) == 0 && bytes32 > 0) {
        return (uint64_t)bytes32;
    }

    /* Unknown hardware should get the conservative profile, not unlimited
     * caches. */
    return 256ULL * DCMegabyte;
}

- (DCDeviceMemoryClass)dc_memoryClassForPhysicalBytes:(uint64_t)bytes {
    uint64_t megabytes = bytes / DCMegabyte;

    /* Use broad bins so small reporting differences/reserved regions do not
     * move nominal 256/512/1024 MB devices into the wrong class. */
    if (megabytes <= 384) return DCDeviceMemoryClass256MB;
    if (megabytes <= 768) return DCDeviceMemoryClass512MB;
    if (megabytes <= 1536) return DCDeviceMemoryClass1GB;
    return DCDeviceMemoryClass2GBPlus;
}

- (NSUInteger)imageMemoryCacheBudget {
    switch (self.memoryClass) {
        case DCDeviceMemoryClass256MB: return DCMB(8);
        case DCDeviceMemoryClass512MB: return DCMB(16);
        case DCDeviceMemoryClass1GB: return DCMB(32);
        case DCDeviceMemoryClass2GBPlus: return DCMB(48);
        case DCDeviceMemoryClassUnknown:
        default: return DCMB(8);
    }
}

- (NSUInteger)imageMemoryCacheCountLimit {
    /* Byte cost is authoritative; count is only a guard against thousands of
     * tiny decoded objects. */
    switch (self.memoryClass) {
        case DCDeviceMemoryClass256MB: return 24;
        case DCDeviceMemoryClass512MB: return 48;
        case DCDeviceMemoryClass1GB: return 96;
        case DCDeviceMemoryClass2GBPlus: return 128;
        case DCDeviceMemoryClassUnknown:
        default: return 24;
    }
}

- (NSUInteger)chatThumbnailMemoryBudget {
    // Reserve part of the decoded-image budget for avatars, guild icons and chrome.
    switch (self.memoryClass) {
        case DCDeviceMemoryClass256MB: return DCMB(6);
        case DCDeviceMemoryClass512MB: return DCMB(12);
        case DCDeviceMemoryClass1GB: return DCMB(24);
        case DCDeviceMemoryClass2GBPlus: return DCMB(32);
        case DCDeviceMemoryClassUnknown:
        default: return DCMB(6);
    }
}

- (NSUInteger)URLMemoryCacheBudget {
    /* NSURLCache holds response data, not decoded UIKit pixels.  It still needs
     * to shrink on 256 MB hardware so it does not compete with the live graph. */
    switch (self.memoryClass) {
        case DCDeviceMemoryClass256MB: return DCMB(2);
        case DCDeviceMemoryClass512MB: return DCMB(4);
        case DCDeviceMemoryClass1GB: return DCMB(8);
        case DCDeviceMemoryClass2GBPlus: return DCMB(16);
        case DCDeviceMemoryClassUnknown:
        default: return DCMB(2);
    }
}

- (NSInteger)chatMessageSoftLimit {
    // Message limits are based on memory class rather than device model.
    return (self.memoryClass == DCDeviceMemoryClass256MB) ? 48 : 80;
}

- (NSInteger)chatMessageHardLimit {
    return (self.memoryClass == DCDeviceMemoryClass256MB) ? 60 : 128;
}

- (NSInteger)chatMessageTrimBatch {
    return (self.memoryClass == DCDeviceMemoryClass256MB) ? 6 : 12;
}

- (uint64_t)currentResidentMemoryBytes {
    task_basic_info_data_t info;
    mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(),
                                     TASK_BASIC_INFO,
                                     (task_info_t)&info,
                                     &count);
    if (result != KERN_SUCCESS) return 0;
    return (uint64_t)info.resident_size;
}

- (uint64_t)systemReclaimableMemoryEstimateBytes {
    mach_port_t host = mach_host_self();
    vm_size_t pageSize = 0;
    if (host_page_size(host, &pageSize) != KERN_SUCCESS || pageSize == 0) {
        mach_port_deallocate(mach_task_self(), host);
        return 0;
    }

    vm_statistics_data_t stats;
    mach_msg_type_number_t count = HOST_VM_INFO_COUNT;
    kern_return_t result = host_statistics(host,
                                           HOST_VM_INFO,
                                           (host_info_t)&stats,
                                           &count);
    mach_port_deallocate(mach_task_self(), host);
    if (result != KERN_SUCCESS) return 0;

    /* "free + inactive" is only an estimate of memory the system may reclaim;
     * it is intentionally not exposed as a process/jetsam allowance. */
    uint64_t pages = (uint64_t)stats.free_count + (uint64_t)stats.inactive_count;
    return pages * (uint64_t)pageSize;
}

- (NSString *)dc_memoryClassName {
    switch (self.memoryClass) {
        case DCDeviceMemoryClass256MB: return @"256MB";
        case DCDeviceMemoryClass512MB: return @"512MB";
        case DCDeviceMemoryClass1GB: return @"1GB";
        case DCDeviceMemoryClass2GBPlus: return @"2GB+";
        case DCDeviceMemoryClassUnknown:
        default: return @"unknown";
    }
}

- (void)logResourceProfileWithReason:(NSString *)reason {
    uint64_t resident = [self currentResidentMemoryBytes];
    uint64_t reclaimable = [self systemReclaimableMemoryEstimateBytes];

    NSLog(@"[ResourcePolicy] %@ class %@ physical %.0fMB resident %.1fMB "
          @"systemReclaimable~%.1fMB imageCache %.1fMB/%lu chatThumb %.1fMB "
          @"urlCache %.1fMB chatWindow %ld/%ld trim %ld warnings %lu",
          reason ?: @"profile",
          [self dc_memoryClassName],
          (double)self.physicalMemoryBytes / (double)DCMegabyte,
          (double)resident / (double)DCMegabyte,
          (double)reclaimable / (double)DCMegabyte,
          (double)self.imageMemoryCacheBudget / (double)DCMegabyte,
          (unsigned long)self.imageMemoryCacheCountLimit,
          (double)self.chatThumbnailMemoryBudget / (double)DCMegabyte,
          (double)self.URLMemoryCacheBudget / (double)DCMegabyte,
          (long)self.chatMessageSoftLimit,
          (long)self.chatMessageHardLimit,
          (long)self.chatMessageTrimBatch,
          (unsigned long)_memoryWarningCount);
}

- (void)noteMemoryWarning {
    _memoryWarningCount++;
    [self logResourceProfileWithReason:@"memory warning"];
}

@end
