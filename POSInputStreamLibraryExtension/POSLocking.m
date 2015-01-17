//
//  POSLocking.m
//  POSInputStreamLibrary
//
//  Created by Vlad Mihaylenko on 25/07/14.
//  Copyright (c) 2014 Vlad Mihaylenko. All rights reserved.
//

#import "POSLocking.h"

@implementation GCDLock {
    dispatch_semaphore_t semaphore_;
}

- (void)lock {
    semaphore_ = dispatch_semaphore_create(0);
}

- (void)unlock {
    dispatch_semaphore_signal(semaphore_);
}

- (BOOL)waitWithTimeout:(dispatch_time_t)timeout {
    return dispatch_semaphore_wait(semaphore_, timeout) == 0;
}

@end


@implementation DummyLock
- (void)lock {}
- (void)unlock {}
- (BOOL)waitWithTimeout:(dispatch_time_t)timeout { return YES; }
@end