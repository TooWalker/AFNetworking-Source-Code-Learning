// AFURLSessionManager.m
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

#import "AFURLSessionManager.h"
#import <objc/runtime.h>

#ifndef NSFoundationVersionNumber_iOS_8_0
#define NSFoundationVersionNumber_With_Fixed_5871104061079552_bug 1140.11
#else
#define NSFoundationVersionNumber_With_Fixed_5871104061079552_bug NSFoundationVersionNumber_iOS_8_0
#endif

static dispatch_queue_t url_session_manager_creation_queue() {
    static dispatch_queue_t af_url_session_manager_creation_queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        af_url_session_manager_creation_queue = dispatch_queue_create("com.alamofire.networking.session.manager.creation", DISPATCH_QUEUE_SERIAL);
    });

    return af_url_session_manager_creation_queue;
}

static void url_session_manager_create_task_safely(dispatch_block_t block) {
    if (NSFoundationVersionNumber < NSFoundationVersionNumber_With_Fixed_5871104061079552_bug) {
        // Fix of bug
        // Open Radar:http://openradar.appspot.com/radar?id=5871104061079552 (status: Fixed in iOS8)
        // Issue about:https://github.com/AFNetworking/AFNetworking/issues/2093
        dispatch_sync(url_session_manager_creation_queue(), block);
    } else {
        block();
    }
}

static dispatch_queue_t url_session_manager_processing_queue() {
    static dispatch_queue_t af_url_session_manager_processing_queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        af_url_session_manager_processing_queue = dispatch_queue_create("com.alamofire.networking.session.manager.processing", DISPATCH_QUEUE_CONCURRENT);
    });

    return af_url_session_manager_processing_queue;
}

static dispatch_group_t url_session_manager_completion_group() {
    static dispatch_group_t af_url_session_manager_completion_group;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        af_url_session_manager_completion_group = dispatch_group_create();
    });

    return af_url_session_manager_completion_group;
}

NSString * const AFNetworkingTaskDidResumeNotification = @"com.alamofire.networking.task.resume";
NSString * const AFNetworkingTaskDidCompleteNotification = @"com.alamofire.networking.task.complete";
NSString * const AFNetworkingTaskDidSuspendNotification = @"com.alamofire.networking.task.suspend";
NSString * const AFURLSessionDidInvalidateNotification = @"com.alamofire.networking.session.invalidate";
NSString * const AFURLSessionDownloadTaskDidFailToMoveFileNotification = @"com.alamofire.networking.session.download.file-manager-error";

NSString * const AFNetworkingTaskDidCompleteSerializedResponseKey = @"com.alamofire.networking.task.complete.serializedresponse";
NSString * const AFNetworkingTaskDidCompleteResponseSerializerKey = @"com.alamofire.networking.task.complete.responseserializer";
NSString * const AFNetworkingTaskDidCompleteResponseDataKey = @"com.alamofire.networking.complete.finish.responsedata";
NSString * const AFNetworkingTaskDidCompleteErrorKey = @"com.alamofire.networking.task.complete.error";
NSString * const AFNetworkingTaskDidCompleteAssetPathKey = @"com.alamofire.networking.task.complete.assetpath";

static NSString * const AFURLSessionManagerLockName = @"com.alamofire.networking.session.manager.lock";

static NSUInteger const AFMaximumNumberOfAttemptsToRecreateBackgroundSessionUploadTask = 3;

typedef void (^AFURLSessionDidBecomeInvalidBlock)(NSURLSession *session, NSError *error);
typedef NSURLSessionAuthChallengeDisposition (^AFURLSessionDidReceiveAuthenticationChallengeBlock)(NSURLSession *session, NSURLAuthenticationChallenge *challenge, NSURLCredential * __autoreleasing *credential);

typedef NSURLRequest * (^AFURLSessionTaskWillPerformHTTPRedirectionBlock)(NSURLSession *session, NSURLSessionTask *task, NSURLResponse *response, NSURLRequest *request);
typedef NSURLSessionAuthChallengeDisposition (^AFURLSessionTaskDidReceiveAuthenticationChallengeBlock)(NSURLSession *session, NSURLSessionTask *task, NSURLAuthenticationChallenge *challenge, NSURLCredential * __autoreleasing *credential);
typedef void (^AFURLSessionDidFinishEventsForBackgroundURLSessionBlock)(NSURLSession *session);

typedef NSInputStream * (^AFURLSessionTaskNeedNewBodyStreamBlock)(NSURLSession *session, NSURLSessionTask *task);
typedef void (^AFURLSessionTaskDidSendBodyDataBlock)(NSURLSession *session, NSURLSessionTask *task, int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend);
typedef void (^AFURLSessionTaskDidCompleteBlock)(NSURLSession *session, NSURLSessionTask *task, NSError *error);

typedef NSURLSessionResponseDisposition (^AFURLSessionDataTaskDidReceiveResponseBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLResponse *response);
typedef void (^AFURLSessionDataTaskDidBecomeDownloadTaskBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLSessionDownloadTask *downloadTask);
typedef void (^AFURLSessionDataTaskDidReceiveDataBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data);
typedef NSCachedURLResponse * (^AFURLSessionDataTaskWillCacheResponseBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSCachedURLResponse *proposedResponse);

typedef NSURL * (^AFURLSessionDownloadTaskDidFinishDownloadingBlock)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, NSURL *location);
typedef void (^AFURLSessionDownloadTaskDidWriteDataBlock)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite);
typedef void (^AFURLSessionDownloadTaskDidResumeBlock)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t fileOffset, int64_t expectedTotalBytes);
typedef void (^AFURLSessionTaskProgressBlock)(NSProgress *);

typedef void (^AFURLSessionTaskCompletionHandler)(NSURLResponse *response, id responseObject, NSError *error);


#pragma mark -

@interface AFURLSessionManagerTaskDelegate : NSObject <NSURLSessionTaskDelegate, NSURLSessionDataDelegate, NSURLSessionDownloadDelegate>
@property (nonatomic, weak) AFURLSessionManager *manager;
@property (nonatomic, strong) NSMutableData *mutableData;
@property (nonatomic, strong) NSProgress *uploadProgress;
@property (nonatomic, strong) NSProgress *downloadProgress;
@property (nonatomic, copy) NSURL *downloadFileURL;
@property (nonatomic, copy) AFURLSessionDownloadTaskDidFinishDownloadingBlock downloadTaskDidFinishDownloading;
@property (nonatomic, copy) AFURLSessionTaskProgressBlock uploadProgressBlock;
@property (nonatomic, copy) AFURLSessionTaskProgressBlock downloadProgressBlock;
@property (nonatomic, copy) AFURLSessionTaskCompletionHandler completionHandler;
@end

@implementation AFURLSessionManagerTaskDelegate

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    self.mutableData = [NSMutableData data];
    self.uploadProgress = [[NSProgress alloc] initWithParent:nil userInfo:nil];
    self.uploadProgress.totalUnitCount = NSURLSessionTransferSizeUnknown;

    self.downloadProgress = [[NSProgress alloc] initWithParent:nil userInfo:nil];
    self.downloadProgress.totalUnitCount = NSURLSessionTransferSizeUnknown;
    return self;
}

#pragma mark - NSProgress Tracking

/**
 *  设置 uploadProgress 和 downloadProgress 这两个 NSProgress 变量
 */
