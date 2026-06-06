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
static IMP OrigAFGetParametersSuccessFailure;
static IMP OrigAFGetParametersProgressSuccessFailure;
static IMP OrigViewControllerSetTitle;
static IMP OrigNavigationItemSetTitle;
static IMP OrigLabelSetText;
static IMP OrigButtonSetTitleForState;
static IMP OrigAlertControllerWithTitleMessageStyle;
static IMP OrigWindowSetRootViewController;
static IMP OrigAVPlayerPlayerWithURL;
static IMP OrigAVPlayerItemPlayerItemWithURL;
static IMP OrigZFLandScapeInitWithFrame;
static IMP OrigZFLandScapeInitWithCoder;
static IMP OrigZFLandScapeLayoutSubviews;
static IMP OrigZFLandScapeSetVideoUrl;
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
static NSString *JLYLastLoginUID;
static UIViewController *JLYComicShellRootController;
static BOOL JLYManualActivationPromptVisible;
static NSString * const JLYStoredLoginUIDKey = @"JLYSearchAddonStoredLoginUID";
static const void *JLYDownloadVideoURLKey = &JLYDownloadVideoURLKey;
static const void *JLYDownloadButtonKey = &JLYDownloadButtonKey;
static const void *JLYRateButtonKey = &JLYRateButtonKey;
static const void *JLYReturnComicGestureKey = &JLYReturnComicGestureKey;
static BOOL JLYPaidPluginHooksInstalled;
static BOOL JLYVideoControlHooksInstalled;
static const NSTimeInterval JLYAuthorizedCacheTTL = 300.0;
static const NSTimeInterval JLYDeniedCacheTTL = 30.0;

static NSString *JLYString(id value);
static UIWindow *JLYKeyWindow(void);
static UIViewController *JLYTopViewController(void);
static void JLYRememberComicShellRoot(UIViewController *controller);
static NSString *JLYDeviceIdentifier(void);
static BOOL JLYActivateOrCheckManualUID(NSString *uid, NSString *code, NSString **message);
static void JLYPromptManualActivationIfNeeded(void);
static void JLYInstallPaidPluginHooks(void);

static NSURL *JLYURLFromValue(id value) {
    if ([value isKindOfClass:NSURL.class]) {
        return value;
    }
    NSString *text = JLYString(value);
    if (text.length == 0) {
        return nil;
    }
    return [NSURL URLWithString:text];
}

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

static NSString *JLYComicButtonTitle(void) {
    unichar chars[] = {0x6F2B, 0x753B};
    return [NSString stringWithCharacters:chars length:2];
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

static BOOL JLYURLIsPaidAppList(NSURL *url) {
    NSString *absolute = JLYString(url.absoluteString).lowercaseString;
    return [absolute containsString:@"/api/posts/app-list"] && ![absolute containsString:@"/api/posts/all-app-list"];
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

static BOOL JLYValueLooksTrue(id value) {
    if (!value || value == (id)kCFNull) {
        return NO;
    }
    if ([value respondsToSelector:@selector(boolValue)] && ![value isKindOfClass:NSString.class]) {
        return [value boolValue];
    }
    NSString *text = [[JLYString(value) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    return [text isEqualToString:@"1"] ||
           [text isEqualToString:@"true"] ||
           [text isEqualToString:@"yes"] ||
           [text isEqualToString:@"vip"];
}

static BOOL JLYDictionaryContainsNativeVIP(id value, NSInteger depth) {
    if (depth <= 0 || !value || value == (id)kCFNull) {
        return NO;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = value;
        NSArray<NSString *> *keys = @[@"is_vip", @"isVIP", @"isVip", @"vip", @"pay_vip", @"vip_free"];
        for (NSString *key in keys) {
            if (JLYValueLooksTrue(dictionary[key])) {
                return YES;
            }
        }
        for (id item in dictionary.allValues) {
            if (JLYDictionaryContainsNativeVIP(item, depth - 1)) {
                return YES;
            }
        }
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)value) {
            if (JLYDictionaryContainsNativeVIP(item, depth - 1)) {
                return YES;
            }
        }
    }
    return NO;
}

static BOOL JLYDictionaryContainsNativeVIPForUID(id value, NSString *uid, NSInteger depth) {
    uid = JLYString(uid);
    if (uid.length == 0 || depth <= 0 || !value || value == (id)kCFNull) {
        return NO;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = value;
        NSArray<NSString *> *uidKeys = @[@"login_uid", @"uid", @"user_id", @"d_uid"];
        BOOL uidMatches = NO;
        for (NSString *key in uidKeys) {
            if ([JLYString(dictionary[key]) isEqualToString:uid]) {
                uidMatches = YES;
                break;
            }
        }
        if (uidMatches && JLYDictionaryContainsNativeVIP(dictionary, 1)) {
            return YES;
        }
        for (id item in dictionary.allValues) {
            if (JLYDictionaryContainsNativeVIPForUID(item, uid, depth - 1)) {
                return YES;
            }
        }
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)value) {
            if (JLYDictionaryContainsNativeVIPForUID(item, uid, depth - 1)) {
                return YES;
            }
        }
    }
    return NO;
}

static BOOL JLYRequestHasNativeVIP(NSURLRequest *request) {
    NSArray<NSString *> *keys = @[@"is_vip", @"isVIP", @"isVip", @"vip", @"pay_vip", @"vip_free"];
    for (NSString *key in keys) {
        if (JLYValueLooksTrue(JLYValueFromRequest(request, key))) {
            return YES;
        }
    }
    return NO;
}

