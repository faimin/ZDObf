#import <XCTest/XCTest.h>
@import ZDObfKitObjC;
#import "Fixture.h"

// Runtime 是进程级单例，且 `swift test` 会把 Swift 与 Objective-C 两个测试 target 放进同一个
// xctest 进程：Swift 套件（ZDObfKitTests）已经成功初始化过单例时，这里看到的就是“已初始化”状态。
// 因此本套件对两种起始状态都成立（单独运行是未初始化，与 Swift 套件同跑是已初始化），
// 不能假设自己是第一个初始化的人。“未初始化 → 失败的初始化不占用单例”的严格顺序由 Swift 套件负责。
@interface ZDObfObjCTests : XCTestCase
@end

static NSData *KeyData(void) {
    uint8_t bytes[32];
    for (int index = 0; index < 32; index++) bytes[index] = (uint8_t)index;
    return [NSData dataWithBytes:bytes length:32];
}

static const NSInteger kAlreadyInitializedCode = 2;  // ZD_STRING_ERROR_ALREADY_INITIALIZED

static NSString *DecodeID(uint64_t identifier) {
    unsigned char bytes[8];
    for (int index = 0; index < 8; index++) bytes[index] = (unsigned char)(identifier >> (index * 8));
    return ZDStringDecodeBytes(bytes, sizeof(bytes));
}

@implementation ZDObfObjCTests

- (void)test01_InvalidInitializationReportsErrorsAndDoesNotChangeState {
    // 起始状态可能是未初始化，也可能已被同进程的 Swift 套件初始化。
    BOOL wasInitialized = DecodeID(kFixtureUrlID) != nil;

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
    // 失败的初始化既不能占用单例，也不能影响已有目录。
    XCTAssertEqual(DecodeID(kFixtureUrlID) != nil, wasInitialized, @"失败的初始化不能改变单例状态");
}

- (void)test02_InitializeAndDecode {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:kFixtureBlobBase64 options:0];
    NSError *error = nil;
    if (!ZDObfInitialize(blob, KeyData(), &error)) {
        // 同进程的 Swift 套件已经初始化过：只接受“已初始化”这一种失败原因。
        XCTAssertEqualObjects(error.domain, ZDObfErrorDomain);
        XCTAssertEqual(error.code, kAlreadyInitializedCode, @"%@", error);
    }

    XCTAssertEqualObjects(DecodeID(kFixtureUrlID), @"https://api.example.com/v1/user");
    XCTAssertEqualObjects(DecodeID(kFixtureUnicodeID), @"你好，ZDObf!\n");
    XCTAssertEqualObjects(DecodeID(kFixtureEmptyID), @"");
    XCTAssertNil(DecodeID(0xdeadbeef), @"未知 ID 返回 nil");
    XCTAssertNil(ZDStringDecodeBytes((const unsigned char[]){1, 2, 3}, 3), @"ID 必须正好是 8 字节");

    // 再次初始化失败，已有目录不受影响。
    error = nil;
    XCTAssertFalse(ZDObfInitialize(blob, KeyData(), &error));
    XCTAssertEqual(error.code, kAlreadyInitializedCode);
    XCTAssertEqualObjects(DecodeID(kFixtureUrlID), @"https://api.example.com/v1/user");
}

- (void)test03_EmbeddedInitializationFailsWithoutASection {
    NSError *error = nil;
    XCTAssertFalse(ZDObfInitializeEmbedded(KeyData(), &error));
    XCTAssertNotNil(error);

    // 内嵌 key 模式（无参）同样需要 section。
    error = nil;
    XCTAssertFalse(ZDObfInitializeEmbeddedWithBuiltInKey(&error));
    XCTAssertNotNil(error);
}

@end
