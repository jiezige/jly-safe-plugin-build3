#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <objc/runtime.h>

#ifdef __cplusplus
#define JLY_EXTERN_C extern "C"
#else
#define JLY_EXTERN_C extern
#endif

static NSString * const kJLYBaseURL = @"https://stz.jlyapp.cn";
static NSString * const kJLYUpdatePath = @"/app-update.json";
static NSString * const kJLYVip1BaseURL = @"https://api.jlyapp.cn";
static NSString * const kJLYVip1CheckPath = @"/vip1";
static NSString * const kJLYActivationPath = @"/vip1/activate";
static NSString * const kJLYPaidPostsPath = @"/api/posts/app-list";
static NSString * const kJLYPaidPostsToken = @"EUDV6gd9cvJOWCBtKIfniR1zueqAjp5rSYxFso8yGX43mbZa";
static NSString * const kJLYIngestPath = @"/api/posts/ingest-response";
static NSString * const kJLYVip1MeetListURL = @"https://api.jlyapp.cn/vip1/meet-list";
static NSString * const kJLYVip1ActivateURL = @"https://api.jlyapp.cn/vip1/activate";
static NSString * const kJLYDefaultsSuite = @"cn.jly.safeplugin";
static BOOL const kJLYRequireActivationOnLaunch = NO;

static BOOL JLYStringHasVideoSuffix(NSString *value);
static BOOL JLYURLLooksLikeCircleEndpoint(NSString *value);
static BOOL JLYURLLooksLikeCircleListV1(NSURL *url);
static BOOL JLYURLLooksLikePaidPosts(NSURL *url);
static BOOL JLYURLLooksLikeMeetList(NSURL *url);
static NSURL *JLYRoutedURL(NSURL *url);

@interface JLYPaidVideoCell : UITableViewCell
@end

@interface JLYSafePlugin : NSObject <UITableViewDataSource, UITableViewDelegate>
+ (instancetype)shared;
- (void)start;
- (void)checkUpdate;
- (void)showActivationPromptWithReason:(NSString *)reason;
- (BOOL)isActivated;
- (NSUserDefaults *)defaults;
- (void)showPaidVideoList;
- (void)checkVip1ThenShowPaidVideoList;
- (void)fetchPaidVideoListWithPageInfo:(NSString *)pageInfo append:(BOOL)append;
- (void)installDynamicPaidVideoEntryIfNeededInViewController:(UIViewController *)viewController;
- (void)installMoreAuthorizationOverlaysInViewController:(UIViewController *)viewController;
- (void)replaceFollowColumnTitleInViewController:(UIViewController *)viewController;
- (void)captureLoginUIDFromRequest:(NSURLRequest *)request;
- (void)captureLoginUIDFromBodyData:(NSData *)body;
- (void)captureLoginUIDFromResponseData:(NSData *)data;
- (void)verifyAuthorizationAfterLoginUID:(NSString *)uid force:(BOOL)force;
- (void)reportResponseData:(NSData *)data forURL:(NSURL *)url;
- (void)ensureCircleListAuthorizationIfNeeded;
- (NSData *)nativeCircleListDataIfNeededForURL:(NSURL *)url data:(NSData *)data;
- (void)handleCircleListV1Request:(NSURLRequest *)request
                            data:(NSData *)data
                        response:(NSURLResponse *)response
                           error:(NSError *)error
               completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;
- (NSURLRequest *)routedRequest:(NSURLRequest *)request;
@end

@interface UIControl (JLYSafePluginHooks)
- (void)jly_sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event;
@end

@interface UIViewController (JLYSafePluginHooks)
- (void)jly_viewDidAppear:(BOOL)animated;
- (void)jly_viewDidLayoutSubviews;
@end

@interface NSURLSession (JLYSafePluginHooks)
- (NSURLSessionDataTask *)jly_dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;
- (NSURLSessionDataTask *)jly_dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;
- (NSURLSessionDataTask *)jly_dataTaskWithRequest:(NSURLRequest *)request;
- (NSURLSessionUploadTask *)jly_uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;
- (NSURLSessionUploadTask *)jly_uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;
- (NSURLSessionUploadTask *)jly_uploadTaskWithStreamedRequest:(NSURLRequest *)request;
@end

@interface NSURLConnection (JLYSafePluginHooks)
+ (void)jly_sendAsynchronousRequest:(NSURLRequest *)request queue:(NSOperationQueue *)queue completionHandler:(void (^)(NSURLResponse *response, NSData *data, NSError *connectionError))handler;
+ (NSData *)jly_sendSynchronousRequest:(NSURLRequest *)request returningResponse:(NSURLResponse **)response error:(NSError **)error;
+ (NSURLConnection *)jly_connectionWithRequest:(NSURLRequest *)request delegate:(id)delegate;
- (instancetype)jly_initWithRequest:(NSURLRequest *)request delegate:(id)delegate startImmediately:(BOOL)startImmediately;
@end

@implementation JLYPaidVideoCell
@end

@implementation JLYSafePlugin {
  BOOL _started;
  BOOL _paidListLoading;
  BOOL _circleAuthChecking;
  BOOL _loginAuthChecking;
  NSString *_lastLoginAuthUID;
  NSMutableArray<NSDictionary *> *_paidPosts;
  UITableViewController *_paidListController;
}

+ (instancetype)shared {
  static JLYSafePlugin *plugin;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    plugin = [[JLYSafePlugin alloc] init];
  });
  return plugin;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _paidPosts = [NSMutableArray array];
  }
  return self;
}

- (void)start {
  if (_started) return;
  _started = YES;

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(applicationReady)
                                               name:UIApplicationDidFinishLaunchingNotification
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(applicationReady)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(applicationReady)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self applicationReady];
  });
}

- (void)applicationReady {
  static BOOL didRunOnce = NO;
  if (didRunOnce) return;
  didRunOnce = YES;

  [self checkUpdate];
  NSString *uid = [self uid];
  if (uid.length > 0) {
    [self verifyAuthorizationAfterLoginUID:uid force:YES];
  }
  if (kJLYRequireActivationOnLaunch && ![self isActivated]) {
    [self showActivationPromptWithReason:@"请输入激活码"];
  }
}

- (NSUserDefaults *)defaults {
  NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kJLYDefaultsSuite];
  return defaults ?: [NSUserDefaults standardUserDefaults];
}

- (NSString *)deviceId {
  NSString *saved = [[self defaults] stringForKey:@"device_id"];
  if (saved.length > 0) return saved;

  NSString *identifier = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
  if (identifier.length == 0) {
    identifier = [[NSUUID UUID] UUIDString];
  }
  [[self defaults] setObject:identifier forKey:@"device_id"];
  [[self defaults] synchronize];
  return identifier;
}

- (NSString *)uid {
  NSString *loginUID = [self loginUIDFromAppStorage];
  if (loginUID.length > 0) return loginUID;
  return @"";
}

