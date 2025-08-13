//
//  TJPCacheManager.m
//  
//
//  Created by 唐佳鹏 on 2025/1/18.
//

#import "TJPCacheManager.h"

// 常用缓存时间定义
NSTimeInterval const TJPCacheExpireTimeShort = 5 * 60;   // 5分钟
NSTimeInterval const TJPCacheExpireTimeMedium = 60 * 60;  // 1小时
NSTimeInterval const TJPCacheExpireTimeLong = 24 * 60 * 60; // 24小时

@interface TJPCacheManager ()

@property (nonatomic, strong) NSMutableDictionary *refreshStrategies;
@property (nonatomic, strong) NSMutableSet *refreshingKeys;
@property (nonatomic, strong) dispatch_queue_t cacheQueue;
@property (nonatomic, strong) NSTimer *cleanupTimer;


@end

@implementation TJPCacheManager

- (instancetype)initWithCacheStrategy:(id<TJPCacheProtocol>)cacheStrategy
                       defaultStrategy:(TJPCacheStrategy)strategy {
    self = [super init];
    if (self) {
        _cacheStrategy = cacheStrategy;
        _defaultStrategy = strategy;
        _maxCacheSize = 50 * 1024 * 1024; // 50MB
        _maxCacheCount = 1000;
        _autoCleanupEnabled = YES;
        
        [self setupAutoCleanup];
    }
    return self;
}

- (void)fetchDataForKey:(NSString *)key
               strategy:(TJPCacheStrategy)strategy
            networkFetch:(id(^)(void))networkFetch
             completion:(void(^)(id data, BOOL fromCache, NSError *error))completion {
    
    switch (strategy) {
        case TJPCacheStrategyCacheFirst:
            [self fetchWithCacheFirst:key networkFetch:networkFetch completion:completion];
            break;
            
        case TJPCacheStrategyNetworkFirst:
            [self fetchWithNetworkFirst:key networkFetch:networkFetch completion:completion];
            break;
            
        case TJPCacheStrategyStaleWhileRevalidate:
            [self fetchWithStaleWhileRevalidate:key networkFetch:networkFetch completion:completion];
            break;
    }
}

#pragma mark - 缓存策略实现

- (void)fetchWithCacheFirst:(NSString *)key
                networkFetch:(id(^)(void))networkFetch
                  completion:(void(^)(id data, BOOL fromCache, NSError *error))completion {
    
    // 1. 先检查缓存
    id cachedData = [self.cacheStrategy loadCacheForKey:key];
    if (cachedData) {
        if (completion) completion(cachedData, YES, nil);
        return;
    }
    
    // 2. 缓存未命中，请求网络
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            id networkData = networkFetch ? networkFetch() : nil;
            if (networkData) {
                // 保存到缓存
                [self saveCacheWithData:networkData forKey:key expireTime:TJPCacheExpireTimeMedium];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(networkData, NO, nil);
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSError *error = [NSError errorWithDomain:@"TJPCacheError"
                                                         code:1001
                                                     userInfo:@{NSLocalizedDescriptionKey: @"网络请求返回空数据"}];
                    if (completion) completion(nil, NO, error);
                });
            }
        } @catch (NSException *exception) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *error = [NSError errorWithDomain:@"TJPCacheError"
                                                     code:1002
                                                 userInfo:@{NSLocalizedDescriptionKey: exception.reason}];
                if (completion) completion(nil, NO, error);
            });
        }
    });
}

- (void)fetchWithNetworkFirst:(NSString *)key
                 networkFetch:(id(^)(void))networkFetch
                   completion:(void(^)(id data, BOOL fromCache, NSError *error))completion {
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            // 1. 先请求网络
            id networkData = networkFetch ? networkFetch() : nil;
            if (networkData) {
                // 保存到缓存
                [self saveCacheWithData:networkData forKey:key expireTime:TJPCacheExpireTimeMedium];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(networkData, NO, nil);
                });
                return;
            }
        } @catch (NSException *exception) {
            NSLog(@"网络请求失败: %@", exception.reason);
        }
        
        // 2. 网络失败，尝试缓存
        id cachedData = [self.cacheStrategy loadCacheForKey:key];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (cachedData) {
                if (completion) completion(cachedData, YES, nil);
            } else {
                NSError *error = [NSError errorWithDomain:@"TJPCacheError"
                                                     code:1003
                                                 userInfo:@{NSLocalizedDescriptionKey: @"网络请求失败且无缓存数据"}];
                if (completion) completion(nil, NO, error);
            }
        });
    });
}

- (void)fetchWithStaleWhileRevalidate:(NSString *)key
                         networkFetch:(id(^)(void))networkFetch
                           completion:(void(^)(id data, BOOL fromCache, NSError *error))completion {
    
    // 1. 立即返回缓存数据（如果有）
    id cachedData = [self.cacheStrategy loadCacheForKey:key];
    if (cachedData) {
        if (completion) completion(cachedData, YES, nil);
    }
    
    // 2. 同时在后台更新数据
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            id networkData = networkFetch ? networkFetch() : nil;
            if (networkData) {
                // 更新缓存
                [self saveCacheWithData:networkData forKey:key expireTime:TJPCacheExpireTimeMedium];
                
                // 如果之前没有缓存，现在返回网络数据
                if (!cachedData) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (completion) completion(networkData, NO, nil);
                    });
                }
                
                // 发送数据更新通知
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"TJPCacheDidUpdateNotification"
                                                                        object:nil
                                                                      userInfo:@{@"key": key, @"data": networkData}];
                });
            }
        } @catch (NSException *exception) {
            NSLog(@"后台更新失败: %@", exception.reason);
        }
    });
    
    // 3. 如果没有缓存数据，返回错误
    if (!cachedData) {
        NSError *error = [NSError errorWithDomain:@"TJPCacheError"
                                             code:1004
                                         userInfo:@{NSLocalizedDescriptionKey: @"无缓存数据且后台更新中"}];
        if (completion) completion(nil, NO, error);
    }
}

