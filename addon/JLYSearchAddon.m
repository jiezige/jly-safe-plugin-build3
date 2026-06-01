#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *JLYSearchQuery;
static NSString *JLYMatchmakerSearchQuery;
static IMP OrigPaidPostsURLWithCountPageInfo;
static IMP OrigShowPaidVideoList;
static IMP OrigReloadPaidVideoList;
static IMP OrigPlayVideoURLString;
static IMP OrigViewControllerViewDidAppear;
static IMP OrigAFRequestWithMethodURLStringParametersError;
static IMP OrigAFDataTaskWithHTTPMethodURLStringParametersProgressSuccessFailure;
static IMP OrigAFPostParametersSuccessFailure;
static IMP OrigAFPostParametersProgressSuccessFailure;
static IMP OrigViewControllerSetTitle;
static IMP OrigNavigationItemSetTitle;
static IMP OrigLabelSetText;
static IMP OrigButtonSetTitleForState;
static IMP OrigAlertControllerWithTitleMessageStyle;
static IMP OrigAVPlayerPlayerWithURL;
static IMP OrigAVPlayerItemPlayerItemWithURL;
static IMP OrigSessionDataTaskWithRequestCompletion;
static IMP OrigSessionDataTaskWithURLCompletion;
static IMP OrigConnectionWithRequestDelegate;
static IMP OrigConnectionWithRequestDelegateStart;
static IMP OrigSendAsyncRequestQueueCompletion;
static IMP OrigSendSyncRequestReturningResponseError;
static NSString *JLYMeetAuthorizedCacheKey;
static NSDate *JLYMeetAuthorizedCacheDate;
static BOOL JLYMeetAuthorizedCacheValue;
static NSURL *JLYLastPlayableVideoURL;
static const void *JLYDownloadVideoURLKey = &JLYDownloadVideoURLKey;
static BOOL JLYPaidPluginHooksInstalled;

static UIViewController *JLYTopViewController(void);
static void JLYInstallPaidPluginHooks(void);

static NSString *JLYString(id value) {
    if (!value || value == (id)kCFNull) {
        return @"";
    }
    if ([value isKindOfClass:NSString.class]) {
        return value;
    }
    return [value description] ?: @"";
}

static NSString *JLYDisplayString(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0) {
        return value;
    }
    NSString *patched = [value stringByReplacingOccurrencesOfString:@"红娘" withString:@"所有视频"];
    patched = [patched stringByReplacingOccurrencesOfString:@"请先开通会员后查看" withString:@"请先激活后查看"];
    patched = [patched stringByReplacingOccurrencesOfString:@"请先开通会员" withString:@"请先激活"];
    return patched;
}

