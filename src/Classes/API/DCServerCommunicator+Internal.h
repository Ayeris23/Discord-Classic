#import "DCServerCommunicator.h"
#import <zlib.h>

@interface DCServerCommunicator () {
    z_stream _inflateStream;
}

@property (assign, nonatomic) BOOL inflateStreamReady;
@property (strong, nonatomic) NSMutableData *compressedBuffer;

@property (strong, nonatomic) UIView *notificationView;
@property (assign, nonatomic) BOOL gotHeartbeat;
@property (assign, nonatomic) BOOL heartbeatDefined;
@property (assign, nonatomic) BOOL applicationSuspended;
@property (assign, nonatomic) BOOL reconnectPendingAfterForeground;
@property (assign, nonatomic) NSUInteger reconnectGeneration;
@property (assign, nonatomic) NSTimeInterval heartbeatInterval;

@property (assign, nonatomic) BOOL canIdentify;

@property (assign, nonatomic) NSInteger sequenceNumber;
@property (assign, nonatomic) NSInteger persistedSequenceNumber;
@property (strong, nonatomic) NSString *sessionId;
@property (strong, nonatomic) NSString *resumeGatewayURL;

@property (assign, nonatomic) BOOL isReconnecting;
@property (assign, nonatomic) NSInteger reconnectAttempts;
@property (strong, nonatomic) NSTimer *cooldownTimer;
@property (strong, nonatomic) UIAlertView *alertView;
@property (assign, nonatomic) BOOL oldMode;

- (void)showNonIntrusiveNotificationWithTitle:(NSString *)title;
- (void)dismissNotification;

// Canonical guild/channel mutation helpers used by Gateway replay. Declaring
// these here keeps the old compiler from inferring id-returning selectors when
// one private helper calls another defined later in the implementation file.
- (DCGuild *)guildWithSnowflake:(NSString *)guildID;
- (DCGuild *)privateGuild;
- (DCChannel *)channelInGuild:(DCGuild *)guild withSnowflake:(NSString *)channelID;
- (void)ensureChannel:(DCChannel *)channel
      membershipInGuild:(DCGuild *)guild
          shouldAppear:(BOOL)shouldAppear;
- (void)mergeChannel:(DCChannel *)channel fromData:(NSDictionary *)d guild:(DCGuild *)guild;
- (void)resortChannelsForGuild:(DCGuild *)guild;
- (void)handleUserSettingsProtoUpdateWithData:(NSDictionary *)d;
- (void)handleGuildCreateWithData:(NSDictionary *)d;
- (void)handleGuildUpdateWithData:(NSDictionary *)d;
- (void)handleGuildDeleteWithData:(NSDictionary *)d;
@end