- (NSString *)loginUIDFromAppStorage {
  NSArray<NSUserDefaults *> *stores = @[
    [NSUserDefaults standardUserDefaults],
    [self defaults],
  ];
  NSArray<NSString *> *keys = @[@"login_uid", @"loginUid"];

  for (NSUserDefaults *store in stores) {
    for (NSString *key in keys) {
      id value = [store objectForKey:key];
      NSString *string = [self stringValue:value fallback:@""];
      if (string.length > 0 && ![string hasPrefix:@"ios_"]) return string;
    }
  }

  NSArray<NSString *> *plistNames = @[@"UserInfo", @"userInfo", @"LoginInfo", @"loginInfo", @"Account", @"account"];
  for (NSString *name in plistNames) {
    NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"plist"];
    NSDictionary *dict = path.length > 0 ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    if (![dict isKindOfClass:[NSDictionary class]]) continue;
    for (NSString *key in keys) {
      NSString *string = [self stringValue:dict[key] fallback:@""];
      if (string.length > 0 && ![string hasPrefix:@"ios_"]) return string;
    }
  }

  return @"";
}

- (void)cacheLoginUIDIfValid:(NSString *)value {
  NSString *uid = [self stringValue:value fallback:@""];
  if (uid.length == 0 || [uid hasPrefix:@"ios_"]) return;
  NSString *previous = [[self defaults] stringForKey:@"login_uid"];
  [[self defaults] setObject:uid forKey:@"login_uid"];
  [[self defaults] synchronize];
  [self verifyAuthorizationAfterLoginUID:uid force:![previous isEqualToString:uid]];
}

- (NSString *)queryValueNamed:(NSString *)name inString:(NSString *)value {
  if (name.length == 0 || value.length == 0) return @"";
  NSURLComponents *components = [NSURLComponents componentsWithString:value];
  NSArray<NSURLQueryItem *> *items = components.queryItems;
  if (items.count == 0) {
    components = [NSURLComponents componentsWithString:[@"https://local/?" stringByAppendingString:value]];
    items = components.queryItems;
  }
  for (NSURLQueryItem *item in items) {
    if ([item.name isEqualToString:name] && item.value.length > 0) return item.value;
  }
  return @"";
}

- (void)captureLoginUIDFromRequest:(NSURLRequest *)request {
  NSString *urlString = request.URL.absoluteString ?: @"";
  NSString *uid = [self queryValueNamed:@"login_uid" inString:urlString];
  if (uid.length == 0) uid = [self queryValueNamed:@"uid" inString:urlString];
  if (uid.length > 0) {
    [self cacheLoginUIDIfValid:uid];
    return;
  }

  [self captureLoginUIDFromBodyData:request.HTTPBody];
}

- (void)captureLoginUIDFromBodyData:(NSData *)body {
  if (body.length == 0) return;
  NSString *bodyString = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"";
  NSString *uid = [self queryValueNamed:@"login_uid" inString:bodyString];
  if (uid.length == 0) uid = [self queryValueNamed:@"uid" inString:bodyString];
  if (uid.length == 0) {
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if ([json isKindOfClass:[NSDictionary class]]) {
      uid = [self stringValue:json[@"login_uid"] fallback:@""];
      if (uid.length == 0) uid = [self stringValue:json[@"uid"] fallback:@""];
    }
  }
  if (uid.length > 0) [self cacheLoginUIDIfValid:uid];
}

- (NSString *)findLoginUIDInObject:(id)object depth:(NSInteger)depth {
  if (!object || depth < 0) return @"";
  if ([object isKindOfClass:[NSDictionary class]]) {
    NSDictionary *dict = (NSDictionary *)object;
    for (NSString *key in @[@"login_uid", @"loginUid"]) {
      NSString *value = [self stringValue:dict[key] fallback:@""];
      if (value.length > 0 && ![value hasPrefix:@"ios_"]) return value;
    }
    for (id value in dict.allValues) {
      NSString *found = [self findLoginUIDInObject:value depth:depth - 1];
      if (found.length > 0) return found;
    }
  } else if ([object isKindOfClass:[NSArray class]]) {
    for (id value in (NSArray *)object) {
      NSString *found = [self findLoginUIDInObject:value depth:depth - 1];
      if (found.length > 0) return found;
    }
  }
  return @"";
}

- (void)captureLoginUIDFromResponseData:(NSData *)data {
  if (data.length == 0) return;
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  NSString *uid = [self findLoginUIDInObject:json depth:5];
  if (uid.length > 0) [self cacheLoginUIDIfValid:uid];
}

- (BOOL)isActivated {
  return [[self defaults] boolForKey:@"activated"];
}

- (NSURL *)urlWithPath:(NSString *)path {
  return [NSURL URLWithString:[kJLYBaseURL stringByAppendingString:path]];
}

- (NSURL *)vip1URLWithPath:(NSString *)path {
  return [NSURL URLWithString:[kJLYVip1BaseURL stringByAppendingString:path]];
}

- (NSURL *)paidPostsURLWithPageInfo:(NSString *)pageInfo {
  return [self paidPostsURLWithCount:@"20" pageInfo:pageInfo];
}

- (NSURL *)paidPostsURLWithCount:(NSString *)count pageInfo:(NSString *)pageInfo {
  NSURLComponents *components = [NSURLComponents componentsWithString:[kJLYBaseURL stringByAppendingString:kJLYPaidPostsPath]];
  NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
  [items addObject:[NSURLQueryItem queryItemWithName:@"token" value:kJLYPaidPostsToken]];
  [items addObject:[NSURLQueryItem queryItemWithName:@"uid" value:[self uid]]];
  [items addObject:[NSURLQueryItem queryItemWithName:@"device_id" value:[self deviceId]]];
  [items addObject:[NSURLQueryItem queryItemWithName:@"count" value:(count.length > 0 ? count : @"10")]];
  if (pageInfo.length > 0) [items addObject:[NSURLQueryItem queryItemWithName:@"page_info" value:pageInfo]];
  components.queryItems = items;
  return components.URL;
}

- (NSData *)paidPostsBodyWithCount:(NSString *)count pageInfo:(NSString *)pageInfo {
  NSMutableDictionary *payload = [@{
    @"uid": [self uid],
    @"device_id": [self deviceId],
    @"count": (count.length > 0 ? count : @"10")
  } mutableCopy];
  if (pageInfo.length > 0) payload[@"page_info"] = pageInfo;
  return [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
}

- (void)clearActivationState {
  NSUserDefaults *defaults = [self defaults];
  [defaults setBool:NO forKey:@"activated"];
  [defaults removeObjectForKey:@"activation_code"];
  [defaults synchronize];
}

- (BOOL)isAuthorizedResponseJSON:(NSDictionary *)json {
  if (![json isKindOfClass:[NSDictionary class]]) return NO;
  return [json[@"authorized"] boolValue]
    || ([json[@"ok"] boolValue] && [json[@"activated"] boolValue]);
}

- (void)verifyAuthorizationAfterLoginUID:(NSString *)uid force:(BOOL)force {
  uid = [self stringValue:uid fallback:@""];
  if (uid.length == 0 || [uid hasPrefix:@"ios_"]) return;
  if (_loginAuthChecking) return;
  if (!force && [_lastLoginAuthUID isEqualToString:uid]) return;

  NSURL *url = [self vip1URLWithPath:kJLYVip1CheckPath];
  if (!url) return;

  _loginAuthChecking = YES;
  _lastLoginAuthUID = [uid copy];

  NSDictionary *payload = @{
    @"uid": uid,
    @"device_id": [self deviceId]
  };
  NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  request.HTTPBody = body;
  [request setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"content-type"];
  [request setValue:@"application/json" forHTTPHeaderField:@"accept"];

  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    BOOL authorized = NO;
    if (!error && data.length > 0) {
      NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      authorized = [self isAuthorizedResponseJSON:json];
    }

    self->_loginAuthChecking = NO;
    if (authorized) {
      [[self defaults] setBool:YES forKey:@"activated"];
      [[self defaults] synchronize];
    } else {
      [self clearActivationState];
      dispatch_async(dispatch_get_main_queue(), ^{
        [self showActivationPromptWithReason:@"激活后可共享免费观看使用此软件的解锁的付费视频"];
      });
    }
  }];
  [task resume];
}