static NSURL *JLYAppendSearchQuery(id urlValue) {
    NSString *query = [JLYString(JLYSearchQuery) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (query.length == 0 || !urlValue) {
        return urlValue;
    }

    NSURL *url = [urlValue isKindOfClass:NSURL.class] ? urlValue : [NSURL URLWithString:JLYString(urlValue)];
    if (!url) {
        return urlValue;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) {
        return urlValue;
    }

    NSMutableArray<NSURLQueryItem *> *items = [components.queryItems mutableCopy] ?: [NSMutableArray array];
    NSIndexSet *existing = [items indexesOfObjectsPassingTest:^BOOL(NSURLQueryItem *item, NSUInteger idx, BOOL *stop) {
        return [item.name isEqualToString:@"q"] || [item.name isEqualToString:@"id"];
    }];
    if (existing.count) {
        [items removeObjectsAtIndexes:existing];
    }
    [items addObject:[NSURLQueryItem queryItemWithName:@"q" value:query]];
    components.queryItems = items;

    NSURL *patched = components.URL;
    return patched ?: urlValue;
}

static BOOL JLYURLIsMeetList(NSURL *url) {
    NSString *absolute = JLYString(url.absoluteString).lowercaseString;
    return [absolute containsString:@"sm/meet/getmeetlist"] || [absolute containsString:@"meet/getmeetlist"];
}

static BOOL JLYURLIsMatchmakerRecommend(NSURL *url) {
    NSString *absolute = JLYString(url.absoluteString).lowercaseString;
    return [absolute containsString:@"sm/matchmaker/recommend"] ||
           [absolute containsString:@"sm/matchmaker/recommenduser"] ||
           [absolute containsString:@"/matchmaker/recommend"] ||
           [absolute containsString:@"/matchmaker/recommenduser"];
}

static BOOL JLYURLIsMatchmakerDetail(NSURL *url) {
    NSString *absolute = JLYString(url.absoluteString).lowercaseString;
    if ([absolute containsString:@"circle/detailv1"]) {
        return NO;
    }
    return [absolute containsString:@"sm/matchmaker/detail"] ||
           [absolute containsString:@"/matchmaker/detail"] ||
           [absolute hasSuffix:@"matchmaker/detail"];
}

static BOOL JLYURLIsAllAppList(NSURL *url) {
    NSString *absolute = JLYString(url.absoluteString).lowercaseString;
    return [absolute containsString:@"/api/posts/all-app-list"];
}

static NSString *JLYURLDecode(NSString *value) {
    NSString *plusFixed = [value stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    return [plusFixed stringByRemovingPercentEncoding] ?: value ?: @"";
}

static NSString *JLYURLEncode(NSString *value) {
    NSMutableCharacterSet *allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [allowed removeCharactersInString:@"&+=?"];
    return [JLYString(value) stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static NSString *JLYFormValue(NSString *form, NSString *name) {
    if (form.length == 0 || name.length == 0) {
        return @"";
    }
    NSArray<NSString *> *pairs = [form componentsSeparatedByString:@"&"];
    NSString *prefix = [name stringByAppendingString:@"="];
    for (NSString *pair in pairs) {
        if ([pair hasPrefix:prefix]) {
            return JLYURLDecode([pair substringFromIndex:prefix.length]);
        }
    }
    return @"";
}

static void JLYSetOrAppendFormValue(NSMutableString *form, NSString *name, NSString *value) {
    if (name.length == 0) {
        return;
    }
    NSArray<NSString *> *pairs = [form componentsSeparatedByString:@"&"];
    NSString *prefix = [name stringByAppendingString:@"="];
    NSMutableArray<NSString *> *updated = [NSMutableArray array];
    BOOL found = NO;
    for (NSString *pair in pairs) {
        if (pair.length == 0) {
            continue;
        }
        if ([pair hasPrefix:prefix]) {
            [updated addObject:[NSString stringWithFormat:@"%@=%@", name, JLYURLEncode(value)]];
            found = YES;
        } else {
            [updated addObject:pair];
        }
    }
    if (!found) {
        [updated addObject:[NSString stringWithFormat:@"%@=%@", name, JLYURLEncode(value)]];
    }
    [form setString:[updated componentsJoinedByString:@"&"]];
}

static NSString *JLYRequestBodyString(NSURLRequest *request) {
    NSData *body = request.HTTPBody;
    if (!body.length) {
        return @"";
    }
    return [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"";
}

static NSString *JLYValueFromRequest(NSURLRequest *request, NSString *name) {
    NSString *value = JLYFormValue(request.URL.query ?: @"", name);
    if (value.length) {
        return value;
    }
    return JLYFormValue(JLYRequestBodyString(request), name);
}

static NSString *JLYDeviceIdentifier(void) {
    NSString *vendor = UIDevice.currentDevice.identifierForVendor.UUIDString;
    if (vendor.length) {
        return vendor;
    }
    return @"";
}

static BOOL JLYRemoteVip1Authorized(NSString *uid, NSString *deviceId) {
    uid = JLYString(uid);
    deviceId = JLYString(deviceId);
    if (uid.length == 0 && deviceId.length == 0) {
        return NO;
    }

    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", uid, deviceId];
    if ([cacheKey isEqualToString:JLYMeetAuthorizedCacheKey] &&
        JLYMeetAuthorizedCacheDate &&
        fabs([JLYMeetAuthorizedCacheDate timeIntervalSinceNow]) < 300.0) {
        return JLYMeetAuthorizedCacheValue;
    }

    NSURL *url = [NSURL URLWithString:@"https://pee.jlyapp.cn/vip1"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 6.0;
    [request setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"content-type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"accept"];
    NSDictionary *payload = @{@"uid": uid ?: @"", @"device_id": deviceId ?: @""};
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    __block BOOL finished = NO;
    __block BOOL authorized = NO;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
        if (data.length) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:NSDictionary.class]) {
                id value = json[@"authorized"];
                authorized = [value respondsToSelector:@selector(boolValue)] && [value boolValue];
            }
        }
        finished = YES;
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(semaphore, timeout) != 0 && !finished) {
        [task cancel];
    }

    JLYMeetAuthorizedCacheKey = cacheKey;
    JLYMeetAuthorizedCacheDate = [NSDate date];
    JLYMeetAuthorizedCacheValue = authorized;
    return authorized;
}

static NSURLRequest *JLYRoutedMeetRequest(NSURLRequest *request) {
    if (!request || !JLYURLIsMeetList(request.URL)) {
        return request;
    }

    NSString *uid = JLYValueFromRequest(request, @"login_uid");
    if (uid.length == 0) {
        uid = JLYValueFromRequest(request, @"uid");
    }
    NSString *deviceId = JLYValueFromRequest(request, @"device_id");
    if (deviceId.length == 0) {
        deviceId = JLYDeviceIdentifier();
    }

    if (!JLYRemoteVip1Authorized(uid, deviceId)) {
        return request;
    }

    NSURL *vipURL = [NSURL URLWithString:@"https://pee.jlyapp.cn/vip1/meet-list"];
    NSMutableURLRequest *mutable = [request mutableCopy];
    mutable.URL = vipURL;
    return mutable;
}

static NSURLRequest *JLYRoutedMatchmakerRequest(NSURLRequest *request) {
    if (!request || !JLYURLIsMatchmakerRecommend(request.URL)) {
        return request;
    }

    NSString *body = JLYRequestBodyString(request);
    NSMutableString *form = [NSMutableString stringWithString:body ?: @""];

    NSString *uid = JLYValueFromRequest(request, @"login_uid");
    if (uid.length == 0) {
        uid = JLYValueFromRequest(request, @"uid");
    }
    if (uid.length == 0) {
        uid = JLYDeviceIdentifier();
    }

    if (uid.length) {
        JLYSetOrAppendFormValue(form, @"uid", uid);
        JLYSetOrAppendFormValue(form, @"login_uid", uid);
    }
    if (JLYFormValue(form, @"count").length == 0) {
        JLYSetOrAppendFormValue(form, @"count", @"10");
    }

    NSString *query = [JLYString(JLYMatchmakerSearchQuery) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (query.length) {
        JLYSetOrAppendFormValue(form, @"q", query);
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://pee.jlyapp.cn/api/posts/all-app-list"];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"token" value:@"EUDV6gd9cvJOWCBtKIfniR1zueqAjp5rSYxFso8yGX43mbZa"]];
    if (query.length) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"q" value:query]];
    }
    NSString *pageInfo = JLYValueFromRequest(request, @"page_info");
    if (pageInfo.length && JLYFormValue(form, @"page_info").length == 0) {
        JLYSetOrAppendFormValue(form, @"page_info", pageInfo);
    }
    components.queryItems = items;

    NSMutableURLRequest *mutable = [request mutableCopy];
    mutable.URL = components.URL;
    mutable.HTTPMethod = @"POST";
    [mutable setValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"content-type"];
    mutable.HTTPBody = [form dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    return mutable;
}

static NSURLRequest *JLYRoutedMatchmakerDetailRequest(NSURLRequest *request) {
    if (!request || !JLYURLIsMatchmakerDetail(request.URL)) {
        return request;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    if (!components) {
        return request;
    }
    components.path = [components.path stringByReplacingOccurrencesOfString:@"matchmaker/detail"
                                                                 withString:@"Circle/detailV1"
                                                                    options:NSCaseInsensitiveSearch
                                                                      range:NSMakeRange(0, components.path.length)];
    NSMutableURLRequest *mutable = [request mutableCopy];
    mutable.URL = components.URL;
    return mutable;
}

static NSURLRequest *JLYRoutedAllAppListSearchRequest(NSURLRequest *request) {
    if (!request || !JLYURLIsAllAppList(request.URL)) {
        return request;
    }

    NSString *query = [JLYString(JLYSearchQuery ?: JLYMatchmakerSearchQuery) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (query.length == 0) {
        return request;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    if (!components) {
        return request;
    }
    NSMutableArray<NSURLQueryItem *> *items = [components.queryItems mutableCopy] ?: [NSMutableArray array];
    NSIndexSet *existing = [items indexesOfObjectsPassingTest:^BOOL(NSURLQueryItem *item, NSUInteger idx, BOOL *stop) {
        return [item.name isEqualToString:@"q"] || [item.name isEqualToString:@"id"];
    }];
    if (existing.count) {
        [items removeObjectsAtIndexes:existing];
    }
    [items addObject:[NSURLQueryItem queryItemWithName:@"q" value:query]];
    components.queryItems = items;

    NSMutableURLRequest *mutable = [request mutableCopy];
    mutable.URL = components.URL;
    if ([JLYString(mutable.HTTPMethod).uppercaseString isEqualToString:@"POST"]) {
        NSMutableString *form = [NSMutableString stringWithString:JLYRequestBodyString(request)];
        NSString *uid = JLYValueFromRequest(request, @"login_uid");
        if (uid.length == 0) {
            uid = JLYValueFromRequest(request, @"uid");
        }
        if (uid.length == 0) {
            uid = JLYDeviceIdentifier();
        }
        JLYSetOrAppendFormValue(form, @"q", query);
        if (uid.length) {
            JLYSetOrAppendFormValue(form, @"uid", uid);
            JLYSetOrAppendFormValue(form, @"login_uid", uid);
        }
        if (JLYFormValue(form, @"count").length == 0) {
            JLYSetOrAppendFormValue(form, @"count", @"10");
        }
        NSString *pageInfo = JLYValueFromRequest(request, @"page_info");
        if (pageInfo.length && JLYFormValue(form, @"page_info").length == 0) {
            JLYSetOrAppendFormValue(form, @"page_info", pageInfo);
        }
        [mutable setValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"content-type"];
        mutable.HTTPBody = [form dataUsingEncoding:NSUTF8StringEncoding] ?: mutable.HTTPBody;
    }
    return mutable;
}

static NSMutableDictionary *JLYMutableParameters(id parameters) {
    if ([parameters isKindOfClass:NSMutableDictionary.class]) {
        return parameters;
    }
    if ([parameters isKindOfClass:NSDictionary.class]) {
        return [parameters mutableCopy];
    }
    return [NSMutableDictionary dictionary];
}

static NSString *JLYUIDFromParameters(NSDictionary *parameters) {
    NSString *uid = JLYString(parameters[@"login_uid"]);
    if (uid.length == 0) {
        uid = JLYString(parameters[@"uid"]);
    }
    if (uid.length == 0) {
        uid = JLYDeviceIdentifier();
    }
    return uid;
}

static BOOL JLYRewriteMatchmakerURLString(NSString **urlString, id *parameters) {
    NSURL *url = [NSURL URLWithString:JLYString(*urlString)];
    if (!JLYURLIsMatchmakerRecommend(url)) {
        return NO;
    }

    NSMutableDictionary *mutable = JLYMutableParameters(*parameters);
    NSString *uid = JLYUIDFromParameters(mutable);
    if (uid.length) {
        mutable[@"uid"] = uid;
        mutable[@"login_uid"] = uid;
    }
    if (!mutable[@"count"]) {
        mutable[@"count"] = @"10";
    }

    NSString *query = [JLYString(JLYMatchmakerSearchQuery) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (query.length) {
        mutable[@"q"] = query;
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://pee.jlyapp.cn/api/posts/all-app-list"];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"token" value:@"EUDV6gd9cvJOWCBtKIfniR1zueqAjp5rSYxFso8yGX43mbZa"]];
    if (query.length) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"q" value:query]];
    }
    components.queryItems = items;
    *urlString = components.URL.absoluteString;
    *parameters = mutable;
    return YES;
}

static BOOL JLYRewriteMatchmakerDetailURLString(NSString **urlString) {
    NSURL *url = [NSURL URLWithString:JLYString(*urlString)];
    if (!JLYURLIsMatchmakerDetail(url)) {
        return NO;
    }

    NSString *routed = [JLYString(*urlString) stringByReplacingOccurrencesOfString:@"matchmaker/detail"
                                                                        withString:@"Circle/detailV1"
                                                                           options:NSCaseInsensitiveSearch
                                                                             range:NSMakeRange(0, JLYString(*urlString).length)];
    *urlString = routed;
    return YES;
}

static BOOL JLYRewriteAllAppListURLString(NSString **urlString, id *parameters) {
    NSURL *url = [NSURL URLWithString:JLYString(*urlString)];
    if (!JLYURLIsAllAppList(url)) {
        return NO;
    }

    NSString *query = [JLYString(JLYSearchQuery ?: JLYMatchmakerSearchQuery) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (query.length == 0) {
        return NO;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) {
        return NO;
    }
    NSMutableArray<NSURLQueryItem *> *items = [components.queryItems mutableCopy] ?: [NSMutableArray array];
    NSIndexSet *existing = [items indexesOfObjectsPassingTest:^BOOL(NSURLQueryItem *item, NSUInteger idx, BOOL *stop) {
        return [item.name isEqualToString:@"q"] || [item.name isEqualToString:@"id"];
    }];
    if (existing.count) {
        [items removeObjectsAtIndexes:existing];
    }
    [items addObject:[NSURLQueryItem queryItemWithName:@"q" value:query]];
    components.queryItems = items;
    *urlString = components.URL.absoluteString;

    NSMutableDictionary *mutable = JLYMutableParameters(*parameters);
    mutable[@"q"] = query;
    *parameters = mutable;
    return YES;
}

static id JLYAFRequestWithMethodURLStringParametersError(id self, SEL _cmd, NSString *method, NSString *urlString, id parameters, NSError **error) {
    NSString *routedURL = urlString;
    id routedParameters = parameters;
    JLYRewriteMatchmakerURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerDetailURLString(&routedURL);
    JLYRewriteAllAppListURLString(&routedURL, &routedParameters);
    id (*orig)(id, SEL, NSString *, NSString *, id, NSError **) = (id (*)(id, SEL, NSString *, NSString *, id, NSError **))OrigAFRequestWithMethodURLStringParametersError;
    return orig ? orig(self, _cmd, method, routedURL, routedParameters, error) : nil;
}

static id JLYAFDataTaskWithHTTPMethodURLStringParametersProgressSuccessFailure(id self, SEL _cmd, NSString *method, NSString *urlString, id parameters, id uploadProgress, id downloadProgress, id success, id failure) {
    NSString *routedURL = urlString;
    id routedParameters = parameters;
    JLYRewriteMatchmakerURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerDetailURLString(&routedURL);
    JLYRewriteAllAppListURLString(&routedURL, &routedParameters);
    id (*orig)(id, SEL, NSString *, NSString *, id, id, id, id, id) = (id (*)(id, SEL, NSString *, NSString *, id, id, id, id, id))OrigAFDataTaskWithHTTPMethodURLStringParametersProgressSuccessFailure;
    return orig ? orig(self, _cmd, method, routedURL, routedParameters, uploadProgress, downloadProgress, success, failure) : nil;
}

static id JLYAFPostParametersSuccessFailure(id self, SEL _cmd, NSString *urlString, id parameters, id success, id failure) {
    NSString *routedURL = urlString;
    id routedParameters = parameters;
    JLYRewriteMatchmakerURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerDetailURLString(&routedURL);
    JLYRewriteAllAppListURLString(&routedURL, &routedParameters);
    id (*orig)(id, SEL, NSString *, id, id, id) = (id (*)(id, SEL, NSString *, id, id, id))OrigAFPostParametersSuccessFailure;
    return orig ? orig(self, _cmd, routedURL, routedParameters, success, failure) : nil;
}

static id JLYAFPostParametersProgressSuccessFailure(id self, SEL _cmd, NSString *urlString, id parameters, id progress, id success, id failure) {
    NSString *routedURL = urlString;
    id routedParameters = parameters;
    JLYRewriteMatchmakerURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerDetailURLString(&routedURL);
    JLYRewriteAllAppListURLString(&routedURL, &routedParameters);
    id (*orig)(id, SEL, NSString *, id, id, id, id) = (id (*)(id, SEL, NSString *, id, id, id, id))OrigAFPostParametersProgressSuccessFailure;
    return orig ? orig(self, _cmd, routedURL, routedParameters, progress, success, failure) : nil;
}

static NSURLRequest *JLYRoutedRequest(NSURLRequest *request) {
    NSURLRequest *routed = JLYRoutedMeetRequest(request);
    routed = JLYRoutedMatchmakerRequest(routed);
    routed = JLYRoutedMatchmakerDetailRequest(routed);
    routed = JLYRoutedAllAppListSearchRequest(routed);
    return routed;
}

static id JLYSessionDataTaskWithRequestCompletion(id self, SEL _cmd, NSURLRequest *request, id completion) {
    id (*orig)(id, SEL, NSURLRequest *, id) = (id (*)(id, SEL, NSURLRequest *, id))OrigSessionDataTaskWithRequestCompletion;
    return orig ? orig(self, _cmd, JLYRoutedRequest(request), completion) : nil;
}

static id JLYSessionDataTaskWithURLCompletion(id self, SEL _cmd, NSURL *url, id completion) {
    id (*orig)(id, SEL, NSURL *, id) = (id (*)(id, SEL, NSURL *, id))OrigSessionDataTaskWithURLCompletion;
    if (!JLYURLIsMeetList(url) && !JLYURLIsMatchmakerRecommend(url)) {
        return orig ? orig(self, _cmd, url, completion) : nil;
    }
    NSURLRequest *request = JLYRoutedRequest([NSURLRequest requestWithURL:url]);
    IMP requestIMP = OrigSessionDataTaskWithRequestCompletion;
    if (requestIMP) {
        id (*requestOrig)(id, SEL, NSURLRequest *, id) = (id (*)(id, SEL, NSURLRequest *, id))requestIMP;
        return requestOrig(self, NSSelectorFromString(@"dataTaskWithRequest:completionHandler:"), request, completion);
    }
    return orig ? orig(self, _cmd, request.URL, completion) : nil;
}

static id JLYConnectionWithRequestDelegate(id self, SEL _cmd, NSURLRequest *request, id delegate) {
    id (*orig)(id, SEL, NSURLRequest *, id) = (id (*)(id, SEL, NSURLRequest *, id))OrigConnectionWithRequestDelegate;
    return orig ? orig(self, _cmd, JLYRoutedRequest(request), delegate) : nil;
}

static id JLYConnectionWithRequestDelegateStart(id self, SEL _cmd, NSURLRequest *request, id delegate, BOOL startImmediately) {
    id (*orig)(id, SEL, NSURLRequest *, id, BOOL) = (id (*)(id, SEL, NSURLRequest *, id, BOOL))OrigConnectionWithRequestDelegateStart;
    return orig ? orig(self, _cmd, JLYRoutedRequest(request), delegate, startImmediately) : nil;
}

static void JLYSendAsyncRequestQueueCompletion(id self, SEL _cmd, NSURLRequest *request, NSOperationQueue *queue, id completion) {
    void (*orig)(id, SEL, NSURLRequest *, NSOperationQueue *, id) = (void (*)(id, SEL, NSURLRequest *, NSOperationQueue *, id))OrigSendAsyncRequestQueueCompletion;
    if (orig) {
        orig(self, _cmd, JLYRoutedRequest(request), queue, completion);
    }
}

static NSData *JLYSendSyncRequestReturningResponseError(id self, SEL _cmd, NSURLRequest *request, NSURLResponse **response, NSError **error) {
    NSData *(*orig)(id, SEL, NSURLRequest *, NSURLResponse **, NSError **) = (NSData *(*)(id, SEL, NSURLRequest *, NSURLResponse **, NSError **))OrigSendSyncRequestReturningResponseError;
    return orig ? orig(self, _cmd, JLYRoutedRequest(request), response, error) : nil;
}

static id JLYPaidPostsURLWithCountPageInfo(id self, SEL _cmd, id count, id pageInfo) {
    id (*orig)(id, SEL, id, id) = (id (*)(id, SEL, id, id))OrigPaidPostsURLWithCountPageInfo;
    return JLYAppendSearchQuery(orig ? orig(self, _cmd, count, pageInfo) : nil);
}

static UITableViewController *JLYPaidListController(id plugin) {
    @try {
        id controller = [plugin valueForKey:@"paidListController"];
        if (!controller) {
            controller = [plugin valueForKey:@"_paidListController"];
        }
        if ([controller isKindOfClass:UITableViewController.class]) {
            return controller;
        }
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static void JLYReloadPaidList(id plugin) {
    SEL reload = NSSelectorFromString(@"reloadPaidVideoList");
    if ([plugin respondsToSelector:reload]) {
        ((void (*)(id, SEL))objc_msgSend)(plugin, reload);
    }
}

static void JLYPresentSearch(id plugin) {
    UITableViewController *controller = JLYPaidListController(plugin);
    UIViewController *presenter = controller ?: UIApplication.sharedApplication.keyWindow.rootViewController;
    while (presenter.presentedViewController) {
        presenter = presenter.presentedViewController;
    }
    if (!presenter) {
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"搜索付费视频"
                                                                   message:@"输入帖子关键词或ID"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"关键词 / ID";
        textField.text = JLYSearchQuery ?: @"";
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        JLYSearchQuery = nil;
        JLYReloadPaidList(plugin);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"搜索" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        JLYSearchQuery = alert.textFields.firstObject.text ?: @"";
        JLYReloadPaidList(plugin);
    }]];

    [presenter presentViewController:alert animated:YES completion:nil];
}

static void JLYInstallSearchButton(id plugin) {
    UITableViewController *controller = JLYPaidListController(plugin);
    if (!controller || controller.navigationItem.rightBarButtonItem.tag == 0x4A4C5951) {
        return;
    }

    UIBarButtonItem *button = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSearch
                                                                            target:plugin
                                                                            action:NSSelectorFromString(@"jly_searchPaidVideos")];
    button.tag = 0x4A4C5951;
    controller.navigationItem.rightBarButtonItem = button;
}

static void JLYShowPaidVideoList(id self, SEL _cmd) {
    void (*orig)(id, SEL) = (void (*)(id, SEL))OrigShowPaidVideoList;
    if (orig) {
        orig(self, _cmd);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        JLYInstallSearchButton(self);
    });
}

static void JLYReloadPaidVideoList(id self, SEL _cmd) {
    void (*orig)(id, SEL) = (void (*)(id, SEL))OrigReloadPaidVideoList;
    if (orig) {
        orig(self, _cmd);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        JLYInstallSearchButton(self);
    });
}

static void JLYSearchPaidVideos(id self, SEL _cmd) {
    JLYPresentSearch(self);
}

static BOOL JLYURLLooksLikeDirectVideo(NSURL *url) {
    if (![url isKindOfClass:NSURL.class]) {
        return NO;
    }
    NSString *scheme = JLYString(url.scheme).lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"file"]) {
        return NO;
    }
    NSString *path = JLYString(url.path).lowercaseString;
    if ([path hasSuffix:@".m3u8"] || [path hasSuffix:@".ts"] || [path hasSuffix:@".m4s"] || [path hasSuffix:@".key"]) {
        return NO;
    }
    return YES;
}

static void JLYShowToast(UIViewController *presenter, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *target = presenter ?: JLYTopViewController();
        while (target.presentedViewController && ![target.presentedViewController isKindOfClass:UIAlertController.class]) {
            target = target.presentedViewController;
        }
        if (!target) {
            return;
        }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                       message:message ?: @""
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [target presentViewController:alert animated:YES completion:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [alert dismissViewControllerAnimated:YES completion:nil];
            });
        }];
    });
}

