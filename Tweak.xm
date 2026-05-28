#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString * const kJLYRuntimeBaseURL = @"https://pee.jlyapp.cn";
static NSString * const kJLYRuntimeIngestPath = @"/api/posts/ingest-response";

static BOOL JLYIsCollectURL(NSString *urlString) {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) return NO;
    NSString *lower = urlString.lowercaseString;
    if ([lower containsString:@"pee.jlyapp.cn"]) return NO;
    return [lower containsString:@"sm/circle/mymoment"] ||
           [lower containsString:@"circle/mymoment"] ||
           [lower containsString:@"sm/circle/myspace"] ||
           [lower containsString:@"circle/myspace"] ||
           [lower containsString:@"sm/wall/myspacewalllist"] ||
           [lower containsString:@"wall/myspacewalllist"] ||
           [lower containsString:@"sm/circle/detailv1"] ||
           [lower containsString:@"circle/detailv1"] ||
           [lower containsString:@"sm/circle/mypaymoment"] ||
           [lower containsString:@"circle/mypaymoment"];
}

static NSString *JLYRewriteURLString(NSString *urlString) {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) return urlString;
    NSString *rewritten = [urlString stringByReplacingOccurrencesOfString:@"Circle/myMomentV1" withString:@"Circle/myMoment"];
    rewritten = [rewritten stringByReplacingOccurrencesOfString:@"circle/myMomentV1" withString:@"circle/myMoment"];
    rewritten = [rewritten stringByReplacingOccurrencesOfString:@"Circle/mymomentV1" withString:@"Circle/mymoment"];
    rewritten = [rewritten stringByReplacingOccurrencesOfString:@"circle/mymomentV1" withString:@"circle/mymoment"];
    rewritten = [rewritten stringByReplacingOccurrencesOfString:@"sm/Circle/myMomentV1" withString:@"sm/Circle/myMoment"];
    rewritten = [rewritten stringByReplacingOccurrencesOfString:@"sm/circle/mymomentv1" withString:@"sm/circle/mymoment"];
    return rewritten;
}

static NSURL *JLYRewriteURL(NSURL *url) {
    NSString *original = url.absoluteString;
    NSString *rewritten = JLYRewriteURLString(original);
    if (![rewritten isKindOfClass:[NSString class]] || [rewritten isEqualToString:original]) return url;
    NSURL *newURL = [NSURL URLWithString:rewritten];
    return newURL ?: url;
}

static NSURLRequest *JLYRewriteRequest(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]]) return request;
    NSURL *oldURL = request.URL;
    NSURL *newURL = JLYRewriteURL(oldURL);
    if (!newURL || [newURL isEqual:oldURL]) return request;

    NSMutableURLRequest *mutable = [request mutableCopy];
    mutable.URL = newURL;
    return mutable;
}

static NSString *JLYTextFromObject(id obj) {
    if (!obj) return nil;
    if ([obj isKindOfClass:[NSData class]]) {
        return [[NSString alloc] initWithData:(NSData *)obj encoding:NSUTF8StringEncoding];
    }
    if ([obj isKindOfClass:[NSString class]]) return (NSString *)obj;
    if ([NSJSONSerialization isValidJSONObject:obj]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
        if (data.length) return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    return [obj description];
}

static void JLYPostPayload(NSDictionary *payload) {
    if (!payload) return;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!body.length) return;

    NSURL *url = [NSURL URLWithString:[kJLYRuntimeBaseURL stringByAppendingString:kJLYRuntimeIngestPath]];
    if (!url) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    [request setValue:@"application/json" forHTTPHeaderField:@"content-type"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request] resume];
}

static void JLYReport(NSString *source, NSString *urlString, id responseObject) {
    if (!JLYIsCollectURL(urlString)) return;
    NSString *text = JLYTextFromObject(responseObject);
    if (text.length == 0) return;
    JLYPostPayload(@{
        @"source_endpoint": source ?: @"ios-runtime-hook",
        @"url": urlString ?: @"",
        @"response": text
    });
}

static void JLYPing(NSString *stage) {
    JLYPostPayload(@{
        @"source_endpoint": @"ios-runtime-hook-ping",
        @"url": stage ?: @"loaded",
        @"response": @"{\"hook_loaded\":true,\"rewrite\":\"myMomentV1_to_myMoment\"}"
    });
}

