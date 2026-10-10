//
//  LCSignCore.h
//  LCSignCore
//
//  伞形头文件（umbrella header）。
//
//  为什么需要它：LCSignCore 是混合语言的 framework，Swift 侧要调 ObjC++ 的
//  ZSignBridge。App target 可以用桥接头，但 **framework target 不支持桥接头**
//  （Xcode 直接报 "using bridging headers with framework targets is unsupported"）。
//  Apple 给 framework 的做法是：Defines Module 置 Yes，然后把想暴露给 Swift 的
//  ObjC 头文件统统 import 进伞形头文件里。这样同一个 target 里的 Swift 代码
//  无需 import 语句就能看到这些声明。
//
//  文件名必须与 PRODUCT_MODULE_NAME 一致 —— 也就是 LCSignCore。
//
//  注意：只 import ZSignBridge.h。zsign 的 C++ 头文件（bundle.h / openssl.h）
//  绝对不能出现在这里，否则 C++ 依赖链会污染整个 Swift 编译单元，
//  这也正是 zsign_shim.h 那一层存在的理由。
//

#import <Foundation/Foundation.h>

#import "ZSignBridge.h"