static void JLYSaveVideoFileToAlbum(NSURL *fileURL, UIViewController *presenter) {
    if (!fileURL) {
        JLYShowToast(presenter, @"该视频暂不支持保存到相册");
        return;
    }

    void (^saveBlock)(void) = ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
        } completionHandler:^(BOOL success, NSError *error) {
            JLYShowToast(presenter, success ? @"视频已保存到相册" : (error.localizedDescription ?: @"保存失败"));
        }];
    };

    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
    if (status == PHAuthorizationStatusAuthorized) {
        saveBlock();
        return;
    }
    if (@available(iOS 14.0, *)) {
        if (status == PHAuthorizationStatusLimited) {
            saveBlock();
            return;
        }
    }
    if (status == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus newStatus) {
            BOOL allowed = newStatus == PHAuthorizationStatusAuthorized;
            if (@available(iOS 14.0, *)) {
                allowed = allowed || newStatus == PHAuthorizationStatusLimited;
            }
            if (allowed) {
                saveBlock();
            } else {
                JLYShowToast(presenter, @"没有相册权限");
            }
        }];
        return;
    }
    JLYShowToast(presenter, @"没有相册权限");
}

static void JLYDownloadVideoAction(id self, SEL _cmd) {
    UIViewController *presenter = [self isKindOfClass:UIViewController.class] ? self : JLYTopViewController();
    NSURL *url = objc_getAssociatedObject(self, JLYDownloadVideoURLKey) ?: JLYLastPlayableVideoURL;
    if (!JLYURLLooksLikeDirectVideo(url)) {
        JLYShowToast(presenter, @"该视频暂不支持保存到相册");
        return;
    }
    if ([JLYString(url.scheme).lowercaseString isEqualToString:@"file"]) {
        JLYSaveVideoFileToAlbum(url, presenter);
        return;
    }

    JLYShowToast(presenter, @"开始下载视频");
    NSURLSessionDownloadTask *task = [NSURLSession.sharedSession downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error || !location) {
            JLYShowToast(presenter, error.localizedDescription ?: @"下载失败");
            return;
        }
        NSString *extension = url.pathExtension.length ? url.pathExtension : @"mp4";
        NSString *name = [[NSUUID UUID].UUIDString stringByAppendingPathExtension:extension];
        NSURL *target = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
        [[NSFileManager defaultManager] removeItemAtURL:target error:nil];
        NSError *moveError = nil;
        [[NSFileManager defaultManager] moveItemAtURL:location toURL:target error:&moveError];
        if (moveError) {
            JLYShowToast(presenter, moveError.localizedDescription ?: @"下载失败");
            return;
        }
        JLYSaveVideoFileToAlbum(target, presenter);
    }];
    [task resume];
}