- (void)setupProgressForTask:(NSURLSessionTask *)task {
    __weak __typeof__(task) weakTask = task;

    /**
     *  先是设置两个 progress 的 totalUnitCount
     */
    /** uploadProgress 的 totalUnitCount 对应期望发送(send)的数据大小 */
    self.uploadProgress.totalUnitCount = task.countOfBytesExpectedToSend;
    /** downloadProgress 的 totalUnitCount 对应期望接收(receive)的数据大小 */
    self.downloadProgress.totalUnitCount = task.countOfBytesExpectedToReceive;
    
    /**
     *  设置uploadProgress对应的cancel、pause和resume这三个状态，正好对应session task的cancel、suspend和resume三个状态
     */
    [self.uploadProgress setCancellable:YES];
    [self.uploadProgress setCancellationHandler:^{
        __typeof__(weakTask) strongTask = weakTask;
        [strongTask cancel];
    }];
    
    [self.uploadProgress setPausable:YES];
    [self.uploadProgress setPausingHandler:^{
        __typeof__(weakTask) strongTask = weakTask;
        [strongTask suspend];
    }];
    
    if ([self.uploadProgress respondsToSelector:@selector(setResumingHandler:)]) {
        [self.uploadProgress setResumingHandler:^{
            __typeof__(weakTask) strongTask = weakTask;
            [strongTask resume];
        }];
    }

    /**
     *  设置downloadProgress对应的cancel、pause和resume这三个状态，正好对应session task的cancel、suspend和resume三个状态
     */
    [self.downloadProgress setCancellable:YES];
    [self.downloadProgress setCancellationHandler:^{
        __typeof__(weakTask) strongTask = weakTask;
        [strongTask cancel];
    }];
    
    [self.downloadProgress setPausable:YES];
    [self.downloadProgress setPausingHandler:^{
        __typeof__(weakTask) strongTask = weakTask;
        [strongTask suspend];
    }];

    if ([self.downloadProgress respondsToSelector:@selector(setResumingHandler:)]) {
        [self.downloadProgress setResumingHandler:^{
            __typeof__(weakTask) strongTask = weakTask;
            [strongTask resume];
        }];
    }

    /**
     *  给session task添加KVO。使得FURLSessionManager的对象观察以下属性：
     *  NSURLSessionTask 的 countOfBytesReceived、countOfBytesExpectedToReceive、countOfBytesSent、countOfBytesExpectedToSend 属性
     */
    [task addObserver:self
           forKeyPath:NSStringFromSelector(@selector(countOfBytesReceived))
              options:NSKeyValueObservingOptionNew
              context:NULL];
    [task addObserver:self
           forKeyPath:NSStringFromSelector(@selector(countOfBytesExpectedToReceive))
              options:NSKeyValueObservingOptionNew
              context:NULL];

    [task addObserver:self
           forKeyPath:NSStringFromSelector(@selector(countOfBytesSent))
              options:NSKeyValueObservingOptionNew
              context:NULL];
    [task addObserver:self
           forKeyPath:NSStringFromSelector(@selector(countOfBytesExpectedToSend))
              options:NSKeyValueObservingOptionNew
              context:NULL];

    /**
     *  给两个progress添加KVO。使得FURLSessionManager的对象观察以下属性：
     *  NSProgress的fractionCompleted属性（任务已经完成的比例，取值为0-1）
     */
    [self.downloadProgress addObserver:self
                            forKeyPath:NSStringFromSelector(@selector(fractionCompleted))
                               options:NSKeyValueObservingOptionNew
                               context:NULL];
    [self.uploadProgress addObserver:self
                          forKeyPath:NSStringFromSelector(@selector(fractionCompleted))
                             options:NSKeyValueObservingOptionNew
                             context:NULL];
}

- (void)cleanUpProgressForTask:(NSURLSessionTask *)task {
    [task removeObserver:self forKeyPath:NSStringFromSelector(@selector(countOfBytesReceived))];
    [task removeObserver:self forKeyPath:NSStringFromSelector(@selector(countOfBytesExpectedToReceive))];
    [task removeObserver:self forKeyPath:NSStringFromSelector(@selector(countOfBytesSent))];
    [task removeObserver:self forKeyPath:NSStringFromSelector(@selector(countOfBytesExpectedToSend))];
    [self.downloadProgress removeObserver:self forKeyPath:NSStringFromSelector(@selector(fractionCompleted))];
    [self.uploadProgress removeObserver:self forKeyPath:NSStringFromSelector(@selector(fractionCompleted))];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSString *,id> *)change context:(void *)context {
    /**
     *  总结一下，也就是说:
     
     downloadProgress.completedUnitCount    《==      countOfBytesReceived更新
     downloadProgress.totalUnitCount        《==      countOfBytesExpectedToReceive更新
     uploadProgress.completedUnitCount      《==      countOfBytesSent更新
     uploadProgress.totalUnitCount          《==      countOfBytesExpectedToSend更新
     
     调用自定义的downloadProgressBlock        《==      downloadProgress.fractionCompleted更新
     调用自定义的uploadProgressBlock          《==      uploadProgress.fractionCompleted更新
     
     最后两个KVO事件中使用的block其实就是根据NSProgress的状态做用户自定义的行为，比如需要更新UI进度条的状态之类的。
     */
    if ([object isKindOfClass:[NSURLSessionTask class]] || [object isKindOfClass:[NSURLSessionDownloadTask class]]) {
        if ([keyPath isEqualToString:NSStringFromSelector(@selector(countOfBytesReceived))]) {
            self.downloadProgress.completedUnitCount = [change[NSKeyValueChangeNewKey] longLongValue];
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(countOfBytesExpectedToReceive))]) {
            self.downloadProgress.totalUnitCount = [change[NSKeyValueChangeNewKey] longLongValue];
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(countOfBytesSent))]) {
            self.uploadProgress.completedUnitCount = [change[NSKeyValueChangeNewKey] longLongValue];
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(countOfBytesExpectedToSend))]) {
            self.uploadProgress.totalUnitCount = [change[NSKeyValueChangeNewKey] longLongValue];
        }
    }
    else if ([object isEqual:self.downloadProgress]) {
        if (self.downloadProgressBlock) {
            self.downloadProgressBlock(object);
        }
    }
    else if ([object isEqual:self.uploadProgress]) {
        if (self.uploadProgressBlock) {
            self.uploadProgressBlock(object);
        }
    }
}

#pragma mark - NSURLSessionTaskDelegate

- (void)URLSession:(__unused NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
    __strong AFURLSessionManager *manager = self.manager;

    __block id responseObject = nil;

    // 因为NSNotification这个类中本身有userInfo属性，可作为响应函数的参数
    // 不过我在AFNetworking源码中还未发现使用userInfo作为参数的做法，可能需要用户自己实现
    
    /**
     * userInfo中的key值例举如下：
     * AFNetworkingTaskDidCompleteResponseDataKey session 存储task获取到的原始response数据，与序列化后的response有所不同
     * AFNetworkingTaskDidCompleteSerializedResponseKey 存储经过序列化（serialized）后的response
     * AFNetworkingTaskDidCompleteResponseSerializerKey 保存序列化response的序列化器(serializer)
     * AFNetworkingTaskDidCompleteAssetPathKey 存储下载任务后，数据文件存放在磁盘上的位置
     * AFNetworkingTaskDidCompleteErrorKey 错误信息
     */
    __block NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    // serializer
    userInfo[AFNetworkingTaskDidCompleteResponseSerializerKey] = manager.responseSerializer;

    //Performance Improvement from #2672
    // 具体可以查看#issue 2672。这里主要是针对大文件的时候，性能提升会很明显
    NSData *data = nil;
    if (self.mutableData) {
        // 要先判断是否为nil
        data = [self.mutableData copy];
        //We no longer need the reference, so nil it out to gain back some memory.
        //此处不再需要mutableData了
        self.mutableData = nil;
    }

    if (self.downloadFileURL) {
        userInfo[AFNetworkingTaskDidCompleteAssetPathKey] = self.downloadFileURL;
    } else if (data) {
        userInfo[AFNetworkingTaskDidCompleteResponseDataKey] = data;
    }

    // 如果task出错了，处理error信息
    // 所以对应的观察者在处理error的时候，比如可以先判断userInfo[AFNetworkingTaskDidCompleteErrorKey]是否有值，有值的话，就说明是要处理error
    if (error) {
        userInfo[AFNetworkingTaskDidCompleteErrorKey] = error;

        // 这里用group方式来运行task完成方法，表示当前所有的task任务完成，才会通知执行其他操作
        // 如果没有实现自定义的completionGroup和completionQueue，那么就使用AFNetworking提供的私有的dispatch_group_t和提供的dispatch_get_main_queue内容
        dispatch_group_async(manager.completionGroup ?: url_session_manager_completion_group(), manager.completionQueue ?: dispatch_get_main_queue(), ^{
            if (self.completionHandler) {
                self.completionHandler(task.response, responseObject, error);
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingTaskDidCompleteNotification object:task userInfo:userInfo];
            });
        });
    } else {
        dispatch_async(url_session_manager_processing_queue(), ^{
            NSError *serializationError = nil;
            // 根据对应的task和data将response data解析成可用的数据格式，比如JSON serializer就将data解析成JSON格式
            responseObject = [manager.responseSerializer responseObjectForResponse:task.response data:data error:&serializationError];

            // 注意如果有downloadFileURL，意味着data存放在了磁盘上了，所以此处responseObject保存的是data存放位置，供后面completionHandler处理。没有downloadFileURL，就直接使用内存中的解析后的data数据
            if (self.downloadFileURL) {
                responseObject = self.downloadFileURL;
            }

            if (responseObject) {
                userInfo[AFNetworkingTaskDidCompleteSerializedResponseKey] = responseObject;
            }

            // 序列化的时候出现错误
            if (serializationError) {
                userInfo[AFNetworkingTaskDidCompleteErrorKey] = serializationError;
            }

            // 同上面的代码
            dispatch_group_async(manager.completionGroup ?: url_session_manager_completion_group(), manager.completionQueue ?: dispatch_get_main_queue(), ^{
                if (self.completionHandler) {
                    self.completionHandler(task.response, responseObject, serializationError);
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingTaskDidCompleteNotification object:task userInfo:userInfo];
                });
            });
        });
    }
}

