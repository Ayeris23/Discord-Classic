//
//  DCChannel.m
//  Discord Classic
//
//  Created by bag.xml on 3/12/18.
//  Copyright (c) 2018 bag.xml. All rights reserved.
//

#import "DCChannel.h"
#include <objc/NSObjCRuntime.h>
#include <CoreFoundation/CFBase.h>
#include <Foundation/Foundation.h>
#include "DCChatViewController.h"
#include "DCMessage.h"
#import "DCServerCommunicator.h"
#import "DCTools.h"
#import "NSString+Emojize.h"

@interface DCAttachmentUploadConnection : NSObject <NSURLConnectionDataDelegate>
@property (nonatomic, strong) NSURLConnection *connection;
@property (nonatomic, strong) NSHTTPURLResponse *response;
@property (nonatomic, strong) NSMutableData *responseData;
@property (nonatomic, strong) NSURL *bodyFileURL;
@property (nonatomic, copy) DCAttachmentUploadProgressBlock progressBlock;
@property (nonatomic, copy) DCAttachmentUploadCompletionBlock completionBlock;
- (id)initWithRequest:(NSURLRequest *)request
           bodyFileURL:(NSURL *)bodyFileURL
             progress:(DCAttachmentUploadProgressBlock)progress
           completion:(DCAttachmentUploadCompletionBlock)completion;
- (void)start;
@end

static NSMutableSet *DCActiveAttachmentUploads(void) {
    static NSMutableSet *uploads = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uploads = [NSMutableSet set];
    });
    return uploads;
}

@implementation DCAttachmentUploadConnection

- (id)initWithRequest:(NSURLRequest *)request
           bodyFileURL:(NSURL *)bodyFileURL
             progress:(DCAttachmentUploadProgressBlock)progress
           completion:(DCAttachmentUploadCompletionBlock)completion {
    self = [super init];
    if (!self) return nil;

    _responseData = [NSMutableData data];
    _bodyFileURL = [bodyFileURL copy];
    _progressBlock = [progress copy];
    _completionBlock = [completion copy];
    _connection = [[NSURLConnection alloc] initWithRequest:request
                                                   delegate:self
                                           startImmediately:NO];
    return self;
}

- (void)start {
    NSAssert([NSThread isMainThread], @"Attachment uploads must start on the main thread");
    if (!self.connection) {
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain
                                             code:NSURLErrorUnknown
                                         userInfo:nil];
        if (self.completionBlock) self.completionBlock(nil, error);
        return;
    }

    [DCActiveAttachmentUploads() addObject:self];
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    [self.connection start];
}

- (NSInputStream *)connection:(NSURLConnection *)connection
                 needNewBodyStream:(NSURLRequest *)request {
    if (!self.bodyFileURL.path.length) return nil;
    return [NSInputStream inputStreamWithFileAtPath:self.bodyFileURL.path];
}

- (void)connection:(NSURLConnection *)connection
   didSendBodyData:(NSInteger)bytesWritten
 totalBytesWritten:(NSInteger)totalBytesWritten
totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite {
    if (!self.progressBlock || totalBytesExpectedToWrite <= 0) return;
    CGFloat progress = (CGFloat)totalBytesWritten / (CGFloat)totalBytesExpectedToWrite;
    self.progressBlock(MIN(1.0f, MAX(0.0f, progress)));
}

- (void)connection:(NSURLConnection *)connection
 didReceiveResponse:(NSURLResponse *)response {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        self.response = (NSHTTPURLResponse *)response;
    }
    [self.responseData setLength:0];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    if (data.length) [self.responseData appendData:data];
}

- (void)dc_finishWithMessageSnowflake:(NSString *)messageSnowflake
                                error:(NSError *)error {
    DCAttachmentUploadCompletionBlock completion = self.completionBlock;
    self.progressBlock = nil;
    self.completionBlock = nil;
    self.connection = nil;
    self.bodyFileURL = nil;

    [DCActiveAttachmentUploads() removeObject:self];
    [UIApplication sharedApplication].networkActivityIndicatorVisible =
        DCActiveAttachmentUploads().count > 0;

    if (completion) completion(messageSnowflake, error);
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    NSInteger statusCode = self.response.statusCode;
    if (statusCode < 200 || statusCode >= 300) {
        NSError *error = [NSError errorWithDomain:@"DiscordClassicAttachmentUpload"
                                             code:statusCode ?: NSURLErrorBadServerResponse
                                         userInfo:nil];
        [self dc_finishWithMessageSnowflake:nil error:error];
        return;
    }

    NSString *messageSnowflake = nil;
    if (self.responseData.length) {
        id responseObject =
            [NSJSONSerialization JSONObjectWithData:self.responseData options:0 error:nil];
        if ([responseObject isKindOfClass:[NSDictionary class]]) {
            id value = [(NSDictionary *)responseObject objectForKey:@"id"];
            if ([value isKindOfClass:[NSString class]]) {
                messageSnowflake = value;
            }
        }
    }

    if (self.progressBlock) self.progressBlock(1.0f);
    [self dc_finishWithMessageSnowflake:messageSnowflake error:nil];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    [self dc_finishWithMessageSnowflake:nil error:error];
}

@end

@interface DCChannel ()

@property NSURLConnection *connection;

@end

@implementation DCChannel
@synthesize users;

static dispatch_queue_t channel_event_queue;
- (dispatch_queue_t)get_channel_event_queue {
    if (channel_event_queue == nil) {
        channel_event_queue = dispatch_queue_create(
            [@"Discord::API::Channel::Event" UTF8String],
            DISPATCH_QUEUE_CONCURRENT
        );
    }
    return channel_event_queue;
}