- (void)checkUpdate {
  NSURL *url = [self urlWithPath:kJLYUpdatePath];
  if (!url) return;

  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url
                                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    if (error || data.length == 0) return;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return;
    if (![json[@"enabled"] boolValue]) return;

    NSString *title = [self stringValue:json[@"title"] fallback:@"发现新版本"];
    NSString *message = [self stringValue:json[@"message"] fallback:@"请更新到最新版本"];
    NSString *downloadURL = [self stringValue:json[@"url"] fallback:@""];
    BOOL force = [json[@"force"] boolValue];
    NSString *dedupeKey = [NSString stringWithFormat:@"%@|%@|%@", title, message, downloadURL];

    if (!force && [[[self defaults] stringForKey:@"last_update_alert"] isEqualToString:dedupeKey]) {
      return;
    }

    [[self defaults] setObject:dedupeKey forKey:@"last_update_alert"];
    [[self defaults] synchronize];

    dispatch_async(dispatch_get_main_queue(), ^{
      [self presentUpdateTitle:title message:message downloadURL:downloadURL force:force];
    });
  }];
  [task resume];
}

- (NSString *)stringValue:(id)value fallback:(NSString *)fallback {
  if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
  if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
  return fallback;
}

- (NSArray *)arrayValue:(id)value {
  if ([value isKindOfClass:[NSArray class]]) return value;
  if ([value isKindOfClass:[NSString class]] && [value length] > 0) return @[value];
  return @[];
}

- (UIViewController *)topViewController {
  UIWindow *keyWindow = nil;
  for (UIWindow *window in [UIApplication sharedApplication].windows) {
    if (window.isKeyWindow) {
      keyWindow = window;
      break;
    }
  }
  if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;

  UIViewController *vc = keyWindow.rootViewController;
  while (vc.presentedViewController) vc = vc.presentedViewController;
  if ([vc isKindOfClass:[UINavigationController class]]) {
    vc = [(UINavigationController *)vc visibleViewController];
  }
  if ([vc isKindOfClass:[UITabBarController class]]) {
    vc = [(UITabBarController *)vc selectedViewController];
  }
  return vc;
}

- (void)presentUpdateTitle:(NSString *)title message:(NSString *)message downloadURL:(NSString *)downloadURL force:(BOOL)force {
  UIViewController *vc = [self topViewController];
  if (!vc) return;

  UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                 message:message
                                                          preferredStyle:UIAlertControllerStyleAlert];
  if (!force) {
    [alert addAction:[UIAlertAction actionWithTitle:@"以后再说"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
  }
  [alert addAction:[UIAlertAction actionWithTitle:@"立即更新"
                                            style:UIAlertActionStyleDefault
                                          handler:^(__unused UIAlertAction *action) {
    NSURL *url = [NSURL URLWithString:downloadURL];
    if (!url) return;
    UIApplication *app = [UIApplication sharedApplication];
    if ([app respondsToSelector:@selector(openURL:options:completionHandler:)]) {
      [app openURL:url options:@{} completionHandler:nil];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      [app openURL:url];
#pragma clang diagnostic pop
    }
  }]];
  [vc presentViewController:alert animated:YES completion:nil];
}

- (void)showActivationPromptWithReason:(NSString *)reason {
  UIViewController *vc = [self topViewController];
  if (!vc) return;

  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"激活码"
                                                                 message:reason ?: @"请输入激活码"
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
    textField.placeholder = @"激活码";
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
  }];
  [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:@"确认激活"
                                            style:UIAlertActionStyleDefault
                                          handler:^(__unused UIAlertAction *action) {
    NSString *code = alert.textFields.firstObject.text ?: @"";
    [self activateWithCode:code];
  }]];
  [vc presentViewController:alert animated:YES completion:nil];
}

- (void)activateWithCode:(NSString *)code {
  if (code.length == 0) {
    [self showActivationPromptWithReason:@"激活码不能为空"];
    return;
  }

  NSString *uid = [self uid];
  if (uid.length == 0) {
    [self presentMessage:@"未获取到login_uid，请先登录账号后重试"];
    return;
  }

  [self presentToast:@"正在验证激活码"];
  NSURL *url = [self vip1URLWithPath:kJLYActivationPath];
  if (!url) return;

  NSDictionary *payload = @{
    @"uid": uid,
    @"device_id": [self deviceId],
    @"code": code
  };
  NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  request.HTTPBody = body;
  [request setValue:@"application/json" forHTTPHeaderField:@"content-type"];

  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    BOOL activated = NO;
    NSString *message = @"激活失败";
    if (!error && data.length > 0) {
      NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      if ([json isKindOfClass:[NSDictionary class]]) {
        activated = [self isAuthorizedResponseJSON:json];
        message = [self stringValue:json[@"message"] fallback:(activated ? @"激活成功" : @"激活失败")];
      }
    }

    if (activated) {
      [[self defaults] setBool:YES forKey:@"activated"];
      [[self defaults] setObject:code forKey:@"activation_code"];
      [[self defaults] setBool:YES forKey:@"route_meet_list_to_vip1"];
      [[self defaults] synchronize];
    } else {
      [self clearActivationState];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      if (activated) {
        [self presentToast:message];
        if (self->_paidListController) {
          [self fetchPaidVideoListWithPageInfo:nil append:NO];
        } else {
          [self showPaidVideoList];
        }
      } else {
        [self presentMessage:message];
      }
    });
  }];
  [task resume];
}

- (void)presentToast:(NSString *)message {
  UIViewController *vc = [self topViewController];
  if (!vc) return;

  UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                 message:message
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [vc presentViewController:alert animated:YES completion:^{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [alert dismissViewControllerAnimated:YES completion:nil];
    });
  }];
}

- (void)presentMessage:(NSString *)message {
  UIViewController *vc = [self topViewController];
  if (!vc) return;

  UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                 message:message
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
  [vc presentViewController:alert animated:YES completion:nil];
}

- (void)checkVip1ThenShowPaidVideoList {
  [self checkRemoteVip1Authorization];
}