static void JLYInstallDownloadButtonOnPlayer(UIViewController *controller, NSURL *url) {
    if (!controller || !url) {
        return;
    }
    class_addMethod(controller.class, NSSelectorFromString(@"jly_downloadCurrentVideo"), (IMP)JLYDownloadVideoAction, "v@:");
    objc_setAssociatedObject(controller, JLYDownloadVideoURLKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIBarButtonItem *button = [[UIBarButtonItem alloc] initWithTitle:@"下载"
                                                               style:UIBarButtonItemStylePlain
                                                              target:controller
                                                              action:NSSelectorFromString(@"jly_downloadCurrentVideo")];
    controller.navigationItem.rightBarButtonItem = button;

    UIView *host = controller.view;
    if (!host || [host viewWithTag:0x4A4C5944]) {
        return;
    }
    UIButton *overlay = [UIButton buttonWithType:UIButtonTypeSystem];
    overlay.tag = 0x4A4C5944;
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.58];
    overlay.tintColor = UIColor.whiteColor;
    overlay.layer.cornerRadius = 18.0;
    overlay.layer.masksToBounds = YES;
    overlay.titleLabel.font = [UIFont boldSystemFontOfSize:15.0];
    [overlay setTitle:@"下载" forState:UIControlStateNormal];
    [overlay setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [overlay addTarget:controller action:NSSelectorFromString(@"jly_downloadCurrentVideo") forControlEvents:UIControlEventTouchUpInside];
    [host addSubview:overlay];
    UILayoutGuide *guide = host.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [overlay.topAnchor constraintEqualToAnchor:guide.topAnchor constant:12.0],
        [overlay.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-12.0],
        [overlay.widthAnchor constraintEqualToConstant:72.0],
        [overlay.heightAnchor constraintEqualToConstant:36.0],
    ]];
}

