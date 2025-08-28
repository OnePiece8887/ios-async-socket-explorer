//
//  TJPMemoryCache.m
//  
//
//  Created by 唐佳鹏 on 2025/1/18.
//

#import "TJPMemoryCache.h"
#import "TJPNetworkDefine.h"

@interface TJPMemoryCache ()
@property (nonatomic, strong) dispatch_queue_t cacheQueue;
@end

@implementation TJPMemoryCache

- (instancetype)init {
    self = [super init];
    if (self) {
        _cache = [[NSCache alloc] init];
        _cacheExpiryTimes = [NSMutableDictionary dictionary];
        _cacheQueue = dispatch_queue_create("com.tjp.memory.cache", DISPATCH_QUEUE_CONCURRENT);
        
        // 设置NSCache的一些默认配置
        _cache.countLimit = 100; // 默认最大缓存对象数量
        _cache.totalCostLimit = 10 * 1024 * 1024; // 默认最大缓存大小 10MB
    }
    return self;
}

#pragma mark - TJPCacheProtocol Implementation

- (void)saveCacheWithData:(id)data forKey:(NSString *)key {
    [self saveCacheWithData:data forKey:key expireTime:3600]; // 默认1小时过期
}

// 存储缓存数据，添加过期时间
- (void)saveCacheWithData:(id)data forKey:(NSString *)key expireTime:(NSTimeInterval)expireTime {
    if (data && key) {
        dispatch_barrier_async(self.cacheQueue, ^{
            [self.cache setObject:data forKey:key];
            TJPLOG_INFO(@"TJPMemoryCache save cache with data for key: %@", key);
            
            // 设置过期时间
            NSTimeInterval expiryTimestamp = [[NSDate date] timeIntervalSince1970] + expireTime;
            self.cacheExpiryTimes[key] = @(expiryTimestamp);
        });
    }
}

// 读取缓存数据，并检查是否过期
- (id)loadCacheForKey:(NSString *)key {
    if (!key) return nil;
    
    __block id result = nil;
    dispatch_sync(self.cacheQueue, ^{
        NSNumber *expiryTimestamp = self.cacheExpiryTimes[key];
        
        if (expiryTimestamp) {
            NSTimeInterval currentTimestamp = [[NSDate date] timeIntervalSince1970];
            if (currentTimestamp > [expiryTimestamp doubleValue]) {
                // 缓存过期，删除缓存并返回nil
                [self.cache removeObjectForKey:key];
                [self.cacheExpiryTimes removeObjectForKey:key];
                TJPLOG_INFO(@"TJPMemoryCache cache expired for key: %@", key);
                return;
            }
        }
        
        result = [self.cache objectForKey:key];
        if (result) {
            TJPLOG_INFO(@"TJPMemoryCache load cache for key: %@", key);
        }
    });
    
    return result;
    
}

// 删除缓存数据
- (void)removeCacheForKey:(NSString *)key {
    if (!key) return;
    
    dispatch_barrier_async(self.cacheQueue, ^{
        [self.cache removeObjectForKey:key];
        [self.cacheExpiryTimes removeObjectForKey:key];
        TJPLOG_INFO(@"TJPMemoryCache remove cache for key: %@", key);
    });
}

// 清除所有缓存
- (void)clearAllCache {
    dispatch_barrier_async(self.cacheQueue, ^{
        [self.cache removeAllObjects];
        [self.cacheExpiryTimes removeAllObjects];
        TJPLOG_INFO(@"TJPMemoryCache clear all cache");
    });
}

// 检查是否存在指定key的缓存
- (BOOL)hasCacheForKey:(NSString *)key {
    if (!key) return NO;
    
    __block BOOL hasCache = NO;
    dispatch_sync(self.cacheQueue, ^{
        // 先检查是否过期
        NSNumber *expiryTimestamp = self.cacheExpiryTimes[key];
        if (expiryTimestamp) {
            NSTimeInterval currentTimestamp = [[NSDate date] timeIntervalSince1970];
            if (currentTimestamp > [expiryTimestamp doubleValue]) {
                // 已过期
                [self.cache removeObjectForKey:key];
                [self.cacheExpiryTimes removeObjectForKey:key];
                hasCache = NO;
                return;
            }
        }
        
        hasCache = [self.cache objectForKey:key] != nil;
    });
    
    return hasCache;
}

// 获取指定key的缓存剩余时间
- (NSTimeInterval)remainingTimeForKey:(NSString *)key {
    if (!key) return 0;
    
    __block NSTimeInterval remainingTime = 0;
    dispatch_sync(self.cacheQueue, ^{
        NSNumber *expiryTimestamp = self.cacheExpiryTimes[key];
        if (expiryTimestamp) {
            NSTimeInterval currentTimestamp = [[NSDate date] timeIntervalSince1970];
            remainingTime = [expiryTimestamp doubleValue] - currentTimestamp;
            if (remainingTime < 0) {
                remainingTime = 0;
                // 清理过期缓存
                [self.cache removeObjectForKey:key];
                [self.cacheExpiryTimes removeObjectForKey:key];
            }
        }
    });
    
    return remainingTime;
}

