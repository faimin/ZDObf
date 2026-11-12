#include "../../crates/runtime/include/zd_string_runtime.h"

int main(void) {
    // 链接烟雾测试只验证 XCFramework 导出的 C ABI 可被 iOS Simulator 解析。
    return zd_string_get(1).error == ZD_STRING_ERROR_NOT_INITIALIZED ? 0 : 1;
}