static void JLYPlayVideoURLString(id self, SEL _cmd, id urlString) {
    NSURL *url = [urlString isKindOfClass:NSURL.class] ? urlString : [NSURL URLWithString:JLYString(urlString)];
    if (url) {
        JLYLastPlayableVideoURL = url;
    }
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))OrigPlayVideoURLString;
    if (orig) {
        orig(self, _cmd, urlString);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *top = JLYTopViewController();
        JLYInstallDownloadButtonOnPlayer(top, url ?: JLYLastPlayableVideoURL);
    });
}

static id JLYAVPlayerPlayerWithURL(id self, SEL _cmd, NSURL *url) {
    if (url) {
        JLYLastPlayableVideoURL = url;
    }
    id (*orig)(id, SEL, NSURL *) = (id (*)(id, SEL, NSURL *))OrigAVPlayerPlayerWithURL;
    return orig ? orig(self, _cmd, url) : nil;
}

static id JLYAVPlayerItemPlayerItemWithURL(id self, SEL _cmd, NSURL *url) {
    if (url) {
        JLYLastPlayableVideoURL = url;
    }
    id (*orig)(id, SEL, NSURL *) = (id (*)(id, SEL, NSURL *))OrigAVPlayerItemPlayerItemWithURL;
    return orig ? orig(self, _cmd, url) : nil;
}