static UIImage *DCNormalizedUploadImage(UIImage *image) {
    if (!image || image.imageOrientation == UIImageOrientationUp) {
        return image;
    }

    UIGraphicsBeginImageContextWithOptions(image.size, NO, image.scale);
    [image drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
    UIImage *normalized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return normalized ?: image;
}

static BOOL DCWriteBytesToStream(NSOutputStream *stream,
                                 const uint8_t *bytes,
                                 NSUInteger length) {
    NSUInteger offset = 0;
    while (offset < length) {
        NSInteger written = [stream write:&bytes[offset] maxLength:length - offset];
        if (written <= 0) return NO;
        offset += (NSUInteger)written;
    }
    return YES;
}

static BOOL DCWriteDataToStream(NSOutputStream *stream, NSData *data) {
    if (!data.length) return YES;
    return DCWriteBytesToStream(stream, data.bytes, data.length);
}

static BOOL DCWriteStringToStream(NSOutputStream *stream, NSString *string) {
    return DCWriteDataToStream(stream, [string dataUsingEncoding:NSUTF8StringEncoding]);
}

static BOOL DCAppendFileToStream(NSOutputStream *output, NSURL *fileURL) {
    NSInputStream *input = [NSInputStream inputStreamWithFileAtPath:fileURL.path];
    if (!input) return NO;

    [input open];
    uint8_t buffer[64 * 1024];
    BOOL success = YES;

    while (YES) {
        NSInteger count = [input read:buffer maxLength:sizeof(buffer)];
        if (count < 0) {
            success = NO;
            break;
        }
        if (count == 0) break;
        if (!DCWriteBytesToStream(output, buffer, (NSUInteger)count)) {
            success = NO;
            break;
        }
    }

    [input close];
    return success;
}

static dispatch_queue_t channel_send_queue;
- (dispatch_queue_t)get_channel_send_queue {
    if (channel_send_queue == nil) {
        channel_send_queue = dispatch_queue_create(
            [@"Discord::API::Channel::Send" UTF8String], DISPATCH_QUEUE_SERIAL
        );
    }
    return channel_send_queue;
}

- (NSString *)description {
    return
        [NSString stringWithFormat:
                      @"[Channel] Snowflake: %@, Type: %li, Read: %d, Name: %@",
                      self.snowflake, (long)self.type, self.unread, self.name];
}

- (void)checkIfRead {
    self.unread = (self.mentionCount > 0) || 
                  (self.lastMessageId && 
                   self.lastMessageId != (id)NSNull.null && 
                   [self.lastMessageId isKindOfClass:[NSString class]] && 
                   ![self.lastMessageId isEqualToString:self.lastReadMessageId]);
    [self.parentGuild checkIfRead];
}

// copied straight from https://stackoverflow.com/a/7935625, thanks!
+ (NSString*)escapeUnicodeString:(NSString*)string {
    // lastly escaped quotes and back slash
    // note that the backslash has to be escaped before the quote
    // otherwise it will end up with an extra backslash
    NSString* escapedString = [string stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escapedString = [escapedString stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];

    // convert to encoded unicode
    // do this by getting the data for the string
    // in UTF16 little endian (for network byte order)
    NSData* data = [escapedString dataUsingEncoding:NSUTF16LittleEndianStringEncoding allowLossyConversion:YES];
    size_t bytesRead = 0;
    const char* bytes = data.bytes;
    NSMutableString* encodedString = [NSMutableString string];

    // loop through the byte array
    // read two bytes at a time, if the bytes
    // are above a certain value they are unicode
    // otherwise the bytes are ASCII characters
    // the %C format will write the character value of bytes
    while (bytesRead < data.length)
    {
        uint16_t code = *((uint16_t*) &bytes[bytesRead]);
        if (code > 0x007E)
        {
            [encodedString appendFormat:@"\\u%04X", code];
        }
        else
        {
            [encodedString appendFormat:@"%C", code];
        }
        bytesRead += sizeof(uint16_t);
    }

    // done
    return encodedString;
}

- (void)sendMessage:(NSString *)message
    referencingMessage:(DCMessage *)referencedMessage
           disablePing:(BOOL)disablePing {
    dispatch_async([self get_channel_send_queue], ^{
        NSMutableURLRequest *urlRequest = [DCServerCommunicator
            requestWithPath:[NSString stringWithFormat:@"/channels/%@/messages", self.snowflake]
                      token:DCServerCommunicator.sharedInstance.token];
        [urlRequest setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];

            NSString *escapedMessage = message;
        CFStringRef transform = CFSTR("Any-Hex/Java");
        NSMutableString *mutableMessage = [escapedMessage mutableCopy];
        CFStringTransform((__bridge CFMutableStringRef)mutableMessage, NULL, transform, NO);
        NSMutableDictionary *dictionary = [@{
            @"content" : mutableMessage
        } mutableCopy];

        if (referencedMessage) {
            [dictionary addEntriesFromDictionary:@{
                @"type" : @(DCMessageTypeReply),
                @"message_reference" : @{
                    @"type" : @(DCMessageReferenceTypeDefault),
                    @"message_id" : referencedMessage.snowflake,
                    @"channel_id" : DCServerCommunicator.sharedInstance.selectedChannel.snowflake,
                    @"fail_if_not_exists" : @YES
                }
            }];
            if (disablePing) {
                [dictionary addEntriesFromDictionary:@{
                    @"allowed_mentions" : @{
                        @"parse" : @[ @"users", @"roles", @"everyone" ],
                        @"replied_user" : @NO
                    }
                }];
            }
        } else {
            [dictionary addEntriesFromDictionary:@{
                @"type" : @(DCMessageTypeDefault)
            }];
        }
        NSError *writeError = nil;
        NSData *jsonData    = [NSJSONSerialization dataWithJSONObject:dictionary options:NSJSONWritingPrettyPrinted error:&writeError];
        if (writeError) {
            DBGLOG(@"Error serializing message to JSON: %@", writeError);
            return;
        }
        NSString *messageString = [[[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] stringByReplacingOccurrencesOfString:@"\\\\u" withString:@"\\u"];
        DBGLOG(@"[DCChannel] Sending message: %@", messageString);

        [urlRequest setHTTPMethod:@"POST"];

        [urlRequest setHTTPBody:[NSData dataWithBytes:[messageString UTF8String]
                                               length:[messageString length]]];

        NSError *error                  = nil;
        NSHTTPURLResponse *responseCode = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
        });
        NSData *responseData = nil;
        NSInteger maxRetries = 3;
        NSInteger attempt = 0;

        while (attempt < maxRetries) {
            responseData = [DCTools checkData:[NSURLConnection sendSynchronousRequest:urlRequest
                                                                   returningResponse:&responseCode
                                                                               error:&error]
                                    withError:error];
            if (responseData && responseCode.statusCode == 200) {
                break;
            }
            attempt++;
            if (attempt < maxRetries) {
                [NSThread sleepForTimeInterval:1.0];
            }
        }

        if (!responseData || responseCode.statusCode != 200) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertView *alert = [[UIAlertView alloc]
                    initWithTitle:@"Failed to Send"
                          message:@"Your message could not be sent. Please check your connection and try again."
                         delegate:nil
                cancelButtonTitle:@"OK"
                otherButtonTitles:nil];
                [alert show];
            });
        }
        dispatch_sync(dispatch_get_main_queue(), ^{
            [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
        });
    });
}

