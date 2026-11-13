#import <XCTest/XCTest.h>
@import ZDObfKitObjC;
#import "Fixture.h"

// Runtime 是进程级单例，用例按名字顺序依赖彼此（失败的初始化不会占用单例）。
@interface ZDObfObjCTests : XCTestCase
@end

static NSData *KeyData(void) {
    uint8_t bytes[32];
    for (int index = 0; index < 32; index++) bytes[index] = (uint8_t)index;
    return [NSData dataWithBytes:bytes length:32];
}

static NSString *DecodeID(uint64_t identifier) {
    unsigned char bytes[8];
    for (int index = 0; index < 8; index++) bytes[index] = (unsigned char)(identifier >> (index * 8));
    return ZDStringDecodeBytes(bytes, sizeof(bytes));
}

@implementation ZDObfObjCTests

- (void)test01_InvalidInitializationReportsErrorsAndDoesNotLatch {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:kFixtureBlobBase64 options:0];
    XCTAssertNotNil(blob);

    NSError *error = nil;
    XCTAssertFalse(ZDObfInitialize(blob, [NSData dataWithBytes:"short" length:5], &error));
    XCTAssertEqualObjects(error.domain, ZDObfErrorDomain);

    error = nil;
    NSData *wrongKey = [NSData dataWithBytes:(uint8_t[32]){0xff} length:32];
    XCTAssertFalse(ZDObfInitialize(blob, wrongKey, &error));
    XCTAssertNotNil(error, @"错误 key 必须带 NSError");

    // 初始化失败时 error 参数可以为 NULL。
    XCTAssertFalse(ZDObfInitialize(blob, wrongKey, NULL));
    XCTAssertNil(DecodeID(kFixtureUrlID), @"失败的初始化不能占用单例");
}

- (void)test02_InitializeAndDecode {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:kFixtureBlobBase64 options:0];
    NSError *error = nil;
    XCTAssertTrue(ZDObfInitialize(blob, KeyData(), &error), @"%@", error);

    XCTAssertEqualObjects(DecodeID(kFixtureUrlID), @"https://api.example.com/v1/user");
    XCTAssertEqualObjects(DecodeID(kFixtureUnicodeID), @"你好，ZDObf!\n");
    XCTAssertEqualObjects(DecodeID(kFixtureEmptyID), @"");
    XCTAssertNil(DecodeID(0xdeadbeef), @"未知 ID 返回 nil");
    XCTAssertNil(ZDStringDecodeBytes((const unsigned char[]){1, 2, 3}, 3), @"ID 必须正好是 8 字节");

    // 再次初始化失败，已有目录不受影响。
    XCTAssertFalse(ZDObfInitialize(blob, KeyData(), &error));
    XCTAssertEqualObjects(DecodeID(kFixtureUrlID), @"https://api.example.com/v1/user");
}

- (void)test03_EmbeddedInitializationFailsWithoutASection {
    NSError *error = nil;
    XCTAssertFalse(ZDObfInitializeEmbedded(KeyData(), &error));
    XCTAssertNotNil(error);
}

@end