static UIViewController *JLYTopViewController(void) {
    UIViewController *controller = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (controller.presentedViewController) {
        controller = controller.presentedViewController;
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        controller = ((UINavigationController *)controller).topViewController;
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        UIViewController *selected = ((UITabBarController *)controller).selectedViewController;
        if ([selected isKindOfClass:UINavigationController.class]) {
            selected = ((UINavigationController *)selected).topViewController;
        }
        controller = selected ?: controller;
    }
    return controller;
}

static BOOL JLYLooksLikeMatchmakerController(UIViewController *controller) {
    NSString *className = NSStringFromClass(controller.class).lowercaseString;
    NSString *title = JLYString(controller.title).lowercaseString;
    NSString *navTitle = JLYString(controller.navigationItem.title).lowercaseString;
    NSString *combined = [NSString stringWithFormat:@"%@ %@ %@", className, title, navTitle];
    return [combined containsString:@"matchmaker"] ||
           [combined containsString:@"recommend"] ||
           [combined containsString:@"square"] ||
           [combined containsString:@"moment"] ||
           [combined containsString:@"红娘"] ||
           [combined containsString:@"所有视频"] ||
           [combined containsString:@"推荐"] ||
           [combined containsString:@"动态"];
}

static void JLYRefreshVisibleController(UIViewController *controller) {
    NSArray<NSString *> *selectors = @[
        @"reloadData",
        @"refreshData",
        @"requestData",
        @"loadData",
        @"headerRefresh",
        @"beginRefreshing",
    ];
    for (NSString *name in selectors) {
        SEL sel = NSSelectorFromString(name);
        if ([controller respondsToSelector:sel]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, sel);
            return;
        }
    }
    for (UIView *view in controller.view.subviews) {
        if ([view respondsToSelector:@selector(reloadData)]) {
            ((void (*)(id, SEL))objc_msgSend)(view, @selector(reloadData));
        }
    }
}

static BOOL JLYLooksLikeAllAppListController(UIViewController *controller) {
    NSString *className = NSStringFromClass(controller.class).lowercaseString;
    NSString *title = JLYString(controller.title).lowercaseString;
    NSString *navTitle = JLYString(controller.navigationItem.title).lowercaseString;
    NSString *combined = [NSString stringWithFormat:@"%@ %@ %@", className, title, navTitle];
    return [combined containsString:@"paid"] ||
           [combined containsString:@"video"] ||
           [combined containsString:@"post"] ||
           [combined containsString:@"moment"] ||
           [combined containsString:@"matchmaker"] ||
           [combined containsString:@"recommend"] ||
           [combined containsString:@"红娘"] ||
           [combined containsString:@"所有视频"] ||
           [combined containsString:@"全部"] ||
           [combined containsString:@"付费"] ||
           [combined containsString:@"视频"] ||
           [combined containsString:@"帖子"] ||
           [combined containsString:@"动态"];
}