- (void)showPaidVideoList {
  [[self defaults] setBool:YES forKey:@"route_meet_list_to_vip1"];
  [[self defaults] synchronize];
  NSLog(@"vip1入口已触发");

  UITableViewController *table = [[UITableViewController alloc] initWithStyle:UITableViewStylePlain];
  table.title = @"解锁的付费视频";
  table.tableView.dataSource = self;
  table.tableView.delegate = self;
  table.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                          target:self
                                                                                          action:@selector(reloadPaidVideoList)];
  table.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                         target:self
                                                                                         action:@selector(closePaidVideoList)];
  _paidListController = table;

  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:table];
  [[self topViewController] presentViewController:nav animated:YES completion:nil];
  [self fetchPaidVideoListWithPageInfo:nil append:NO];
}

- (void)checkRemoteVip1Authorization {
  NSURL *url = [self vip1URLWithPath:kJLYVip1CheckPath];
  if (!url) return;
  NSString *uid = [self uid];
  if (uid.length == 0) {
    [self presentMessage:@"未获取到login_uid，请先登录账号后重试"];
    return;
  }

  NSDictionary *payload = @{
    @"uid": uid,
    @"device_id": [self deviceId]
  };
  NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  request.HTTPBody = body;
  [request setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"content-type"];
  [request setValue:@"application/json" forHTTPHeaderField:@"accept"];

  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    BOOL authorized = NO;
    NSString *message = @"激活后可共享免费观看使用此软件的解锁的付费视频";
    if (!error && data.length > 0) {
      NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      if ([json isKindOfClass:[NSDictionary class]]) {
        authorized = [self isAuthorizedResponseJSON:json];
        message = [self stringValue:json[@"message"] fallback:message];
      }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      if (authorized) {
        [[self defaults] setBool:YES forKey:@"activated"];
        [[self defaults] synchronize];
        if (self->_paidListController) {
          [self fetchPaidVideoListWithPageInfo:nil append:NO];
        } else {
          [self showPaidVideoList];
        }
      } else {
        [self clearActivationState];
        [self showActivationPromptWithReason:message];
      }
    });
  }];
  [task resume];
}

- (NSData *)emptyNativeCircleListData {
  NSDictionary *payload = @{
    @"moment_list": @[],
    @"like": @[],
    @"user": @[],
    @"display": @[],
    @"favorite": @[],
    @"start": @0
  };
  NSDictionary *json = @{
    @"c": @200,
    @"n": @"",
    @"m": @"",
    @"p": payload,
    @"h": @"",
    @"l": @"",
    @"ts": @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0))
  };
  return [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
}

- (NSData *)nativeCircleListDataFromPaidPostsData:(NSData *)data fallbackData:(NSData *)fallbackData {
  if (data.length == 0) return fallbackData ?: [self emptyNativeCircleListData];
  NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![json isKindOfClass:[NSDictionary class]]) return fallbackData ?: [self emptyNativeCircleListData];
  NSMutableDictionary *nativeJSON = [json mutableCopy];
  NSMutableDictionary *payload = [[nativeJSON objectForKey:@"p"] isKindOfClass:[NSDictionary class]]
    ? [[nativeJSON objectForKey:@"p"] mutableCopy]
    : [NSMutableDictionary dictionary];
  if (![payload[@"moment_list"] isKindOfClass:[NSArray class]]) payload[@"moment_list"] = @[];
  if (![payload[@"like"] isKindOfClass:[NSArray class]]) payload[@"like"] = @[];
  if (![payload[@"user"] isKindOfClass:[NSArray class]]) payload[@"user"] = @[];
  if (![payload[@"display"] isKindOfClass:[NSArray class]]) payload[@"display"] = @[];
  if (![payload[@"favorite"] isKindOfClass:[NSArray class]]) payload[@"favorite"] = @[];
  if (!payload[@"start"]) payload[@"start"] = @0;
  nativeJSON[@"c"] = @200;
  nativeJSON[@"n"] = @"";
  nativeJSON[@"m"] = @"";
  nativeJSON[@"p"] = payload;
  nativeJSON[@"h"] = nativeJSON[@"h"] ?: @"";
  nativeJSON[@"l"] = nativeJSON[@"l"] ?: @"";
  nativeJSON[@"ts"] = nativeJSON[@"ts"] ?: @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0));
  NSData *nativeData = [NSJSONSerialization dataWithJSONObject:nativeJSON options:0 error:nil];
  return nativeData ?: fallbackData ?: [self emptyNativeCircleListData];
}

- (void)fetchPaidNativeCircleListForRequest:(NSURLRequest *)request
                               fallbackData:(NSData *)fallbackData
                                   response:(NSURLResponse *)response
                                      error:(NSError *)error
                          completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
  NSString *bodyString = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding] ?: @"";
  NSString *count = [self queryValueNamed:@"count" inString:bodyString];
  NSString *pageInfo = [self queryValueNamed:@"page_info" inString:bodyString];
  NSURL *paidURL = [self paidPostsURLWithCount:count pageInfo:pageInfo];
  if (!paidURL) {
    if (completionHandler) completionHandler(fallbackData ?: [self emptyNativeCircleListData], response, error);
    return;
  }

  NSMutableURLRequest *paidRequest = [NSMutableURLRequest requestWithURL:paidURL];
  paidRequest.HTTPMethod = @"POST";
  paidRequest.HTTPBody = [self paidPostsBodyWithCount:count pageInfo:pageInfo];
  [paidRequest setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"content-type"];
  [paidRequest setValue:@"application/json" forHTTPHeaderField:@"accept"];

  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:paidRequest
                                                           completionHandler:^(NSData *paidData, NSURLResponse *paidResponse, NSError *paidError) {
    NSData *nativeData = (!paidError && paidData.length > 0)
      ? [self nativeCircleListDataFromPaidPostsData:paidData fallbackData:fallbackData]
      : (fallbackData ?: [self emptyNativeCircleListData]);
    if (completionHandler) {
      completionHandler(nativeData, paidResponse ?: response, paidError ?: error);
    }
  }];
  [task resume];
}