- (void)editMessage:(DCMessage *)message withContent:(NSString *)content {
    dispatch_async([self get_channel_send_queue], ^{

        NSMutableURLRequest *urlRequest = [DCServerCommunicator 
            requestWithPath:[NSString stringWithFormat:@"/channels/%@/messages/%@", 
                self.snowflake, message.snowflake]
                      token:DCServerCommunicator.sharedInstance.token];
        [urlRequest setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
        [urlRequest setHTTPMethod:@"PATCH"];

        NSMutableString *mutableContent = [content mutableCopy];

        NSDictionary *dictionary = @{@"content" : mutableContent};
        NSError *writeError = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dictionary
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:&writeError];
        if (writeError) {
            DBGLOG(@"Error serializing message to JSON: %@", writeError);
            return;
        }
        NSString *messageString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        [urlRequest setHTTPBody:[NSData dataWithBytes:[messageString UTF8String]
                                               length:[messageString length]]];

        NSError *error                  = nil;
        NSHTTPURLResponse *responseCode = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
        });
        NSData *responseData = nil;
        NSInteger maxRetries = 3;
        NSInteger attempt = 0;

        while (attempt < maxRetries) {
            responseData = [DCTools checkData:[NSURLConnection sendSynchronousRequest:urlRequest
                                                                   returningResponse:&responseCode
                                                                               error:&error]
                                    withError:error];
            if (responseData && responseCode.statusCode == 200) {
                break;
            }
            attempt++;
            if (attempt < maxRetries) {
                [NSThread sleepForTimeInterval:1.0];
            }
        }

        if (!responseData || responseCode.statusCode != 200) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertView *alert = [[UIAlertView alloc]
                    initWithTitle:@"Failed to Edit"
                          message:@"Your message could not be edited. Please check your connection and try again."
                         delegate:nil
                cancelButtonTitle:@"OK"
                otherButtonTitles:nil];
                [alert show];
            });
        }
        dispatch_sync(dispatch_get_main_queue(), ^{
            [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
        });
    });
}

