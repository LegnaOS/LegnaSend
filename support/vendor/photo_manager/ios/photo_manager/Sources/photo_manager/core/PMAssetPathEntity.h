#import <Foundation/Foundation.h>

#define PM_TYPE_ALBUM 1
#define PM_TYPE_FOLDER 2
@class PHAsset;
@class PHAssetCollection;

NS_ASSUME_NONNULL_BEGIN

@interface PMAssetPathEntity : NSObject

@property(nonatomic, copy, nullable) NSString *id;
@property(nonatomic, copy, nullable) NSString *name;
@property(nonatomic, assign) BOOL isAll;
@property(nonatomic, assign) int type;
@property(nonatomic, assign) NSUInteger assetCount;
@property(nonatomic, assign) long modifiedDate;
@property(nonatomic, strong, nullable) PHAssetCollection *collection;

+ (instancetype)entityWithId:(NSString *)id name:(nullable NSString *)name assetCollection:(nullable PHAssetCollection*)collection;

@end

@interface PMAssetEntity : NSObject

@property(nonatomic, copy, nullable) NSString *id;
@property(nonatomic, assign) long createDt;
@property(nonatomic, assign) NSUInteger width;
@property(nonatomic, assign) NSUInteger height;
@property(nonatomic, assign) long duration;
@property(nonatomic, assign) int type;
@property(nonatomic, strong, nullable) PHAsset *phAsset;
@property(nonatomic, assign) long modifiedDt;
@property(nonatomic, strong, nullable) NSNumber *lat;
@property(nonatomic, strong, nullable) NSNumber *lng;
@property(nonatomic, copy, nullable) NSString *title;
@property(nonatomic, assign) NSUInteger subtype;
@property(nonatomic, assign) BOOL favorite;
@property(nonatomic, assign) BOOL isLocallyAvailable;

- (instancetype)initWithId:(NSString *)id
                  createDt:(long)createDt
                     width:(NSUInteger)width
                    height:(NSUInteger)height
                  duration:(long)duration
                      type:(int)type;

+ (instancetype)entityWithId:(NSString *)id
                    createDt:(long)createDt
                       width:(NSUInteger)width
                      height:(NSUInteger)height
                    duration:(long)duration
                        type:(int)type;

@end

NS_ASSUME_NONNULL_END
