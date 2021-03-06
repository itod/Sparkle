//
//  SUAppcast.m
//  Sparkle
//
//  Created by Andy Matuschak on 3/12/06.
//  Copyright 2006 Andy Matuschak. All rights reserved.
//

#import "SUUpdater.h"

#import "SUAppcast.h"
#import "SUAppcastItem.h"
#import "SUVersionComparisonProtocol.h"
#import "SUAppcast.h"
#import "SUConstants.h"
#import "SULog.h"

@interface NSXMLElement (SUAppcastExtensions)
@property (readonly, copy) NSDictionary *attributesAsDictionary;
@end

@implementation NSXMLElement (SUAppcastExtensions)
- (NSDictionary *)attributesAsDictionary
{
    NSEnumerator *attributeEnum = [[self attributes] objectEnumerator];
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];

    for (NSXMLNode *attribute in attributeEnum) {
        NSString *attrName = [attribute name];
        if (!attrName) {
            continue;
        }
        dictionary[attrName] = [attribute stringValue];
    }
    return dictionary;
}
@end

@interface SUAppcast () <NSURLDownloadDelegate>
@property (strong) void (^completionBlock)(NSError *);
@property (copy) NSString *downloadFilename;
@property (strong) NSURLDownload *download;
@property (copy) NSArray *items;
- (void)reportError:(NSError *)error;
- (NSXMLNode *)bestNodeInNodes:(NSArray *)nodes;
@end

@implementation SUAppcast

@synthesize downloadFilename;
@synthesize completionBlock;
@synthesize userAgentString;
@synthesize httpHeaders;
@synthesize download;
@synthesize items;

- (void)fetchAppcastFromURL:(NSURL *)url completionBlock:(void (^)(NSError *))block
{
    self.completionBlock = block;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:30.0];
    if (self.userAgentString) {
        [request setValue:self.userAgentString forHTTPHeaderField:@"User-Agent"];
    }

    if (self.httpHeaders) {
        for (NSString *key in self.httpHeaders) {
            id value = [self.httpHeaders objectForKey:key];
            [request setValue:value forHTTPHeaderField:key];
        }
    }

    [request setValue:@"application/rss+xml,*/*;q=0.1" forHTTPHeaderField:@"Accept"];

    self.download = [[NSURLDownload alloc] initWithRequest:request delegate:self];
}

- (void)download:(NSURLDownload *)__unused aDownload decideDestinationWithSuggestedFilename:(NSString *)filename
{
    NSString *destinationFilename = NSTemporaryDirectory();
	if (destinationFilename)
	{
        destinationFilename = [destinationFilename stringByAppendingPathComponent:filename];
        [self.download setDestination:destinationFilename allowOverwrite:NO];
    }
}

- (void)download:(NSURLDownload *)__unused aDownload didCreateDestination:(NSString *)path
{
    self.downloadFilename = path;
}

- (void)downloadDidFinish:(NSURLDownload *)__unused aDownload
{
    NSError *error = nil;
    NSArray *appcastItems = [self parseAppcastItemsFromXMLFile:[NSURL fileURLWithPath:self.downloadFilename] error:&error];

    [[NSFileManager defaultManager] removeItemAtPath:self.downloadFilename error:nil];
    self.downloadFilename = nil;

    if (appcastItems) {
        self.items = appcastItems;
        self.completionBlock(nil);
        self.completionBlock = nil;
    } else {
        NSMutableDictionary *userInfo = [NSMutableDictionary
            dictionaryWithObject: SULocalizedString(@"An error occurred while parsing the update feed.", nil)
                          forKey: NSLocalizedDescriptionKey];
        if (error) {
            userInfo[NSUnderlyingErrorKey] = error;
        }
        [self reportError:[NSError errorWithDomain:SUSparkleErrorDomain
                                              code:SUAppcastParseError
                                          userInfo:userInfo]];
    }
}