- (void)deleteMessage:(DCMessage *)message {
    dispatch_async([self get_channel_send_queue], ^{
        NSMutableURLRequest *urlRequest = [DCServerCommunicator
            requestWithPath:[NSString stringWithFormat:@"/channels/%@/messages/%@",
                self.snowflake, message.snowflake]
                      token:DCServerCommunicator.sharedInstance.token];
        [urlRequest setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
        [urlRequest setHTTPMethod:@"DELETE"];

        dispatch_sync(dispatch_get_main_queue(), ^{
            [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
        });
        __block NSInteger attempt = 0;
        NSInteger maxRetries = 3;

        __block void (^retryBlock)(void) = ^{
            [NSURLConnection
                sendAsynchronousRequest:urlRequest
                                  queue:[NSOperationQueue currentQueue]
                      completionHandler:^(NSURLResponse *response, NSData *data, NSError *connError) {
                          NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                          if ((!connError && httpResponse.statusCode == 204) || attempt >= maxRetries) {
                              dispatch_async(dispatch_get_main_queue(), ^{
                                  [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
                                  if (connError || httpResponse.statusCode != 204) {
                                      UIAlertView *alert = [[UIAlertView alloc]
                                          initWithTitle:@"Failed to Delete"
                                                message:@"Your message could not be deleted. Please check your connection and try again."
                                               delegate:nil
                                      cancelButtonTitle:@"OK"
                                      otherButtonTitles:nil];
                                      [alert show];
                                  }
                              });
                          } else {
                              attempt++;
                              [NSThread sleepForTimeInterval:1.0];
                              retryBlock();
                          }
                      }];
        };
        retryBlock();
    });
}

- (NSMutableURLRequest *)dc_attachmentRequestForChannelID:(NSString *)channelID
                                                      data:(NSData *)data
                                                  mimeType:(NSString *)mimeType
                                                  filename:(NSString *)filename {
    if (!channelID.length || !data.length || !mimeType.length || !filename.length) {
        return nil;
    }

    NSMutableURLRequest *urlRequest = [DCServerCommunicator
        requestWithPath:[NSString stringWithFormat:@"/channels/%@/messages", channelID]
                  token:DCServerCommunicator.sharedInstance.token];
    [urlRequest setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
    [urlRequest setHTTPMethod:@"POST"];

    NSString *boundary = @"---------------------------14737809831466499882746641449";
    NSString *contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary];
    [urlRequest setValue:contentType forHTTPHeaderField:@"Content-Type"];

    NSMutableData *postbody = [NSMutableData data];
    [postbody appendData:[[NSString stringWithFormat:@"\r\n--%@\r\n", boundary]
                             dataUsingEncoding:NSUTF8StringEncoding]];
    [postbody appendData:[[NSString stringWithFormat:
        @"Content-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\n",
        filename] dataUsingEncoding:NSUTF8StringEncoding]];
    [postbody appendData:[[NSString stringWithFormat:@"Content-Type: %@\r\n\r\n", mimeType]
                             dataUsingEncoding:NSUTF8StringEncoding]];
    [postbody appendData:data];
    [postbody appendData:[[NSString stringWithFormat:@"\r\n--%@\r\n", boundary]
                             dataUsingEncoding:NSUTF8StringEncoding]];
    [postbody appendData:[@"Content-Disposition: form-data; name=\"content\"\r\n\r\n "
                             dataUsingEncoding:NSUTF8StringEncoding]];
    [postbody appendData:[[NSString stringWithFormat:@"\r\n--%@--", boundary]
                             dataUsingEncoding:NSUTF8StringEncoding]];
    [urlRequest setHTTPBody:postbody];
    return urlRequest;
}

- (NSMutableURLRequest *)dc_attachmentRequestForChannelID:(NSString *)channelID
                                                 fileURLs:(NSArray *)fileURLs
                                                mimeTypes:(NSArray *)mimeTypes
                                                filenames:(NSArray *)filenames
                                                  content:(NSString *)content
                                       referencingMessage:(DCMessage *)referencedMessage
                                             disablePing:(BOOL)disablePing
                                              bodyFileURL:(NSURL **)bodyFileURL {
    NSUInteger count = fileURLs.count;
    if (!channelID.length || count == 0 || count > 10 ||
        mimeTypes.count != count || filenames.count != count) {
        return nil;
    }

    NSString *boundary = [NSString stringWithFormat:@"DiscordClassic-%@",
                          [[NSProcessInfo processInfo] globallyUniqueString]];
    NSString *bodyFilename = [NSString stringWithFormat:@"discord-upload-%@.multipart",
                              [[NSProcessInfo processInfo] globallyUniqueString]];
    NSString *bodyPath = [NSTemporaryDirectory() stringByAppendingPathComponent:bodyFilename];
    NSOutputStream *output = [NSOutputStream outputStreamToFileAtPath:bodyPath append:NO];
    [output open];

    NSMutableArray *attachments = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        NSString *filename = [filenames objectAtIndex:i];
        if (![filename isKindOfClass:[NSString class]] || !filename.length) {
            [output close];
            [[NSFileManager defaultManager] removeItemAtPath:bodyPath error:nil];
            return nil;
        }
        [attachments addObject:@{ @"id" : @(i), @"filename" : filename }];
    }

    NSMutableDictionary *payload = [@{
        @"content" : content ?: @"",
        @"attachments" : attachments
    } mutableCopy];

    if (referencedMessage.snowflake.length) {
        [payload addEntriesFromDictionary:@{
            @"type" : @(DCMessageTypeReply),
            @"message_reference" : @{
                @"type" : @(DCMessageReferenceTypeDefault),
                @"message_id" : referencedMessage.snowflake,
                @"channel_id" : channelID,
                @"fail_if_not_exists" : @YES
            }
        }];
        if (disablePing) {
            [payload setObject:@{
                @"parse" : @[ @"users", @"roles", @"everyone" ],
                @"replied_user" : @NO
            } forKey:@"allowed_mentions"];
        }
    } else {
        [payload setObject:@(DCMessageTypeDefault) forKey:@"type"];
    }

    NSData *payloadData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    BOOL success = payloadData != nil;

    if (success) {
        success = DCWriteStringToStream(output,
            [NSString stringWithFormat:@"--%@\r\n"
                                       "Content-Disposition: form-data; name=\"payload_json\"\r\n"
                                       "Content-Type: application/json\r\n\r\n",
                                       boundary]);
    }
    if (success) success = DCWriteDataToStream(output, payloadData);
    if (success) success = DCWriteStringToStream(output, @"\r\n");

    for (NSUInteger i = 0; success && i < count; i++) {
        NSURL *fileURL = [fileURLs objectAtIndex:i];
        NSString *mimeType = [mimeTypes objectAtIndex:i];
        NSString *filename = [filenames objectAtIndex:i];
        if (![fileURL isKindOfClass:[NSURL class]] ||
            ![mimeType isKindOfClass:[NSString class]] || !mimeType.length) {
            success = NO;
            break;
        }

        success = DCWriteStringToStream(output,
            [NSString stringWithFormat:@"--%@\r\n"
                                       "Content-Disposition: form-data; name=\"files[%lu]\"; filename=\"%@\"\r\n"
                                       "Content-Type: %@\r\n\r\n",
                                       boundary,
                                       (unsigned long)i,
                                       filename,
                                       mimeType]);
        if (success) success = DCAppendFileToStream(output, fileURL);
        if (success) success = DCWriteStringToStream(output, @"\r\n");
    }

    if (success) {
        success = DCWriteStringToStream(output,
            [NSString stringWithFormat:@"--%@--\r\n", boundary]);
    }
    [output close];

    if (!success) {
        [[NSFileManager defaultManager] removeItemAtPath:bodyPath error:nil];
        return nil;
    }

    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:bodyPath
                                                                                 error:nil];
    unsigned long long bodyLength = [[attributes objectForKey:NSFileSize] unsignedLongLongValue];
    if (bodyLength == 0) {
        [[NSFileManager defaultManager] removeItemAtPath:bodyPath error:nil];
        return nil;
    }

    NSMutableURLRequest *request = [DCServerCommunicator
        requestWithPath:[NSString stringWithFormat:@"/channels/%@/messages", channelID]
                  token:DCServerCommunicator.sharedInstance.token];
    [request setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
    [request setHTTPMethod:@"POST"];
    request.timeoutInterval = 120.0;
    [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
   forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"%llu", bodyLength]
   forHTTPHeaderField:@"Content-Length"];
    [request setHTTPBodyStream:[NSInputStream inputStreamWithFileAtPath:bodyPath]];

    if (bodyFileURL) *bodyFileURL = [NSURL fileURLWithPath:bodyPath];
    return request;
}

- (void)dc_startAttachmentRequest:(NSURLRequest *)request
                       bodyFileURL:(NSURL *)bodyFileURL
                         progress:(DCAttachmentUploadProgressBlock)progress
                       completion:(DCAttachmentUploadCompletionBlock)completion {
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_main_queue(), ^{
        DCAttachmentUploadCompletionBlock finishedBlock =
            ^(NSString *messageSnowflake, NSError *error) {
                if (completion) completion(messageSnowflake, error);
                dispatch_semaphore_signal(finished);
            };

        if (!request) {
            NSError *error = [NSError errorWithDomain:@"DiscordClassicAttachmentUpload"
                                                 code:NSURLErrorUnknown
                                             userInfo:nil];
            finishedBlock(nil, error);
            return;
        }

        DCAttachmentUploadConnection *upload =
            [[DCAttachmentUploadConnection alloc] initWithRequest:request
                                                      bodyFileURL:bodyFileURL
                                                         progress:progress
                                                       completion:finishedBlock];
        [upload start];
    });

    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
#if !OS_OBJECT_USE_OBJC
    dispatch_release(finished);
#endif
}

- (void)sendImage:(UIImage *)image mimeType:(NSString *)type {
    [self sendImage:image mimeType:type progress:nil completion:nil];
}

- (void)sendImage:(UIImage *)image
         mimeType:(NSString *)type
         progress:(DCAttachmentUploadProgressBlock)progress
       completion:(DCAttachmentUploadCompletionBlock)completion {
    if (!image) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *error = [NSError errorWithDomain:@"DiscordClassicAttachmentUpload"
                                                     code:NSURLErrorUnknown
                                                 userInfo:nil];
                completion(nil, error);
            });
        }
        return;
    }

    NSString *channelID = [self.snowflake copy];
    __block UIImage *sourceImage = image;
    dispatch_async([self get_channel_send_queue], ^{
        @autoreleasepool {
            UIImage *uploadImage = DCNormalizedUploadImage(sourceImage);
            NSData *imageData = nil;
            NSString *extension = @"jpg";
            NSString *uploadType = @"image/jpeg";

            if ([type isEqualToString:@"image/png"]) {
                imageData = UIImagePNGRepresentation(uploadImage);
                extension = @"png";
                uploadType = @"image/png";
            } else {
                imageData = UIImageJPEGRepresentation(uploadImage, 0.8f);
            }

            NSMutableURLRequest *request =
                [self dc_attachmentRequestForChannelID:channelID
                                                  data:imageData
                                              mimeType:uploadType
                                              filename:[NSString stringWithFormat:@"upload.%@", extension]];
            uploadImage = nil;
            imageData = nil;
            sourceImage = nil;
            [self dc_startAttachmentRequest:request
                                bodyFileURL:nil
                                   progress:progress
                                 completion:completion];
        }
    });
}