#pragma mark - NSURLSessionDataTaskDelegate

- (void)URLSession:(__unused NSURLSession *)session
          dataTask:(__unused NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data
{
    [self.mutableData appendData:data];
}

#pragma mark - NSURLSessionDownloadTaskDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location
{
    NSError *fileManagerError = nil;
    self.downloadFileURL = nil;

    if (self.downloadTaskDidFinishDownloading) {
        self.downloadFileURL = self.downloadTaskDidFinishDownloading(session, downloadTask, location);
        if (self.downloadFileURL) {
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:self.downloadFileURL error:&fileManagerError];

            if (fileManagerError) {
                [[NSNotificationCenter defaultCenter] postNotificationName:AFURLSessionDownloadTaskDidFailToMoveFileNotification object:downloadTask userInfo:fileManagerError.userInfo];
            }
        }
    }
}

@end

#pragma mark -

/**
 *  A workaround for issues related to key-value observing the `state` of an `NSURLSessionTask`.
 *
 *  See:
 *  - https://github.com/AFNetworking/AFNetworking/issues/1477
 *  - https://github.com/AFNetworking/AFNetworking/issues/2638
 *  - https://github.com/AFNetworking/AFNetworking/pull/2702
 */

static inline void af_swizzleSelector(Class theClass, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getInstanceMethod(theClass, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(theClass, swizzledSelector);
    method_exchangeImplementations(originalMethod, swizzledMethod);
}

static inline BOOL af_addMethod(Class theClass, SEL selector, Method method) {
    return class_addMethod(theClass, selector,  method_getImplementation(method),  method_getTypeEncoding(method));
}

static NSString * const AFNSURLSessionTaskDidResumeNotification  = @"com.alamofire.networking.nsurlsessiontask.resume";
static NSString * const AFNSURLSessionTaskDidSuspendNotification = @"com.alamofire.networking.nsurlsessiontask.suspend";

@interface _AFURLSessionTaskSwizzling : NSObject

@end

@implementation _AFURLSessionTaskSwizzling

+ (void)load {
    /**
     WARNING: Trouble Ahead
     https://github.com/AFNetworking/AFNetworking/pull/2702
     */

    if (NSClassFromString(@"NSURLSessionTask")) {
        /**
         iOS 7 and iOS 8 differ in NSURLSessionTask implementation, which makes the next bit of code a bit tricky.
         Many Unit Tests have been built to validate as much of this behavior has possible.
         Here is what we know:
            - NSURLSessionTasks are implemented with class clusters, meaning the class you request from the API isn't actually the type of class you will get back.
            - Simply referencing `[NSURLSessionTask class]` will not work. You need to ask an `NSURLSession` to actually create an object, and grab the class from there.
            - On iOS 7, `localDataTask` is a `__NSCFLocalDataTask`, which inherits from `__NSCFLocalSessionTask`, which inherits from `__NSCFURLSessionTask`.
            - On iOS 8, `localDataTask` is a `__NSCFLocalDataTask`, which inherits from `__NSCFLocalSessionTask`, which inherits from `NSURLSessionTask`.
            - On iOS 7, `__NSCFLocalSessionTask` and `__NSCFURLSessionTask` are the only two classes that have their own implementations of `resume` and `suspend`, and `__NSCFLocalSessionTask` DOES NOT CALL SUPER. This means both classes need to be swizzled.
            - On iOS 8, `NSURLSessionTask` is the only class that implements `resume` and `suspend`. This means this is the only class that needs to be swizzled.
            - Because `NSURLSessionTask` is not involved in the class hierarchy for every version of iOS, its easier to add the swizzled methods to a dummy class and manage them there.
        
         Some Assumptions:
            - No implementations of `resume` or `suspend` call super. If this were to change in a future version of iOS, we'd need to handle it.
            - No background task classes override `resume` or `suspend`
         
         The current solution:
            1) Grab an instance of `__NSCFLocalDataTask` by asking an instance of `NSURLSession` for a data task.
            2) Grab a pointer to the original implementation of `af_resume`
            3) Check to see if the current class has an implementation of resume. If so, continue to step 4.
            4) Grab the super class of the current class.
            5) Grab a pointer for the current class to the current implementation of `resume`.
            6) Grab a pointer for the super class to the current implementation of `resume`.
            7) If the current class implementation of `resume` is not equal to the super class implementation of `resume` AND the current implementation of `resume` is not equal to the original implementation of `af_resume`, THEN swizzle the methods
            8) Set the current class to the super class, and repeat steps 3-8
         */
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        NSURLSession * session = [NSURLSession sessionWithConfiguration:configuration];
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wnonnull"
        NSURLSessionDataTask *localDataTask = [session dataTaskWithURL:nil];
#pragma clang diagnostic pop
        IMP originalAFResumeIMP = method_getImplementation(class_getInstanceMethod([self class], @selector(af_resume)));
        Class currentClass = [localDataTask class];
        
        while (class_getInstanceMethod(currentClass, @selector(resume))) {
            Class superClass = [currentClass superclass];
            IMP classResumeIMP = method_getImplementation(class_getInstanceMethod(currentClass, @selector(resume)));
            IMP superclassResumeIMP = method_getImplementation(class_getInstanceMethod(superClass, @selector(resume)));
            if (classResumeIMP != superclassResumeIMP &&
                originalAFResumeIMP != classResumeIMP) {
                [self swizzleResumeAndSuspendMethodForClass:currentClass];
            }
            currentClass = [currentClass superclass];
        }
        
        [localDataTask cancel];
        [session finishTasksAndInvalidate];
    }
}

+ (void)swizzleResumeAndSuspendMethodForClass:(Class)theClass {
    Method afResumeMethod = class_getInstanceMethod(self, @selector(af_resume));
    Method afSuspendMethod = class_getInstanceMethod(self, @selector(af_suspend));

    if (af_addMethod(theClass, @selector(af_resume), afResumeMethod)) {
        af_swizzleSelector(theClass, @selector(resume), @selector(af_resume));
    }

    if (af_addMethod(theClass, @selector(af_suspend), afSuspendMethod)) {
        af_swizzleSelector(theClass, @selector(suspend), @selector(af_suspend));
    }
}

- (NSURLSessionTaskState)state {
    NSAssert(NO, @"State method should never be called in the actual dummy class");
    return NSURLSessionTaskStateCanceling;
}

- (void)af_resume {
    NSAssert([self respondsToSelector:@selector(state)], @"Does not respond to state");
    NSURLSessionTaskState state = [self state];
    [self af_resume];
    
    if (state != NSURLSessionTaskStateRunning) {
        [[NSNotificationCenter defaultCenter] postNotificationName:AFNSURLSessionTaskDidResumeNotification object:self];
    }
}

- (void)af_suspend {
    NSAssert([self respondsToSelector:@selector(state)], @"Does not respond to state");
    NSURLSessionTaskState state = [self state];
    [self af_suspend];
    
    if (state != NSURLSessionTaskStateSuspended) {
        [[NSNotificationCenter defaultCenter] postNotificationName:AFNSURLSessionTaskDidSuspendNotification object:self];
    }
}
@end

#pragma mark -

@interface AFURLSessionManager ()
@property (readwrite, nonatomic, strong) NSURLSessionConfiguration *sessionConfiguration;
@property (readwrite, nonatomic, strong) NSOperationQueue *operationQueue;
@property (readwrite, nonatomic, strong) NSURLSession *session;
@property (readwrite, nonatomic, strong) NSMutableDictionary *mutableTaskDelegatesKeyedByTaskIdentifier;
@property (readonly, nonatomic, copy) NSString *taskDescriptionForSessionTasks;
@property (readwrite, nonatomic, strong) NSLock *lock;
@property (readwrite, nonatomic, copy) AFURLSessionDidBecomeInvalidBlock sessionDidBecomeInvalid;
@property (readwrite, nonatomic, copy) AFURLSessionDidReceiveAuthenticationChallengeBlock sessionDidReceiveAuthenticationChallenge;
@property (readwrite, nonatomic, copy) AFURLSessionDidFinishEventsForBackgroundURLSessionBlock didFinishEventsForBackgroundURLSession;
@property (readwrite, nonatomic, copy) AFURLSessionTaskWillPerformHTTPRedirectionBlock taskWillPerformHTTPRedirection;
@property (readwrite, nonatomic, copy) AFURLSessionTaskDidReceiveAuthenticationChallengeBlock taskDidReceiveAuthenticationChallenge;
@property (readwrite, nonatomic, copy) AFURLSessionTaskNeedNewBodyStreamBlock taskNeedNewBodyStream;
@property (readwrite, nonatomic, copy) AFURLSessionTaskDidSendBodyDataBlock taskDidSendBodyData;
@property (readwrite, nonatomic, copy) AFURLSessionTaskDidCompleteBlock taskDidComplete;
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskDidReceiveResponseBlock dataTaskDidReceiveResponse;
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskDidBecomeDownloadTaskBlock dataTaskDidBecomeDownloadTask;
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskDidReceiveDataBlock dataTaskDidReceiveData;
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskWillCacheResponseBlock dataTaskWillCacheResponse;
@property (readwrite, nonatomic, copy) AFURLSessionDownloadTaskDidFinishDownloadingBlock downloadTaskDidFinishDownloading;
@property (readwrite, nonatomic, copy) AFURLSessionDownloadTaskDidWriteDataBlock downloadTaskDidWriteData;
@property (readwrite, nonatomic, copy) AFURLSessionDownloadTaskDidResumeBlock downloadTaskDidResume;
@end

@implementation AFURLSessionManager

- (instancetype)init {
    return [self initWithSessionConfiguration:nil];
}

- (instancetype)initWithSessionConfiguration:(NSURLSessionConfiguration *)configuration {
    self = [super init];
    if (!self) {
        return nil;
    }

    if (!configuration) {
        configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    }

    self.sessionConfiguration = configuration;

    /** 创建了一个操作队列 */
    self.operationQueue = [[NSOperationQueue alloc] init];
    /** 赋值操作队列的最大并发操作数为1 */
    self.operationQueue.maxConcurrentOperationCount = 1;
    /** 用该操作队列来初始化NSURLSession */
    self.session = [NSURLSession sessionWithConfiguration:self.sessionConfiguration delegate:self delegateQueue:self.operationQueue];

    self.responseSerializer = [AFJSONResponseSerializer serializer];

    self.securityPolicy = [AFSecurityPolicy defaultPolicy];

#if !TARGET_OS_WATCH
    self.reachabilityManager = [AFNetworkReachabilityManager sharedManager];
#endif

    self.mutableTaskDelegatesKeyedByTaskIdentifier = [[NSMutableDictionary alloc] init];

    self.lock = [[NSLock alloc] init];
    self.lock.name = AFURLSessionManagerLockName;

    [self.session getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        for (NSURLSessionDataTask *task in dataTasks) {
            [self addDelegateForDataTask:task uploadProgress:nil downloadProgress:nil completionHandler:nil];
        }

        for (NSURLSessionUploadTask *uploadTask in uploadTasks) {
            [self addDelegateForUploadTask:uploadTask progress:nil completionHandler:nil];
        }

        for (NSURLSessionDownloadTask *downloadTask in downloadTasks) {
            [self addDelegateForDownloadTask:downloadTask progress:nil destination:nil completionHandler:nil];
        }
    }];

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark -

- (NSString *)taskDescriptionForSessionTasks {
    return [NSString stringWithFormat:@"%p", self];
}

- (void)taskDidResume:(NSNotification *)notification {
    NSURLSessionTask *task = notification.object;
    if ([task respondsToSelector:@selector(taskDescription)]) {
        if ([task.taskDescription isEqualToString:self.taskDescriptionForSessionTasks]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingTaskDidResumeNotification object:task];
            });
        }
    }
}

