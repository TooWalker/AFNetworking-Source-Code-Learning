// AFNetworkActivityIndicatorManager.m
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

#import "AFNetworkActivityIndicatorManager.h"

#if TARGET_OS_IOS
#import "AFURLSessionManager.h"

typedef NS_ENUM(NSInteger, AFNetworkActivityManagerState) {
    AFNetworkActivityManagerStateNotActive,
    AFNetworkActivityManagerStateDelayingStart,
    AFNetworkActivityManagerStateActive,
    AFNetworkActivityManagerStateDelayingEnd
};

static NSTimeInterval const kDefaultAFNetworkActivityManagerActivationDelay = 1.0;
static NSTimeInterval const kDefaultAFNetworkActivityManagerCompletionDelay = 0.17;

static NSURLRequest * AFNetworkRequestFromNotification(NSNotification *notification) {
    if ([[notification object] respondsToSelector:@selector(originalRequest)]) {
        return [(NSURLSessionTask *)[notification object] originalRequest];
    } else {
        return nil;
    }
}

typedef void (^AFNetworkActivityActionBlock)(BOOL networkActivityIndicatorVisible);

@interface AFNetworkActivityIndicatorManager ()
@property (readwrite, nonatomic, assign) NSInteger activityCount;
@property (readwrite, nonatomic, strong) NSTimer *activationDelayTimer;
@property (readwrite, nonatomic, strong) NSTimer *completionDelayTimer;
@property (readonly, nonatomic, getter = isNetworkActivityOccurring) BOOL networkActivityOccurring;
@property (nonatomic, copy) AFNetworkActivityActionBlock networkActivityActionBlock;
@property (nonatomic, assign) AFNetworkActivityManagerState currentState;   /**< 当前的菊花状态 */
@property (nonatomic, assign, getter=isNetworkActivityIndicatorVisible) BOOL networkActivityIndicatorVisible;

- (void)updateCurrentStateForNetworkActivityChange;
@end

@implementation AFNetworkActivityIndicatorManager

+ (instancetype)sharedManager {
    static AFNetworkActivityIndicatorManager *_sharedManager = nil;
    static dispatch_once_t oncePredicate;
    dispatch_once(&oncePredicate, ^{
        _sharedManager = [[self alloc] init];
    });

    return _sharedManager;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    self.currentState = AFNetworkActivityManagerStateNotActive;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(networkRequestDidStart:) name:AFNetworkingTaskDidResumeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(networkRequestDidFinish:) name:AFNetworkingTaskDidSuspendNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(networkRequestDidFinish:) name:AFNetworkingTaskDidCompleteNotification object:nil];
    
    self.activationDelay = kDefaultAFNetworkActivityManagerActivationDelay;
    self.completionDelay = kDefaultAFNetworkActivityManagerCompletionDelay;

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [_activationDelayTimer invalidate];
    [_completionDelayTimer invalidate];
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    if (enabled == NO) {
        [self setCurrentState:AFNetworkActivityManagerStateNotActive];
    }
}

- (void)setNetworkingActivityActionWithBlock:(void (^)(BOOL networkActivityIndicatorVisible))block {
    self.networkActivityActionBlock = block;
}

- (BOOL)isNetworkActivityOccurring {
    @synchronized(self) {
        /** activityCount的增减是通过incrementActivityCount和decrementActivityCount两个函数进行的 */
        return self.activityCount > 0;
    }
}

/**
 *  设定状态栏显示菊花的方法
 */
- (void)setNetworkActivityIndicatorVisible:(BOOL)networkActivityIndicatorVisible {
    if (_networkActivityIndicatorVisible != networkActivityIndicatorVisible) {
        
        //手动通知
        //==================================================================//
        [self willChangeValueForKey:@"networkActivityIndicatorVisible"];
        @synchronized(self) {
             _networkActivityIndicatorVisible = networkActivityIndicatorVisible;
        }
        [self didChangeValueForKey:@"networkActivityIndicatorVisible"];
        //==================================================================//
        
        if (self.networkActivityActionBlock) {
            /** 如果用户自定义过 networkActivityActionBlock 这个 block 代码块，就用用户自己定义的 block 去处理 */
            self.networkActivityActionBlock(networkActivityIndicatorVisible);
        } else {
            /** 否则，使用系统的显示菊花的方法 */
            [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:networkActivityIndicatorVisible];
        }
    }
}

- (void)setActivityCount:(NSInteger)activityCount {
	@synchronized(self) {
		_activityCount = activityCount;
	}

    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateCurrentStateForNetworkActivityChange];
    });
}

- (void)incrementActivityCount {
    [self willChangeValueForKey:@"activityCount"];
	@synchronized(self) {
		_activityCount++;
	}
    [self didChangeValueForKey:@"activityCount"];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateCurrentStateForNetworkActivityChange];
    });
}

- (void)decrementActivityCount {
    [self willChangeValueForKey:@"activityCount"];
	@synchronized(self) {
		_activityCount = MAX(_activityCount - 1, 0);
	}
    [self didChangeValueForKey:@"activityCount"];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateCurrentStateForNetworkActivityChange];
    });
}

- (void)networkRequestDidStart:(NSNotification *)notification {
    if ([AFNetworkRequestFromNotification(notification) URL]) {
        /** 调用了incrementActivityCount */
        [self incrementActivityCount];
    }
}

- (void)networkRequestDidFinish:(NSNotification *)notification {
    if ([AFNetworkRequestFromNotification(notification) URL]) {
        /** 调用了decrementActivityCount */
        [self decrementActivityCount];
    }
}