- (void)handleCircleListV1Request:(NSURLRequest *)request
                            data:(NSData *)data
                        response:(NSURLResponse *)response
                           error:(NSError *)error
               completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
  if (!completionHandler) return;
  NSString *uid = [self uid];
  if (uid.length == 0) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self presentMessage:@"未获取到login_uid，请先登录账号后重试"];
    });
    completionHandler(data ?: [self emptyNativeCircleListData], response, error);
    return;
  }

  NSURL *url = [self vip1URLWithPath:kJLYVip1CheckPath];
  if (!url) {
    completionHandler(data ?: [self emptyNativeCircleListData], response, error);
    return;
  }

  NSDictionary *payload = @{
    @"uid": uid,
    @"device_id": [self deviceId]
  };
  NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  NSMutableURLRequest *authRequest = [NSMutableURLRequest requestWithURL:url];
  authRequest.HTTPMethod = @"POST";
  authRequest.HTTPBody = body;
  [authRequest setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"content-type"];
  [authRequest setValue:@"application/json" forHTTPHeaderField:@"accept"];

  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:authRequest
                                                               completionHandler:^(NSData *authData, NSURLResponse *authResponse, NSError *authError) {
    BOOL authorized = NO;
    NSString *message = @"激活后可共享免费观看使用此软件的解锁的付费视频";
    if (!authError && authData.length > 0) {
      NSDictionary *json = [NSJSONSerialization JSONObjectWithData:authData options:0 error:nil];
      if ([json isKindOfClass:[NSDictionary class]]) {
        authorized = [self isAuthorizedResponseJSON:json];
        message = [self stringValue:json[@"message"] fallback:message];
      }
    }

    if (authorized) {
      [[self defaults] setBool:YES forKey:@"activated"];
      [[self defaults] synchronize];
      [self fetchPaidNativeCircleListForRequest:request fallbackData:data response:response error:error completionHandler:completionHandler];
    } else {
      [self clearActivationState];
      dispatch_async(dispatch_get_main_queue(), ^{
        [self showActivationPromptWithReason:message];
      });
      completionHandler(data ?: [self emptyNativeCircleListData], response ?: authResponse, error ?: authError);
    }
  }];
  [task resume];
}

- (void)ensureCircleListAuthorizationIfNeeded {
  if (_circleAuthChecking) return;
  NSString *uid = [self uid];
  if (uid.length == 0) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self presentMessage:@"未获取到login_uid，请先登录账号后重试"];
    });
    return;
  }

  _circleAuthChecking = YES;
  NSURL *url = [self vip1URLWithPath:kJLYVip1CheckPath];
  if (!url) {
    _circleAuthChecking = NO;
    return;
  }

  NSDictionary *payload = @{
    @"uid": uid,
    @"device_id": [self deviceId]
  };
  NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  request.HTTPBody = body;
  [request setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"content-type"];
  [request setValue:@"application/json" forHTTPHeaderField:@"accept"];

  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    BOOL authorized = NO;
    NSString *message = @"激活后可共享免费观看使用此软件的解锁的付费视频";
    if (!error && data.length > 0) {
      NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      if ([json isKindOfClass:[NSDictionary class]]) {
        authorized = [self isAuthorizedResponseJSON:json];
        message = [self stringValue:json[@"message"] fallback:message];
      }
    }

    self->_circleAuthChecking = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (authorized) {
        [[self defaults] setBool:YES forKey:@"activated"];
        [[self defaults] synchronize];
      } else {
        [self clearActivationState];
        [self showActivationPromptWithReason:message];
      }
    });
  }];
  [task resume];
}

- (NSData *)nativeCircleListDataIfNeededForURL:(NSURL *)url data:(NSData *)data {
  if (!JLYURLLooksLikePaidPosts(url)) return data;
  return [self nativeCircleListDataFromPaidPostsData:data fallbackData:[self emptyNativeCircleListData]];
}

- (NSString *)visibleTextInView:(UIView *)view maxDepth:(NSInteger)depth {
  if (!view || depth < 0) return @"";
  NSMutableArray<NSString *> *parts = [NSMutableArray array];
  if ([view isKindOfClass:[UILabel class]]) {
    NSString *text = [(UILabel *)view text];
    if (text.length > 0) [parts addObject:text];
  } else if ([view isKindOfClass:[UIButton class]]) {
    NSString *text = [(UIButton *)view titleForState:UIControlStateNormal];
    if (text.length > 0) [parts addObject:text];
  }
  for (UIView *child in view.subviews) {
    NSString *childText = [self visibleTextInView:child maxDepth:depth - 1];
    if (childText.length > 0) [parts addObject:childText];
  }
  return [parts componentsJoinedByString:@"|"];
}

- (void)collectViewsContainingText:(NSString *)needle fromView:(UIView *)view into:(NSMutableArray<UIView *> *)matches depth:(NSInteger)depth {
  if (!view || depth < 0 || view.hidden || view.alpha < 0.05) return;

  NSString *text = @"";
  if ([view isKindOfClass:[UILabel class]]) {
    text = [(UILabel *)view text] ?: @"";
    if (text.length == 0) text = [(UILabel *)view attributedText].string ?: @"";
  } else if ([view isKindOfClass:[UIButton class]]) {
    UIButton *button = (UIButton *)view;
    text = [button titleForState:UIControlStateNormal] ?: button.currentTitle ?: button.titleLabel.text ?: @"";
    if (text.length == 0) text = [button attributedTitleForState:UIControlStateNormal].string ?: @"";
  }

  if ([text containsString:needle]) {
    [matches addObject:view];
  }

  for (UIView *child in view.subviews) {
    [self collectViewsContainingText:needle fromView:child into:matches depth:depth - 1];
  }
}

- (void)installMoreAuthorizationOverlaysInViewController:(UIViewController *)viewController {
  if (!viewController.view.window) return;

  NSMutableArray<UIView *> *targets = [NSMutableArray array];
  [self collectViewsContainingText:@"查看更多" fromView:viewController.view into:targets depth:8];
  for (UIView *target in targets) {
    if ([target viewWithTag:9102403]) continue;
    if (CGRectGetWidth(target.bounds) < 8.0 || CGRectGetHeight(target.bounds) < 8.0) continue;

    UIButton *overlay = [UIButton buttonWithType:UIButtonTypeCustom];
    overlay.tag = 9102403;
    overlay.backgroundColor = [UIColor clearColor];
    overlay.frame = target.bounds;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addTarget:self action:@selector(checkVip1ThenShowPaidVideoList) forControlEvents:UIControlEventTouchUpInside];
    target.userInteractionEnabled = YES;
    [target addSubview:overlay];
  }
}

- (void)replaceFollowColumnTitleInViewController:(UIViewController *)viewController {
  if (!viewController.view.window) return;
  NSMutableArray<UIView *> *targets = [NSMutableArray array];
  [self collectViewsContainingText:@"关注" fromView:viewController.view into:targets depth:8];
  for (UIView *target in targets) {
    if ([target isKindOfClass:[UILabel class]]) {
      UILabel *label = (UILabel *)target;
      if ([label.text isEqualToString:@"关注"]) {
        label.text = @"解锁的付费视频";
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.65;
      }
    } else if ([target isKindOfClass:[UIButton class]]) {
      UIButton *button = (UIButton *)target;
      NSString *title = [button titleForState:UIControlStateNormal] ?: button.currentTitle ?: @"";
      if ([title isEqualToString:@"关注"]) {
        [button setTitle:@"解锁的付费视频" forState:UIControlStateNormal];
        button.titleLabel.adjustsFontSizeToFitWidth = YES;
        button.titleLabel.minimumScaleFactor = 0.65;
      }
    }
  }
}

- (BOOL)viewControllerLooksLikeDynamicPage:(UIViewController *)viewController {
  if (!viewController.view.window) return NO;
  NSString *title = viewController.title ?: viewController.navigationItem.title ?: @"";
  NSString *visibleText = [self visibleTextInView:viewController.view maxDepth:4];
  NSString *combined = [NSString stringWithFormat:@"%@|%@", title, visibleText];
  if ([combined containsString:@"解锁的付费视频"]) return YES;
  BOOL hasTabRow = [combined containsString:@"推荐"]
    && [combined containsString:@"动态"]
    && ([combined containsString:@"红娘"] || [combined containsString:@"关注"]);
  return hasTabRow;
}