- (void)taskDidSuspend:(NSNotification *)notification {
    NSURLSessionTask *task = notification.object;
    if ([task respondsToSelector:@selector(taskDescription)]) {
        if ([task.taskDescription isEqualToString:self.taskDescriptionForSessionTasks]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingTaskDidSuspendNotification object:task];
            });
        }
    }
}

#pragma mark -

- (AFURLSessionManagerTaskDelegate *)delegateForTask:(NSURLSessionTask *)task {
    NSParameterAssert(task);

    AFURLSessionManagerTaskDelegate *delegate = nil;
    [self.lock lock];
    delegate = self.mutableTaskDelegatesKeyedByTaskIdentifier[@(task.taskIdentifier)];
    [self.lock unlock];

    return delegate;
}

- (void)setDelegate:(AFURLSessionManagerTaskDelegate *)delegate
            forTask:(NSURLSessionTask *)task
{
    /** 首先是基本的判断，判断session task和delegate是否为空 */
    NSParameterAssert(task);
    NSParameterAssert(delegate);

    /**
     *  使用NSLock来加锁，这个很简单，和@synchronized作用类似，不过@synchronized多了一个可以使用变量作为互斥信号量的功能
     */
    [self.lock lock];
    /** 以该session task的taskIdentifier为key，delegate为value，赋值给mutableTaskDelegatesKeyedByTaskIdentifier(NSMutableDictionary类型的变量) */
    self.mutableTaskDelegatesKeyedByTaskIdentifier[@(task.taskIdentifier)] = delegate;
    [delegate setupProgressForTask:task];
    [self addNotificationObserverForTask:task];
    [self.lock unlock];
}

- (void)addDelegateForDataTask:(NSURLSessionDataTask *)dataTask
                uploadProgress:(nullable void (^)(NSProgress *uploadProgress)) uploadProgressBlock
              downloadProgress:(nullable void (^)(NSProgress *downloadProgress)) downloadProgressBlock
             completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    AFURLSessionManagerTaskDelegate *delegate = [[AFURLSessionManagerTaskDelegate alloc] init];
    delegate.manager = self;
    delegate.completionHandler = completionHandler;

    dataTask.taskDescription = self.taskDescriptionForSessionTasks;
    /** 关键代码：将一个session task和一个AFURLSessionManagerTaskDelegate类型的delegate变量绑在一起 */
    [self setDelegate:delegate forTask:dataTask];

    delegate.uploadProgressBlock = uploadProgressBlock;
    delegate.downloadProgressBlock = downloadProgressBlock;
}

