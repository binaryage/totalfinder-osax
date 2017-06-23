#import <Cocoa/Cocoa.h>

@protocol TFVersionComparison

- (NSComparisonResult)compareVersion:(NSString*)versionA toVersion:(NSString*)versionB;

@end
