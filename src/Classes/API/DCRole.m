#import "DCRole.h"

@implementation DCRole

- (NSString *)description {
    return [NSString
        stringWithFormat:@"[Role] Snowflake: %@, Name: %@, Color: %ld, Hoist: %d, Unicode Emoji: %@, Position: %ld, Permissions: %@, Managed: %d, Mentionable: %d, Flags: %ld",
                         self.snowflake,
                         self.name,
                         (long)self.color,
                         self.hoist,
                         self.unicodeEmoji,
                         (long)self.position,
                         self.permissions,
                         self.managed,
                         self.mentionable,
                         (long)self.flags];
}

#pragma mark - NSCoding

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:self.snowflake forKey:@"snowflake"];
    [aCoder encodeObject:self.name forKey:@"name"];
    [aCoder encodeInteger:self.color forKey:@"color"];
    [aCoder encodeBool:self.hoist forKey:@"hoist"];
    [aCoder encodeObject:self.iconID forKey:@"iconID"];
    [aCoder encodeObject:self.unicodeEmoji forKey:@"unicodeEmoji"];
    [aCoder encodeInteger:self.position forKey:@"position"];
    [aCoder encodeObject:self.permissions forKey:@"permissions"];
    [aCoder encodeBool:self.managed forKey:@"managed"];
    [aCoder encodeBool:self.mentionable forKey:@"mentionable"];
    [aCoder encodeInteger:self.flags forKey:@"flags"];
    // UIImage icon is runtime state and is deliberately not archived.
}

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [super init];
    if (self) {
        self.snowflake = [aDecoder decodeObjectForKey:@"snowflake"];
        self.name = [aDecoder decodeObjectForKey:@"name"];
        self.color = [aDecoder decodeIntegerForKey:@"color"];
        self.hoist = [aDecoder decodeBoolForKey:@"hoist"];
        self.iconID = [aDecoder decodeObjectForKey:@"iconID"];
        self.unicodeEmoji = [aDecoder decodeObjectForKey:@"unicodeEmoji"];
        self.position = [aDecoder decodeIntegerForKey:@"position"];
        self.permissions = [aDecoder decodeObjectForKey:@"permissions"];
        self.managed = [aDecoder decodeBoolForKey:@"managed"];
        self.mentionable = [aDecoder decodeBoolForKey:@"mentionable"];
        self.flags = [aDecoder decodeIntegerForKey:@"flags"];
    }
    return self;
}
@end
