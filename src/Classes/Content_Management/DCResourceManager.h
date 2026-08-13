//
//  DCResourceManager.h
//  Discord Classic
//
//  Central resource policy for old iOS hardware.  Keep device-specific quirks
//  out of cache/media code; consumers ask this object for budgets instead.
//

#import <Foundation/Foundation.h>


typedef NS_ENUM(NSInteger, DCDeviceMemoryClass) {
    DCDeviceMemoryClassUnknown = 0,
    DCDeviceMemoryClass256MB,
    DCDeviceMemoryClass512MB,
    DCDeviceMemoryClass1GB,
    DCDeviceMemoryClass2GBPlus,
};

@interface DCResourceManager : NSObject

+ (instancetype)sharedManager;

@property (nonatomic, readonly) uint64_t physicalMemoryBytes;
@property (nonatomic, readonly) DCDeviceMemoryClass memoryClass;

/* Stable, capacity-derived budgets.  These are deliberately not calculated
 * from momentary "free RAM" because that value is noisy and is not a jetsam
 * allowance. */
@property (nonatomic, readonly) NSUInteger imageMemoryCacheBudget;
@property (nonatomic, readonly) NSUInteger imageMemoryCacheCountLimit;
@property (nonatomic, readonly) NSUInteger chatThumbnailMemoryBudget;
@property (nonatomic, readonly) NSUInteger URLMemoryCacheBudget;

/* Memory-driven chat residency.  CPU/display-specific pagination policy stays
 * separate; this only answers how many complete message models we can keep. */
@property (nonatomic, readonly) NSInteger chatMessageSoftLimit;
@property (nonatomic, readonly) NSInteger chatMessageHardLimit;
@property (nonatomic, readonly) NSInteger chatMessageTrimBatch;

/* Telemetry only.  These values are useful in logs and future adaptive policy,
 * but are not presented as an exact remaining process/jetsam budget. */
- (uint64_t)currentResidentMemoryBytes;
- (uint64_t)systemReclaimableMemoryEstimateBytes;

- (void)logResourceProfileWithReason:(NSString *)reason;
- (void)noteMemoryWarning;

@end