- (UIView *)dynamicEntryContainerInView:(UIView *)root {
  if (!root) return nil;
  NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
  while (stack.count > 0) {
    UIView *view = stack.firstObject;
    [stack removeObjectAtIndex:0];
    if (CGRectGetWidth(view.bounds) > 220.0 && CGRectGetHeight(view.bounds) >= 28.0 && CGRectGetHeight(view.bounds) <= 88.0) {
      NSString *text = [self visibleTextInView:view maxDepth:3];
      BOOL hasTabSignals = [text containsString:@"推荐"]
        && [text containsString:@"动态"]
        && ([text containsString:@"红娘"] || [text containsString:@"关注"]);
      if (hasTabSignals) return view;
    }
    [stack addObjectsFromArray:view.subviews];
  }
  return nil;
}

- (void)installDynamicPaidVideoEntryIfNeededInViewController:(UIViewController *)viewController {
  if (![self viewControllerLooksLikeDynamicPage:viewController]) return;

  UIView *container = [self dynamicEntryContainerInView:viewController.view];
  if (!container) container = viewController.view;
  if (!container || [container viewWithTag:9102402]) return;

  UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
  button.tag = 9102402;
  button.backgroundColor = [UIColor clearColor];
  [button setTitle:@"解锁的付费视频" forState:UIControlStateNormal];
  [button setTitleColor:[UIColor colorWithRed:0.13 green:0.13 blue:0.13 alpha:1.0] forState:UIControlStateNormal];
  button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
  button.titleLabel.adjustsFontSizeToFitWidth = YES;
  button.titleLabel.minimumScaleFactor = 0.72;
  [button addTarget:self action:@selector(checkVip1ThenShowPaidVideoList) forControlEvents:UIControlEventTouchUpInside];

  CGFloat width = 116.0;
  CGFloat height = MAX(30.0, MIN(44.0, CGRectGetHeight(container.bounds)));
  CGFloat x = MAX(8.0, CGRectGetWidth(container.bounds) - width - 8.0);
  CGFloat y = MAX(0.0, (CGRectGetHeight(container.bounds) - height) / 2.0);
  if (container == viewController.view) {
    y = 88.0;
    if (@available(iOS 11.0, *)) y = viewController.view.safeAreaInsets.top + 44.0;
  }
  button.frame = CGRectMake(x, y, width, height);
  button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
  button.layer.zPosition = 9999.0;
  [container addSubview:button];
}

- (void)closePaidVideoList {
  UITableViewController *controller = _paidListController;
  _paidListController = nil;
  [controller dismissViewControllerAnimated:YES completion:nil];
}

- (void)reloadPaidVideoList {
  [self checkVip1ThenShowPaidVideoList];
}

- (void)fetchPaidVideoListWithPageInfo:(NSString *)pageInfo append:(BOOL)append {
  if (_paidListLoading) return;
  _paidListLoading = YES;
  NSURL *url = [self paidPostsURLWithPageInfo:pageInfo];
  if (!url) {
    _paidListLoading = NO;
    return;
  }

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  request.HTTPBody = [self paidPostsBodyWithCount:@"20" pageInfo:pageInfo];
  [request setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"content-type"];
  [request setValue:@"application/json" forHTTPHeaderField:@"accept"];

  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    NSMutableArray *posts = [NSMutableArray array];
    if (!error && data.length > 0) {
      NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      NSDictionary *payload = [json[@"p"] isKindOfClass:[NSDictionary class]] ? json[@"p"] : nil;
      NSArray *list = payload[@"moment_list"];
      if ([list isKindOfClass:[NSArray class]]) {
        [posts addObjectsFromArray:list];
      }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      self->_paidListLoading = NO;
      if (!append) [self->_paidPosts removeAllObjects];
      [self->_paidPosts addObjectsFromArray:posts];
      [self->_paidListController.tableView reloadData];
      if (posts.count == 0 && !append) {
        [self presentMessage:@"暂无解锁的付费视频"];
      }
    });
  }];
  [task resume];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return _paidPosts.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"JLYPaidVideoCell"];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"JLYPaidVideoCell"];
  }
  NSDictionary *post = _paidPosts[indexPath.row];
  NSString *content = [self stringValue:post[@"content"] fallback:@"解锁的付费视频"];
  NSString *nickname = [self stringValue:post[@"nickname"] fallback:@"付费视频用户"];
  NSString *money = [self stringValue:post[@"money"] fallback:@"0"];
  cell.textLabel.text = content.length > 0 ? content : @"解锁的付费视频";
  cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@金币", nickname, money];
  cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  return 64.0;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  NSDictionary *post = _paidPosts[indexPath.row];
  NSArray *media = [self arrayValue:post[@"media"]];
  NSString *first = @"";
  for (id value in media) {
    NSString *candidate = [self stringValue:value fallback:@""];
    if (JLYStringHasVideoSuffix(candidate)) {
      first = candidate;
      break;
    }
  }
  if (first.length == 0) {
    [self presentMessage:@"未找到可播放的视频地址"];
    return;
  }
  [self playVideoURLString:first];
}

- (void)playVideoURLString:(NSString *)urlString {
  NSURL *url = [NSURL URLWithString:urlString];
  if (!url.scheme.length) {
    url = [NSURL URLWithString:urlString relativeToURL:[NSURL URLWithString:kJLYBaseURL]];
  }
  if (!url) return;

  AVPlayerViewController *playerVC = [[AVPlayerViewController alloc] init];
  playerVC.player = [AVPlayer playerWithURL:url.absoluteURL];
  [[self topViewController] presentViewController:playerVC animated:YES completion:^{
    [playerVC.player play];
  }];
}

- (void)reportResponseData:(NSData *)data forURL:(NSURL *)url {
  if (data.length == 0 || !JLYURLLooksLikeCircleEndpoint(url.absoluteString)) return;

  NSDictionary *payload = @{
    @"url": url.absoluteString ?: @"",
    @"response": [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @""
  };
  NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  if (body.length == 0) return;

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self urlWithPath:kJLYIngestPath]];
  request.HTTPMethod = @"POST";
  request.HTTPBody = body;
  [request setValue:@"application/json" forHTTPHeaderField:@"content-type"];

  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request];
  [task resume];
}

- (NSURLRequest *)routedRequest:(NSURLRequest *)request {
  [self captureLoginUIDFromRequest:request];
  if (JLYURLLooksLikeCircleListV1(request.URL)) {
    [self ensureCircleListAuthorizationIfNeeded];
    return request;
  }
  NSURL *routedURL = JLYRoutedURL(request.URL);
  if (!routedURL || [routedURL isEqual:request.URL]) return request;

  NSMutableURLRequest *mutableRequest = [request mutableCopy];
  [mutableRequest setURL:routedURL];
  return mutableRequest;
}

@end