- (void)addDelegateForUploadTask:(NSURLSessionUploadTask *)uploadTask
                        progress:(void (^)(NSProgress *uploadProgress)) uploadProgressBlock
               completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    AFURLSessionManagerTaskDelegate *delegate = [[AFURLSessionManagerTaskDelegate alloc] init];
    delegate.manager = self;
    delegate.completionHandler = completionHandler;

    uploadTask.taskDescription = self.taskDescriptionForSessionTasks;

    [self setDelegate:delegate forTask:uploadTask];

    delegate.uploadProgressBlock = uploadProgressBlock;
}

- (void)addDelegateForDownloadTask:(NSURLSessionDownloadTask *)downloadTask
                          progress:(void (^)(NSProgress *downloadProgress)) downloadProgressBlock
                       destination:(NSURL * (^)(NSURL *targetPath, NSURLResponse *response))destination
                 completionHandler:(void (^)(NSURLResponse *response, NSURL *filePath, NSError *error))completionHandler
{
    AFURLSessionManagerTaskDelegate *delegate = [[AFURLSessionManagerTaskDelegate alloc] init];
    delegate.manager = self;
    delegate.completionHandler = completionHandler;

    if (destination) {
        delegate.downloadTaskDidFinishDownloading = ^NSURL * (NSURLSession * __unused session, NSURLSessionDownloadTask *task, NSURL *location) {
            return destination(location, task.response);
        };
    }

    downloadTask.taskDescription = self.taskDescriptionForSessionTasks;

    [self setDelegate:delegate forTask:downloadTask];

    delegate.downloadProgressBlock = downloadProgressBlock;
}

- (void)removeDelegateForTask:(NSURLSessionTask *)task {
    NSParameterAssert(task);

    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:task];
    [self.lock lock];
    [delegate cleanUpProgressForTask:task];
    [self removeNotificationObserverForTask:task];
    [self.mutableTaskDelegatesKeyedByTaskIdentifier removeObjectForKey:@(task.taskIdentifier)];
    [self.lock unlock];
}

#pragma mark -

- (NSArray *)tasksForKeyPath:(NSString *)keyPath {
    __block NSArray *tasks = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self.session getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        if ([keyPath isEqualToString:NSStringFromSelector(@selector(dataTasks))]) {
            tasks = dataTasks;
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(uploadTasks))]) {
            tasks = uploadTasks;
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(downloadTasks))]) {
            tasks = downloadTasks;
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(tasks))]) {
            tasks = [@[dataTasks, uploadTasks, downloadTasks] valueForKeyPath:@"@unionOfArrays.self"];
        }

        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    return tasks;
}

- (NSArray *)tasks {
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

- (NSArray *)dataTasks {
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

- (NSArray *)uploadTasks {
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

- (NSArray *)downloadTasks {
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

#pragma mark -

- (void)invalidateSessionCancelingTasks:(BOOL)cancelPendingTasks {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (cancelPendingTasks) {
            [self.session invalidateAndCancel];
        } else {
            [self.session finishTasksAndInvalidate];
        }
    });
}

#pragma mark -

- (void)setResponseSerializer:(id <AFURLResponseSerialization>)responseSerializer {
    NSParameterAssert(responseSerializer);

    _responseSerializer = responseSerializer;
}

#pragma mark -
- (void)addNotificationObserverForTask:(NSURLSessionTask *)task {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(taskDidResume:) name:AFNSURLSessionTaskDidResumeNotification object:task];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(taskDidSuspend:) name:AFNSURLSessionTaskDidSuspendNotification object:task];
}

- (void)removeNotificationObserverForTask:(NSURLSessionTask *)task {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AFNSURLSessionTaskDidSuspendNotification object:task];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AFNSURLSessionTaskDidResumeNotification object:task];
}

#pragma mark -

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    return [self dataTaskWithRequest:request uploadProgress:nil downloadProgress:nil completionHandler:completionHandler];
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                               uploadProgress:(nullable void (^)(NSProgress *uploadProgress)) uploadProgressBlock
                             downloadProgress:(nullable void (^)(NSProgress *downloadProgress)) downloadProgressBlock
                            completionHandler:(nullable void (^)(NSURLResponse *response, id _Nullable responseObject,  NSError * _Nullable error))completionHandler {
    /** 创建一个dataTask */
    __block NSURLSessionDataTask *dataTask = nil;
    url_session_manager_create_task_safely(^{
        dataTask = [self.session dataTaskWithRequest:request];
    });

    /** 调用addDelegateForDataTask函数 */
    [self addDelegateForDataTask:dataTask uploadProgress:uploadProgressBlock downloadProgress:downloadProgressBlock completionHandler:completionHandler];

    return dataTask;
}

#pragma mark -

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromFile:(NSURL *)fileURL
                                         progress:(void (^)(NSProgress *uploadProgress)) uploadProgressBlock
                                completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    __block NSURLSessionUploadTask *uploadTask = nil;
    url_session_manager_create_task_safely(^{
        uploadTask = [self.session uploadTaskWithRequest:request fromFile:fileURL];
    });

    // uploadTask may be nil on iOS7 because uploadTaskWithRequest:fromFile: may return nil despite being documented as nonnull (https://devforums.apple.com/message/926113#926113)
    if (!uploadTask && self.attemptsToRecreateUploadTasksForBackgroundSessions && self.session.configuration.identifier) {
        for (NSUInteger attempts = 0; !uploadTask && attempts < AFMaximumNumberOfAttemptsToRecreateBackgroundSessionUploadTask; attempts++) {
            uploadTask = [self.session uploadTaskWithRequest:request fromFile:fileURL];
        }
    }

    [self addDelegateForUploadTask:uploadTask progress:uploadProgressBlock completionHandler:completionHandler];

    return uploadTask;
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData
                                         progress:(void (^)(NSProgress *uploadProgress)) uploadProgressBlock
                                completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    __block NSURLSessionUploadTask *uploadTask = nil;
    url_session_manager_create_task_safely(^{
        uploadTask = [self.session uploadTaskWithRequest:request fromData:bodyData];
    });

    [self addDelegateForUploadTask:uploadTask progress:uploadProgressBlock completionHandler:completionHandler];

    return uploadTask;
}

- (NSURLSessionUploadTask *)uploadTaskWithStreamedRequest:(NSURLRequest *)request
                                                 progress:(void (^)(NSProgress *uploadProgress)) uploadProgressBlock
                                        completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    __block NSURLSessionUploadTask *uploadTask = nil;
    url_session_manager_create_task_safely(^{
        uploadTask = [self.session uploadTaskWithStreamedRequest:request];
    });

    [self addDelegateForUploadTask:uploadTask progress:uploadProgressBlock completionHandler:completionHandler];

    return uploadTask;
}

#pragma mark -

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request
                                             progress:(void (^)(NSProgress *downloadProgress)) downloadProgressBlock
                                          destination:(NSURL * (^)(NSURL *targetPath, NSURLResponse *response))destination
                                    completionHandler:(void (^)(NSURLResponse *response, NSURL *filePath, NSError *error))completionHandler
{
    __block NSURLSessionDownloadTask *downloadTask = nil;
    url_session_manager_create_task_safely(^{
        downloadTask = [self.session downloadTaskWithRequest:request];
    });

    [self addDelegateForDownloadTask:downloadTask progress:downloadProgressBlock destination:destination completionHandler:completionHandler];

    return downloadTask;
}

- (NSURLSessionDownloadTask *)downloadTaskWithResumeData:(NSData *)resumeData
                                                progress:(void (^)(NSProgress *downloadProgress)) downloadProgressBlock
                                             destination:(NSURL * (^)(NSURL *targetPath, NSURLResponse *response))destination
                                       completionHandler:(void (^)(NSURLResponse *response, NSURL *filePath, NSError *error))completionHandler
{
    __block NSURLSessionDownloadTask *downloadTask = nil;
    url_session_manager_create_task_safely(^{
        downloadTask = [self.session downloadTaskWithResumeData:resumeData];
    });

    [self addDelegateForDownloadTask:downloadTask progress:downloadProgressBlock destination:destination completionHandler:completionHandler];

    return downloadTask;
}

