// AFAppDotNetAPIClient.h
//
// Copyright (c) 2011–2016 Alamofire Software Foundation ( http://alamofire.org/ )
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "AFAppDotNetAPIClient.h"

static NSString * const AFAppDotNetAPIBaseURLString = @"https://api.app.net/";

@implementation AFAppDotNetAPIClient

+ (instancetype)sharedClient {
    static AFAppDotNetAPIClient *_sharedClient = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 初始化 HTTP Client 的 base url，此处为@"https://api.app.net/"
        _sharedClient = [[AFAppDotNetAPIClient alloc] initWithBaseURL:[NSURL URLWithString:AFAppDotNetAPIBaseURLString]];
        // 设置HTTP Client的安全策略为AFSSLPinningModeNone
        _sharedClient.securityPolicy = [AFSecurityPolicy policyWithPinningMode:AFSSLPinningModeNone];
        /**
         *  知识点：SSL Pinning
         Https对比Http已经很安全，但在建立安全链接的过程中，可能遭受中间人攻击。防御这种类型攻击的最直接方式是Client使用者能正确鉴定Server发的证书【目前很多浏览器在这方面做的足够好，用户只要不在遇到警告时还继续其中的危险操作】，而对于Client的开发者而言，一种方式保持一个可信的根证书颁发机构列表，确认可信的证书，警告或阻止不是可信根证书颁发机构颁发的证书。
         
         SSL Pinning其实就是证书绑定，一般浏览器的做法是信任可信根证书颁发机构颁发的证书，但在移动端【非浏览器的桌面应用亦如此】，应用只和少数的几个Server有交互，所以可以做得更极致点，直接就在应用内保留需要使用的具体Server的证书。对于iOS开发者而言，如果使用AFNetwoking作为网络库，那么要做到这点就很方便，直接证书作为资源打包进去就好，AFNetworking会自动加载，具体代码就不贴了，nsscreencast已经有很好的tutorial。
         */
    });
    
    return _sharedClient;
}

@end
