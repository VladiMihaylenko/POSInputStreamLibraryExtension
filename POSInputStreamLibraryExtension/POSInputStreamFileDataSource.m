//
//  POSInputStreamFileDataSource.m
//  POSInputStreamLibrary
//
//  Created by Vlad Mihaylenko on 24/07/14.
//  Copyright (c) 2014 Vlad Mihaylenko. All rights reserved.
//

#import "POSInputStreamFileDataSource.h"
#import "POSLocking.h"

NSString * const POSBlobInputStreamFileDataSourceErrorDomain = @"com.github.pavelosipov.POSBlobInputStreamFileDataSource";

static uint64_t const kFileCacheBufferSize = 131072;

typedef NS_ENUM(NSInteger, UpdateCacheMode) {
    UpdateCacheModeReopenWhenError,
    UpdateCacheModeFailWhenError
};

#pragma mark - NSError (POSBlobInputStreamFileDataSource)

@interface NSError (POSBlobInputStreamFileDataSource)
+ (NSError *)pos_fileOpenError;
@end

@implementation NSError (POSBlobInputStreamFileDataSource)

+ (NSError *)pos_fileOpenError {
    NSDictionary *userInfo = @{ NSLocalizedDescriptionKey : @"Failed to open File stream." };
    return [NSError errorWithDomain:POSBlobInputStreamAssetDataSourceErrorDomain
                               code:POSBlobInputStreamAssetDataSourceErrorCodeOpen
                           userInfo:userInfo];
}

+ (NSError *)pos_fileReadErrorWithPath:(NSString *)filePath reason:(NSError *)reason {
    NSString *description = [NSString stringWithFormat:@"Failed to read File with path %@", filePath];
    if (reason) {
        return [NSError errorWithDomain:POSBlobInputStreamAssetDataSourceErrorDomain
                                   code:POSBlobInputStreamAssetDataSourceErrorCodeRead
                               userInfo:@{ NSLocalizedDescriptionKey:description, NSUnderlyingErrorKey:reason }];
    } else {
        return [NSError errorWithDomain:POSBlobInputStreamAssetDataSourceErrorDomain
                                   code:POSBlobInputStreamAssetDataSourceErrorCodeRead
                               userInfo:@{ NSLocalizedDescriptionKey:description }];
    }
}

@end

#pragma mark - POSBlobInputStreamAssetDataSource

@interface POSInputStreamFileDataSource ()
@property (nonatomic, readwrite) NSError *error;
@end

@implementation POSInputStreamFileDataSource {
    NSString *_filePath;
    NSFileHandle *_file;
    off_t _fileSize;
    off_t _readOffset;
    uint8_t _fileCache[kFileCacheBufferSize];
    off_t _fileCacheSize;
    off_t _fileCacheOffset;
    off_t _fileCacheInternalOffset;
    BOOL _isOpenComplited;
}

@dynamic openCompleted, hasBytesAvailable, atEnd;

- (instancetype)initWithFilePath:(NSString *)filePath {
    NSAssert([[NSFileManager defaultManager] fileExistsAtPath:filePath], @"File dosen't exist");
    if (self = [super init]) {
        _openSynchronously = NO;
        _filePath = filePath;
        _fileCacheSize = 0;
        _fileCacheOffset = 0;
        _fileCacheInternalOffset = 0;
        _isOpenComplited = YES;
    }
    return self;
}

- (BOOL)isOpenCompleted {
    return _isOpenComplited;
}

- (void) dealloc {
    [_file closeFile];
}

#pragma mark - POSBlobInputStreamDataSource

- (void)open {
    [self p_open];
}

- (BOOL)hasBytesAvailable {
    return [self p_availableBytesCount] > 0;
}

- (BOOL)isAtEnd {
    return _fileSize <= _readOffset;
}

- (id)propertyForKey:(NSString *)key {
    if (![key isEqualToString:NSStreamFileCurrentOffsetKey]) {
        return nil;
    }
    return @(_readOffset);
}

