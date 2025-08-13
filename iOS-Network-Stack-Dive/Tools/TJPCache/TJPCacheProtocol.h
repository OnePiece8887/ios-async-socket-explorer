//
//  TJPCacheProtocol.h
//  
//
//  Created by 唐佳鹏 on 2025/1/18.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol TJPCacheProtocol <NSObject>

// 基础缓存操作
- (void)saveCacheWithData:(id)data forKey:(NSString *)key expireTime:(NSTimeInterval)expireTime;
- (id)loadCacheForKey:(NSString *)key;
- (void)removeCacheForKey:(NSString *)key;
- (void)clearAllCache;

// 缓存数据查询
- (BOOL)hasCacheForKey:(NSString *)key;
- (NSTimeInterval)remainingTimeForKey:(NSString *)key;
- (NSUInteger)cacheSize;

// 批量操作
- (void)removeCacheWithKeyPrefix:(NSString *)keyPrefix;
- (NSArray<NSString *> *)allCacheKeys;

@end

NS_ASSUME_NONNULL_END
