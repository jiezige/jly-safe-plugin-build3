#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *JLYSearchQuery;
static NSString *JLYMatchmakerSearchQuery;
static IMP OrigPaidPostsURLWithCountPageInfo;
static IMP OrigShowPaidVideoList;
static IMP OrigReloadPaidVideoList;
static IMP OrigViewControllerViewDidAppear;
static IMP OrigAFRequestWithMethodURLStringParametersError;
static IMP OrigAFDataTaskWithHTTPMethodURLStringParametersProgressSuccessFailure;
static IMP OrigAFPostParametersSuccessFailure;
static IMP OrigAFPostParametersProgressSuccessFailure;
static IMP OrigSessionDataTaskWithRequestCompletion;
static IMP OrigSessionDataTaskWithURLCompletion;
static IMP OrigConnectionWithRequestDelegate;
static IMP OrigConnectionWithRequestDelegateStart;
static IMP OrigSendAsyncRequestQueueCompletion;
static IMP OrigSendSyncRequestReturningResponseError;
static NSString *JLYMeetAuthorizedCacheKey;
static NSDate *JLYMeetAuthorizedCacheDate;
static BOOL JLYMeetAuthorizedCacheValue;

static NSString *JLYString(id value) {
    if (!value || value == (id)kCFNull) {
        return @"";
    }
    if ([value isKindOfClass:NSString.class]) {
        return value;
    }
    return [value description] ?: @"";
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
    if ([absolute containsString:@"matchmaker/detailv1"]) {
        return NO;
    }
    return [absolute containsString:@"sm/matchmaker/detail"] ||
           [absolute containsString:@"/matchmaker/detail"] ||
           [absolute hasSuffix:@"matchmaker/detail"];
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
                                                                 withString:@"matchmaker/detailV1"
                                                                    options:NSCaseInsensitiveSearch
                                                                      range:NSMakeRange(0, components.path.length)];
    NSMutableURLRequest *mutable = [request mutableCopy];
    mutable.URL = components.URL;
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
                                                                        withString:@"matchmaker/detailV1"
                                                                           options:NSCaseInsensitiveSearch
                                                                             range:NSMakeRange(0, JLYString(*urlString).length)];
    *urlString = routed;
    return YES;
}

static id JLYAFRequestWithMethodURLStringParametersError(id self, SEL _cmd, NSString *method, NSString *urlString, id parameters, NSError **error) {
    NSString *routedURL = urlString;
    id routedParameters = parameters;
    JLYRewriteMatchmakerURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerDetailURLString(&routedURL);
    id (*orig)(id, SEL, NSString *, NSString *, id, NSError **) = (id (*)(id, SEL, NSString *, NSString *, id, NSError **))OrigAFRequestWithMethodURLStringParametersError;
    return orig ? orig(self, _cmd, method, routedURL, routedParameters, error) : nil;
}

static id JLYAFDataTaskWithHTTPMethodURLStringParametersProgressSuccessFailure(id self, SEL _cmd, NSString *method, NSString *urlString, id parameters, id uploadProgress, id downloadProgress, id success, id failure) {
    NSString *routedURL = urlString;
    id routedParameters = parameters;
    JLYRewriteMatchmakerURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerDetailURLString(&routedURL);
    id (*orig)(id, SEL, NSString *, NSString *, id, id, id, id, id) = (id (*)(id, SEL, NSString *, NSString *, id, id, id, id, id))OrigAFDataTaskWithHTTPMethodURLStringParametersProgressSuccessFailure;
    return orig ? orig(self, _cmd, method, routedURL, routedParameters, uploadProgress, downloadProgress, success, failure) : nil;
}

static id JLYAFPostParametersSuccessFailure(id self, SEL _cmd, NSString *urlString, id parameters, id success, id failure) {
    NSString *routedURL = urlString;
    id routedParameters = parameters;
    JLYRewriteMatchmakerURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerDetailURLString(&routedURL);
    id (*orig)(id, SEL, NSString *, id, id, id) = (id (*)(id, SEL, NSString *, id, id, id))OrigAFPostParametersSuccessFailure;
    return orig ? orig(self, _cmd, routedURL, routedParameters, success, failure) : nil;
}

static id JLYAFPostParametersProgressSuccessFailure(id self, SEL _cmd, NSString *urlString, id parameters, id progress, id success, id failure) {
    NSString *routedURL = urlString;
    id routedParameters = parameters;
    JLYRewriteMatchmakerURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerDetailURLString(&routedURL);
    id (*orig)(id, SEL, NSString *, id, id, id, id) = (id (*)(id, SEL, NSString *, id, id, id, id))OrigAFPostParametersProgressSuccessFailure;
    return orig ? orig(self, _cmd, routedURL, routedParameters, progress, success, failure) : nil;
}

static NSURLRequest *JLYRoutedRequest(NSURLRequest *request) {
    NSURLRequest *routed = JLYRoutedMeetRequest(request);
    routed = JLYRoutedMatchmakerRequest(routed);
    routed = JLYRoutedMatchmakerDetailRequest(routed);
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
    if ([self isKindOfClass:UIViewController.class]) {
        JLYInstallMatchmakerSearchButton((UIViewController *)self);
    }
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
}

__attribute__((constructor))
static void JLYSearchAddonInit(void) {
    JLYInstallMeetRoutingHooks();
    JLYInstallAFNetworkingHooks();
    JLYInstallMatchmakerUIHooks();
    dispatch_async(dispatch_get_main_queue(), ^{
        Class cls = NSClassFromString(@"JLYSafePlugin");
        if (!cls) {
            return;
        }

        class_addMethod(cls, NSSelectorFromString(@"jly_searchPaidVideos"), (IMP)JLYSearchPaidVideos, "v@:");
        JLYSwizzle(cls, NSSelectorFromString(@"paidPostsURLWithCount:pageInfo:"), (IMP)JLYPaidPostsURLWithCountPageInfo, &OrigPaidPostsURLWithCountPageInfo);
        JLYSwizzle(cls, NSSelectorFromString(@"showPaidVideoList"), (IMP)JLYShowPaidVideoList, &OrigShowPaidVideoList);
        JLYSwizzle(cls, NSSelectorFromString(@"reloadPaidVideoList"), (IMP)JLYReloadPaidVideoList, &OrigReloadPaidVideoList);
    });
}