- (void)sendData:(NSData *)data mimeType:(NSString *)type {
    [self sendData:data mimeType:type progress:nil completion:nil];
}

- (void)sendData:(NSData *)data
        mimeType:(NSString *)type
        progress:(DCAttachmentUploadProgressBlock)progress
      completion:(DCAttachmentUploadCompletionBlock)completion {
    NSString *channelID = [self.snowflake copy];
    __block NSData *uploadData = [data copy];
    NSString *uploadType = [type copy];

    dispatch_async([self get_channel_send_queue], ^{
        @autoreleasepool {
            NSString *extension = [[uploadType componentsSeparatedByString:@"/"] lastObject];
            if (!extension.length) extension = @"bin";

            NSMutableURLRequest *request =
                [self dc_attachmentRequestForChannelID:channelID
                                                  data:uploadData
                                              mimeType:uploadType
                                              filename:[NSString stringWithFormat:@"upload.%@", extension]];
            uploadData = nil;
            [self dc_startAttachmentRequest:request
                                bodyFileURL:nil
                                   progress:progress
                                 completion:completion];
        }
    });
}

- (void)sendVideo:(NSURL *)videoURL mimeType:(NSString *)type {
    [self sendVideo:videoURL mimeType:type progress:nil completion:nil];
}

- (void)sendVideo:(NSURL *)videoURL
         mimeType:(NSString *)type
         progress:(DCAttachmentUploadProgressBlock)progress
       completion:(DCAttachmentUploadCompletionBlock)completion {
    NSString *channelID = [self.snowflake copy];
    NSURL *uploadURL = [videoURL copy];
    NSString *requestedType = [type copy];

    dispatch_async([self get_channel_send_queue], ^{
        @autoreleasepool {
            NSData *videoData = [NSData dataWithContentsOfURL:uploadURL];
            BOOL isQuickTime =
                [requestedType isEqualToString:@"mov"] ||
                [requestedType isEqualToString:@"video/mov"] ||
                [requestedType isEqualToString:@"video/quicktime"] ||
                [[uploadURL.pathExtension lowercaseString] isEqualToString:@"mov"];

            NSString *filename = isQuickTime ? @"upload.mov" : @"upload.mp4";
            NSString *videoContentType = isQuickTime ? @"video/quicktime" : @"video/mp4";

            NSMutableURLRequest *request =
                [self dc_attachmentRequestForChannelID:channelID
                                                  data:videoData
                                              mimeType:videoContentType
                                              filename:filename];
            videoData = nil;
            [self dc_startAttachmentRequest:request
                                bodyFileURL:nil
                                   progress:progress
                                 completion:completion];
        }
    });
}

- (void)sendTemporaryFileURLs:(NSArray *)fileURLs
           mimeTypes:(NSArray *)mimeTypes
           filenames:(NSArray *)filenames
            progress:(DCAttachmentUploadProgressBlock)progress
          completion:(DCAttachmentUploadCompletionBlock)completion {
    [self sendTemporaryFileURLs:fileURLs
                      mimeTypes:mimeTypes
                      filenames:filenames
                        content:@""
             referencingMessage:nil
                    disablePing:NO
                       progress:progress
                     completion:completion];
}

- (void)sendTemporaryFileURLs:(NSArray *)fileURLs
           mimeTypes:(NSArray *)mimeTypes
           filenames:(NSArray *)filenames
             content:(NSString *)content
  referencingMessage:(DCMessage *)referencedMessage
         disablePing:(BOOL)disablePing
            progress:(DCAttachmentUploadProgressBlock)progress
          completion:(DCAttachmentUploadCompletionBlock)completion {
    if (fileURLs.count == 0 || fileURLs.count > 10 ||
        mimeTypes.count != fileURLs.count || filenames.count != fileURLs.count) {
        for (NSURL *URL in fileURLs) {
            if ([URL isKindOfClass:[NSURL class]]) {
                [[NSFileManager defaultManager] removeItemAtURL:URL error:nil];
            }
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *error = [NSError errorWithDomain:@"DiscordClassicAttachmentUpload"
                                                     code:NSURLErrorBadURL
                                                 userInfo:nil];
                completion(nil, error);
            });
        }
        return;
    }

    NSString *channelID = [self.snowflake copy];
    NSArray *URLs = [fileURLs copy];
    NSArray *types = [mimeTypes copy];
    NSArray *names = [filenames copy];
    NSString *messageContent = [content copy] ?: @"";
    DCMessage *reference = referencedMessage;

    dispatch_async([self get_channel_send_queue], ^{
        @autoreleasepool {
            NSURL *bodyFileURL = nil;
            NSMutableURLRequest *request =
                [self dc_attachmentRequestForChannelID:channelID
                                              fileURLs:URLs
                                             mimeTypes:types
                                             filenames:names
                                               content:messageContent
                                    referencingMessage:reference
                                          disablePing:disablePing
                                           bodyFileURL:&bodyFileURL];
            for (NSURL *URL in URLs) {
                if ([URL isKindOfClass:[NSURL class]]) {
                    [[NSFileManager defaultManager] removeItemAtURL:URL error:nil];
                }
            }
            [self dc_startAttachmentRequest:request
                                bodyFileURL:bodyFileURL
                                   progress:progress
                                 completion:completion];
            if (bodyFileURL) {
                [[NSFileManager defaultManager] removeItemAtURL:bodyFileURL error:nil];
            }
        }
    });
}