#pragma mark -
- (NSProgress *)uploadProgressForTask:(NSURLSessionTask *)task {
    return [[self delegateForTask:task] uploadProgress];
}

- (NSProgress *)downloadProgressForTask:(NSURLSessionTask *)task {
    return [[self delegateForTask:task] downloadProgress];
}

#pragma mark -

- (void)setSessionDidBecomeInvalidBlock:(void (^)(NSURLSession *session, NSError *error))block {
    self.sessionDidBecomeInvalid = block;
}

- (void)setSessionDidReceiveAuthenticationChallengeBlock:(NSURLSessionAuthChallengeDisposition (^)(NSURLSession *session, NSURLAuthenticationChallenge *challenge, NSURLCredential * __autoreleasing *credential))block {
    self.sessionDidReceiveAuthenticationChallenge = block;
}

- (void)setDidFinishEventsForBackgroundURLSessionBlock:(void (^)(NSURLSession *session))block {
    self.didFinishEventsForBackgroundURLSession = block;
}

#pragma mark -

- (void)setTaskNeedNewBodyStreamBlock:(NSInputStream * (^)(NSURLSession *session, NSURLSessionTask *task))block {
    self.taskNeedNewBodyStream = block;
}

- (void)setTaskWillPerformHTTPRedirectionBlock:(NSURLRequest * (^)(NSURLSession *session, NSURLSessionTask *task, NSURLResponse *response, NSURLRequest *request))block {
    self.taskWillPerformHTTPRedirection = block;
}

- (void)setTaskDidReceiveAuthenticationChallengeBlock:(NSURLSessionAuthChallengeDisposition (^)(NSURLSession *session, NSURLSessionTask *task, NSURLAuthenticationChallenge *challenge, NSURLCredential * __autoreleasing *credential))block {
    self.taskDidReceiveAuthenticationChallenge = block;
}

- (void)setTaskDidSendBodyDataBlock:(void (^)(NSURLSession *session, NSURLSessionTask *task, int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend))block {
    self.taskDidSendBodyData = block;
}

- (void)setTaskDidCompleteBlock:(void (^)(NSURLSession *session, NSURLSessionTask *task, NSError *error))block {
    self.taskDidComplete = block;
}

#pragma mark -

- (void)setDataTaskDidReceiveResponseBlock:(NSURLSessionResponseDisposition (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLResponse *response))block {
    self.dataTaskDidReceiveResponse = block;
}

- (void)setDataTaskDidBecomeDownloadTaskBlock:(void (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLSessionDownloadTask *downloadTask))block {
    self.dataTaskDidBecomeDownloadTask = block;
}

- (void)setDataTaskDidReceiveDataBlock:(void (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data))block {
    self.dataTaskDidReceiveData = block;
}

- (void)setDataTaskWillCacheResponseBlock:(NSCachedURLResponse * (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSCachedURLResponse *proposedResponse))block {
    self.dataTaskWillCacheResponse = block;
}

#pragma mark -

- (void)setDownloadTaskDidFinishDownloadingBlock:(NSURL * (^)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, NSURL *location))block {
    self.downloadTaskDidFinishDownloading = block;
}

- (void)setDownloadTaskDidWriteDataBlock:(void (^)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite))block {
    self.downloadTaskDidWriteData = block;
}

- (void)setDownloadTaskDidResumeBlock:(void (^)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t fileOffset, int64_t expectedTotalBytes))block {
    self.downloadTaskDidResume = block;
}

#pragma mark - NSObject
/**
 *  重写该类的 description 方法
 */
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, session: %@, operationQueue: %@>", NSStringFromClass([self class]), self, self.session, self.operationQueue];
}

- (BOOL)respondsToSelector:(SEL)selector {
    if (selector == @selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)) {
        return self.taskWillPerformHTTPRedirection != nil;
    } else if (selector == @selector(URLSession:dataTask:didReceiveResponse:completionHandler:)) {
        return self.dataTaskDidReceiveResponse != nil;
    } else if (selector == @selector(URLSession:dataTask:willCacheResponse:completionHandler:)) {
        return self.dataTaskWillCacheResponse != nil;
    } else if (selector == @selector(URLSessionDidFinishEventsForBackgroundURLSession:)) {
        return self.didFinishEventsForBackgroundURLSession != nil;
    }

    return [[self class] instancesRespondToSelector:selector];
}

#pragma mark - NSURLSessionDelegate
/**
 *  当前这个session已经失效时，该代理方法被调用
 */
- (void)URLSession:(NSURLSession *)session
didBecomeInvalidWithError:(NSError *)error
{
    // sessionDidBecomeInvalid 是自定义的一个block，用来处理session无效的情况。
    // 此处插一句，刚才突然灵光一现，体验到了block的好处：
    // 此处并不是让用户自己实现didBecomeInvalidWithError:方法，
    // 而是让用户实现sessionDidBecomeInvalid这个block，隐藏细节。
    // 确实很妙，以后要学会使用block！
    if (self.sessionDidBecomeInvalid) {
        self.sessionDidBecomeInvalid(session, error);
    }

    // 当一个session无效时，post名为AFURLSessionDidInvalidateNotification的Notification
    // 不过源代码中没有举例如何使用这个Notification，所以需要用户自己定义，比如结束进度条的显示啊
    [[NSNotificationCenter defaultCenter] postNotificationName:AFURLSessionDidInvalidateNotification object:session];
}


/**
 *  web服务器接收到客户端请求时，有时候需要先验证客户端是否为正常用户，再决定是够返回真实数据。这种情况称之为服务端要求客户端接收挑战（NSURLAuthenticationChallenge *challenge）。接收到挑战后，客户端要根据服务端传来的challenge来生成completionHandler所需的NSURLSessionAuthChallengeDisposition disposition 和 NSURLCredential *credential（disposition指定应对这个挑战的方法，而credential是客户端生成的挑战证书，注意只有challenge中认证方法为 NSURLAuthenticationMethodServerTrust 的时候，才需要生成挑战证书）。最后调用completionHandler回应服务器端的挑战。
 
     该代理方法会在下面两种情况调用：
     1. 当服务器端要求客户端提供证书时或者进行NTLM认证（Windows NT LAN Manager，微软提出的WindowsNT挑战/响应验证机制）时，此方法允许你的app提供正确的挑战证书。
     2. 当某个session使用SSL/TLS协议，第一次和服务器端建立连接的时候，服务器会发送给iOS客户端一个证书，此方法允许你的app验证服务期端的证书链（certificate keychain）
 
     如果你没有实现该方法，该session会调用其NSURLSessionTaskDelegate的代理方法URLSession:task:didReceiveChallenge:completionHandler:
 */
- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
    //挑战处理类型为 默认
    /*
     NSURLSessionAuthChallengePerformDefaultHandling：默认方式处理
     NSURLSessionAuthChallengeUseCredential：使用指定的证书
     NSURLSessionAuthChallengeCancelAuthenticationChallenge：取消挑战
     */
    NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
    __block NSURLCredential *credential = nil;
    
    // sessionDidReceiveAuthenticationChallenge是自定义方法，用来如何应对服务器端的认证挑战
    if (self.sessionDidReceiveAuthenticationChallenge) {
        disposition = self.sessionDidReceiveAuthenticationChallenge(session, challenge, &credential);
    } else {
        // 此处服务器要求客户端的接收认证挑战方法是 NSURLAuthenticationMethodServerTrust
        // 也就是说服务器端需要客户端返回一个根据认证挑战的保护空间提供的信任（即challenge.protectionSpace.serverTrust）产生的挑战证书
        // 而这个证书就需要使用credentialForTrust:来创建一个NSURLCredential对象
        if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
            // 基于客户端的安全策略来决定是否信任该服务器，不信任的话，也就没必要响应挑战
            if ([self.securityPolicy evaluateServerTrust:challenge.protectionSpace.serverTrust forDomain:challenge.protectionSpace.host]) {
                // 创建挑战证书（注：挑战方式为 UseCredential 和 PerformDefaultHandling 都需要新建挑战证书）
                credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
                if (credential) {
                    // 确定挑战处理的方式
                    disposition = NSURLSessionAuthChallengeUseCredential;   /**< 使用指定的证书 */
                } else {
                    disposition = NSURLSessionAuthChallengePerformDefaultHandling;  /**< 默认方式处理 */
                }
            } else {
                disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;   /**< 取消挑战 */
            }
        } else {
            disposition = NSURLSessionAuthChallengePerformDefaultHandling;  /**< 默认方式处理 */
        }
    }

    // 必须调用此方法，完成认证挑战
    if (completionHandler) {
        completionHandler(disposition, credential);
    }
}