static BOOL JLYParametersHaveNativeVIP(NSDictionary *parameters) {
    if (![parameters isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    return JLYDictionaryContainsNativeVIP(parameters, 2);
}

static BOOL JLYStoredNativeVIPLikelyActiveForUID(NSString *uid) {
    NSDictionary *defaults = NSUserDefaults.standardUserDefaults.dictionaryRepresentation;
    return JLYDictionaryContainsNativeVIPForUID(defaults, uid, 4);
}

static NSString *JLYAuthorizationCacheKey(NSString *uid, NSString *deviceId) {
    return [NSString stringWithFormat:@"%@|%@", JLYString(uid), JLYString(deviceId)];
}

static BOOL JLYCachedRemoteVip1Authorized(NSString *uid, NSString *deviceId, BOOL *authorized) {
    NSString *cacheKey = JLYAuthorizationCacheKey(uid, deviceId);
    NSTimeInterval maxAge = JLYMeetAuthorizedCacheValue ? JLYAuthorizedCacheTTL : JLYDeniedCacheTTL;
    if ([cacheKey isEqualToString:JLYMeetAuthorizedCacheKey] &&
        JLYMeetAuthorizedCacheDate &&
        fabs([JLYMeetAuthorizedCacheDate timeIntervalSinceNow]) < maxAge) {
        if (authorized) {
            *authorized = JLYMeetAuthorizedCacheValue;
        }
        return YES;
    }
    return NO;
}

static void JLYSetRemoteVip1AuthorizationCache(NSString *uid, NSString *deviceId, BOOL authorized) {
    JLYMeetAuthorizedCacheKey = JLYAuthorizationCacheKey(uid, deviceId);
    JLYMeetAuthorizedCacheDate = [NSDate date];
    JLYMeetAuthorizedCacheValue = authorized;
}

static void JLYRememberLoginUID(NSString *uid) {
    uid = [JLYString(uid) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (uid.length) {
        JLYLastLoginUID = uid;
        [NSUserDefaults.standardUserDefaults setObject:uid forKey:JLYStoredLoginUIDKey];
        [NSUserDefaults.standardUserDefaults synchronize];
    }
}

static NSString *JLYRequestLoginUID(NSURLRequest *request) {
    NSString *uid = JLYValueFromRequest(request, @"login_uid");
    if (uid.length == 0) {
        uid = JLYValueFromRequest(request, @"uid");
    }
    JLYRememberLoginUID(uid);
    if (uid.length) {
        return uid;
    }
    if (JLYLastLoginUID.length) {
        return JLYLastLoginUID;
    }
    uid = JLYString([NSUserDefaults.standardUserDefaults objectForKey:JLYStoredLoginUIDKey]);
    JLYRememberLoginUID(uid);
    return uid;
}

static void JLYRememberLoginUIDFromRequest(NSURLRequest *request) {
    if (!request) {
        return;
    }
    NSString *uid = JLYValueFromRequest(request, @"login_uid");
    if (uid.length == 0) {
        uid = JLYValueFromRequest(request, @"uid");
    }
    JLYRememberLoginUID(uid);
}

static NSDictionary *JLYPostVip1JSON(NSString *path, NSDictionary *payload) {
    NSURL *url = [NSURL URLWithString:[@"https://pee.jlyapp.cn" stringByAppendingString:path ?: @""]];
    if (!url) {
        return nil;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 8.0;
    [request setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"content-type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"accept"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload ?: @{} options:0 error:nil];

    __block NSDictionary *result = nil;
    __block BOOL finished = NO;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
        if (data.length) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:NSDictionary.class]) {
                result = json;
            }
        }
        finished = YES;
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(semaphore, timeout) != 0 && !finished) {
        [task cancel];
    }
    return result;
}

static void JLYShowMessage(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = JLYTopViewController();
        if (!presenter) {
            return;
        }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title ?: @"提示"
                                                                       message:JLYDisplayString(message)
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

static void JLYPromptManualActivationIfNeeded(void) {
    if (JLYManualActivationPromptVisible || JLYRequestLoginUID(nil).length) {
        return;
    }
    JLYManualActivationPromptVisible = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = JLYTopViewController();
        if (!presenter) {
            JLYManualActivationPromptVisible = NO;
            return;
        }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"手动激活"
                                                                       message:@"未获取到用户ID，请填写用户ID和激活码"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            textField.placeholder = @"用户ID";
            textField.text = JLYString([NSUserDefaults.standardUserDefaults objectForKey:JLYStoredLoginUIDKey]);
            textField.keyboardType = UIKeyboardTypeASCIICapable;
        }];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            textField.placeholder = @"激活码（已激活可不填）";
            textField.keyboardType = UIKeyboardTypeASCIICapable;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
            JLYManualActivationPromptVisible = NO;
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSString *uid = alert.textFields.count > 0 ? alert.textFields[0].text : @"";
            NSString *code = alert.textFields.count > 1 ? alert.textFields[1].text : @"";
            JLYManualActivationPromptVisible = NO;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSString *message = nil;
                BOOL ok = JLYActivateOrCheckManualUID(uid, code, &message);
                JLYShowMessage(ok ? @"成功" : @"失败", message);
            });
        }]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