- (void)sendTypingIndicator {
    dispatch_async([self get_channel_event_queue], ^{
        NSMutableURLRequest *urlRequest = [DCServerCommunicator
            requestWithPath:[NSString stringWithFormat:@"/channels/%@/typing", self.snowflake]
                      token:DCServerCommunicator.sharedInstance.token];
        [urlRequest setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
        [urlRequest setHTTPMethod:@"POST"];
        NSError *error                  = nil;
        NSHTTPURLResponse *responseCode = nil;

        // YES; [DCTools checkData:[NSURLConnection
        // sendSynchronousRequest:urlRequest
        [NSURLConnection sendSynchronousRequest:urlRequest
                              returningResponse:&responseCode
                                          error:&error];
        /*[UIApplication sharedApplication].networkActivityIndicatorVisible =
         * NO;*/
    });
}

- (void)ackMessage:(NSString *)messageId {
    if (messageId.length == 0) return;

    self.lastReadMessageId = messageId;
    self.mentionCount = 0;
    [self checkIfRead];
    dispatch_async([self get_channel_event_queue], ^{
        NSMutableURLRequest *urlRequest = [DCServerCommunicator
            requestWithPath:[NSString stringWithFormat:@"/channels/%@/messages/%@/ack", 
                self.snowflake, messageId]
                      token:DCServerCommunicator.sharedInstance.token];
        [urlRequest setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
        [urlRequest setHTTPMethod:@"POST"];

        NSMutableData *postbody = NSMutableData.new;
        [postbody appendData:[@"{\"token\":null,\"last_viewed\":3287}"
            dataUsingEncoding:NSUTF8StringEncoding]];
        NSError *error                  = nil;
        NSHTTPURLResponse *responseCode = nil;

        [urlRequest setHTTPBody:postbody];

        // YES; [DCTools checkData:[NSURLConnection
        // sendSynchronousRequest:urlRequest
        [NSURLConnection sendSynchronousRequest:urlRequest
                              returningResponse:&responseCode
                                          error:&error];
        /*[UIApplication sharedApplication].networkActivityIndicatorVisible =
         * NO;*/
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.snowflake.length) {
            [NSNotificationCenter.defaultCenter
                postNotificationName:@"MESSAGE ACK"
                              object:self
                            userInfo:@{ @"channelId" : self.snowflake }];
        }
    });
}

- (NSArray *)getMessages:(int)numberOfMessages
           beforeMessage:(DCMessage *)message {
    NSMutableArray *messages = NSMutableArray.new;
    NSData *response         = nil;
    // Generate URL from args
    NSMutableString *path = [NSMutableString
        stringWithFormat:@"/channels/%@/messages?", self.snowflake];

    if (numberOfMessages) {
        [path appendString:[NSString stringWithFormat:@"limit=%d", numberOfMessages]];
    }
    if (numberOfMessages && message) {
        [path appendString:@"&"];
    }
    if (message) {
        [path appendString:[NSString stringWithFormat:@"before=%@", message.snowflake]];
    }

    NSMutableURLRequest *urlRequest = [DCServerCommunicator
        requestWithPath:path
                  token:DCServerCommunicator.sharedInstance.token];
    [urlRequest setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];

    NSError *error                  = nil;
    NSHTTPURLResponse *responseCode = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    });
    NSData *uncheckedResponse = nil;
    NSInteger maxRetries = 3;
    NSInteger attempt = 0;

    while (attempt < maxRetries && !uncheckedResponse) {
        uncheckedResponse = [NSURLConnection sendSynchronousRequest:urlRequest
                                                  returningResponse:&responseCode
                                                              error:&error];
        if (!uncheckedResponse || responseCode.statusCode != 200) {
            attempt++;
            if (attempt < maxRetries) {
                NSLog(@"[DCChannel] Request failed, retrying (%ld/%ld)...", (long)attempt, (long)maxRetries);
                [NSThread sleepForTimeInterval:1.0];
                uncheckedResponse = nil;
            }
        } else {
            break;
        }
    }

    response = [DCTools checkData:uncheckedResponse withError:error];
    dispatch_sync(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
    });
    if (!response || responseCode == nil || responseCode.statusCode != 200) {
        return nil;
    }

    // JSON decoding is pure Foundation work; keep it off the UI thread.
    CFAbsoluteTime jsonStart = CFAbsoluteTimeGetCurrent();
    NSError *parseError = nil;
    NSArray *parsedResponse =
        [NSJSONSerialization JSONObjectWithData:response
                                        options:0
                                          error:&parseError];

    if (parseError) {
        NSLog(@"Error: %@", parseError);
        return nil;
    }
    if (parsedResponse.count <= 0) {
        return [NSArray array];
    }

    CFAbsoluteTime jsonElapsed = CFAbsoluteTimeGetCurrent() - jsonStart;

    // Model/UI-backed message construction still commits on main, but REST
    // history defers the legacy screen-width height pass. The chat layout
    // builder will perform the same DTCoreText measurement at the exact table
    // width before the rows are inserted.
    CFAbsoluteTime convertStart = CFAbsoluteTimeGetCurrent();
    dispatch_sync(dispatch_get_main_queue(), ^{

        for (NSDictionary *jsonMessage in parsedResponse) {
            @autoreleasepool {
                DCMessage *convertedMessage =
                    [DCTools convertJsonMessage:jsonMessage
                                     deferLegacyLayout:YES
                                               channel:self];
                [messages insertObject:convertedMessage atIndex:0];
            }
        }
    });
    NSLog(@"[ChatPerf] REST older parse %.3fs off-main, convert %.3fs main (%lu msgs)",
          jsonElapsed,
          CFAbsoluteTimeGetCurrent() - convertStart,
          (unsigned long)messages.count);

    if (messages.count > 0) {
        return messages;
    }

    [DCTools alert:@"No messages!"
        withMessage:@"No further messages could be found"];

    return nil;
}

