#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString * const kJLYCollectBaseURL = @"https://pee.api.jluapp.cn";
static NSString * const kJLYCollectPath = @"/api/posts/ingest-response";

@interface JLYCollectOnly : NSObject
+ (instancetype)shared;
- (void)reportResponseData:(NSData *)data forURL:(NSURL *)url;
@end

@interface NSURLSession (JLYCollectOnlyHooks)
- (NSURLSessionDataTask *)jlyc_dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;
- (NSURLSessionDataTask *)jlyc_dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;
- (NSURLSessionUploadTask *)jlyc_uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;
- (NSURLSessionUploadTask *)jlyc_uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;
@end

@interface NSURLConnection (JLYCollectOnlyHooks)
+ (void)jlyc_sendAsynchronousRequest:(NSURLRequest *)request queue:(NSOperationQueue *)queue completionHandler:(void (^)(NSURLResponse *response, NSData *data, NSError *connectionError))handler;
+ (NSData *)jlyc_sendSynchronousRequest:(NSURLRequest *)request returningResponse:(NSURLResponse **)response error:(NSError **)error;
@end

static BOOL JLYCURLLooksLikeTarget(NSURL *url) {
  NSString *lower = [url.absoluteString.lowercaseString stringByReplacingOccurrencesOfString:@"//" withString:@"/"];
  return [lower containsString:@"sm/circle/mymoment"];
}

@implementation JLYCollectOnly
+ (instancetype)shared {
  static JLYCollectOnly *instance;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{ instance = [[JLYCollectOnly alloc] init]; });
  return instance;
}

- (void)reportResponseData:(NSData *)data forURL:(NSURL *)url {
  if (data.length == 0 || !JLYCURLLooksLikeTarget(url)) return;
  NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
  if (text.length == 0) return;
  NSDictionary *payload = @{
    @"source_endpoint": @"/sm/Circle/myMoment",
    @"url": url.absoluteString ?: @"",
    @"response": text
  };
  NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  if (body.length == 0) return;
  NSURL *target = [NSURL URLWithString:[kJLYCollectBaseURL stringByAppendingString:kJLYCollectPath]];
  if (!target) return;
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:target];
  request.HTTPMethod = @"POST";
  request.HTTPBody = body;
  [request setValue:@"application/json" forHTTPHeaderField:@"content-type"];
  NSURLSessionDataTask *task = [[NSURLSession sharedSession] jlyc_dataTaskWithRequest:request completionHandler:nil];
  [task resume];
}
@end

@implementation NSURLSession (JLYCollectOnlyHooks)
- (NSURLSessionDataTask *)jlyc_dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
  void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
    [[JLYCollectOnly shared] reportResponseData:data forURL:url];
    if (completionHandler) completionHandler(data, response, error);
  };
  return [self jlyc_dataTaskWithURL:url completionHandler:wrapped];
}

- (NSURLSessionDataTask *)jlyc_dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
  NSURL *url = request.URL;
  void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
    [[JLYCollectOnly shared] reportResponseData:data forURL:url];
    if (completionHandler) completionHandler(data, response, error);
  };
  return [self jlyc_dataTaskWithRequest:request completionHandler:wrapped];
}

- (NSURLSessionUploadTask *)jlyc_uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
  NSURL *url = request.URL;
  void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
    [[JLYCollectOnly shared] reportResponseData:data forURL:url];
    if (completionHandler) completionHandler(data, response, error);
  };
  return [self jlyc_uploadTaskWithRequest:request fromData:bodyData completionHandler:wrapped];
}

- (NSURLSessionUploadTask *)jlyc_uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
  NSURL *url = request.URL;
  void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
    [[JLYCollectOnly shared] reportResponseData:data forURL:url];
    if (completionHandler) completionHandler(data, response, error);
  };
  return [self jlyc_uploadTaskWithRequest:request fromFile:fileURL completionHandler:wrapped];
}
@end

@implementation NSURLConnection (JLYCollectOnlyHooks)
+ (void)jlyc_sendAsynchronousRequest:(NSURLRequest *)request queue:(NSOperationQueue *)queue completionHandler:(void (^)(NSURLResponse *response, NSData *data, NSError *connectionError))handler {
  NSURL *url = request.URL;
  void (^wrapped)(NSURLResponse *, NSData *, NSError *) = ^(NSURLResponse *response, NSData *data, NSError *connectionError) {
    [[JLYCollectOnly shared] reportResponseData:data forURL:url];
    if (handler) handler(response, data, connectionError);
  };
  [self jlyc_sendAsynchronousRequest:request queue:queue completionHandler:wrapped];
}

+ (NSData *)jlyc_sendSynchronousRequest:(NSURLRequest *)request returningResponse:(NSURLResponse **)response error:(NSError **)error {
  NSData *data = [self jlyc_sendSynchronousRequest:request returningResponse:response error:error];
  [[JLYCollectOnly shared] reportResponseData:data forURL:request.URL];
  return data;
}
@end

static void JLYCExchangeInstanceMethod(Class cls, SEL original, SEL replacement) {
  Method originalMethod = class_getInstanceMethod(cls, original);
  Method replacementMethod = class_getInstanceMethod(cls, replacement);
  if (!originalMethod || !replacementMethod) return;
  method_exchangeImplementations(originalMethod, replacementMethod);
}

static void JLYCExchangeClassMethod(Class cls, SEL original, SEL replacement) {
  Method originalMethod = class_getClassMethod(cls, original);
  Method replacementMethod = class_getClassMethod(cls, replacement);
  if (!originalMethod || !replacementMethod) return;
  method_exchangeImplementations(originalMethod, replacementMethod);
}

__attribute__((constructor))
static void JLYCollectOnlyEntry(void) {
  @autoreleasepool {
    Class session = [NSURLSession class];
    JLYCExchangeInstanceMethod(session, @selector(dataTaskWithURL:completionHandler:), @selector(jlyc_dataTaskWithURL:completionHandler:));
    JLYCExchangeInstanceMethod(session, @selector(dataTaskWithRequest:completionHandler:), @selector(jlyc_dataTaskWithRequest:completionHandler:));
    JLYCExchangeInstanceMethod(session, @selector(uploadTaskWithRequest:fromData:completionHandler:), @selector(jlyc_uploadTaskWithRequest:fromData:completionHandler:));
    JLYCExchangeInstanceMethod(session, @selector(uploadTaskWithRequest:fromFile:completionHandler:), @selector(jlyc_uploadTaskWithRequest:fromFile:completionHandler:));
    Class connection = [NSURLConnection class];
    JLYCExchangeClassMethod(connection, @selector(sendAsynchronousRequest:queue:completionHandler:), @selector(jlyc_sendAsynchronousRequest:queue:completionHandler:));
    JLYCExchangeClassMethod(connection, @selector(sendSynchronousRequest:returningResponse:error:), @selector(jlyc_sendSynchronousRequest:returningResponse:error:));
  }
}