#pragma mark - Internal State Management
/**
 *  setCurrentState:函数集中了状态的处理过程
 */
- (void)setCurrentState:(AFNetworkActivityManagerState)currentState {
    /** 整个函数是包含在@synchronized中，使用self作为锁的唯一标识。主要是担心多个网络线程同时修改currentState */
    @synchronized(self) {
        /** 判断currentState是否有变化，如果变了，就执行if语句中的函数 */
        if (_currentState != currentState) {
            
            /**
             *  知识点：手动通知
             
             KVO中有两种通知Observer的方式，自动通知和手动通知。自动通知顾名思义就是只要值变化了，就自动通知观察者。
             
             ①但是有时候我们有些地方的值变化了，并不想通知观察者亦或不想立即通知观察者
             ②此处虽然值还没变，但是我也想通知观察者，那么就可以使用手动通知，在你想发送给观察者消息的地方，加上willChangeValueForKey和didChangeValueForKey。
             
             说白了只要加上这两句话，就会通知观察者，不管是不是值变化了（亲测值没变化也有效）。不过，在此之前最好是把自动通知关掉，可以利用automaticallyNotifiesObserversForKey:来返回NO，达到关闭自动通知的功能（当然，开着也行，那么自动通知和手动通知会揉在一起，执行起来很乱）
             */
            //===================================================================//
            [self willChangeValueForKey:@"currentState"];
            _currentState = currentState;
            /** 判断currentState，并作出相应处理 */
            switch (currentState) {
                case AFNetworkActivityManagerStateNotActive:
                    [self cancelActivationDelayTimer];
                    [self cancelCompletionDelayTimer];
                    [self setNetworkActivityIndicatorVisible:NO];
                    break;
                case AFNetworkActivityManagerStateDelayingStart:
                    [self startActivationDelayTimer];
                    break;
                case AFNetworkActivityManagerStateActive:
                    [self cancelCompletionDelayTimer];
                    [self setNetworkActivityIndicatorVisible:YES];
                    break;
                case AFNetworkActivityManagerStateDelayingEnd:
                    [self startCompletionDelayTimer];
                    break;
            }
        }
        [self didChangeValueForKey:@"currentState"];
        //===================================================================//
        
    }
}

- (void)updateCurrentStateForNetworkActivityChange {
    if (self.enabled) {
        switch (self.currentState) {
                
            /** 在状态转移过程中，有一个属性很重要，叫做isNetworkActivityOccurring。这个其实是最真实的记录session task起始的状态。不过这个属性是根据activityCount来决定的 */
            case AFNetworkActivityManagerStateNotActive:
                if (self.isNetworkActivityOccurring) {
                    [self setCurrentState:AFNetworkActivityManagerStateDelayingStart];
                }
                break;
            case AFNetworkActivityManagerStateDelayingStart:
                //No op. Let the delay timer finish out.
                break;
            case AFNetworkActivityManagerStateActive:
                if (!self.isNetworkActivityOccurring) {
                    [self setCurrentState:AFNetworkActivityManagerStateDelayingEnd];
                }
                break;
            case AFNetworkActivityManagerStateDelayingEnd:
                if (self.isNetworkActivityOccurring) {
                    [self setCurrentState:AFNetworkActivityManagerStateActive];
                }
                break;
        }
    }
}

- (void)startActivationDelayTimer {
    
    // 定义了一个名为activationDelayTimer的定时器，定时器的时间为self.activationDelay。
    // 执行完定时器后，执行 activationDelayTimerFired 函数
    self.activationDelayTimer = [NSTimer timerWithTimeInterval:self.activationDelay target:self selector:@selector(activationDelayTimerFired) userInfo:nil repeats:NO];
    
    // 将该定时器添加到RunLoop里面执行。注意这里添加计时器的时候，使用的Mode是NSRunLoopCommonModes，表示不管RunLoop出于什么状态，都执行这个计时器任务（因为如果不指定这个mode的话，UI操作会阻塞计时器任务）。
    [[NSRunLoop mainRunLoop] addTimer:self.activationDelayTimer forMode:NSRunLoopCommonModes];
}

- (void)activationDelayTimerFired {
    if (self.networkActivityOccurring) {
        [self setCurrentState:AFNetworkActivityManagerStateActive];
    } else {
        [self setCurrentState:AFNetworkActivityManagerStateNotActive];
    }
}

- (void)startCompletionDelayTimer {
    [self.completionDelayTimer invalidate];
    
    // 定义了一个名为completionDelayTimer的定时器，定时器的时间为completionDelay。
    // 执行完定时器后，执行 completionDelayTimerFired 函数
    self.completionDelayTimer = [NSTimer timerWithTimeInterval:self.completionDelay target:self selector:@selector(completionDelayTimerFired) userInfo:nil repeats:NO];
    
    // 将该定时器添加到RunLoop里面执行。注意这里添加计时器的时候，使用的Mode是NSRunLoopCommonModes，表示不管RunLoop出于什么状态，都执行这个计时器任务（因为如果不指定这个mode的话，UI操作会阻塞计时器任务）。
    [[NSRunLoop mainRunLoop] addTimer:self.completionDelayTimer forMode:NSRunLoopCommonModes];
}

- (void)completionDelayTimerFired {
    [self setCurrentState:AFNetworkActivityManagerStateNotActive];
}

- (void)cancelActivationDelayTimer {
    [self.activationDelayTimer invalidate];
}

- (void)cancelCompletionDelayTimer {
    [self.completionDelayTimer invalidate];
}

@end

#endif