- (NSArray *)getMessages:(int)numberOfMessages
            afterMessage:(DCMessage *)message {
    NSMutableArray *messages = NSMutableArray.new;
    NSData *response         = nil;

    NSMutableString *path = [NSMutableString
        stringWithFormat:@"/channels/%@/messages?", self.snowflake];

    if (numberOfMessages) {
        [path appendString:[NSString stringWithFormat:@"limit=%d", numberOfMessages]];
    }
    if (numberOfMessages && message) {
        [path appendString:@"&"];
    }
    if (message) {
        [path appendString:[NSString stringWithFormat:@"after=%@", message.snowflake]];
    }

    NSMutableURLRequest *urlRequest = [DCServerCommunicator
        requestWithPath:path
                  token:DCServerCommunicator.sharedInstance.token];
    [urlRequest setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];

    NSError *error                  = nil;
    NSHTTPURLResponse *responseCode = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    });

    NSData *uncheckedResponse = nil;
    NSInteger maxRetries      = 3;
    NSInteger attempt         = 0;
    while (attempt < maxRetries && !uncheckedResponse) {
        uncheckedResponse = [NSURLConnection sendSynchronousRequest:urlRequest
                                                  returningResponse:&responseCode
                                                              error:&error];
        if (!uncheckedResponse || responseCode.statusCode != 200) {
            attempt++;
            if (attempt < maxRetries) {
                NSLog(@"[DCChannel] afterMessage request failed, retrying (%ld/%ld)...", (long)attempt, (long)maxRetries);
                [NSThread sleepForTimeInterval:1.0];
                uncheckedResponse = nil;
            }
        } else {
            break;
        }
    }

    response = [DCTools checkData:uncheckedResponse withError:error];
    dispatch_sync(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
    });

    if (!response || responseCode == nil || responseCode.statusCode != 200) {
        return nil;
    }

   // JSON decoding is pure Foundation work; keep it off the UI thread.
   CFAbsoluteTime jsonStart = CFAbsoluteTimeGetCurrent();
   NSError *parseError = nil;
   NSArray *parsedResponse =
       [NSJSONSerialization JSONObjectWithData:response
                                       options:0
                                         error:&parseError];

   if (parseError) {
       NSLog(@"Error: %@", parseError);
       return nil;
   }
   if (parsedResponse.count <= 0) {
       return [NSArray array];
   }

   CFAbsoluteTime jsonElapsed = CFAbsoluteTimeGetCurrent() - jsonStart;

   // Keep model/UI-backed conversion on main, but defer legacy sizing.
   CFAbsoluteTime convertStart = CFAbsoluteTimeGetCurrent();
   dispatch_sync(dispatch_get_main_queue(), ^{

       static NSArray *joinMessages;
       static dispatch_once_t onceToken;
       dispatch_once(&onceToken, ^{
           joinMessages = @[
               @"%@ joined the party.",
               @"%@ is here.",
               @"Welcome, %@. We hope you brought pizza.",
               @"A wild %@ appeared.",
               @"%@ just landed.",
               @"%@ just slid into the server.",
               @"%@ just showed up!",
               @"Welcome %@. Say hi!",
               @"%@ hopped into the server.",
               @"Everyone welcome %@!",
               @"Glad you're here, %@.",
               @"Good to see you, %@.",
               @"Yay you made it, %@!",
           ];
       });

        for (NSDictionary *jsonMessage in parsedResponse) {
            @autoreleasepool {
                DCMessage *convertedMessage =
                    [DCTools convertJsonMessage:jsonMessage
                                     deferLegacyLayout:YES
                                               channel:self];

                NSString *messageType = [jsonMessage objectForKey:@"type"];

                if ([messageType intValue] == DCMessageTypeRecipientAdd) {
                    NSArray *mentions     = [jsonMessage objectForKey:@"mentions"];
                    NSDictionary *mention = mentions.firstObject;
                    // NSString *targetName = [mentions
                            NSString *targetUsername =
                        [mention objectForKey:@"global_name"];
                    if ([targetUsername isKindOfClass:[NSNull class]]) {
                        targetUsername = @"Deleted User";
                    }
                    convertedMessage.content       = [NSString
                        stringWithFormat:@"%@ added %@ to the group conversation.",
                                         [convertedMessage.author displayName],
                                         targetUsername];
                    float contentWidth             = UIScreen.mainScreen.bounds.size.width - 63;
                    CGSize textSize                = [convertedMessage.content
                             sizeWithFont:[UIFont systemFontOfSize:14]
                        constrainedToSize:CGSizeMake(contentWidth, MAXFLOAT)
                            lineBreakMode:NSLineBreakByWordWrapping];
                    convertedMessage.contentHeight = textSize.height + 40;
                } else if ([messageType intValue] == DCMessageTypeRecipientRemove) {
                    convertedMessage.content       = [NSString
                        stringWithFormat:@"%@ left the group conversation.",
                                         [convertedMessage.author displayName]];
                    float contentWidth             = UIScreen.mainScreen.bounds.size.width - 63;
                    CGSize textSize                = [convertedMessage.content
                             sizeWithFont:[UIFont systemFontOfSize:14]
                        constrainedToSize:CGSizeMake(contentWidth, MAXFLOAT)
                            lineBreakMode:NSLineBreakByWordWrapping];
                    convertedMessage.contentHeight = textSize.height + 40;
                } else if ([messageType intValue] == DCMessageTypeChannelNameChange) {
                    convertedMessage.content       = [NSString
                        stringWithFormat:@"%@ changed the group name to %@.",
                                         [convertedMessage.author displayName],
                                         [jsonMessage objectForKey:@"content"]];
                    float contentWidth             = UIScreen.mainScreen.bounds.size.width - 63;
                    CGSize textSize                = [convertedMessage.content
                             sizeWithFont:[UIFont systemFontOfSize:14]
                        constrainedToSize:CGSizeMake(contentWidth, MAXFLOAT)
                            lineBreakMode:NSLineBreakByWordWrapping];
                    convertedMessage.contentHeight = textSize.height + 30;
                } else if ([messageType intValue] == DCMessageTypeChannelIconChange) {
                    convertedMessage.content       = [NSString
                        stringWithFormat:@"%@ changed the group icon.",
                                         [convertedMessage.author displayName]];
                    float contentWidth             = UIScreen.mainScreen.bounds.size.width - 63;
                    CGSize textSize                = [convertedMessage.content
                             sizeWithFont:[UIFont systemFontOfSize:14]
                        constrainedToSize:CGSizeMake(contentWidth, MAXFLOAT)
                            lineBreakMode:NSLineBreakByWordWrapping];
                    convertedMessage.contentHeight = textSize.height + 15;
                } else if ([messageType intValue] == DCMessageTypeChannelPinnedMessage) {
                    convertedMessage.content       = [NSString
                        stringWithFormat:@"%@ pinned a message to this channel.",
                                         [convertedMessage.author displayName]];
                    float contentWidth             = UIScreen.mainScreen.bounds.size.width - 63;
                    CGSize textSize                = [convertedMessage.content
                             sizeWithFont:[UIFont systemFontOfSize:14]
                        constrainedToSize:CGSizeMake(contentWidth, MAXFLOAT)
                            lineBreakMode:NSLineBreakByWordWrapping];
                    convertedMessage.contentHeight = textSize.height + 40;
                } else if ([messageType intValue] == DCMessageTypeUserJoin) {
                    static dispatch_once_t dateFormatOnceToken;
                    static NSDateFormatter *dateFormatter;
                    dispatch_once(&dateFormatOnceToken, ^{
                        dateFormatter = [NSDateFormatter new];
                        dateFormatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSSSS+00':'00";
                        dateFormatter.timeZone     = [NSTimeZone timeZoneWithName:@"GMT"];
                        dateFormatter.locale     = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
                    });
                    NSDate *timestamp = [dateFormatter dateFromString:[jsonMessage objectForKey:@"timestamp"]];
                    uint64_t time = [timestamp timeIntervalSince1970] * 1000; // ms
                    convertedMessage.content       = [NSString
                        stringWithFormat:joinMessages[time % joinMessages.count],
                                         [convertedMessage.author displayName]];
                    float contentWidth             = UIScreen.mainScreen.bounds.size.width - 63;
                    CGSize textSize                = [convertedMessage.content
                             sizeWithFont:[UIFont systemFontOfSize:14]
                        constrainedToSize:CGSizeMake(contentWidth, MAXFLOAT)
                            lineBreakMode:NSLineBreakByWordWrapping];
                    convertedMessage.contentHeight = textSize.height + 20;
                } else if ([messageType intValue] == DCMessageTypeGuildBoost) {
                    convertedMessage.content       = [NSString
                        stringWithFormat:@"%@ just boosted the server!",
                                         [convertedMessage.author displayName]];
                    float contentWidth             = UIScreen.mainScreen.bounds.size.width - 63;
                    CGSize textSize                = [convertedMessage.content
                             sizeWithFont:[UIFont systemFontOfSize:14]
                        constrainedToSize:CGSizeMake(contentWidth, MAXFLOAT)
                            lineBreakMode:NSLineBreakByWordWrapping];
                    convertedMessage.contentHeight = textSize.height + 20;
                } else if ([messageType intValue] == DCMessageTypeThreadCreated) {
                    convertedMessage.content       = [NSString
                        stringWithFormat:@"%@ started a thread: 'placeholder'. See all 'placeholder'.",
                                         [convertedMessage.author displayName]];
                    float contentWidth             = UIScreen.mainScreen.bounds.size.width - 63;
                    CGSize textSize                = [convertedMessage.content
                             sizeWithFont:[UIFont systemFontOfSize:14]
                        constrainedToSize:CGSizeMake(contentWidth, MAXFLOAT)
                            lineBreakMode:NSLineBreakByWordWrapping];
                    convertedMessage.contentHeight = textSize.height + 20;
                }
                [messages insertObject:convertedMessage atIndex:0];
            }
        }
    });
    NSLog(@"[ChatPerf] REST newer parse %.3fs off-main, convert %.3fs main (%lu msgs)",
          jsonElapsed,
          CFAbsoluteTimeGetCurrent() - convertStart,
          (unsigned long)messages.count);

    return messages.count > 0 ? messages : nil;
}

