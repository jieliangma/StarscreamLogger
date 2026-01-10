//
//  Entry.m
//  Pods
//
//  Created by 马杰亮 on 2026/1/10.
//

static id kLogServer;

__attribute__((constructor(100)))
static void entry(void) {
    Class cls = NSClassFromString(@"StarscreamLogger.LogServer");
    kLogServer = [[cls alloc] init];
}
