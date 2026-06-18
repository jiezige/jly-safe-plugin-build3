#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-build/libJLYRouteFix.dylib}"
mkdir -p "$(dirname "$OUT")"
SRC="$(mktemp /tmp/JLYRouteFix.XXXXXX.m)"
trap 'rm -f "$SRC"' EXIT

cat > "$SRC" <<'OBJC'
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static id (*orig_EVSRouter_instance_openURL)(id, SEL, id);
static id (*orig_EVSRouter_class_openURL)(id, SEL, id);
static id (*orig_EVSRouter_instance_handlerForURL)(id, SEL, id);
static id (*orig_EVSRouter_class_handlerForURL)(id, SEL, id);
static BOOL JLYRFInstalled = NO;

static NSString *JLYRFURLString(id url) {
  if (!url) {
    return @"";
  }
  if ([url isKindOfClass:[NSURL class]]) {
    return [(NSURL *)url absoluteString] ?: @"";
  }
  if ([url isKindOfClass:[NSString class]]) {
    return (NSString *)url;
  }
  return [url description] ?: @"";
}

static BOOL JLYRFShouldHandle(NSString *urlString) {
  if (!urlString.length) {
    return NO;
  }
  NSArray<NSString *> *prefixes = @[
    @"kSearchViewController://",
    @"localwebview://",
    @"webview://",
    @"userhome://",
    @"online://",
    @"mallhome://",
    @"grouplist://",
    @"groupcell://",
    @"livelist://",
    @"fictionlist://",
    @"userinbox://",
    @"useroutbox://",
    @"mallBuyRecord://"
  ];
  for (NSString *prefix in prefixes) {
    if ([urlString hasPrefix:prefix]) {
      return YES;
    }
  }
  return NO;
}

static BOOL JLYRFRouteResultFailed(id result) {
  if (!result || [result isKindOfClass:[NSNull class]]) {
    return YES;
  }
  if ([result isKindOfClass:[NSNumber class]]) {
    return ![(NSNumber *)result boolValue];
  }
  return NO;
}

static NSDictionary<NSString *, NSString *> *JLYRFParams(NSString *urlString) {
  NSMutableDictionary *params = [NSMutableDictionary dictionary];
  NSString *body = urlString ?: @"";
  NSRange scheme = [body rangeOfString:@"://"];
  if (scheme.location != NSNotFound) {
    body = [body substringFromIndex:scheme.location + scheme.length];
  }
  for (NSString *piece in [body componentsSeparatedByString:@"&"]) {
    NSRange eq = [piece rangeOfString:@"="];
    if (eq.location == NSNotFound || eq.location == 0) {
      continue;
    }
    NSString *key = [piece substringToIndex:eq.location];
    NSString *value = [piece substringFromIndex:eq.location + 1];
    params[key] = [value stringByRemovingPercentEncoding] ?: value;
  }
  return params;
}

static UIViewController *JLYRFTopViewController(void) {
  UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
  if (!keyWindow) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
      if (!window.hidden && window.alpha > 0.01 && window.windowLevel == UIWindowLevelNormal) {
        keyWindow = window;
        break;
      }
    }
  }
  UIViewController *vc = keyWindow.rootViewController;
  while (vc.presentedViewController) {
    vc = vc.presentedViewController;
  }
  if ([vc isKindOfClass:[UITabBarController class]]) {
    UIViewController *selected = [(UITabBarController *)vc selectedViewController];
    vc = selected ?: vc;
  }
  if ([vc isKindOfClass:[UINavigationController class]]) {
    vc = [(UINavigationController *)vc topViewController];
  }
  return vc;
}

static UINavigationController *JLYRFTopNavigationController(void) {
  UIViewController *top = JLYRFTopViewController();
  if ([top isKindOfClass:[UINavigationController class]]) {
    return (UINavigationController *)top;
  }
  return top.navigationController;
}

static void JLYRFSet(id obj, NSString *key, id value) {
  if (!obj || !key.length || !value) {
    return;
  }
  @try {
    [obj setValue:value forKey:key];
  } @catch (__unused NSException *exception) {
  }
}