static BOOL JLYActivateOrCheckManualUID(NSString *uid, NSString *code, NSString **message) {
    uid = [JLYString(uid) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    code = [JLYString(code) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (uid.length == 0) {
        if (message) *message = @"请填写用户ID";
        return NO;
    }

    NSString *deviceId = JLYDeviceIdentifier();
    NSDictionary *payload = code.length ? @{@"uid": uid, @"login_uid": uid, @"device_id": deviceId ?: @"", @"code": code} :
                                          @{@"uid": uid, @"login_uid": uid, @"device_id": deviceId ?: @""};
    NSDictionary *json = JLYPostVip1JSON(code.length ? @"/vip1/activate" : @"/vip1", payload);
    BOOL ok = [json[@"authorized"] respondsToSelector:@selector(boolValue)] && [json[@"authorized"] boolValue];
    if (ok) {
        JLYRememberLoginUID(uid);
        JLYSetRemoteVip1AuthorizationCache(uid, deviceId, YES);
        if (message) *message = code.length ? @"激活成功，请重新点击解锁" : @"用户ID已保存，请重新点击解锁";
        return YES;
    }

    if (json) {
        JLYSetRemoteVip1AuthorizationCache(uid, deviceId, NO);
    }
    NSString *serverMessage = JLYDisplayString(JLYString(json[@"message"]));
    if (serverMessage.length == 0) {
        serverMessage = code.length ? @"激活失败，请检查用户ID和激活码" : @"该用户ID未激活，请填写激活码";
    }
    if (message) *message = serverMessage;
    return NO;
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

    BOOL cachedAuthorized = NO;
    if (JLYCachedRemoteVip1Authorized(uid, deviceId, &cachedAuthorized)) {
        return cachedAuthorized;
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
    __block BOOL gotResponse = NO;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
        if (data.length) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:NSDictionary.class]) {
                gotResponse = YES;
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

    if (gotResponse || authorized) {
        JLYSetRemoteVip1AuthorizationCache(uid, deviceId, authorized);
    }
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
    JLYRememberLoginUID(uid);

    if (JLYRequestHasNativeVIP(request) || JLYStoredNativeVIPLikelyActiveForUID(uid)) {
        return request;
    }

    if (uid.length == 0) {
        JLYPromptManualActivationIfNeeded();
        return request;
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
    mutable.HTTPMethod = @"POST";
    [mutable setValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"content-type"];

    NSMutableString *form = [NSMutableString stringWithString:JLYRequestBodyString(request)];
    if (form.length == 0) {
        form = [NSMutableString stringWithString:request.URL.query ?: @""];
    }
    if (uid.length) {
        JLYSetOrAppendFormValue(form, @"uid", uid);
        JLYSetOrAppendFormValue(form, @"login_uid", uid);
    } else {
        JLYPromptManualActivationIfNeeded();
    }
    if (deviceId.length) {
        JLYSetOrAppendFormValue(form, @"device_id", deviceId);
    }
    mutable.HTTPBody = [form dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    return mutable;
}

static NSURLRequest *JLYRoutedMatchmakerRequest(NSURLRequest *request) {
    if (!request || !JLYURLIsMatchmakerRecommend(request.URL)) {
        return request;
    }

    NSString *body = JLYRequestBodyString(request);
    NSMutableString *form = [NSMutableString stringWithString:body ?: @""];

    NSString *uid = JLYRequestLoginUID(request);

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
        NSString *uid = JLYRequestLoginUID(request);
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

static NSURLRequest *JLYRoutedPaidAppListPostRequest(NSURLRequest *request) {
    if (!request || !JLYURLIsPaidAppList(request.URL)) {
        return request;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    if (!components) {
        return request;
    }

    NSString *query = [JLYString(JLYSearchQuery) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSURLQueryItem *> *items = [components.queryItems mutableCopy] ?: [NSMutableArray array];
    NSIndexSet *existing = [items indexesOfObjectsPassingTest:^BOOL(NSURLQueryItem *item, NSUInteger idx, BOOL *stop) {
        return [item.name isEqualToString:@"q"] || [item.name isEqualToString:@"id"];
    }];
    if (existing.count) {
        [items removeObjectsAtIndexes:existing];
    }
    if (query.length) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"q" value:query]];
    }
    components.queryItems = items;

    NSMutableString *form = [NSMutableString stringWithString:JLYRequestBodyString(request)];
    NSString *uid = JLYRequestLoginUID(request);
    if (uid.length) {
        JLYSetOrAppendFormValue(form, @"uid", uid);
        JLYSetOrAppendFormValue(form, @"login_uid", uid);
    } else {
        JLYPromptManualActivationIfNeeded();
    }
    if (JLYFormValue(form, @"count").length == 0) {
        NSString *count = JLYValueFromRequest(request, @"count");
        JLYSetOrAppendFormValue(form, @"count", count.length ? count : @"10");
    }
    NSString *pageInfo = JLYValueFromRequest(request, @"page_info");
    if (pageInfo.length) {
        JLYSetOrAppendFormValue(form, @"page_info", pageInfo);
    }
    if (query.length) {
        JLYSetOrAppendFormValue(form, @"q", query);
    }

    NSMutableURLRequest *mutable = [request mutableCopy];
    mutable.URL = components.URL;
    mutable.HTTPMethod = @"POST";
    [mutable setValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"content-type"];
    mutable.HTTPBody = [form dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
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
    JLYRememberLoginUID(uid);
    if (uid.length) {
        return uid;
    }
    if (JLYLastLoginUID.length) {
        return JLYLastLoginUID;
    }
    uid = JLYString([NSUserDefaults.standardUserDefaults objectForKey:JLYStoredLoginUIDKey]);
    JLYRememberLoginUID(uid);
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
    } else {
        JLYPromptManualActivationIfNeeded();
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

static BOOL JLYRewriteMeetURLString(NSString **urlString, id *parameters) {
    NSURL *url = [NSURL URLWithString:JLYString(*urlString)];
    if (!JLYURLIsMeetList(url)) {
        return NO;
    }

    NSMutableDictionary *mutable = JLYMutableParameters(*parameters);

    NSURLComponents *originalComponents = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in originalComponents.queryItems ?: @[]) {
        if (item.name.length && !mutable[item.name]) {
            mutable[item.name] = item.value ?: @"";
        }
    }

    NSString *uid = JLYUIDFromParameters(mutable);
    if (JLYParametersHaveNativeVIP(mutable) || JLYStoredNativeVIPLikelyActiveForUID(uid)) {
        return NO;
    }
    if (uid.length == 0) {
        JLYPromptManualActivationIfNeeded();
        return NO;
    }
    if (uid.length) {
        mutable[@"uid"] = uid;
        mutable[@"login_uid"] = uid;
    } else {
        JLYPromptManualActivationIfNeeded();
    }
    NSString *deviceId = JLYString(mutable[@"device_id"]);
    if (deviceId.length == 0) {
        deviceId = JLYDeviceIdentifier();
    }
    if (deviceId.length) {
        mutable[@"device_id"] = deviceId;
    }
    if (!JLYRemoteVip1Authorized(uid, deviceId)) {
        return NO;
    }

    *urlString = @"https://pee.jlyapp.cn/vip1/meet-list";
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

static BOOL JLYRewritePaidAppListURLString(NSString **urlString, id *parameters) {
    NSURL *url = [NSURL URLWithString:JLYString(*urlString)];
    if (!JLYURLIsPaidAppList(url)) {
        return NO;
    }

    NSString *query = [JLYString(JLYSearchQuery) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
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
    if (query.length) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"q" value:query]];
    }
    components.queryItems = items;
    *urlString = components.URL.absoluteString;

    NSMutableDictionary *mutable = JLYMutableParameters(*parameters);
    NSString *uid = JLYUIDFromParameters(mutable);
    if (uid.length) {
        mutable[@"uid"] = uid;
        mutable[@"login_uid"] = uid;
    }
    if (!mutable[@"count"]) {
        mutable[@"count"] = @"10";
    }
    if (query.length) {
        mutable[@"q"] = query;
    }
    *parameters = mutable;
    return YES;
}

static id JLYAFRequestWithMethodURLStringParametersError(id self, SEL _cmd, NSString *method, NSString *urlString, id parameters, NSError **error) {
    NSString *routedURL = urlString;
    id routedParameters = parameters;
    BOOL paidAppList = JLYURLIsPaidAppList([NSURL URLWithString:JLYString(urlString)]);
    BOOL routedMeet = JLYRewriteMeetURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerDetailURLString(&routedURL);
    JLYRewritePaidAppListURLString(&routedURL, &routedParameters);
    JLYRewriteAllAppListURLString(&routedURL, &routedParameters);
    id (*orig)(id, SEL, NSString *, NSString *, id, NSError **) = (id (*)(id, SEL, NSString *, NSString *, id, NSError **))OrigAFRequestWithMethodURLStringParametersError;
    return orig ? orig(self, _cmd, (routedMeet || paidAppList) ? @"POST" : method, routedURL, routedParameters, error) : nil;
}

static id JLYAFDataTaskWithHTTPMethodURLStringParametersProgressSuccessFailure(id self, SEL _cmd, NSString *method, NSString *urlString, id parameters, id uploadProgress, id downloadProgress, id success, id failure) {
    NSString *routedURL = urlString;
    id routedParameters = parameters;
    BOOL paidAppList = JLYURLIsPaidAppList([NSURL URLWithString:JLYString(urlString)]);
    BOOL routedMeet = JLYRewriteMeetURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerDetailURLString(&routedURL);
    JLYRewritePaidAppListURLString(&routedURL, &routedParameters);
    JLYRewriteAllAppListURLString(&routedURL, &routedParameters);
    id (*orig)(id, SEL, NSString *, NSString *, id, id, id, id, id) = (id (*)(id, SEL, NSString *, NSString *, id, id, id, id, id))OrigAFDataTaskWithHTTPMethodURLStringParametersProgressSuccessFailure;
    return orig ? orig(self, _cmd, (routedMeet || paidAppList) ? @"POST" : method, routedURL, routedParameters, uploadProgress, downloadProgress, success, failure) : nil;
}

static id JLYAFPostParametersSuccessFailure(id self, SEL _cmd, NSString *urlString, id parameters, id success, id failure) {
    NSString *routedURL = urlString;
    id routedParameters = parameters;
    JLYRewriteMeetURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerDetailURLString(&routedURL);
    JLYRewritePaidAppListURLString(&routedURL, &routedParameters);
    JLYRewriteAllAppListURLString(&routedURL, &routedParameters);
    id (*orig)(id, SEL, NSString *, id, id, id) = (id (*)(id, SEL, NSString *, id, id, id))OrigAFPostParametersSuccessFailure;
    return orig ? orig(self, _cmd, routedURL, routedParameters, success, failure) : nil;
}

static id JLYAFPostParametersProgressSuccessFailure(id self, SEL _cmd, NSString *urlString, id parameters, id progress, id success, id failure) {
    NSString *routedURL = urlString;
    id routedParameters = parameters;
    JLYRewriteMeetURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerDetailURLString(&routedURL);
    JLYRewritePaidAppListURLString(&routedURL, &routedParameters);
    JLYRewriteAllAppListURLString(&routedURL, &routedParameters);
    id (*orig)(id, SEL, NSString *, id, id, id, id) = (id (*)(id, SEL, NSString *, id, id, id, id))OrigAFPostParametersProgressSuccessFailure;
    return orig ? orig(self, _cmd, routedURL, routedParameters, progress, success, failure) : nil;
}

static id JLYAFGetParametersSuccessFailure(id self, SEL _cmd, NSString *urlString, id parameters, id success, id failure) {
    NSString *routedURL = urlString;
    id routedParameters = parameters;
    BOOL paidAppList = JLYURLIsPaidAppList([NSURL URLWithString:JLYString(urlString)]);
    BOOL routedMeet = JLYRewriteMeetURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerDetailURLString(&routedURL);
    JLYRewritePaidAppListURLString(&routedURL, &routedParameters);
    JLYRewriteAllAppListURLString(&routedURL, &routedParameters);
    if (routedMeet && OrigAFPostParametersSuccessFailure) {
        id (*postOrig)(id, SEL, NSString *, id, id, id) = (id (*)(id, SEL, NSString *, id, id, id))OrigAFPostParametersSuccessFailure;
        return postOrig(self, NSSelectorFromString(@"POST:parameters:success:failure:"), routedURL, routedParameters, success, failure);
    }
    if (paidAppList && OrigAFPostParametersSuccessFailure) {
        id (*postOrig)(id, SEL, NSString *, id, id, id) = (id (*)(id, SEL, NSString *, id, id, id))OrigAFPostParametersSuccessFailure;
        return postOrig(self, NSSelectorFromString(@"POST:parameters:success:failure:"), routedURL, routedParameters, success, failure);
    }
    id (*orig)(id, SEL, NSString *, id, id, id) = (id (*)(id, SEL, NSString *, id, id, id))OrigAFGetParametersSuccessFailure;
    return orig ? orig(self, _cmd, routedURL, routedParameters, success, failure) : nil;
}

static id JLYAFGetParametersProgressSuccessFailure(id self, SEL _cmd, NSString *urlString, id parameters, id progress, id success, id failure) {
    NSString *routedURL = urlString;
    id routedParameters = parameters;
    BOOL paidAppList = JLYURLIsPaidAppList([NSURL URLWithString:JLYString(urlString)]);
    BOOL routedMeet = JLYRewriteMeetURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerURLString(&routedURL, &routedParameters);
    JLYRewriteMatchmakerDetailURLString(&routedURL);
    JLYRewritePaidAppListURLString(&routedURL, &routedParameters);
    JLYRewriteAllAppListURLString(&routedURL, &routedParameters);
    if (routedMeet && OrigAFPostParametersProgressSuccessFailure) {
        id (*postOrig)(id, SEL, NSString *, id, id, id, id) = (id (*)(id, SEL, NSString *, id, id, id, id))OrigAFPostParametersProgressSuccessFailure;
        return postOrig(self, NSSelectorFromString(@"POST:parameters:progress:success:failure:"), routedURL, routedParameters, progress, success, failure);
    }
    if (paidAppList && OrigAFPostParametersProgressSuccessFailure) {
        id (*postOrig)(id, SEL, NSString *, id, id, id, id) = (id (*)(id, SEL, NSString *, id, id, id, id))OrigAFPostParametersProgressSuccessFailure;
        return postOrig(self, NSSelectorFromString(@"POST:parameters:progress:success:failure:"), routedURL, routedParameters, progress, success, failure);
    }
    id (*orig)(id, SEL, NSString *, id, id, id, id) = (id (*)(id, SEL, NSString *, id, id, id, id))OrigAFGetParametersProgressSuccessFailure;
    return orig ? orig(self, _cmd, routedURL, routedParameters, progress, success, failure) : nil;
}

static NSURLRequest *JLYRoutedRequest(NSURLRequest *request) {
    JLYRememberLoginUIDFromRequest(request);
    NSURLRequest *routed = JLYRoutedMeetRequest(request);
    routed = JLYRoutedMatchmakerRequest(routed);
    routed = JLYRoutedMatchmakerDetailRequest(routed);
    routed = JLYRoutedPaidAppListPostRequest(routed);
    routed = JLYRoutedAllAppListSearchRequest(routed);
    return routed;
}

static id JLYSessionDataTaskWithRequestCompletion(id self, SEL _cmd, NSURLRequest *request, id completion) {
    id (*orig)(id, SEL, NSURLRequest *, id) = (id (*)(id, SEL, NSURLRequest *, id))OrigSessionDataTaskWithRequestCompletion;
    return orig ? orig(self, _cmd, JLYRoutedRequest(request), completion) : nil;
}

static id JLYSessionDataTaskWithURLCompletion(id self, SEL _cmd, NSURL *url, id completion) {
    id (*orig)(id, SEL, NSURL *, id) = (id (*)(id, SEL, NSURL *, id))OrigSessionDataTaskWithURLCompletion;
    if (!JLYURLIsMeetList(url) && !JLYURLIsMatchmakerRecommend(url) && !JLYURLIsPaidAppList(url) && !JLYURLIsAllAppList(url)) {
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
    return;
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

static void JLYDownloadFromVideoControl(id self, SEL _cmd) {
    NSURL *url = objc_getAssociatedObject(self, JLYDownloadVideoURLKey) ?: JLYLastPlayableVideoURL;
    if (!url) {
        @try {
            url = JLYURLFromValue([self valueForKey:@"videoUrl"]);
        } @catch (__unused NSException *exception) {
        }
    }
    UIViewController *presenter = JLYTopViewController();
    if (!JLYURLLooksLikeDirectVideo(url)) {
        JLYShowToast(presenter, @"该视频暂不支持保存到相册");
        return;
    }

    Class downloaderClass = NSClassFromString(@"LE_VideoZipDownload");
    SEL startSel = NSSelectorFromString(@"startDownloadVideoByPath:progress:block:");
    if (downloaderClass) {
        id downloader = nil;
        @try {
            SEL shareSel = NSSelectorFromString(@"shareManager");
            if ([downloaderClass respondsToSelector:shareSel]) {
                downloader = ((id (*)(id, SEL))objc_msgSend)(downloaderClass, shareSel);
            }
            if (!downloader) {
                downloader = [[downloaderClass alloc] init];
            }
        } @catch (__unused NSException *exception) {
        }
        if (downloader && [downloader respondsToSelector:startSel]) {
            JLYShowToast(presenter, @"开始保存视频");
            void (^progressBlock)(id) = ^(__unused id progress) {};
            void (^finishBlock)(id, id) = ^(id result, id error) {
                BOOL ok = NO;
                if ([result respondsToSelector:@selector(boolValue)]) {
                    ok = [result boolValue];
                } else if (result && result != (id)kCFNull) {
                    ok = YES;
                }
                if (error && error != (id)kCFNull) {
                    ok = NO;
                }
                JLYShowToast(presenter, ok ? @"视频已保存到相册" : @"保存失败");
            };
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(downloader, startSel, url.absoluteString ?: @"", progressBlock, finishBlock);
            return;
        }
    }

    JLYDownloadVideoAction(self, _cmd);
}

static NSString *JLYDownloadButtonTitle(void) {
    return [NSString stringWithFormat:@"%C%C", (unichar)0x4E0B, (unichar)0x8F7D];
}

static void JLYInstallDownloadButtonOnVideoControl(UIView *control) {
    if (![control isKindOfClass:UIView.class]) {
        return;
    }
    UIButton *existing = objc_getAssociatedObject(control, JLYDownloadButtonKey);
    if (existing && existing.superview) {
        return;
    }

    class_addMethod(control.class, NSSelectorFromString(@"clickDownloadBtn"), (IMP)JLYDownloadFromVideoControl, "v@:");
    class_addMethod(control.class, NSSelectorFromString(@"jly_downloadVideoFromControl"), (IMP)JLYDownloadFromVideoControl, "v@:");
    @try {
        NSURL *url = JLYURLFromValue([control valueForKey:@"videoUrl"]);
        if (url) {
            objc_setAssociatedObject(control, JLYDownloadVideoURLKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            JLYLastPlayableVideoURL = url;
        }
    } @catch (__unused NSException *exception) {
    }
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.62];
    button.tintColor = UIColor.whiteColor;
    button.layer.cornerRadius = 16.0;
    button.layer.masksToBounds = YES;
    button.titleLabel.font = [UIFont boldSystemFontOfSize:14.0];
    [button setTitle:@"下载" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [button addTarget:control action:NSSelectorFromString(@"clickDownloadBtn") forControlEvents:UIControlEventTouchUpInside];
    [control addSubview:button];
    objc_setAssociatedObject(control, JLYDownloadButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:control.trailingAnchor constant:-12.0],
        [button.bottomAnchor constraintEqualToAnchor:control.bottomAnchor constant:-12.0],
        [button.widthAnchor constraintEqualToConstant:66.0],
        [button.heightAnchor constraintEqualToConstant:32.0],
    ]];
}

static id JLYZFDlButton(id self, SEL _cmd) {
    return objc_getAssociatedObject(self, JLYDownloadButtonKey);
}

static void JLYZFSetDlButton(id self, SEL _cmd, id button) {
    objc_setAssociatedObject(self, JLYDownloadButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id JLYZFVideoUrl(id self, SEL _cmd) {
    return objc_getAssociatedObject(self, JLYDownloadVideoURLKey);
}

static void JLYZFSetVideoUrl(id self, SEL _cmd, id value) {
    NSURL *url = JLYURLFromValue(value);
    if (url) {
        JLYLastPlayableVideoURL = url;
    }
    objc_setAssociatedObject(self, JLYDownloadVideoURLKey, url ?: value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id JLYZFRateButton(id self, SEL _cmd) {
    return objc_getAssociatedObject(self, JLYRateButtonKey);
}

static void JLYZFSetRateButton(id self, SEL _cmd, id button) {
    objc_setAssociatedObject(self, JLYRateButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *JLYReferenceRateButton(UIView *control) {
    if (![control isKindOfClass:UIView.class]) {
        return nil;
    }
    @try {
        id rateButton = [control valueForKey:@"rateButton"];
        if ([rateButton isKindOfClass:UIView.class]) {
            return rateButton;
        }
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static UIView *JLYReferenceBackButton(UIView *control) {
    if (![control isKindOfClass:UIView.class]) {
        return nil;
    }
    @try {
        id backButton = [control valueForKey:@"backBtn"];
        if ([backButton isKindOfClass:UIView.class]) {
            return backButton;
        }
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static void JLYLayoutReferenceDownloadButton(UIView *control) {
    if (![control isKindOfClass:UIView.class]) {
        return;
    }
    UIButton *button = objc_getAssociatedObject(control, JLYDownloadButtonKey);
    if (![button isKindOfClass:UIButton.class]) {
        return;
    }

    UIView *backButton = JLYReferenceBackButton(control);
    UIView *host = backButton.superview ?: control;
    if (button.superview != host) {
        [button removeFromSuperview];
        [host addSubview:button];
    }

    button.translatesAutoresizingMaskIntoConstraints = YES;
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;

    CGFloat width = 44.0;
    CGFloat height = 20.0;
    CGFloat rightInset = 16.0;
    CGFloat gap = 16.0;
    CGFloat centerY = backButton ? backButton.center.y : 22.0;
    CGFloat x = control.frame.size.width - rightInset - width;
    CGFloat y = centerY - height / 2.0;
    if (x < 8.0) {
        x = MAX(host.bounds.size.width - rightInset - width, 8.0);
    }
    if (y < 0.0) {
        y = 0.0;
    }

    button.frame = CGRectMake((NSInteger)(x + 0.5), (NSInteger)(y + 0.5), (NSInteger)(width + 0.5), (NSInteger)(height + 0.5));
    button.hidden = NO;
    button.alpha = 1.0;

    UIView *rateButton = JLYReferenceRateButton(control);
    if (rateButton) {
        if (rateButton.superview != host) {
            [rateButton removeFromSuperview];
            [host addSubview:rateButton];
        }
        CGFloat rateX = button.frame.origin.x - gap - width;
        if (rateX < 8.0) {
            rateX = 8.0;
        }
        rateButton.frame = CGRectMake((NSInteger)(rateX + 0.5), (NSInteger)(y + 0.5), (NSInteger)(width + 0.5), (NSInteger)(height + 0.5));
    }
}

static void JLYInstallReferenceDownloadButtonOnVideoControl(UIView *control) {
    if (![control isKindOfClass:UIView.class]) {
        return;
    }

    class_replaceMethod(control.class, NSSelectorFromString(@"clickDownloadBtn"), (IMP)JLYDownloadFromVideoControl, "v@:");
    class_addMethod(control.class, NSSelectorFromString(@"jly_downloadVideoFromControl"), (IMP)JLYDownloadFromVideoControl, "v@:");
    @try {
        NSURL *url = JLYURLFromValue([control valueForKey:@"videoUrl"]);
        if (url) {
            objc_setAssociatedObject(control, JLYDownloadVideoURLKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            JLYLastPlayableVideoURL = url;
        }
    } @catch (__unused NSException *exception) {
    }

    UIButton *button = objc_getAssociatedObject(control, JLYDownloadButtonKey);
    if (![button isKindOfClass:UIButton.class]) {
        button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.backgroundColor = UIColor.clearColor;
        [button setAdjustsImageWhenHighlighted:YES];
        [button setShowsTouchWhenHighlighted:YES];
        button.contentEdgeInsets = UIEdgeInsetsZero;
        button.imageEdgeInsets = UIEdgeInsetsMake(10.0, 10.0, 10.0, 10.0);
        UIImage *saveImage = [UIImage imageNamed:@"tag_save"];
        if (saveImage) {
            [button setImage:saveImage forState:UIControlStateNormal];
        } else {
            button.titleLabel.font = [UIFont systemFontOfSize:12.0];
            [button setTitle:@"保存" forState:UIControlStateNormal];
            [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        }
        button.tintColor = UIColor.whiteColor;
        [button addTarget:control action:NSSelectorFromString(@"clickDownloadBtn") forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(control, JLYDownloadButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try {
            [control setValue:button forKey:@"dlButton"];
        } @catch (__unused NSException *exception) {
        }
    }

    [button setImage:nil forState:UIControlStateNormal];
    button.backgroundColor = UIColor.whiteColor;
    button.titleLabel.font = [UIFont systemFontOfSize:12.0];
    [button setTitle:JLYDownloadButtonTitle() forState:UIControlStateNormal];
    [button setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    button.layer.cornerRadius = 4.0;
    button.layer.masksToBounds = YES;
    JLYLayoutReferenceDownloadButton(control);
}

static void JLYInstallVideoControlDynamicAccessors(Class cls) {
    class_addMethod(cls, NSSelectorFromString(@"dlButton"), (IMP)JLYZFDlButton, "@@:");
    class_addMethod(cls, NSSelectorFromString(@"setDlButton:"), (IMP)JLYZFSetDlButton, "v@:@");
    class_addMethod(cls, NSSelectorFromString(@"videoUrl"), (IMP)JLYZFVideoUrl, "@@:");
    class_addMethod(cls, NSSelectorFromString(@"setVideoUrl:"), (IMP)JLYZFSetVideoUrl, "v@:@");
    class_addMethod(cls, NSSelectorFromString(@"rateButton"), (IMP)JLYZFRateButton, "@@:");
    class_addMethod(cls, NSSelectorFromString(@"setRateButton:"), (IMP)JLYZFSetRateButton, "v@:@");
    class_replaceMethod(cls, NSSelectorFromString(@"clickDownloadBtn"), (IMP)JLYDownloadFromVideoControl, "v@:");
    class_addMethod(cls, NSSelectorFromString(@"jly_downloadVideoFromControl"), (IMP)JLYDownloadFromVideoControl, "v@:");
}

static id JLYZFLandScapeInitWithFrame(id self, SEL _cmd, CGRect frame) {
    id (*orig)(id, SEL, CGRect) = (id (*)(id, SEL, CGRect))OrigZFLandScapeInitWithFrame;
    id result = orig ? orig(self, _cmd, frame) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        JLYInstallReferenceDownloadButtonOnVideoControl(result);
    });
    return result;
}

static id JLYZFLandScapeInitWithCoder(id self, SEL _cmd, NSCoder *coder) {
    id (*orig)(id, SEL, NSCoder *) = (id (*)(id, SEL, NSCoder *))OrigZFLandScapeInitWithCoder;
    id result = orig ? orig(self, _cmd, coder) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        JLYInstallReferenceDownloadButtonOnVideoControl(result);
    });
    return result;
}

static void JLYZFLandScapeLayoutSubviews(id self, SEL _cmd) {
    void (*orig)(id, SEL) = (void (*)(id, SEL))OrigZFLandScapeLayoutSubviews;
    if (orig) {
        orig(self, _cmd);
    }
    JLYInstallReferenceDownloadButtonOnVideoControl(self);
}

static void JLYZFLandScapeSetVideoUrl(id self, SEL _cmd, id value) {
    NSURL *url = JLYURLFromValue(value);
    if (url) {
        JLYLastPlayableVideoURL = url;
        objc_setAssociatedObject(self, JLYDownloadVideoURLKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))OrigZFLandScapeSetVideoUrl;
    if (orig) {
        orig(self, _cmd, value);
    }
    JLYInstallReferenceDownloadButtonOnVideoControl(self);
}

static NSURL *JLYVideoURLFromController(UIViewController *controller) {
    if (!controller) {
        return nil;
    }
    NSArray<NSString *> *keys = @[
        @"videoUrl",
        @"videoURL",
        @"mUrl",
        @"url",
        @"playUrl",
        @"playURL",
        @"download_url",
        @"downloadUrl",
        @"line_url",
        @"localResUrl",
    ];
    for (NSString *key in keys) {
        @try {
            NSURL *url = JLYURLFromValue([controller valueForKey:key]);
            if (url) {
                return url;
            }
        } @catch (__unused NSException *exception) {
        }
    }
    for (UIView *view in controller.view.subviews) {
        for (NSString *key in keys) {
            @try {
                NSURL *url = JLYURLFromValue([view valueForKey:key]);
                if (url) {
                    return url;
                }
            } @catch (__unused NSException *exception) {
            }
        }
    }
    return JLYLastPlayableVideoURL;
}

static BOOL JLYLooksLikeNativeVideoController(UIViewController *controller) {
    NSString *className = NSStringFromClass(controller.class);
    return [className containsString:@"LE_WatchVideoViewController"] ||
           [className containsString:@"LESystemVideoViewController"] ||
           [className containsString:@"LE_VideoSeedViewController"] ||
           [className containsString:@"LEUserVideo"] ||
           [className.lowercaseString containsString:@"watchvideo"] ||
           [className.lowercaseString containsString:@"systemvideo"];
}

static void JLYPlayVideoURLString(id self, SEL _cmd, id urlString) {
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))OrigPlayVideoURLString;
    if (orig) {
        orig(self, _cmd, urlString);
    }
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

static UIWindow *JLYKeyWindow(void) {
    UIWindow *window = UIApplication.sharedApplication.keyWindow;
    if (window) {
        return window;
    }

    NSArray<UIWindow *> *windows = UIApplication.sharedApplication.windows;
    for (UIWindow *candidate in windows) {
        if (candidate.isKeyWindow) {
            return candidate;
        }
    }
    for (UIWindow *candidate in windows) {
        if (!candidate.hidden && candidate.alpha > 0.0) {
            return candidate;
        }
    }
    return windows.firstObject;
}

static UIViewController *JLYTopViewController(void) {
    UIViewController *controller = JLYKeyWindow().rootViewController;
    if (!controller) {
        return nil;
    }
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

static BOOL JLYClassNameLooksLikeComic(NSString *className) {
    NSString *lower = JLYString(className).lowercaseString;
    return [lower containsString:@"jfcomic"] ||
           [lower containsString:@"comicstore"] ||
           [lower containsString:@"comicbooklist"] ||
           [lower containsString:@"comicbookreader"] ||
           [lower containsString:@"paradisecomicviewcontroller"];
}

static BOOL JLYControllerTreeLooksLikeComic(UIViewController *controller) {
    if (!controller) {
        return NO;
    }
    if (JLYClassNameLooksLikeComic(NSStringFromClass(controller.class))) {
        return YES;
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        UINavigationController *nav = (UINavigationController *)controller;
        for (UIViewController *child in nav.viewControllers) {
            if (JLYControllerTreeLooksLikeComic(child)) {
                return YES;
            }
        }
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        UITabBarController *tab = (UITabBarController *)controller;
        for (UIViewController *child in tab.viewControllers) {
            if (JLYControllerTreeLooksLikeComic(child)) {
                return YES;
            }
        }
    }
    for (UIViewController *child in controller.childViewControllers) {
        if (JLYControllerTreeLooksLikeComic(child)) {
            return YES;
        }
    }
    return NO;
}

static void JLYRememberComicShellRoot(UIViewController *controller) {
    if (!controller || !JLYControllerTreeLooksLikeComic(controller)) {
        return;
    }
    JLYComicShellRootController = controller;
}

static BOOL JLYControllerLooksLikeMainProgram(UIViewController *controller) {
    if (!controller || [controller isKindOfClass:UIAlertController.class]) {
        return NO;
    }
    if (JLYControllerTreeLooksLikeComic(controller)) {
        return NO;
    }

    NSString *className = NSStringFromClass(controller.class).lowercaseString;
    NSString *title = JLYString(controller.title).lowercaseString;
    NSString *navTitle = JLYString(controller.navigationItem.title).lowercaseString;
    NSString *combined = [NSString stringWithFormat:@"%@ %@ %@", className, title, navTitle];
    NSArray<NSString *> *markers = @[
        @"le_mainviewcontroller",
        @"jileyuan",
        @"paradise",
        @"meet",
        @"matchmaker",
        @"circle",
        @"dynamic",
        @"moment",
        @"message",
        @"chat",
        @"recommend",
        @"square",
        @"paid",
        @"video",
        @"live"
    ];
    for (NSString *marker in markers) {
        if ([combined containsString:marker]) {
            return YES;
        }
    }
    return NO;
}

static UIViewController *JLYCreateControllerNamed(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls || ![cls isSubclassOfClass:UIViewController.class]) {
        return nil;
    }

    UIViewController *controller = nil;
    @try {
        NSString *nibName = [[NSBundle mainBundle] pathForResource:className ofType:@"nib"] ? className : nil;
        controller = nibName ? [[cls alloc] initWithNibName:nibName bundle:nil] : [[cls alloc] init];
    } @catch (__unused NSException *exception) {
        controller = nil;
    }
    return controller;
}

static void JLYPrepareComicShellController(UIViewController *root) {
    if ([root isKindOfClass:UINavigationController.class]) {
        UINavigationController *nav = (UINavigationController *)root;
        for (UIViewController *child in nav.viewControllers) {
            if (JLYControllerTreeLooksLikeComic(child)) {
                [nav setViewControllers:@[child] animated:NO];
                return;
            }
        }
        [nav popToRootViewControllerAnimated:NO];
        return;
    }
    if ([root isKindOfClass:UITabBarController.class]) {
        UITabBarController *tab = (UITabBarController *)root;
        NSUInteger index = 0;
        for (UIViewController *child in tab.viewControllers) {
            if (JLYControllerTreeLooksLikeComic(child)) {
                tab.selectedIndex = index;
                return;
            }
            index++;
        }
    }
}

static UIViewController *JLYCreateComicShellRootController(void) {
    if (JLYComicShellRootController) {
        JLYPrepareComicShellController(JLYComicShellRootController);
        return JLYComicShellRootController;
    }

    NSArray<NSString *> *candidates = @[
        @"LE_RN_ComicStoreViewController",
        @"LE_RN_JFComicMoreViewController",
        @"LE_RN_JFComicSectionsListViewController",
        @"LE_RD_JFComicSectionsListViewController",
        @"LE_RN_JFComicBookReaderController",
        @"LE_RD_JFComicBookReaderController"
    ];
    for (NSString *className in candidates) {
        UIViewController *controller = JLYCreateControllerNamed(className);
        if (!controller) {
            continue;
        }
        controller.title = controller.title ?: JLYComicButtonTitle();
        if ([controller isKindOfClass:UINavigationController.class] || [controller isKindOfClass:UITabBarController.class]) {
            JLYRememberComicShellRoot(controller);
            return controller;
        }
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
        nav.navigationBar.translucent = NO;
        JLYRememberComicShellRoot(nav);
        return nav;
    }
    return nil;
}

static void JLYShowReturnComicFailure(void) {
    UIViewController *presenter = JLYTopViewController();
    if (!presenter) {
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Return failed"
                                                                   message:@"Comic shell controller was not found."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void JLYReturnToComicShellAction(id self, SEL _cmd) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = JLYKeyWindow();
        UIViewController *comicRoot = JLYCreateComicShellRootController();
        if (!window || !comicRoot) {
            JLYShowReturnComicFailure();
            return;
        }

        void (^switchRoot)(void) = ^{
            JLYPrepareComicShellController(comicRoot);
            [UIView transitionWithView:window
                              duration:0.25
                               options:UIViewAnimationOptionTransitionCrossDissolve
                            animations:^{
                window.rootViewController = comicRoot;
            } completion:nil];
            [window makeKeyAndVisible];
        };

        UIViewController *currentRoot = window.rootViewController;
        if (currentRoot.presentedViewController) {
            [currentRoot dismissViewControllerAnimated:NO completion:switchRoot];
        } else {
            switchRoot();
        }
    });
}

static void JLYReturnComicTapAction(id self, SEL _cmd, UITapGestureRecognizer *gesture) {
    if (gesture.state != UIGestureRecognizerStateRecognized) {
        return;
    }
    CGPoint point = [gesture locationInView:gesture.view];
    if (point.x <= 96.0 && point.y <= 112.0) {
        JLYReturnToComicShellAction(self, _cmd);
    }
}

static void JLYInstallReturnComicButton(UIViewController *controller) {
    if (!JLYControllerLooksLikeMainProgram(controller)) {
        return;
    }

    UIWindow *window = controller.view.window ?: JLYKeyWindow();
    if (!window || objc_getAssociatedObject(window, JLYReturnComicGestureKey)) {
        return;
    }

    SEL action = NSSelectorFromString(@"jly_returnComicTap:");
    class_addMethod(window.class, action, (IMP)JLYReturnComicTapAction, "v@:@");
    UITapGestureRecognizer *gesture = [[UITapGestureRecognizer alloc] initWithTarget:window action:action];
    gesture.numberOfTapsRequired = 4;
    gesture.cancelsTouchesInView = NO;
    [window addGestureRecognizer:gesture];
    objc_setAssociatedObject(window, JLYReturnComicGestureKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void JLYWindowSetRootViewController(id self, SEL _cmd, UIViewController *rootViewController) {
    JLYRememberComicShellRoot(rootViewController);
    void (*orig)(id, SEL, UIViewController *) = (void (*)(id, SEL, UIViewController *))OrigWindowSetRootViewController;
    if (orig) {
        orig(self, _cmd, rootViewController);
    }
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
        JLYRememberComicShellRoot(JLYKeyWindow().rootViewController);
        JLYInstallReturnComicButton(controller);
        JLYInstallAllAppListSearchButton(controller);
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
    JLYSwizzle(manager,
               NSSelectorFromString(@"GET:parameters:success:failure:"),
               (IMP)JLYAFGetParametersSuccessFailure,
               &OrigAFGetParametersSuccessFailure);
    JLYSwizzle(manager,
               NSSelectorFromString(@"GET:parameters:progress:success:failure:"),
               (IMP)JLYAFGetParametersProgressSuccessFailure,
               &OrigAFGetParametersProgressSuccessFailure);
}

static void JLYInstallMatchmakerUIHooks(void) {
    JLYSwizzle(UIWindow.class,
               NSSelectorFromString(@"setRootViewController:"),
               (IMP)JLYWindowSetRootViewController,
               &OrigWindowSetRootViewController);
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

static void JLYInstallVideoControlHooks(void) {
    if (JLYVideoControlHooksInstalled) {
        return;
    }
    Class cls = NSClassFromString(@"ZFLandScapeControlView");
    if (!cls) {
        return;
    }
    JLYInstallVideoControlDynamicAccessors(cls);
    JLYSwizzle(cls,
               NSSelectorFromString(@"initWithFrame:"),
               (IMP)JLYZFLandScapeInitWithFrame,
               &OrigZFLandScapeInitWithFrame);
    JLYSwizzle(cls,
               NSSelectorFromString(@"initWithCoder:"),
               (IMP)JLYZFLandScapeInitWithCoder,
               &OrigZFLandScapeInitWithCoder);
    JLYSwizzle(cls,
               NSSelectorFromString(@"layoutSubviews"),
               (IMP)JLYZFLandScapeLayoutSubviews,
               &OrigZFLandScapeLayoutSubviews);
    JLYSwizzle(cls,
               NSSelectorFromString(@"setVideoUrl:"),
               (IMP)JLYZFLandScapeSetVideoUrl,
               &OrigZFLandScapeSetVideoUrl);
    JLYVideoControlHooksInstalled = YES;
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