/**
 *  当session中所有已经入队的消息被发送出去后，会调用该代理方法。
 */
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    if (self.didFinishEventsForBackgroundURLSession) {
        // 意味着background session中的消息已经全部发送出去了，返回到主进程执行自定义的函数
        dispatch_async(dispatch_get_main_queue(), ^{
            self.didFinishEventsForBackgroundURLSession(session);
        });
    }
}

#pragma mark - NSURLSessionTaskDelegate
/**
 *  客户端告知服务器端需要HTTP重定向
    此方法只会在default session或者ephemeral session中调用，而在background session中，session task会自动重定向
 
     知识点:
     对于NSURLSession对象的初始化需要使用NSURLSessionConfiguration，而NSURLSessionConfiguration有三个类工厂方法：
     
     +defaultSessionConfiguration 返回一个标准的 configuration，这个配置实际上与 NSURLConnection 的网络堆栈（networking stack）是一样的，具有相同的共享 NSHTTPCookieStorage，共享 NSURLCache 和共享NSURLCredentialStorage。
     
     +ephemeralSessionConfiguration 返回一个预设配置，这个配置中不会对缓存，Cookie 和证书进行持久性的存储。这对于实现像秘密浏览这种功能来说是很理想的。
     
     +backgroundSessionConfiguration:(NSString *)identifier 的独特之处在于，它会创建一个后台 session。后台 session 不同于常规的，普通的 session，它甚至可以在应用程序挂起，退出或者崩溃的情况下运行上传和下载任务。初始化时指定的标识符，被用于向任何可能在进程外恢复后台传输的守护进程（daemon）提供上下文。
 */
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler
{
    NSURLRequest *redirectRequest = request;
    // 自定义如何处理重定向请求，注意会生成一个新的request
    if (self.taskWillPerformHTTPRedirection) {
        redirectRequest = self.taskWillPerformHTTPRedirection(session, task, response, request);
    }

    if (completionHandler) {
        completionHandler(redirectRequest);
    }
}

/**
 *   函数作用：
     同NSURLSessionDelegate中的 - URLSession:didReceiveChallenge:completionHandler:
     
     函数讨论：
     该方法是处理task-level的认证挑战。在NSURLSessionDelegate中提供了一个session-level的认证挑战代理方法。该方法的调用取决于认证挑战的类型：
     对于session-level的认证挑战，挑战类型有 — NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodClientCertificate, 或NSURLAuthenticationMethodServerTrust — 此时session会调用其代理方法URLSession:didReceiveChallenge:completionHandler:。如果你的app没有提供对应的NSURLSessionDelegate方法，那么NSURLSession对象就会调用URLSession:task:didReceiveChallenge:completionHandler:来处理认证挑战。
     对于non-session-level的认证挑战，NSURLSession对象调用URLSession:task:didReceiveChallenge:completionHandler:来处理认证挑战。如果你在app中使用了session代理方法，而且也确实要处理认证挑战这个问题，那么你必须还是在task level来处理这个问题，或者提供一个task-level的handler来显式调用每个session的handler。而对于non-session-level的认证挑战，session的delegate中的URLSession:didReceiveChallenge:completionHandler:方法不会被调用。
 
     函数实现：
     参考URLSession:didReceiveChallenge:completionHandler:实现，除了自定义了taskDidReceiveAuthenticationChallenge这个block处理task-level的认证挑战，其他都一样。
 */
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
    NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
    __block NSURLCredential *credential = nil;

    /** URLSession:didReceiveChallenge:completionHandler: 里面这里是： sessionDidReceiveAuthenticationChallenge
     */
    if (self.taskDidReceiveAuthenticationChallenge) {
        disposition = self.taskDidReceiveAuthenticationChallenge(session, task, challenge, &credential);
    } else {
        if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
            if ([self.securityPolicy evaluateServerTrust:challenge.protectionSpace.serverTrust forDomain:challenge.protectionSpace.host]) {
                disposition = NSURLSessionAuthChallengeUseCredential;
                credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
            } else {
                disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
            }
        } else {
            disposition = NSURLSessionAuthChallengePerformDefaultHandling;
        }
    }

    if (completionHandler) {
        completionHandler(disposition, credential);
    }
}

/**
 *   函数作用：
     当一个session task需要发送一个新的request body stream到服务器端的时候，调用该代理方法。
     
     函数讨论：
     该代理方法会在下面两种情况被调用：
     如果task是由uploadTaskWithStreamedRequest:创建的，那么提供初始的request body stream时候会调用该代理方法。
     因为认证挑战或者其他可恢复的服务器错误，而导致需要客户端重新发送一个含有body stream的request，这时候会调用该代理。
 */
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
 needNewBodyStream:(void (^)(NSInputStream *bodyStream))completionHandler
{
    NSInputStream *inputStream = nil;

    if (self.taskNeedNewBodyStream) {
        // 自定义的获取到新的bodyStream方法
        inputStream = self.taskNeedNewBodyStream(session, task);
    } else if (task.originalRequest.HTTPBodyStream && [task.originalRequest.HTTPBodyStream conformsToProtocol:@protocol(NSCopying)]) {
        // 拷贝一份数据出来到新的bodyStream中（即inputStream）
        inputStream = [task.originalRequest.HTTPBodyStream copy];
    }

    if (completionHandler) {
        completionHandler(inputStream);
    }
}

/**
 *   函数作用：
     周期性地通知代理发送到服务器端数据的进度。
 */
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend
{
    int64_t totalUnitCount = totalBytesExpectedToSend;
    if(totalUnitCount == NSURLSessionTransferSizeUnknown) {
        // 如果totalUnitCount获取失败，就使用HTTP header中的Content-Length作为totalUnitCount
        NSString *contentLength = [task.originalRequest valueForHTTPHeaderField:@"Content-Length"];
        if(contentLength) {
            totalUnitCount = (int64_t) [contentLength longLongValue];
        }
    }
    // 每次发送数据后的相关自定义处理，比如根据totalBytesSent来进行UI界面的数据上传显示
    if (self.taskDidSendBodyData) {
        self.taskDidSendBodyData(session, task, bytesSent, totalBytesSent, totalUnitCount);
    }
}

/**
 *   函数作用：
     告知该session task已经完成了数据传输任务。
     
     函数讨论：
     注意这里的error不会报告服务器端的error，他表示的是客户端这边的error，比如无法解析hostname或者连不上host主机
 */
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
    // 这里第一次展示了AFURLSessionManagerTaskDelegate的作用
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:task];

    // delegate may be nil when completing a task in the background
    // 如果task是在后台完成的，可能delegate会为nil
    if (delegate) {
        // 调用了一样的代理方法，不过是AFURLSessionManagerTaskDelegate中实现的
        [delegate URLSession:session task:task didCompleteWithError:error];
        // 该task结束了，就移除对应的delegate
        [self removeDelegateForTask:task];
    }
    // 自定义处理方法
    if (self.taskDidComplete) {
        self.taskDidComplete(session, task, error);
    }
}

#pragma mark - NSURLSessionDataDelegate

