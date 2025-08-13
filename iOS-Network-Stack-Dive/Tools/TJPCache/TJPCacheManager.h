//
//  TJPCacheManager.h
//  
//
//  Created by 唐佳鹏 on 2025/1/18.
//

#import <UIKit/UIKit.h>
#import "TJPCacheProtocol.h"


NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, TJPCacheStrategy) {
    TJPCacheStrategyCacheFirst,          // 缓存优先
    TJPCacheStrategyNetworkFirst,        // 网络优先
    TJPCacheStrategyStaleWhileRevalidate // 缓存返回，后台更新
};

typedef NS_ENUM(NSUInteger, TJPCacheUpdateReason) {
    TJPCacheUpdateReasonExpired,         // 过期
    TJPCacheUpdateReasonUserRefresh,     // 用户刷新
    TJPCacheUpdateReasonDataChanged,     // 数据变更
    TJPCacheUpdateReasonForceUpdate      // 强制更新
};

@interface TJPCacheManager : NSObject <TJPCacheProtocol>

// 缓存策略的选择（可以是内存、磁盘或数据库缓存）
@property (nonatomic, strong) id<TJPCacheProtocol> cacheStrategy;
@property (nonatomic, assign) TJPCacheStrategy defaultStrategy;


// 缓存配置
@property (nonatomic, assign) NSUInteger maxCacheSize;        // 最大缓存大小
@property (nonatomic, assign) NSUInteger maxCacheCount;       // 最大缓存数量
@property (nonatomic, assign) BOOL autoCleanupEnabled;        // 自动清理

// 常用缓存时间
extern NSTimeInterval const TJPCacheExpireTimeShort;  // 短期缓存：5分钟
extern NSTimeInterval const TJPCacheExpireTimeMedium; // 中期缓存：1小时
extern NSTimeInterval const TJPCacheExpireTimeLong;   // 长期缓存：24小时


// 初始化
- (instancetype)initWithCacheStrategy:(id<TJPCacheProtocol>)cacheStrategy
                       defaultStrategy:(TJPCacheStrategy)strategy;

// 智能缓存操作
- (void)fetchDataForKey:(NSString *)key
               strategy:(TJPCacheStrategy)strategy
            networkFetch:(id(^)(void))networkFetch
             completion:(void(^)(id data, BOOL fromCache, NSError *error))completion;

// 缓存失效管理
- (void)invalidateCacheForKey:(NSString *)key reason:(TJPCacheUpdateReason)reason;
- (void)invalidateCacheWithPattern:(NSString *)pattern;

// 缓存预加载
//- (void)preloadCacheForKeys:(NSArray<NSString *> *)keys
//               networkFetch:(NSDictionary *(^)(NSArray *keys))networkFetch;

@end

NS_ASSUME_NONNULL_END
