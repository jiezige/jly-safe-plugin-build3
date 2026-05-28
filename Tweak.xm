#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString * const kJLYBaseURL = @"https://pee.jlyapp.cn";
static NSString * const kJLYIngestPath = @"/api/posts/ingest-response";

static BOOL JLYURLLooksInteresting(NSString *urlString) {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) return NO;
    NSString *lower = urlString.lowercaseString;
    if ([lower containsString:@"pee.jlyapp.cn"]) return NO;
    return [lower containsString:@"sm/circle/mymoment"] ||
           [lower containsString:@"circle/mymoment"] ||
           [lower containsString:@"sm/circle/detailv1"] ||
           [lower containsString:@"circle/detailv1"] ||
           [lower containsString:@"sm/circle/timelinev1"] ||
           [lower containsString:@"circle/timelinev1"] ||
           [lower containsString:@"sm/circle/mypaymoment"] ||
           [lower containsString:@"circle/mypaymoment"] ||
           [lower containsString:@"sm/circle/list"] ||
           [lower containsString:@"circle/list"];
}

static NSString *JLYJSONStringFromObject(id obj) {
    if (!obj) return nil;
    if ([obj isKindOfClass:[NSData class]]) {
        return [[NSString alloc] initWithData:(NSData *)obj encoding:NSUTF8StringEncoding];
    }
    if ([obj isKindOfClass:[NSString class]]) {
        return (NSString *)obj;
    }
    if ([NSJSONSerialization isValidJSONObject:obj]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
        if (data.length) return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    return [obj description];
}

static void JLYPostJSON(NSDictionary *payload) {
    if (!payload) return;
    NSURL *url = [NSURL URLWithString:[kJLYBaseURL stringByAppendingString:kJLYIngestPath]];
    if (!url) return;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!body.length) return;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.HTTPBody = body;
    [req setValue:@"application/json" forHTTPHeaderField:@"content-type"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req] resume];
}

static void JLYReport(NSString *source, NSString *urlString, id responseObject) {
    if (!JLYURLLooksInteresting(urlString)) return;
    NSString *response = JLYJSONStringFromObject(responseObject);
    if (response.length == 0) return;
    JLYPostJSON(@{
        @"source_endpoint": source ?: @"ios-hook",
        @"url": urlString ?: @"",
        @"response": response
    });
}

static void JLYPing(NSString *stage) {
    JLYPostJSON(@{
        @"source_endpoint": @"ios-hook-ping",
        @"url": stage ?: @"loaded",
        @"response": @"{\"hook_loaded\":true}"
    });
}

typedef NSURLSessionDataTask *(*JLYDataTaskReqIMP)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionDataTask *(*JLYDataTaskURLIMP)(id, SEL, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef id (*JLYAFDataTaskIMP)(id, SEL, NSString *, NSString *, id, id, id, void (^)(NSURLSessionDataTask *, id), void (^)(NSURLSessionDataTask *, NSError *));

static JLYDataTaskReqIMP origDataTaskReq = NULL;
static JLYDataTaskURLIMP origDataTaskURL = NULL;
static JLYAFDataTaskIMP origAFDataTask = NULL;
static SEL selDataTaskReq;
static SEL selDataTaskURL;
static SEL selAFDataTask;

static void JLYInstallNSURLSessionHooks(void) {
    Class cls = objc_getClass("NSURLSession");
    selDataTaskReq = @selector(dataTaskWithRequest:completionHandler:);
    Method mReq = class_getInstanceMethod(cls, selDataTaskReq);
    if (mReq) {
        origDataTaskReq = (JLYDataTaskReqIMP)method_getImplementation(mReq);
        IMP imp = imp_implementationWithBlock(^NSURLSessionDataTask *(id selfObj, NSURLRequest *request, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
            NSString *urlString = request.URL.absoluteString;
            void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
                if (completion) completion(data, response, error);
                if (data.length) JLYReport(@"NSURLSession request", urlString, data);
            };
            return origDataTaskReq(selfObj, selDataTaskReq, request, wrapped);
        });
        method_setImplementation(mReq, imp);
    }

    selDataTaskURL = @selector(dataTaskWithURL:completionHandler:);
    Method mURL = class_getInstanceMethod(cls, selDataTaskURL);
    if (mURL) {
        origDataTaskURL = (JLYDataTaskURLIMP)method_getImplementation(mURL);
        IMP imp = imp_implementationWithBlock(^NSURLSessionDataTask *(id selfObj, NSURL *url, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
            NSString *urlString = url.absoluteString;
            void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
                if (completion) completion(data, response, error);
                if (data.length) JLYReport(@"NSURLSession url", urlString, data);
            };
            return origDataTaskURL(selfObj, selDataTaskURL, url, wrapped);
        });
        method_setImplementation(mURL, imp);
    }
}

static void JLYInstallAFNetworkingHook(void) {
    Class cls = objc_getClass("AFHTTPSessionManager");
    if (!cls) return;
    selAFDataTask = NSSelectorFromString(@"dataTaskWithHTTPMethod:URLString:parameters:uploadProgress:downloadProgress:success:failure:");
    Method m = class_getInstanceMethod(cls, selAFDataTask);
    if (!m) return;

    origAFDataTask = (JLYAFDataTaskIMP)method_getImplementation(m);
    IMP imp = imp_implementationWithBlock(^id(id selfObj, NSString *methodName, NSString *URLString, id parameters, id uploadProgress, id downloadProgress, void (^success)(NSURLSessionDataTask *, id), void (^failure)(NSURLSessionDataTask *, NSError *)) {
        void (^wrappedSuccess)(NSURLSessionDataTask *, id) = ^(NSURLSessionDataTask *task, id responseObject) {
            if (success) success(task, responseObject);
            NSString *urlString = URLString;
            if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) {
                urlString = task.currentRequest.URL.absoluteString ?: task.originalRequest.URL.absoluteString;
            }
            JLYReport(@"AFHTTPSessionManager", urlString, responseObject);
        };
        return origAFDataTask(selfObj, selAFDataTask, methodName, URLString, parameters, uploadProgress, downloadProgress, wrappedSuccess, failure);
    });
    method_setImplementation(m, imp);
}

%ctor {
    @autoreleasepool {
        JLYInstallNSURLSessionHooks();
        JLYInstallAFNetworkingHook();
        JLYPing(@"ctor");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            JLYInstallAFNetworkingHook();
            JLYPing(@"ctor-delay");
        });
    }
}