static void JLYPresentAllAppListSearch(UIViewController *controller) {
    UIViewController *presenter = controller ?: JLYTopViewController();
    while (presenter.presentedViewController) {
        presenter = presenter.presentedViewController;
    }
    if (!presenter) {
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"搜索全部付费"
                                                                   message:@"输入帖子名字或ID"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"名字 / ID";
        textField.text = JLYSearchQuery ?: @"";
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        JLYSearchQuery = nil;
        JLYRefreshVisibleController(controller);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"搜索" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        JLYSearchQuery = alert.textFields.firstObject.text ?: @"";
        JLYRefreshVisibleController(controller);
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void JLYAllAppListSearchAction(id self, SEL _cmd) {
    JLYPresentAllAppListSearch([self isKindOfClass:UIViewController.class] ? self : JLYTopViewController());
}

static void JLYInstallAllAppListSearchButton(UIViewController *controller) {
    if (!controller || !JLYLooksLikeAllAppListController(controller)) {
        return;
    }
    class_addMethod(controller.class, NSSelectorFromString(@"jly_allAppListSearch"), (IMP)JLYAllAppListSearchAction, "v@:");

    UIView *host = controller.view;
    if (!host || [host viewWithTag:0x4A4C4153]) {
        return;
    }
    UIButton *overlay = [UIButton buttonWithType:UIButtonTypeSystem];
    overlay.tag = 0x4A4C4153;
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    overlay.tintColor = UIColor.whiteColor;
    overlay.layer.cornerRadius = 18.0;
    overlay.layer.masksToBounds = YES;
    overlay.titleLabel.font = [UIFont boldSystemFontOfSize:15.0];
    [overlay setTitle:@"搜索" forState:UIControlStateNormal];
    [overlay setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [overlay addTarget:controller action:NSSelectorFromString(@"jly_allAppListSearch") forControlEvents:UIControlEventTouchUpInside];
    [host addSubview:overlay];
    UILayoutGuide *guide = host.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [overlay.topAnchor constraintEqualToAnchor:guide.topAnchor constant:12.0],
        [overlay.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-12.0],
        [overlay.widthAnchor constraintEqualToConstant:72.0],
        [overlay.heightAnchor constraintEqualToConstant:36.0],
    ]];
}

static void JLYPresentMatchmakerSearch(UIViewController *controller) {
    UIViewController *presenter = controller ?: JLYTopViewController();
    while (presenter.presentedViewController) {
        presenter = presenter.presentedViewController;
    }
    if (!presenter) {
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"搜索帖子"
                                                                   message:@"输入帖子名字或ID"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"名字 / ID";
        textField.text = JLYMatchmakerSearchQuery ?: @"";
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        JLYMatchmakerSearchQuery = nil;
        JLYRefreshVisibleController(controller);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"搜索" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        JLYMatchmakerSearchQuery = alert.textFields.firstObject.text ?: @"";
        JLYRefreshVisibleController(controller);
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void JLYMatchmakerSearchAction(id self, SEL _cmd) {
    JLYPresentMatchmakerSearch([self isKindOfClass:UIViewController.class] ? self : JLYTopViewController());
}

static void JLYInstallMatchmakerSearchButton(UIViewController *controller) {
    if (!controller || !controller.navigationController || !JLYLooksLikeMatchmakerController(controller)) {
        return;
    }
    if (controller.navigationItem.rightBarButtonItem.tag == 0x4A4C594D) {
        return;
    }
    class_addMethod(controller.class, NSSelectorFromString(@"jly_matchmakerSearch"), (IMP)JLYMatchmakerSearchAction, "v@:");
    UIBarButtonItem *button = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSearch
                                                                            target:controller
                                                                            action:NSSelectorFromString(@"jly_matchmakerSearch")];
    button.tag = 0x4A4C594D;
    controller.navigationItem.rightBarButtonItem = button;
}

static void JLYViewControllerViewDidAppear(id self, SEL _cmd, BOOL animated) {
    void (*orig)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))OrigViewControllerViewDidAppear;
    if (orig) {
        orig(self, _cmd, animated);
    }
    JLYInstallPaidPluginHooks();
    if ([self isKindOfClass:UIViewController.class]) {
        UIViewController *controller = (UIViewController *)self;
        JLYInstallAllAppListSearchButton(controller);
        if ([NSStringFromClass(controller.class) containsString:@"AVPlayerViewController"] || [controller respondsToSelector:NSSelectorFromString(@"player")]) {
            JLYInstallDownloadButtonOnPlayer(controller, JLYLastPlayableVideoURL);
        }
    }
}

static void JLYViewControllerSetTitle(id self, SEL _cmd, NSString *title) {
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))OrigViewControllerSetTitle;
    if (orig) {
        orig(self, _cmd, JLYDisplayString(title));
    }
}

static void JLYNavigationItemSetTitle(id self, SEL _cmd, NSString *title) {
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))OrigNavigationItemSetTitle;
    if (orig) {
        orig(self, _cmd, JLYDisplayString(title));
    }
}

static void JLYLabelSetText(id self, SEL _cmd, NSString *text) {
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))OrigLabelSetText;
    if (orig) {
        orig(self, _cmd, JLYDisplayString(text));
    }
}

static void JLYButtonSetTitleForState(id self, SEL _cmd, NSString *title, UIControlState state) {
    void (*orig)(id, SEL, NSString *, UIControlState) = (void (*)(id, SEL, NSString *, UIControlState))OrigButtonSetTitleForState;
    if (orig) {
        orig(self, _cmd, JLYDisplayString(title), state);
    }
}

static id JLYAlertControllerWithTitleMessageStyle(id self, SEL _cmd, NSString *title, NSString *message, UIAlertControllerStyle style) {
    id (*orig)(id, SEL, NSString *, NSString *, UIAlertControllerStyle) = (id (*)(id, SEL, NSString *, NSString *, UIAlertControllerStyle))OrigAlertControllerWithTitleMessageStyle;
    return orig ? orig(self, _cmd, JLYDisplayString(title), JLYDisplayString(message), style) : nil;
}

static void JLYSwizzle(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        return;
    }
    *original = method_getImplementation(method);
    method_setImplementation(method, replacement);
}

static void JLYSwizzleClassMethod(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method method = class_getClassMethod(cls, sel);
    if (!method) {
        return;
    }
    *original = method_getImplementation(method);
    method_setImplementation(method, replacement);
}