static BOOL JLYRFInvokeModuleRouter(NSString *urlString) {
  Class cls = NSClassFromString(@"LE_paradiseModuleRouterHandler");
  if (!cls || !urlString.length) {
    return NO;
  }
  SEL sels[] = {@selector(moduleRouterWith:), @selector(moduleRouterWithLinkUrl:)};
  for (NSUInteger i = 0; i < sizeof(sels) / sizeof(SEL); i++) {
    SEL sel = sels[i];
    if ([cls respondsToSelector:sel]) {
      NSLog(@"[JLYRouteFix] module class %@", NSStringFromSelector(sel));
      ((void (*)(id, SEL, id))objc_msgSend)(cls, sel, urlString);
      return YES;
    }
  }
  id obj = [[cls alloc] init];
  for (NSUInteger i = 0; i < sizeof(sels) / sizeof(SEL); i++) {
    SEL sel = sels[i];
    if ([obj respondsToSelector:sel]) {
      NSLog(@"[JLYRouteFix] module instance %@", NSStringFromSelector(sel));
      ((void (*)(id, SEL, id))objc_msgSend)(obj, sel, urlString);
      return YES;
    }
  }
  return NO;
}

static UIViewController *JLYRFCreateController(NSString *urlString) {
  NSDictionary *params = JLYRFParams(urlString);
  NSString *className = nil;
  if ([urlString hasPrefix:@"kSearchViewController://"]) {
    className = @"LE_HSHHomeSearchViewController";
  } else if ([urlString hasPrefix:@"localwebview://"] || [urlString hasPrefix:@"webview://"]) {
    className = @"LE_paradiseLocalWebViewController";
  } else if ([urlString hasPrefix:@"online://"]) {
    className = @"LE_OnlineViewController";
  } else if ([urlString hasPrefix:@"mallhome://"]) {
    className = @"LE_DLShoppingContainerViewController";
  } else if ([urlString hasPrefix:@"userhome://"]) {
    className = NSClassFromString(@"LE_PersonalContainerViewController") ? @"LE_PersonalContainerViewController" : @"LE_SpaceInfoModel";
  }
  Class cls = className.length ? NSClassFromString(className) : Nil;
  if (!cls || ![cls isSubclassOfClass:[UIViewController class]]) {
    return nil;
  }
  UIViewController *vc = [[cls alloc] init];
  NSString *target = params[@"target_id"];
  NSString *webURL = params[@"url"] ?: params[@"path"] ?: urlString;
  JLYRFSet(vc, @"routerUrl", urlString);
  JLYRFSet(vc, @"router_url", urlString);
  JLYRFSet(vc, @"route_url", urlString);
  JLYRFSet(vc, @"webViewStringUrl", webURL);
  JLYRFSet(vc, @"urlString", webURL);
  JLYRFSet(vc, @"requestUrl", webURL);
  JLYRFSet(vc, @"title", params[@"title"]);
  JLYRFSet(vc, @"target_uid", target);
  JLYRFSet(vc, @"targetUid", target);
  JLYRFSet(vc, @"targetLogin_id", target);
  JLYRFSet(vc, @"login_uid", target);
  JLYRFSet(vc, @"userID", target);
  return vc;
}

static BOOL JLYRFOpenFallback(NSString *urlString) {
  if (!JLYRFShouldHandle(urlString)) {
    return NO;
  }
  NSLog(@"[JLYRouteFix] fallback %@", urlString);
  if (JLYRFInvokeModuleRouter(urlString)) {
    return YES;
  }
  UIViewController *vc = JLYRFCreateController(urlString);
  if (!vc) {
    NSLog(@"[JLYRouteFix] no fallback vc %@", urlString);
    return NO;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    UINavigationController *nav = JLYRFTopNavigationController();
    UIViewController *top = JLYRFTopViewController();
    if (nav) {
      [nav pushViewController:vc animated:YES];
    } else if (top) {
      [top presentViewController:vc animated:YES completion:nil];
    }
  });
  return YES;
}

static id JLYRFMakeHandler(NSString *urlString) {
  NSString *captured = [urlString copy];
  void (^handler)(NSDictionary *) = ^(__unused NSDictionary *params) {
    JLYRFOpenFallback(captured);
  };
  return [handler copy];
}