#pragma mark - 缓存失效管理

- (void)invalidateCacheForKey:(NSString *)key reason:(TJPCacheUpdateReason)reason {
    [self.cacheStrategy removeCacheForKey:key];
    
    NSLog(@"缓存失效 - Key: %@, 原因: %lu", key, (unsigned long)reason);
    
    // 可以根据原因执行不同的后续操作
    switch (reason) {
        case TJPCacheUpdateReasonDataChanged:
            // 数据变更时，可能需要同步更新相关缓存
            [self invalidateRelatedCacheForKey:key];
            break;
        default:
            break;
    }
}

- (void)invalidateCacheWithPattern:(NSString *)pattern {
    NSArray *allKeys = [self.cacheStrategy allCacheKeys];
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"SELF LIKE %@", pattern];
    NSArray *matchingKeys = [allKeys filteredArrayUsingPredicate:predicate];
    
    for (NSString *key in matchingKeys) {
        [self.cacheStrategy removeCacheForKey:key];
    }
    
    NSLog(@"批量清理缓存 - 模式: %@, 清理数量: %lu", pattern, (unsigned long)matchingKeys.count);
}

#pragma mark - 私有方法

- (void)invalidateRelatedCacheForKey:(NSString *)key {
    // 根据业务逻辑清理相关缓存
    // 例如：用户信息更新时，清理用户相关的所有缓存
    if ([key containsString:@"user_"]) {
        [self invalidateCacheWithPattern:@"user_*"];
    }
}

- (void)setupAutoCleanup {
    if (!self.autoCleanupEnabled) return;
    
    // 监听内存警告
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleMemoryWarning)
                                                 name:UIApplicationDidReceiveMemoryWarningNotification
                                               object:nil];
    
    // 定期清理过期缓存
    NSTimer *cleanupTimer = [NSTimer scheduledTimerWithTimeInterval:300 // 5分钟
                                                             target:self
                                                           selector:@selector(performPeriodicCleanup)
                                                           userInfo:nil
                                                            repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:cleanupTimer forMode:NSRunLoopCommonModes];
}

- (void)handleMemoryWarning {
    NSLog(@"收到内存警告，开始清理缓存");
    
    // 清理一部分缓存以释放内存
    NSArray *allKeys = [self.cacheStrategy allCacheKeys];
    NSUInteger clearCount = allKeys.count / 2; // 清理一半
    
    for (NSUInteger i = 0; i < clearCount && i < allKeys.count; i++) {
        [self.cacheStrategy removeCacheForKey:allKeys[i]];
    }
}

- (void)performPeriodicCleanup {
    // 定期清理：检查缓存大小和数量
    NSUInteger currentSize = [self.cacheStrategy cacheSize];
    NSUInteger currentCount = [self.cacheStrategy allCacheKeys].count;
    
    if (currentSize > self.maxCacheSize || currentCount > self.maxCacheCount) {
        NSLog(@"缓存超限，开始清理 - 当前大小: %lu, 当前数量: %lu",
              (unsigned long)currentSize, (unsigned long)currentCount);
        
        // 可以实现LRU清理策略
        [self performLRUCleanup];
    }
}

- (void)performLRUCleanup {
    //简化为清理一部分缓存
    NSArray *allKeys = [self.cacheStrategy allCacheKeys];
    NSUInteger clearCount = allKeys.count / 4; // 清理1/4
    
    for (NSUInteger i = 0; i < clearCount && i < allKeys.count; i++) {
        [self.cacheStrategy removeCacheForKey:allKeys[i]];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - TJPCacheProtocol Implementation

- (void)saveCacheWithData:(id)data forKey:(NSString *)key expireTime:(NSTimeInterval)expireTime {
    [self.cacheStrategy saveCacheWithData:data forKey:key expireTime:expireTime];
}

- (id)loadCacheForKey:(NSString *)key {
    return [self.cacheStrategy loadCacheForKey:key];
}

- (void)removeCacheForKey:(NSString *)key {
    [self.cacheStrategy removeCacheForKey:key];
}

- (void)clearAllCache {
    [self.cacheStrategy clearAllCache];
}

- (BOOL)hasCacheForKey:(NSString *)key {
    return [self.cacheStrategy hasCacheForKey:key];
}

- (NSTimeInterval)remainingTimeForKey:(NSString *)key {
    return [self.cacheStrategy remainingTimeForKey:key];
}

- (NSUInteger)cacheSize {
    return [self.cacheStrategy cacheSize];
}

- (void)removeCacheWithKeyPrefix:(NSString *)keyPrefix {
    [self.cacheStrategy removeCacheWithKeyPrefix:keyPrefix];
}

- (NSArray<NSString *> *)allCacheKeys {
    return [self.cacheStrategy allCacheKeys];
}

//- (void)preloadCacheForKeys:(nonnull NSArray<NSString *> *)keys networkFetch:(nonnull NSDictionary * _Nonnull (^)(NSArray * _Nonnull __strong))networkFetch {
//}

@end
