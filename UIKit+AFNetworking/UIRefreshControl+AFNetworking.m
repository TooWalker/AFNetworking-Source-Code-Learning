// UIRefreshControl+AFNetworking.m
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

/**
 *  这个类别和同一目录下的 UIActivityIndicatorView+AFNetworking 里面的结构像极了，简直就是双胞胎，
 *  在理解完这个类别的时候，可以看 UIActivityIndicatorView+AFNetworking，触类傍通
 */

#import "UIRefreshControl+AFNetworking.h"
#import <objc/runtime.h>

#if TARGET_OS_IOS

#import "AFURLSessionManager.h"

@interface AFRefreshControlNotificationObserver : NSObject
@property (readonly, nonatomic, weak) UIRefreshControl *refreshControl;
- (instancetype)initWithActivityRefreshControl:(UIRefreshControl *)refreshControl;

- (void)setRefreshingWithStateOfTask:(NSURLSessionTask *)task;

@end

@implementation UIRefreshControl (AFNetworking)

/** FAQ
 
 *  问：关于这个函数：作用是为了取得 AFRefreshControlNotificationObserver 类的 instance，为何在实现部分要写手动get and set， 应该直接定义一个变量然后new就可以了吧。
 
    答：因为 af_notificationObserver 是在category中的，category是无法创建实例变量的。你如果new一个变量的话，出了af_notificationObserver这个函数，该变量就释放了。下次再取的话无法取得上次new出的变量了。而使用objc_getAssociatedObject相当于给category添加了一个实例变量。
 
    再问：感谢楼主的回复，大概明白了。但是根据我的测试通过AssociatedObject 会生成对应属性的get 和 set 方法，但是没有添加实例变量，因为通过_propertyName 或者 propertyName 都会报错。
        我想问下，如果生成了get和set方法，并且生成了实例变量，那么变量名是什么？？？
 
    再答：使用void objc_setAssociatedObject(id object, const void *key, id value, objc_AssociationPolicy policy);并不是说真得新建了一个属性或实例变量，只是相当于新建了一个，准备来说是给这个对象object绑定了一个属性值value。其内部实现是使用了一个C++ map - ObjectAssociationMap
        类似下面这样:
        objectAssociationMap[key] = value;
 */
- (AFRefreshControlNotificationObserver *)af_notificationObserver {
    
    /** objc_getAssociatedObject 和 objc_setAssociatedObject 方法来绑定一个实例变量 */
    AFRefreshControlNotificationObserver *notificationObserver = objc_getAssociatedObject(self, @selector(af_notificationObserver));
    if (notificationObserver == nil) {
        notificationObserver = [[AFRefreshControlNotificationObserver alloc] initWithActivityRefreshControl:self];
        objc_setAssociatedObject(self, @selector(af_notificationObserver), notificationObserver, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return notificationObserver;
}

- (void)setRefreshingWithStateOfTask:(NSURLSessionTask *)task {
    [[self af_notificationObserver] setRefreshingWithStateOfTask:task];
}

@end

@implementation AFRefreshControlNotificationObserver

- (instancetype)initWithActivityRefreshControl:(UIRefreshControl *)refreshControl
{
    self = [super init];
    if (self) {
        // 仅仅把 refreshControl 传过来，后续要调用 refreshControl 本身的几个方法
        // 所以注意此处 refreshControl 定义的是 weak 属性
        _refreshControl = refreshControl;
    }
    return self;
}

- (void)setRefreshingWithStateOfTask:(NSURLSessionTask *)task {
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];

    /** 先将之前的observer移除 */
    [notificationCenter removeObserver:self name:AFNetworkingTaskDidResumeNotification object:nil];
    [notificationCenter removeObserver:self name:AFNetworkingTaskDidSuspendNotification object:nil];
    [notificationCenter removeObserver:self name:AFNetworkingTaskDidCompleteNotification object:nil];

    if (task) {
        /**
         *  如果当前task状态为NSURLSessionTaskStateRunning，先beginRefreshing，然后添加几个observer:
         1. AFNetworkingTaskDidResumeNotification（任务继续，所以调用beginRefreshing）
         2. AFNetworkingTaskDidCompleteNotification（任务完成，所以调用endRefreshing）
         3. AFNetworkingTaskDidSuspendNotification（任务挂起，所以调用endRefreshing）。有了这几个observer，就可以实时更新refreshControl的状态。
         */
        UIRefreshControl *refreshControl = self.refreshControl;
        if (task.state == NSURLSessionTaskStateRunning) {
            [refreshControl beginRefreshing];

            [notificationCenter addObserver:self selector:@selector(af_beginRefreshing) name:AFNetworkingTaskDidResumeNotification object:task];
            [notificationCenter addObserver:self selector:@selector(af_endRefreshing) name:AFNetworkingTaskDidCompleteNotification object:task];
            [notificationCenter addObserver:self selector:@selector(af_endRefreshing) name:AFNetworkingTaskDidSuspendNotification object:task];
        } else {
            /** 如果task不为NSURLSessionTaskStateRunning，也就是当前任务不是正在运行，就调用endRefreshing */
            [refreshControl endRefreshing];
        }
    }
}

#pragma mark -

- (void)af_beginRefreshing {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.refreshControl beginRefreshing];
    });
}

- (void)af_endRefreshing {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.refreshControl endRefreshing];
    });
}

#pragma mark -

- (void)dealloc {
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    
    [notificationCenter removeObserver:self name:AFNetworkingTaskDidCompleteNotification object:nil];
    [notificationCenter removeObserver:self name:AFNetworkingTaskDidResumeNotification object:nil];
    [notificationCenter removeObserver:self name:AFNetworkingTaskDidSuspendNotification object:nil];
}

@end

#endif
