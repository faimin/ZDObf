#import <Foundation/Foundation.h>
@import ZDObfKitObjC; // SwiftPM 产品的模块名；CocoaPods 里用 #import <ZDObfKit/ZDObf.h>
#import "ProtectedAPIObjC.h"

// 同样不参与编译，由 Generated/ProtectedAPIObjC.m 取代。
NSString * _Nullable DemoProtectedAnalyticsHost(void) {
    return ZDString(@"analytics.example.com");
}