static BOOL JLYStringHasVideoSuffix(NSString *value) {
  NSString *lower = [[value componentsSeparatedByString:@"?"].firstObject lowercaseString];
  return [lower hasSuffix:@".mp4"] || [lower hasSuffix:@".m3u8"] || [lower hasSuffix:@".mov"] || [lower hasSuffix:@".m4v"] || [lower hasSuffix:@".webm"];
}

static BOOL JLYURLLooksLikeCircleEndpoint(NSString *value) {
  NSString *lower = [value.lowercaseString stringByReplacingOccurrencesOfString:@"//" withString:@"/"];
  return [lower containsString:@"sm/circle/timelinev1"]
    || [lower containsString:@"sm/circle/detailv1"]
    || [lower containsString:@"sm/circle/mymomentv1"]
    || [lower containsString:@"sm/circle/mypaymoment"]
    || [lower containsString:@"sm/circle/listv1"];
}

static BOOL JLYURLLooksLikeCircleListV1(NSURL *url) {
  NSString *lower = [url.absoluteString.lowercaseString stringByReplacingOccurrencesOfString:@"//" withString:@"/"];
  return [lower containsString:@"sm/circle/listv1"];
}

static BOOL JLYURLLooksLikePaidPosts(NSURL *url) {
  NSString *lower = [url.absoluteString.lowercaseString stringByReplacingOccurrencesOfString:@"//" withString:@"/"];
  return [lower containsString:@"stz.jlyapp.cn/api/posts/app-list"];
}

static BOOL JLYURLLooksLikeMeetList(NSURL *url) {
  NSString *value = url.absoluteString.lowercaseString;
  return [value containsString:@"sm/meet/getmeetlist"] || [value containsString:@"meet/getmeetlist"];
}

static NSURL *JLYRoutedURL(NSURL *url) {
  if (!url || !JLYURLLooksLikeMeetList(url)) return url;
  if (![[[JLYSafePlugin shared] defaults] boolForKey:@"route_meet_list_to_vip1"]) return url;

  NSURLComponents *source = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
  NSURLComponents *target = [NSURLComponents componentsWithString:kJLYVip1MeetListURL];
  target.queryItems = source.queryItems;
  return target.URL ?: url;
}

@implementation UIControl (JLYSafePluginHooks)

- (void)jly_sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
  if ([self isKindOfClass:[UIButton class]]) {
    UIButton *button = (UIButton *)self;
    NSString *title = [button titleForState:UIControlStateNormal] ?: button.currentTitle ?: @"";
    if ([title containsString:@"查看更多"]) {
      [[JLYSafePlugin shared] checkVip1ThenShowPaidVideoList];
      return;
    }
  }
  [self jly_sendAction:action to:target forEvent:event];
}

@end

@implementation UIViewController (JLYSafePluginHooks)

- (void)jly_installJLYEntries {
  [[JLYSafePlugin shared] installMoreAuthorizationOverlaysInViewController:self];
  [[JLYSafePlugin shared] replaceFollowColumnTitleInViewController:self];
}

- (void)jly_viewDidAppear:(BOOL)animated {
  [self jly_viewDidAppear:animated];
  [self jly_installJLYEntries];
  UIViewController *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [weakSelf jly_installJLYEntries];
  });
}

- (void)jly_viewDidLayoutSubviews {
  [self jly_viewDidLayoutSubviews];
  [self jly_installJLYEntries];
}

@end

@implementation NSURLSession (JLYSafePluginHooks)

- (NSURLSessionDataTask *)jly_dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
  NSURL *routedURL = JLYRoutedURL(url);
  void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
    [[JLYSafePlugin shared] captureLoginUIDFromResponseData:data];
    [[JLYSafePlugin shared] reportResponseData:data forURL:routedURL ?: url];
    NSData *nativeData = [[JLYSafePlugin shared] nativeCircleListDataIfNeededForURL:routedURL ?: url data:data];
    if (completionHandler) completionHandler(nativeData, response, error);
  };
  return [self jly_dataTaskWithURL:routedURL ?: url completionHandler:wrapped];
}

- (NSURLSessionDataTask *)jly_dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
  NSURLRequest *routedRequest = [[JLYSafePlugin shared] routedRequest:request];
  NSURL *requestURL = routedRequest.URL ?: request.URL;
  void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
    [[JLYSafePlugin shared] captureLoginUIDFromResponseData:data];
    [[JLYSafePlugin shared] reportResponseData:data forURL:requestURL];
    if (JLYURLLooksLikeCircleListV1(requestURL)) {
      [[JLYSafePlugin shared] handleCircleListV1Request:routedRequest data:data response:response error:error completionHandler:completionHandler];
      return;
    }
    NSData *nativeData = [[JLYSafePlugin shared] nativeCircleListDataIfNeededForURL:requestURL data:data];
    if (completionHandler) completionHandler(nativeData, response, error);
  };
  return [self jly_dataTaskWithRequest:routedRequest completionHandler:wrapped];
}

- (NSURLSessionDataTask *)jly_dataTaskWithRequest:(NSURLRequest *)request {
  return [self jly_dataTaskWithRequest:[[JLYSafePlugin shared] routedRequest:request]];
}

- (NSURLSessionUploadTask *)jly_uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
  [[JLYSafePlugin shared] captureLoginUIDFromBodyData:bodyData];
  NSURLRequest *routedRequest = [[JLYSafePlugin shared] routedRequest:request];
  NSURL *requestURL = routedRequest.URL ?: request.URL;
  void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
    [[JLYSafePlugin shared] captureLoginUIDFromResponseData:data];
    [[JLYSafePlugin shared] reportResponseData:data forURL:requestURL];
    if (JLYURLLooksLikeCircleListV1(requestURL)) {
      [[JLYSafePlugin shared] handleCircleListV1Request:routedRequest data:data response:response error:error completionHandler:completionHandler];
      return;
    }
    NSData *nativeData = [[JLYSafePlugin shared] nativeCircleListDataIfNeededForURL:requestURL data:data];
    if (completionHandler) completionHandler(nativeData, response, error);
  };
  return [self jly_uploadTaskWithRequest:routedRequest fromData:bodyData completionHandler:wrapped];
}

- (NSURLSessionUploadTask *)jly_uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
  NSURLRequest *routedRequest = [[JLYSafePlugin shared] routedRequest:request];
  NSURL *requestURL = routedRequest.URL ?: request.URL;
  void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
    [[JLYSafePlugin shared] captureLoginUIDFromResponseData:data];
    [[JLYSafePlugin shared] reportResponseData:data forURL:requestURL];
    if (JLYURLLooksLikeCircleListV1(requestURL)) {
      [[JLYSafePlugin shared] handleCircleListV1Request:routedRequest data:data response:response error:error completionHandler:completionHandler];
      return;
    }
    NSData *nativeData = [[JLYSafePlugin shared] nativeCircleListDataIfNeededForURL:requestURL data:data];
    if (completionHandler) completionHandler(nativeData, response, error);
  };
  return [self jly_uploadTaskWithRequest:routedRequest fromFile:fileURL completionHandler:wrapped];
}