static id JLYRFInstanceHandlerForURL(id self, SEL _cmd, id url) {
  id handler = orig_EVSRouter_instance_handlerForURL ? orig_EVSRouter_instance_handlerForURL(self, _cmd, url) : nil;
  NSString *urlString = JLYRFURLString(url);
  if (!handler && JLYRFShouldHandle(urlString)) {
    NSLog(@"[JLYRouteFix] handler fallback - %@", urlString);
    return JLYRFMakeHandler(urlString);
  }
  return handler;
}

static id JLYRFClassHandlerForURL(id self, SEL _cmd, id url) {
  id handler = orig_EVSRouter_class_handlerForURL ? orig_EVSRouter_class_handlerForURL(self, _cmd, url) : nil;
  NSString *urlString = JLYRFURLString(url);
  if (!handler && JLYRFShouldHandle(urlString)) {
    NSLog(@"[JLYRouteFix] handler fallback + %@", urlString);
    return JLYRFMakeHandler(urlString);
  }
  return handler;
}

static id JLYRFInstanceOpenURL(id self, SEL _cmd, id url) {
  NSString *urlString = JLYRFURLString(url);
  id result = orig_EVSRouter_instance_openURL ? orig_EVSRouter_instance_openURL(self, _cmd, url) : nil;
  if (JLYRFRouteResultFailed(result) && JLYRFShouldHandle(urlString)) {
    JLYRFOpenFallback(urlString);
  }
  return result;
}

static id JLYRFClassOpenURL(id self, SEL _cmd, id url) {
  NSString *urlString = JLYRFURLString(url);
  id result = orig_EVSRouter_class_openURL ? orig_EVSRouter_class_openURL(self, _cmd, url) : nil;
  if (JLYRFRouteResultFailed(result) && JLYRFShouldHandle(urlString)) {
    JLYRFOpenFallback(urlString);
  }
  return result;
}

static void JLYRFInstall(void) {
  Class router = NSClassFromString(@"LE_DL_EVSRouter");
  if (!router || JLYRFInstalled) {
    return;
  }
  JLYRFInstalled = YES;
  NSLog(@"[JLYRouteFix] installing on %@", NSStringFromClass(router));

  Method method = class_getInstanceMethod(router, @selector(handlerForURL:));
  if (method) {
    orig_EVSRouter_instance_handlerForURL = (id (*)(id, SEL, id))method_getImplementation(method);
    method_setImplementation(method, (IMP)JLYRFInstanceHandlerForURL);
  }
  Method classMethod = class_getClassMethod(router, @selector(handlerForURL:));
  if (classMethod) {
    Class meta = object_getClass(router);
    orig_EVSRouter_class_handlerForURL = (id (*)(id, SEL, id))method_getImplementation(classMethod);
    class_replaceMethod(meta, @selector(handlerForURL:), (IMP)JLYRFClassHandlerForURL, method_getTypeEncoding(classMethod));
  }
  method = class_getInstanceMethod(router, @selector(openURL:));
  if (method) {
    orig_EVSRouter_instance_openURL = (id (*)(id, SEL, id))method_getImplementation(method);
    method_setImplementation(method, (IMP)JLYRFInstanceOpenURL);
  }
  classMethod = class_getClassMethod(router, @selector(openURL:));
  if (classMethod) {
    Class meta = object_getClass(router);
    orig_EVSRouter_class_openURL = (id (*)(id, SEL, id))method_getImplementation(classMethod);
    class_replaceMethod(meta, @selector(openURL:), (IMP)JLYRFClassOpenURL, method_getTypeEncoding(classMethod));
  }
}

static void JLYRFInstallRetry(NSUInteger attempt) {
  JLYRFInstall();
  if (JLYRFInstalled || attempt >= 40) {
    if (!JLYRFInstalled) {
      NSLog(@"[JLYRouteFix] LE_DL_EVSRouter never appeared");
    }
    return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    JLYRFInstallRetry(attempt + 1);
  });
}

__attribute__((constructor))
static void JLYRouteFixEntry(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    JLYRFInstallRetry(0);
  });
}
OBJC

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
clang -isysroot "$SDK" \
  -target arm64-apple-ios12.0 \
  -dynamiclib \
  -fobjc-arc \
  -fblocks \
  -miphoneos-version-min=12.0 \
  -install_name "@executable_path/libJLYRouteFix.dylib" \
  -framework Foundation \
  -framework UIKit \
  "$SRC" \
  -o "$OUT"

echo "Built $OUT"