typedef NSURLSessionDataTask *(*JLYDataTaskReqIMP)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionDataTask *(*JLYDataTaskURLIMP)(id, SEL, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionUploadTask *(*JLYUploadDataIMP)(id, SEL, NSURLRequest *, NSData *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionUploadTask *(*JLYUploadFileIMP)(id, SEL, NSURLRequest *, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef id (*JLYAFDataTaskIMP)(id, SEL, NSString *, NSString *, id, id, id, void (^)(NSURLSessionDataTask *, id), void (^)(NSURLSessionDataTask *, NSError *));

static JLYDataTaskReqIMP origDataTaskReq = NULL;
static JLYDataTaskURLIMP origDataTaskURL = NULL;
static JLYUploadDataIMP origUploadData = NULL;
static JLYUploadFileIMP origUploadFile = NULL;
static JLYAFDataTaskIMP origAFDataTask = NULL;

static SEL selDataTaskReq;
static SEL selDataTaskURL;
static SEL selUploadData;
static SEL selUploadFile;
static SEL selAFDataTask;

static void JLYInstallNSURLSessionHooks(void) {
    Class cls = objc_getClass("NSURLSession");
    if (!cls) return;

    selDataTaskReq = @selector(dataTaskWithRequest:completionHandler:);
    Method mReq = class_getInstanceMethod(cls, selDataTaskReq);
    if (mReq && !origDataTaskReq) {
        origDataTaskReq = (JLYDataTaskReqIMP)method_getImplementation(mReq);
        IMP imp = imp_implementationWithBlock(^NSURLSessionDataTask *(id selfObj, NSURLRequest *request, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
            NSURLRequest *newRequest = JLYRewriteRequest(request);
            NSString *urlString = newRequest.URL.absoluteString ?: request.URL.absoluteString;
            void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
                if (completion) completion(data, response, error);
                if (data.length) JLYReport(@"NSURLSession dataTaskWithRequest", urlString, data);
            };
            return origDataTaskReq(selfObj, selDataTaskReq, newRequest, wrapped);
        });
        method_setImplementation(mReq, imp);
    }

    selDataTaskURL = @selector(dataTaskWithURL:completionHandler:);
    Method mURL = class_getInstanceMethod(cls, selDataTaskURL);
    if (mURL && !origDataTaskURL) {
        origDataTaskURL = (JLYDataTaskURLIMP)method_getImplementation(mURL);
        IMP imp = imp_implementationWithBlock(^NSURLSessionDataTask *(id selfObj, NSURL *url, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
            NSURL *newURL = JLYRewriteURL(url);
            NSString *urlString = newURL.absoluteString ?: url.absoluteString;
            void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
                if (completion) completion(data, response, error);
                if (data.length) JLYReport(@"NSURLSession dataTaskWithURL", urlString, data);
            };
            return origDataTaskURL(selfObj, selDataTaskURL, newURL, wrapped);
        });
        method_setImplementation(mURL, imp);
    }

    selUploadData = @selector(uploadTaskWithRequest:fromData:completionHandler:);
    Method mUploadData = class_getInstanceMethod(cls, selUploadData);
    if (mUploadData && !origUploadData) {
        origUploadData = (JLYUploadDataIMP)method_getImplementation(mUploadData);
        IMP imp = imp_implementationWithBlock(^NSURLSessionUploadTask *(id selfObj, NSURLRequest *request, NSData *bodyData, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
            NSURLRequest *newRequest = JLYRewriteRequest(request);
            NSString *urlString = newRequest.URL.absoluteString ?: request.URL.absoluteString;
            void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
                if (completion) completion(data, response, error);
                if (data.length) JLYReport(@"NSURLSession uploadData", urlString, data);
            };
            return origUploadData(selfObj, selUploadData, newRequest, bodyData, wrapped);
        });
        method_setImplementation(mUploadData, imp);
    }

    selUploadFile = @selector(uploadTaskWithRequest:fromFile:completionHandler:);
    Method mUploadFile = class_getInstanceMethod(cls, selUploadFile);
    if (mUploadFile && !origUploadFile) {
        origUploadFile = (JLYUploadFileIMP)method_getImplementation(mUploadFile);
        IMP imp = imp_implementationWithBlock(^NSURLSessionUploadTask *(id selfObj, NSURLRequest *request, NSURL *fileURL, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
            NSURLRequest *newRequest = JLYRewriteRequest(request);
            NSString *urlString = newRequest.URL.absoluteString ?: request.URL.absoluteString;
            void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
                if (completion) completion(data, response, error);
                if (data.length) JLYReport(@"NSURLSession uploadFile", urlString, data);
            };
            return origUploadFile(selfObj, selUploadFile, newRequest, fileURL, wrapped);
        });
        method_setImplementation(mUploadFile, imp);
    }
}

static void JLYInstallAFNetworkingHook(void) {
    Class cls = objc_getClass("AFHTTPSessionManager");
    if (!cls) return;
    selAFDataTask = NSSelectorFromString(@"dataTaskWithHTTPMethod:URLString:parameters:uploadProgress:downloadProgress:success:failure:");
    Method m = class_getInstanceMethod(cls, selAFDataTask);
    if (!m || origAFDataTask) return;

    origAFDataTask = (JLYAFDataTaskIMP)method_getImplementation(m);
    IMP imp = imp_implementationWithBlock(^id(id selfObj, NSString *methodName, NSString *URLString, id parameters, id uploadProgress, id downloadProgress, void (^success)(NSURLSessionDataTask *, id), void (^failure)(NSURLSessionDataTask *, NSError *)) {
        NSString *newURLString = JLYRewriteURLString(URLString);
        void (^wrappedSuccess)(NSURLSessionDataTask *, id) = ^(NSURLSessionDataTask *task, id responseObject) {
            if (success) success(task, responseObject);
            NSString *urlString = newURLString;
            if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) {
                urlString = task.currentRequest.URL.absoluteString ?: task.originalRequest.URL.absoluteString;
            }
            JLYReport(@"AFHTTPSessionManager", urlString, responseObject);
        };
        return origAFDataTask(selfObj, selAFDataTask, methodName, newURLString, parameters, uploadProgress, downloadProgress, wrappedSuccess, failure);
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
