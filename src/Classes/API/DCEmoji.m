#import "DCEmoji.h"

@implementation DCEmoji

#pragma mark - NSCoding

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:self.name forKey:@"name"];
    [aCoder encodeObject:self.snowflake forKey:@"snowflake"];
    [aCoder encodeBool:self.animated forKey:@"animated"];
    // Emoji images already have their own memory/SDWebImage cache.
}

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [super init];
    if (self) {
        self.name = [aDecoder decodeObjectForKey:@"name"];
        self.snowflake = [aDecoder decodeObjectForKey:@"snowflake"];
        self.animated = [aDecoder decodeBoolForKey:@"animated"];
    }
    return self;
}

@end