- (BOOL)setProperty:(id)property forKey:(NSString *)key {
    if (![key isEqualToString:NSStreamFileCurrentOffsetKey]) {
        return NO;
    }
    if (![property isKindOfClass:[NSNumber class]]) {
        return NO;
    }
    const long long requestedOffest = [property longLongValue];
    if (requestedOffest < 0) {
        return NO;
    }
    _readOffset = requestedOffest;
    [self p_updateCacheInMode:UpdateCacheModeReopenWhenError];
    return YES;
}

- (NSInteger)read:(uint8_t *)buffer maxLength:(NSUInteger)maxLength {
    NSParameterAssert(buffer);
    NSParameterAssert(maxLength > 0);
    if (self.atEnd) {
        return 0;
    }
    const off_t readResult = MIN(maxLength, [self p_availableBytesCount]);
    memcpy(buffer, _fileCache + _fileCacheInternalOffset, (unsigned long)readResult);
    _fileCacheInternalOffset += readResult;
    const off_t readOffset = _readOffset + readResult;
    NSParameterAssert(readOffset <= _fileSize);
    const BOOL atEnd = readOffset >= _fileSize;
    if (atEnd) {
        [self willChangeValueForKey:POSBlobInputStreamDataSourceAtEndKeyPath];
    }
    _readOffset = readOffset;
    if (atEnd) {
        [self didChangeValueForKey:POSBlobInputStreamDataSourceAtEndKeyPath];
    } else if (![self hasBytesAvailable]) {
        [self p_updateCacheInMode:UpdateCacheModeReopenWhenError];
    }
    return (NSInteger)readResult;
}

- (BOOL)getBuffer:(uint8_t **)buffer length:(NSUInteger *)bufferLength {
    return NO;
}

#pragma mark - POSBlobInputStreamDataSource Private

- (void)p_open {
    id<Locking> lock = [self p_lockForOpening];
    [lock lock];
    dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool {
        [self p_updateFileAtPath:_filePath];
        [self p_updateCacheInMode:UpdateCacheModeFailWhenError];
        [lock unlock];
    }});
    [lock waitWithTimeout:DISPATCH_TIME_FOREVER];
}


- (void)p_updateFileAtPath:(NSString*)filePath {
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
    NSAssert(attributes, @"Attributes of file cannot be empty!");
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:filePath];
    [self willChangeValueForKey:POSBlobInputStreamDataSourceOpenCompletedKeyPath];
    _file = file;
    _fileSize = [attributes[NSFileSize] longLongValue];
    [self didChangeValueForKey:POSBlobInputStreamDataSourceOpenCompletedKeyPath];
}

- (void)p_updateFile:(NSFileHandle*)file withAttributes:(NSDictionary*)attributes {
    [self willChangeValueForKey:POSBlobInputStreamDataSourceOpenCompletedKeyPath];
    _file = file;
    _fileSize = [attributes[NSFileSize] longLongValue];
    [self didChangeValueForKey:POSBlobInputStreamDataSourceOpenCompletedKeyPath];
}



- (void)p_updateCacheInMode:(UpdateCacheMode)mode {
    NSError *readError = nil;
    [_file seekToFileOffset:_readOffset];
    NSData *dataBuffer = [_file readDataOfLength:kFileCacheBufferSize];
    memcpy(_fileCache, dataBuffer.bytes, dataBuffer.length);
    if ([dataBuffer length] > 0) {
        [self willChangeValueForKey:POSBlobInputStreamDataSourceHasBytesAvailableKeyPath];
        _fileCacheSize = dataBuffer.length;
        _fileCacheOffset = _readOffset;
        _fileCacheInternalOffset = 0;
        [self didChangeValueForKey:POSBlobInputStreamDataSourceHasBytesAvailableKeyPath];
    } else {
        switch (mode) {
            case UpdateCacheModeReopenWhenError: {
                [self p_open];
            } break;
            case UpdateCacheModeFailWhenError: {
                [self setError:[NSError pos_fileReadErrorWithPath:_filePath reason:readError]];
            } break;
        }
        
    }
}


- (off_t)p_availableBytesCount {
    return _fileCacheSize - _fileCacheInternalOffset;
}

- (id<Locking>)p_lockForOpening {
    if ([self shouldOpenSynchronously]) {
        NSParameterAssert(!NSThread.currentThread.isMainThread);
        return [GCDLock new];
    } else {
        return [DummyLock new];
    }
}
@end