-(NSArray *)parseAppcastItemsFromXMLFile:(NSURL *)appcastFile error:(NSError *__autoreleasing*)errorp {
    if (errorp) {
        *errorp = nil;
    }

    if (!appcastFile) {
        return nil;
    }

    NSUInteger options = NSXMLNodeLoadExternalEntitiesNever; // Prevent inclusion from file://
    NSXMLDocument *document = [[NSXMLDocument alloc] initWithContentsOfURL:appcastFile options:options error:errorp];
	if (nil == document) {
        return nil;
    }

    NSArray *xmlItems = [document nodesForXPath:@"/rss/channel/item" error:errorp];
    if (nil == xmlItems) {
        return nil;
    }

    NSMutableArray *appcastItems = [NSMutableArray array];
    NSEnumerator *nodeEnum = [xmlItems objectEnumerator];
    NSXMLNode *node;

	while((node = [nodeEnum nextObject])) {
        NSMutableDictionary *nodesDict = [NSMutableDictionary dictionary];
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];

        // First, we'll "index" all the first-level children of this appcast item so we can pick them out by language later.
        if ([[node children] count]) {
            node = [node childAtIndex:0];
            while (nil != node) {
                NSString *name = [node name];
                if (name) {
                    NSMutableArray *nodes = nodesDict[name];
                    if (nodes == nil) {
                        nodes = [NSMutableArray array];
                        nodesDict[name] = nodes;
                    }
                    [nodes addObject:node];
                }
                node = [node nextSibling];
            }
        }

        for (NSString *name in nodesDict) {
            node = [self bestNodeInNodes:nodesDict[name]];
            if ([name isEqualToString:SURSSElementEnclosure]) {
                // enclosure is flattened as a separate dictionary for some reason
                NSDictionary *encDict = [(NSXMLElement *)node attributesAsDictionary];
                dict[name] = encDict;
			}
            else if ([name isEqualToString:SURSSElementPubDate]) {
                // pubDate is expected to be an NSDate by SUAppcastItem, but the RSS class was returning an NSString
                NSString *string = node.stringValue;
                if (string) {
                    NSDate *date = [NSDate dateWithNaturalLanguageString:string];
                    if (date) {
                        dict[name] = date;
                    }
                }
			}
			else if ([name isEqualToString:SUAppcastElementDeltas]) {
                NSMutableArray *deltas = [NSMutableArray array];
                NSEnumerator *childEnum = [[node children] objectEnumerator];
                for (NSXMLNode *child in childEnum) {
                    if ([[child name] isEqualToString:SURSSElementEnclosure]) {
                        [deltas addObject:[(NSXMLElement *)child attributesAsDictionary]];
                    }
                }
                dict[name] = deltas;
			}
            else if ([name isEqualToString:SUAppcastElementTags]) {
                NSMutableArray *tags = [NSMutableArray array];
                NSEnumerator *childEnum = [[node children] objectEnumerator];
                for (NSXMLNode *child in childEnum) {
                    NSString *childName = child.name;
                    if (childName) {
                        [tags addObject:childName];
                    }
                }
                dict[name] = tags;
            }
			else if (name != nil) {
                // add all other values as strings
                NSString *theValue = [[node stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (theValue != nil) {
                    dict[name] = theValue;
                }
            }
        }

        NSString *errString;
        SUAppcastItem *anItem = [[SUAppcastItem alloc] initWithDictionary:dict failureReason:&errString];
        if (anItem) {
            [appcastItems addObject:anItem];
		}
        else {
            SULog(@"Sparkle Updater: Failed to parse appcast item: %@.\nAppcast dictionary was: %@", errString, dict);
            if (errorp) *errorp = [NSError errorWithDomain:SUSparkleErrorDomain
                                                      code:SUAppcastParseError
                                                  userInfo:@{NSLocalizedDescriptionKey: errString}];
            return nil;
        }
    }

    if ([appcastItems count]) {
        NSSortDescriptor *sort = [[NSSortDescriptor alloc] initWithKey:@"date" ascending:NO];
        [appcastItems sortUsingDescriptors:@[sort]];
    }

    return appcastItems;
}

- (void)download:(NSURLDownload *)__unused aDownload didFailWithError:(NSError *)error
{
    if (self.downloadFilename) {
        [[NSFileManager defaultManager] removeItemAtPath:self.downloadFilename error:nil];
    }
    self.downloadFilename = nil;

    [self reportError:error];
}

- (NSURLRequest *)download:(NSURLDownload *)__unused aDownload willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)__unused redirectResponse
{
    return request;
}

- (void)reportError:(NSError *)error
{
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithDictionary:@{
        NSLocalizedDescriptionKey: SULocalizedString(@"An error occurred in retrieving update information. Please try again later.", nil),
        NSLocalizedFailureReasonErrorKey: [error localizedDescription],
        NSUnderlyingErrorKey: error,
    }];

    NSURL *failingUrl = error.userInfo[NSURLErrorFailingURLErrorKey];
    if (failingUrl) {
        userInfo[NSURLErrorFailingURLErrorKey] = failingUrl;
    }

    self.completionBlock([NSError errorWithDomain:SUSparkleErrorDomain code:SUAppcastError userInfo:userInfo]);
    self.completionBlock = nil;
}

- (NSXMLNode *)bestNodeInNodes:(NSArray *)nodes
{
    // We use this method to pick out the localized version of a node when one's available.
    if ([nodes count] == 1)
        return nodes[0];
    else if ([nodes count] == 0)
        return nil;

    NSMutableArray *languages = [NSMutableArray array];
    NSString *lang;
    NSUInteger i;
    for (NSXMLElement *node in nodes) {
        lang = [[node attributeForName:@"xml:lang"] stringValue];
        [languages addObject:(lang ? lang : @"")];
    }
    lang = [NSBundle preferredLocalizationsFromArray:languages][0];
    i = [languages indexOfObject:([languages containsObject:lang] ? lang : @"")];
    if (i == NSNotFound) {
        i = 0;
    }
    return nodes[i];
}

- (SUAppcast *)copyWithoutDeltaUpdates {
    SUAppcast *other = [SUAppcast new];
    NSMutableArray *nonDeltaItems = [NSMutableArray new];

    for(SUAppcastItem *item in self.items) {
        if (![item isDeltaUpdate]) [nonDeltaItems addObject:item];
    }

    other.items = nonDeltaItems;
    return other;
}

@end
