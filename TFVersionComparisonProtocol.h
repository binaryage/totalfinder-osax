@import Cocoa;

@protocol TFVersionComparison

- (NSComparisonResult)compareVersion:(NSString*)versionA toVersion:(NSString*)versionB;

@end