// 获取当前缓存大小（估算）
- (NSUInteger)cacheSize {
    __block NSUInteger size = 0;
    dispatch_sync(self.cacheQueue, ^{
        // NSCache没有直接获取大小的方法，这里返回缓存对象数量
        // 可以根据实际需要估算或精确计算
        size = self.cacheExpiryTimes.count;
    });
    return size;
}

// 根据key前缀删除缓存
- (void)removeCacheWithKeyPrefix:(NSString *)keyPrefix {
    if (!keyPrefix || keyPrefix.length == 0) return;
    
    dispatch_barrier_async(self.cacheQueue, ^{
        NSArray *allKeys = [self.cacheExpiryTimes.allKeys copy];
        NSMutableArray *keysToRemove = [NSMutableArray array];
        
        for (NSString *key in allKeys) {
            if ([key hasPrefix:keyPrefix]) {
                [keysToRemove addObject:key];
            }
        }
        
        for (NSString *key in keysToRemove) {
            [self.cache removeObjectForKey:key];
            [self.cacheExpiryTimes removeObjectForKey:key];
        }
        
        TJPLOG_INFO(@"TJPMemoryCache remove %lu caches with prefix: %@",
                    (unsigned long)keysToRemove.count, keyPrefix);
    });
}

// 获取所有缓存的key
- (NSArray<NSString *> *)allCacheKeys {
    __block NSArray<NSString *> *allKeys = nil;
    dispatch_sync(self.cacheQueue, ^{
        // 清理过期缓存后返回有效的keys
        NSMutableArray *validKeys = [NSMutableArray array];
        NSTimeInterval currentTimestamp = [[NSDate date] timeIntervalSince1970];
        NSArray *keys = [self.cacheExpiryTimes.allKeys copy];
        
        for (NSString *key in keys) {
            NSNumber *expiryTimestamp = self.cacheExpiryTimes[key];
            if (expiryTimestamp) {
                if (currentTimestamp <= [expiryTimestamp doubleValue]) {
                    [validKeys addObject:key];
                } else {
                    // 清理过期缓存
                    [self.cache removeObjectForKey:key];
                    [self.cacheExpiryTimes removeObjectForKey:key];
                }
            } else {
                [validKeys addObject:key];
            }
        }
        
        allKeys = [validKeys copy];
    });
    
    return allKeys;
}

#pragma mark - Helper Methods

// 清理过期缓存
- (void)cleanExpiredCache {
    dispatch_barrier_async(self.cacheQueue, ^{
        NSTimeInterval currentTimestamp = [[NSDate date] timeIntervalSince1970];
        NSArray *allKeys = [self.cacheExpiryTimes.allKeys copy];
        NSMutableArray *expiredKeys = [NSMutableArray array];
        
        for (NSString *key in allKeys) {
            NSNumber *expiryTimestamp = self.cacheExpiryTimes[key];
            if (expiryTimestamp && currentTimestamp > [expiryTimestamp doubleValue]) {
                [expiredKeys addObject:key];
            }
        }
        
        for (NSString *key in expiredKeys) {
            [self.cache removeObjectForKey:key];
            [self.cacheExpiryTimes removeObjectForKey:key];
        }
        
        if (expiredKeys.count > 0) {
            TJPLOG_INFO(@"TJPMemoryCache cleaned %lu expired caches",
                        (unsigned long)expiredKeys.count);
        }
    });
}

// 获取缓存统计信息
- (NSDictionary *)cacheStatistics {
    __block NSDictionary *stats = nil;
    dispatch_sync(self.cacheQueue, ^{
        NSUInteger totalCount = self.cacheExpiryTimes.count;
        NSTimeInterval currentTimestamp = [[NSDate date] timeIntervalSince1970];
        NSUInteger expiredCount = 0;
        
        for (NSString *key in self.cacheExpiryTimes.allKeys) {
            NSNumber *expiryTimestamp = self.cacheExpiryTimes[key];
            if (expiryTimestamp && currentTimestamp > [expiryTimestamp doubleValue]) {
                expiredCount++;
            }
        }
        
        stats = @{
            @"totalCount": @(totalCount),
            @"validCount": @(totalCount - expiredCount),
            @"expiredCount": @(expiredCount)
        };
    });
    
    return stats;
}

#pragma mark - Dealloc

- (void)dealloc {
    [self clearAllCache];
}

@end