static void JLYInstallMeetRoutingHooks(void) {
    JLYSwizzle(NSURLSession.class,
               NSSelectorFromString(@"dataTaskWithRequest:completionHandler:"),
               (IMP)JLYSessionDataTaskWithRequestCompletion,
               &OrigSessionDataTaskWithRequestCompletion);
    JLYSwizzle(NSURLSession.class,
               NSSelectorFromString(@"dataTaskWithURL:completionHandler:"),
               (IMP)JLYSessionDataTaskWithURLCompletion,
               &OrigSessionDataTaskWithURLCompletion);

    JLYSwizzle(NSURLConnection.class,
               NSSelectorFromString(@"initWithRequest:delegate:"),
               (IMP)JLYConnectionWithRequestDelegate,
               &OrigConnectionWithRequestDelegate);
    JLYSwizzle(NSURLConnection.class,
               NSSelectorFromString(@"initWithRequest:delegate:startImmediately:"),
               (IMP)JLYConnectionWithRequestDelegateStart,
               &OrigConnectionWithRequestDelegateStart);
    JLYSwizzleClassMethod(NSURLConnection.class,
                          NSSelectorFromString(@"sendAsynchronousRequest:queue:completionHandler:"),
                          (IMP)JLYSendAsyncRequestQueueCompletion,
                          &OrigSendAsyncRequestQueueCompletion);
    JLYSwizzleClassMethod(NSURLConnection.class,
                          NSSelectorFromString(@"sendSynchronousRequest:returningResponse:error:"),
                          (IMP)JLYSendSyncRequestReturningResponseError,
                          &OrigSendSyncRequestReturningResponseError);
}

static void JLYInstallAFNetworkingHooks(void) {
    Class serializer = NSClassFromString(@"AFHTTPRequestSerializer");
    JLYSwizzle(serializer,
               NSSelectorFromString(@"requestWithMethod:URLString:parameters:error:"),
               (IMP)JLYAFRequestWithMethodURLStringParametersError,
               &OrigAFRequestWithMethodURLStringParametersError);

    Class manager = NSClassFromString(@"AFHTTPSessionManager");
    JLYSwizzle(manager,
               NSSelectorFromString(@"dataTaskWithHTTPMethod:URLString:parameters:uploadProgress:downloadProgress:success:failure:"),
               (IMP)JLYAFDataTaskWithHTTPMethodURLStringParametersProgressSuccessFailure,
               &OrigAFDataTaskWithHTTPMethodURLStringParametersProgressSuccessFailure);
    JLYSwizzle(manager,
               NSSelectorFromString(@"POST:parameters:success:failure:"),
               (IMP)JLYAFPostParametersSuccessFailure,
               &OrigAFPostParametersSuccessFailure);
    JLYSwizzle(manager,
               NSSelectorFromString(@"POST:parameters:progress:success:failure:"),
               (IMP)JLYAFPostParametersProgressSuccessFailure,
               &OrigAFPostParametersProgressSuccessFailure);
}

static void JLYInstallMatchmakerUIHooks(void) {
    JLYSwizzle(UIViewController.class,
               NSSelectorFromString(@"viewDidAppear:"),
               (IMP)JLYViewControllerViewDidAppear,
               &OrigViewControllerViewDidAppear);
    JLYSwizzle(UIViewController.class,
               NSSelectorFromString(@"setTitle:"),
               (IMP)JLYViewControllerSetTitle,
               &OrigViewControllerSetTitle);
    JLYSwizzle(UINavigationItem.class,
               NSSelectorFromString(@"setTitle:"),
               (IMP)JLYNavigationItemSetTitle,
               &OrigNavigationItemSetTitle);
    JLYSwizzle(UILabel.class,
               NSSelectorFromString(@"setText:"),
               (IMP)JLYLabelSetText,
               &OrigLabelSetText);
    JLYSwizzle(UIButton.class,
               NSSelectorFromString(@"setTitle:forState:"),
               (IMP)JLYButtonSetTitleForState,
               &OrigButtonSetTitleForState);
    JLYSwizzleClassMethod(UIAlertController.class,
                          NSSelectorFromString(@"alertControllerWithTitle:message:preferredStyle:"),
                          (IMP)JLYAlertControllerWithTitleMessageStyle,
                          &OrigAlertControllerWithTitleMessageStyle);
    JLYSwizzleClassMethod(AVPlayer.class,
                          NSSelectorFromString(@"playerWithURL:"),
                          (IMP)JLYAVPlayerPlayerWithURL,
                          &OrigAVPlayerPlayerWithURL);
    JLYSwizzleClassMethod(AVPlayerItem.class,
                          NSSelectorFromString(@"playerItemWithURL:"),
                          (IMP)JLYAVPlayerItemPlayerItemWithURL,
                          &OrigAVPlayerItemPlayerItemWithURL);
}

static void JLYInstallPaidPluginHooks(void) {
    if (JLYPaidPluginHooksInstalled) {
        return;
    }
    Class cls = NSClassFromString(@"JLYSafePlugin");
    if (!cls) {
        return;
    }

    class_addMethod(cls, NSSelectorFromString(@"jly_searchPaidVideos"), (IMP)JLYSearchPaidVideos, "v@:");
    JLYSwizzle(cls, NSSelectorFromString(@"paidPostsURLWithCount:pageInfo:"), (IMP)JLYPaidPostsURLWithCountPageInfo, &OrigPaidPostsURLWithCountPageInfo);
    JLYSwizzle(cls, NSSelectorFromString(@"showPaidVideoList"), (IMP)JLYShowPaidVideoList, &OrigShowPaidVideoList);
    JLYSwizzle(cls, NSSelectorFromString(@"reloadPaidVideoList"), (IMP)JLYReloadPaidVideoList, &OrigReloadPaidVideoList);
    JLYSwizzle(cls, NSSelectorFromString(@"playVideoURLString:"), (IMP)JLYPlayVideoURLString, &OrigPlayVideoURLString);
    JLYPaidPluginHooksInstalled = YES;
}

__attribute__((constructor))
static void JLYSearchAddonInit(void) {
    JLYInstallMeetRoutingHooks();
    JLYInstallAFNetworkingHooks();
    JLYInstallMatchmakerUIHooks();
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<NSNumber *> *delays = @[@0.0, @0.5, @1.0, @2.0, @4.0, @8.0, @12.0];
        for (NSNumber *delay in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                JLYInstallPaidPluginHooks();
            });
        }
    });
}
