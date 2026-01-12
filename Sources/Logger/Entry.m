//
//  Entry.m
//  Pods
//
//  Created by 马杰亮 on 2026/1/10.
//

static id kLogServer;

@interface StarscreamLoggerEntry : NSObject

@end

@implementation StarscreamLoggerEntry

+ (void)load {
    Class cls = NSClassFromString(@"StarscreamLogger.LogServer");
    kLogServer = [[cls alloc] init];
}

@end