/**
 *   函数作用：
     告诉代理，该data task获取到了服务器端传回的最初始回复（response）。注意其中的completionHandler这个block，通过传入一个类型为NSURLSessionResponseDisposition的变量来决定该传输任务接下来该做什么：
     NSURLSessionResponseAllow 该task正常进行
     NSURLSessionResponseCancel 该task会被取消
     NSURLSessionResponseBecomeDownload 会调用 URLSession:dataTask:didBecomeDownloadTask: 方法(就是下面那个方法)来新建一个download task以代替当前的 data task
 
     函数讨论：
     该方法是可选的，除非你必须支持“multipart/x-mixed-replace”类型的content-type。因为如果你的request中包含了这种类型的content-type，服务器会将数据分片传回来，而且每次传回来的数据会覆盖之前的数据。每次返回新的数据时，session都会调用该函数，你应该在这个函数中合理地处理先前的数据，否则会被新数据覆盖。如果你没有提供该方法的实现，那么session将会继续任务，也就是说会覆盖之前的数据。
 */
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler
{
    NSURLSessionResponseDisposition disposition = NSURLSessionResponseAllow;

    if (self.dataTaskDidReceiveResponse) {
        disposition = self.dataTaskDidReceiveResponse(session, dataTask, response);
    }

    if (completionHandler) {
        completionHandler(disposition);
    }
}

/**
 *   函数作用：
     如果data task变化成了下载任务（download task），那么就会调用该代理方法
     
     函数讨论：
     比如在- URLSession:dataTask:didReceiveResponse:completionHandler:给completionHandler方法传递NSURLSessionResponseBecomeDownload，就会使data task变成download task。而且之前的data task不会再响应代理方法了
 */
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didBecomeDownloadTask:(NSURLSessionDownloadTask *)downloadTask
{
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:dataTask];
    if (delegate) {
        // 将delegate关联的data task移除，换成新产生的download task
        [self removeDelegateForTask:dataTask];
        [self setDelegate:delegate forTask:downloadTask];
    }
    // 自定义
    if (self.dataTaskDidBecomeDownloadTask) {
        self.dataTaskDidBecomeDownloadTask(session, dataTask, downloadTask);
    }
}

/**
 *   函数作用：
     当接收到部分期望得到的数据（expected data）时，会调用该代理方法。
     
     函数讨论：
     一个NSData类型的数据通常是由一系列不同的数据整合到一起得到的，不管是不是这样，请使用 - enumerateByteRangesUsingBlock:来遍历数据而不是使用bytes方法（因为bytes缺少enumerateByteRangesUsingBlock方法中的range，有了range，enumerateByteRangesUsingBlock就可以对NSData不同的数据块进行遍历，而不像bytes把所有NSData看成一个数据块）。
     
     该代理方法可能会调用多次（比如分片获取数据），你需要自己实现函数将所有数据整合在一起。
 */
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data
{
    // 调用的是 AFURLSessionManagerTaskDelegate 的 didReceiveData 方法
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:dataTask];
    [delegate URLSession:session dataTask:dataTask didReceiveData:data];

    // 自定义
    if (self.dataTaskDidReceiveData) {
        self.dataTaskDidReceiveData(session, dataTask, data);
    }
}

/**
 *   函数作用：
     询问data task或上传任务（upload task）是否缓存response
     
     函数讨论：
     当task接收到所有期望的数据后，session会调用此代理方法。如果你没有实现该方法，那么就会使用 创建session时使用的configuration对象 决定 缓存策略。这个代理方法最初的目的是为了阻止缓存特定的URLs或者修改NSCacheURLResponse对象相关的userInfo字典。
     
     该方法只会 当request决定缓存response时候 调用。作为准则，responses只会当以下条件都成立的时候返回缓存：
     该request是HTTP或HTTPS URL的请求（或者你自定义的网络协议，并且确保该协议支持缓存）
     确保request请求是成功的（返回的status code为200-299）
     返回的response是来自服务器端的，而非缓存中本身就有的
     提供的NSURLRequest对象的缓存策略要允许进行缓存
     服务器返回的response中与缓存相关的header要允许缓存
     该response的大小不能比提供的缓存空间大太多（比如你提供了一个磁盘缓存，那么response大小一定不能比磁盘缓存空间还要大5%）
 */
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler
{
    NSCachedURLResponse *cachedResponse = proposedResponse;

    if (self.dataTaskWillCacheResponse) {
        cachedResponse = self.dataTaskWillCacheResponse(session, dataTask, proposedResponse);
    }

    if (completionHandler) {
        completionHandler(cachedResponse);
    }
}

#pragma mark - NSURLSessionDownloadDelegate

/**
 *  （该代理方法必须实现）
     函数作用：
     告诉代理，该下载任务已完成。
 */
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location
{
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:downloadTask];
    if (self.downloadTaskDidFinishDownloading) {
        // 自定义函数，根据从服务器端获取到的数据临时地址location等参数构建出你想要将临时文件移动的位置
        NSURL *fileURL = self.downloadTaskDidFinishDownloading(session, downloadTask, location);
        if (fileURL) {
            // 如果 delegate 的 downloadFileURL 存在的话，表示用户希望把临时数据存起来
            delegate.downloadFileURL = fileURL;
            NSError *error = nil;
            // 将位于location位置的文件全部移到fileURL位置
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:fileURL error:&error];
            if (error) {
                // 如果移动文件失败，就发送 AFURLSessionDownloadTaskDidFailToMoveFileNotification
                [[NSNotificationCenter defaultCenter] postNotificationName:AFURLSessionDownloadTaskDidFailToMoveFileNotification object:downloadTask userInfo:error.userInfo];
            }

            return;
        }
    }

    // 这一步比较诡异，感觉有重复的嫌疑。或许是为了兼容以前代码吧
    if (delegate) {
        [delegate URLSession:session downloadTask:downloadTask didFinishDownloadingToURL:location];
    }
}

/**
 *  函数作用：
    周期性地通知下载进度
 
 *  @param bytesWritten              自上次调用该方法后，接收到的数据字节数
 *  @param totalBytesWritten         目前已经接收到的数据字节数
 *  @param totalBytesExpectedToWrite 期望收到的文件总字节数，是由Content-Length header提供。如果没有提供，默认是NSURLSessionTransferSizeUnknown
 */
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    // 自定义
    if (self.downloadTaskDidWriteData) {
        self.downloadTaskDidWriteData(session, downloadTask, bytesWritten, totalBytesWritten, totalBytesExpectedToWrite);
    }
}

/**
 *   函数作用：
     告诉代理，下载任务重新开始下载了
 
     函数讨论：
     如果一个resumable（不是很会翻译）下载任务被取消或者失败了，你可以请求一个resumeData对象（比如在userInfo字典中通过NSURLSessionDownloadTaskResumeData这个键来获取到resumeData）并使用它来提供足够的信息以重新开始下载任务。随后，你可以使用resumeData作为downloadTaskWithResumeData:或downloadTaskWithResumeData:completionHandler:的参数。
     当你调用这些方法时，你将开始一个新的下载任务。一旦你继续下载任务，session会调用它的代理方法URLSession:downloadTask:didResumeAtOffset:expectedTotalBytes:其中的downloadTask参数表示的就是新的下载任务，这也意味着下载重新开始了。
 
      fileOffset如果文件缓存策略或者最后文件更新日期阻止重用已经存在的文件内容，那么该值为0。
      否则，该值表示已经存在磁盘上的，不需要重新获取的数据——— 这是断点续传啊！
 */
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes
{
    if (self.downloadTaskDidResume) {
        self.downloadTaskDidResume(session, downloadTask, fileOffset, expectedTotalBytes);
    }
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)decoder {
    NSURLSessionConfiguration *configuration = [decoder decodeObjectOfClass:[NSURLSessionConfiguration class] forKey:@"sessionConfiguration"];

    self = [self initWithSessionConfiguration:configuration];
    if (!self) {
        return nil;
    }

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.session.configuration forKey:@"sessionConfiguration"];
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
    return [[[self class] allocWithZone:zone] initWithSessionConfiguration:self.session.configuration];
}

@end