- (NSURLSessionUploadTask *)jly_uploadTaskWithStreamedRequest:(NSURLRequest *)request {
  return [self jly_uploadTaskWithStreamedRequest:[[JLYSafePlugin shared] routedRequest:request]];
}

@end

@implementation NSURLConnection (JLYSafePluginHooks)

+ (void)jly_sendAsynchronousRequest:(NSURLRequest *)request queue:(NSOperationQueue *)queue completionHandler:(void (^)(NSURLResponse *response, NSData *data, NSError *connectionError))handler {
  NSURLRequest *routedRequest = [[JLYSafePlugin shared] routedRequest:request];
  NSURL *requestURL = routedRequest.URL ?: request.URL;
  void (^wrapped)(NSURLResponse *, NSData *, NSError *) = ^(NSURLResponse *response, NSData *data, NSError *connectionError) {
    [[JLYSafePlugin shared] captureLoginUIDFromResponseData:data];
    [[JLYSafePlugin shared] reportResponseData:data forURL:requestURL];
    if (JLYURLLooksLikeCircleListV1(requestURL)) {
      [[JLYSafePlugin shared] handleCircleListV1Request:routedRequest data:data response:response error:connectionError completionHandler:^(NSData *nativeData, NSURLResponse *nativeResponse, NSError *nativeError) {
        if (handler) handler(nativeResponse, nativeData, nativeError);
      }];
      return;
    }
    NSData *nativeData = [[JLYSafePlugin shared] nativeCircleListDataIfNeededForURL:requestURL data:data];
    if (handler) handler(response, nativeData, connectionError);
  };
  [self jly_sendAsynchronousRequest:routedRequest queue:queue completionHandler:wrapped];
}

+ (NSData *)jly_sendSynchronousRequest:(NSURLRequest *)request returningResponse:(NSURLResponse **)response error:(NSError **)error {
  NSURLRequest *routedRequest = [[JLYSafePlugin shared] routedRequest:request];
  NSData *data = [self jly_sendSynchronousRequest:routedRequest returningResponse:response error:error];
  [[JLYSafePlugin shared] captureLoginUIDFromResponseData:data];
  [[JLYSafePlugin shared] reportResponseData:data forURL:routedRequest.URL ?: request.URL];
  return [[JLYSafePlugin shared] nativeCircleListDataIfNeededForURL:routedRequest.URL ?: request.URL data:data];
}

+ (NSURLConnection *)jly_connectionWithRequest:(NSURLRequest *)request delegate:(id)delegate {
  return [self jly_connectionWithRequest:[[JLYSafePlugin shared] routedRequest:request] delegate:delegate];
}

- (instancetype)jly_initWithRequest:(NSURLRequest *)request delegate:(id)delegate startImmediately:(BOOL)startImmediately {
  return [self jly_initWithRequest:[[JLYSafePlugin shared] routedRequest:request] delegate:delegate startImmediately:startImmediately];
}

@end

static void JLYExchangeInstanceMethod(Class cls, SEL original, SEL replacement) {
  Method originalMethod = class_getInstanceMethod(cls, original);
  Method replacementMethod = class_getInstanceMethod(cls, replacement);
  if (!originalMethod || !replacementMethod) return;
  method_exchangeImplementations(originalMethod, replacementMethod);
}

static void JLYExchangeClassMethod(Class cls, SEL original, SEL replacement) {
  Method originalMethod = class_getClassMethod(cls, original);
  Method replacementMethod = class_getClassMethod(cls, replacement);
  if (!originalMethod || !replacementMethod) return;
  method_exchangeImplementations(originalMethod, replacementMethod);
}

static void JLYInstallURLSessionHooks(void) {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    Class cls = [NSURLSession class];
    JLYExchangeInstanceMethod(cls,
      @selector(dataTaskWithURL:completionHandler:),
      @selector(jly_dataTaskWithURL:completionHandler:));
    JLYExchangeInstanceMethod(cls,
      @selector(dataTaskWithRequest:completionHandler:),
      @selector(jly_dataTaskWithRequest:completionHandler:));
    JLYExchangeInstanceMethod(cls,
      @selector(dataTaskWithRequest:),
      @selector(jly_dataTaskWithRequest:));
    JLYExchangeInstanceMethod(cls,
      @selector(uploadTaskWithRequest:fromData:completionHandler:),
      @selector(jly_uploadTaskWithRequest:fromData:completionHandler:));
    JLYExchangeInstanceMethod(cls,
      @selector(uploadTaskWithRequest:fromFile:completionHandler:),
      @selector(jly_uploadTaskWithRequest:fromFile:completionHandler:));
    JLYExchangeInstanceMethod(cls,
      @selector(uploadTaskWithStreamedRequest:),
      @selector(jly_uploadTaskWithStreamedRequest:));
    JLYExchangeClassMethod([NSURLConnection class],
      @selector(sendAsynchronousRequest:queue:completionHandler:),
      @selector(jly_sendAsynchronousRequest:queue:completionHandler:));
    JLYExchangeClassMethod([NSURLConnection class],
      @selector(sendSynchronousRequest:returningResponse:error:),
      @selector(jly_sendSynchronousRequest:returningResponse:error:));
    JLYExchangeClassMethod([NSURLConnection class],
      @selector(connectionWithRequest:delegate:),
      @selector(jly_connectionWithRequest:delegate:));
    JLYExchangeInstanceMethod([NSURLConnection class],
      @selector(initWithRequest:delegate:startImmediately:),
      @selector(jly_initWithRequest:delegate:startImmediately:));
  });
}

static void JLYInstallUIHooks(void) {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    JLYExchangeInstanceMethod([UIControl class],
      @selector(sendAction:to:forEvent:),
      @selector(jly_sendAction:to:forEvent:));
    JLYExchangeInstanceMethod([UIViewController class],
      @selector(viewDidAppear:),
      @selector(jly_viewDidAppear:));
    JLYExchangeInstanceMethod([UIViewController class],
      @selector(viewDidLayoutSubviews),
      @selector(jly_viewDidLayoutSubviews));
  });
}

__attribute__((constructor))
static void JLYSafePluginEntry(void) {
  @autoreleasepool {
    JLYInstallUIHooks();
    JLYInstallURLSessionHooks();
    [[JLYSafePlugin shared] start];
  }
}

JLY_EXTERN_C void JLYPluginShowActivationPrompt(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    [[JLYSafePlugin shared] showActivationPromptWithReason:@"请输入激活码"];
  });
}

JLY_EXTERN_C BOOL JLYPluginIsActivated(void) {
  return [[JLYSafePlugin shared] isActivated];
}

JLY_EXTERN_C void JLYPluginShowPaidVideos(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    [[JLYSafePlugin shared] checkVip1ThenShowPaidVideoList];
  });
}

JLY_EXTERN_C void JLYPluginActivateVip1Route(void) {
  NSUserDefaults *defaults = [[JLYSafePlugin shared] defaults];
  [defaults setBool:YES forKey:@"route_meet_list_to_vip1"];
  [defaults synchronize];
  NSLog(@"vip1入口已触发");
}