#pragma mark - NSCoding

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:self.snowflake         forKey:@"snowflake"];
    [aCoder encodeObject:self.parentID          forKey:@"parentID"];
    [aCoder encodeObject:self.name              forKey:@"name"];
    [aCoder encodeObject:self.lastMessageId     forKey:@"lastMessageId"];
    [aCoder encodeObject:self.lastReadMessageId forKey:@"lastReadMessageId"];
    [aCoder encodeInteger:self.mentionCount     forKey:@"mentionCount"];
    [aCoder encodeBool:self.muted               forKey:@"muted"];
    [aCoder encodeBool:self.readable            forKey:@"readable"];
    [aCoder encodeBool:self.writeable           forKey:@"writeable"];
    [aCoder encodeObject:self.permissionOverwrites forKey:@"permissionOverwrites"];
    [aCoder encodeInteger:self.type             forKey:@"type"];
    [aCoder encodeInteger:self.position         forKey:@"position"];
    [aCoder encodeObject:self.iconID            forKey:@"iconID"];

    // Persist DM relationships by snowflake, never by archiving DCUser objects.
    // Preserve the durable ID set when present; otherwise derive it from the
    // live canonical recipients before archiving.
    NSMutableArray *recipientIDs = [NSMutableArray array];
    if (self.recipientIDs.count > 0) {
        // Keep the full durable relationship set even if a cold restore could
        // only relink a subset of users from an older/incomplete user cache.
        [recipientIDs addObjectsFromArray:self.recipientIDs];
    } else {
        for (id recipient in self.recipients) {
            if ([recipient respondsToSelector:@selector(snowflake)]) {
                NSString *userID = [recipient snowflake];
                if (userID.length > 0) [recipientIDs addObject:userID];
            }
        }
    }
    [aCoder encodeObject:recipientIDs forKey:@"recipientIDs"];

    // Keep the old display-name field for backwards compatibility with older
    // Discord Classic builds that may read this archive. It is not used for
    // relationship reconstruction because names are not stable identifiers.
    NSMutableArray *recipientNames = [NSMutableArray array];
    for (id recipient in self.recipients) {
        if ([recipient respondsToSelector:@selector(displayName)]) {
            NSString *name = [recipient displayName];
            if (name) [recipientNames addObject:name];
        }
    }
    [aCoder encodeObject:recipientNames forKey:@"recipientNames"];
}

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [super init];
    if (self) {
        self.snowflake         = [aDecoder decodeObjectForKey:@"snowflake"];
        id decodedParentID     = [aDecoder decodeObjectForKey:@"parentID"];
        self.parentID          = [decodedParentID isKindOfClass:[NSString class]] ? decodedParentID : nil;
        self.name              = [aDecoder decodeObjectForKey:@"name"];
        self.lastMessageId     = [aDecoder decodeObjectForKey:@"lastMessageId"];
        self.lastReadMessageId = [aDecoder decodeObjectForKey:@"lastReadMessageId"];
        self.mentionCount      = [aDecoder decodeIntegerForKey:@"mentionCount"];
        self.muted             = [aDecoder decodeBoolForKey:@"muted"];
        self.readable          = [aDecoder containsValueForKey:@"readable"]
            ? [aDecoder decodeBoolForKey:@"readable"] : YES;
        self.writeable         = [aDecoder containsValueForKey:@"writeable"]
            ? [aDecoder decodeBoolForKey:@"writeable"] : YES;
        id decodedOverwrites   = [aDecoder decodeObjectForKey:@"permissionOverwrites"];
        self.permissionOverwrites = [decodedOverwrites isKindOfClass:[NSArray class]]
            ? decodedOverwrites : [NSArray array];
        self.type              = (DCChannelType)[aDecoder decodeIntegerForKey:@"type"];
        self.position          = [aDecoder decodeIntegerForKey:@"position"];
        self.iconID            = [aDecoder decodeObjectForKey:@"iconID"];
        self.recipientIDs      = [aDecoder decodeObjectForKey:@"recipientIDs"];
        self.recipients        = [NSMutableArray array];
        self.users             = [NSArray array];
        // Older archives contain only recipientNames. Those names are left as
        // display fallback in self.name; after one live READY the archive will
        // be rewritten with stable recipientIDs.
    }
    return self;
}

@end
