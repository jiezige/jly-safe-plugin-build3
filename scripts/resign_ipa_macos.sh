#!/usr/bin/env bash
set -euo pipefail

INPUT_IPA="${1:?input IPA path required}"
OUTPUT_IPA="${2:?output IPA path required}"
WORKDIR="$(mktemp -d)"
KEYCHAIN_PATH="$WORKDIR/build.keychain-db"

cleanup() {
  security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

unzip -q "$INPUT_IPA" -d "$WORKDIR/ipa"
APP_DIR="$(find "$WORKDIR/ipa/Payload" -maxdepth 1 -name '*.app' -type d | head -n 1)"
if [[ -z "$APP_DIR" ]]; then
  echo "Payload app directory not found" >&2
  exit 1
fi

APP_BIN="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP_DIR/Info.plist")"
MIAOTAO_LOAD="@executable_path/libmiaotao 2.dylib"
MIAOTAO_ROOT="$APP_DIR/libmiaotao 2.dylib"
LIBTEST="$APP_DIR/Frameworks/libtestMonekyDylib.dylib"
TOUCH_FIX_LOAD="@executable_path/libJLYTouchFix.dylib"
TOUCH_FIX="$APP_DIR/libJLYTouchFix.dylib"
test -f "$MIAOTAO_ROOT"
test -f "$LIBTEST"

python3 - "$LIBTEST" "$MIAOTAO_LOAD" <<'PY'
import importlib.util
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
dylib_name = sys.argv[2]
data = bytearray(target.read_bytes())
if dylib_name.encode() in data:
    print(f"{target} already contains {dylib_name}")
    raise SystemExit(0)

spec = importlib.util.spec_from_file_location("patch_ipa", "scripts/patch_ipa.py")
patch_ipa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch_ipa)
injector = patch_ipa.MachOLoadCommandInjector(data)
target.write_bytes(injector.inject(dylib_name))
print(f"Injected {dylib_name} into {target}")
PY

cat > "$WORKDIR/JLYTouchFix.m" <<'OBJC'
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

static UIView *(*orig_UIView_hitTest)(id, SEL, CGPoint, UIEvent *);
static void (*orig_UIWindow_sendEvent)(id, SEL, UIEvent *);
static BOOL (*orig_UIApplication_sendAction)(id, SEL, SEL, id, id, UIEvent *);
static void (*orig_UIControl_sendAction)(id, SEL, SEL, id, UIEvent *);
static void (*orig_FTPopOverMenu_dismiss)(id, SEL);

static NSTimeInterval JLYTFLastHitLog = 0;
static NSTimeInterval JLYTFLastWindowLog = 0;
static NSTimeInterval JLYTFLastActionLog = 0;

static BOOL JLYTFNameContains(Class cls, const char *needle) {
  while (cls) {
    const char *name = class_getName(cls);
    if (name && strstr(name, needle)) {
      return YES;
    }
    cls = class_getSuperclass(cls);
  }
  return NO;
}

static NSString *JLYTFClassChain(id obj) {
  if (!obj) {
    return @"nil";
  }
  NSMutableArray *names = [NSMutableArray array];
  Class cls = [obj class];
  for (NSInteger i = 0; cls && i < 8; i++) {
    const char *name = class_getName(cls);
    [names addObject:name ? @(name) : @"?"];
    cls = class_getSuperclass(cls);
  }
  return [names componentsJoinedByString:@"<"];
}

static BOOL JLYTFViewTreeContains(UIView *view, const char *needle) {
  if (!view) {
    return NO;
  }
  if (JLYTFNameContains([view class], needle)) {
    return YES;
  }
  for (UIView *subview in view.subviews) {
    if (JLYTFViewTreeContains(subview, needle)) {
      return YES;
    }
  }
  return NO;
}

static BOOL JLYTFHasVisibleMenuView(UIView *view) {
  if (!view || view.hidden || view.alpha < 0.05) {
    return NO;
  }
  if (JLYTFNameContains([view class], "FTPopOverMenuView")) {
    return YES;
  }
  for (UIView *subview in view.subviews) {
    if (JLYTFHasVisibleMenuView(subview)) {
      return YES;
    }
  }
  return NO;
}

static void JLYTFHideWindow(UIWindow *window, NSString *reason) {
  if (!window || window.hidden) {
    return;
  }
  NSLog(@"[JLYTouchFixV2] hide stale plugin window: %@ %@", window, reason);
  window.userInteractionEnabled = NO;
  window.hidden = YES;
  window.alpha = 0.0;
}

static void JLYTFLogWindows(void) {
  NSTimeInterval now = CACurrentMediaTime();
  if (now - JLYTFLastWindowLog < 5.0) {
    return;
  }
  JLYTFLastWindowLog = now;
  NSArray<UIWindow *> *windows = [UIApplication sharedApplication].windows;
  NSMutableArray *parts = [NSMutableArray array];
  for (UIWindow *window in windows) {
    NSString *item = [NSString stringWithFormat:@"%@ hidden=%d alpha=%.2f level=%.1f frame=%@ sub=%lu",
                      JLYTFClassChain(window), window.hidden, window.alpha, window.windowLevel,
                      NSStringFromCGRect(window.frame), (unsigned long)window.subviews.count];
    [parts addObject:item];
  }
  NSLog(@"[JLYTouchFixV2] windows %@", [parts componentsJoinedByString:@" | "]);
}

static void JLYTFCleanupFTPopOverSingleton(void) {
  Class cls = NSClassFromString(@"FTPopOverMenu");
  if (!cls || ![cls respondsToSelector:@selector(sharedInstance)]) {
    return;
  }

  id (*idMsg)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
  BOOL (*boolMsg)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
  id menu = idMsg(cls, @selector(sharedInstance));
  if (!menu) {
    return;
  }

  BOOL onScreen = NO;
  if ([menu respondsToSelector:@selector(isCurrentlyOnScreen)]) {
    onScreen = boolMsg(menu, @selector(isCurrentlyOnScreen));
  }

  UIWindow *backgroundWindow = nil;
  UIView *backgroundView = nil;
  UIView *popMenuView = nil;
  @try {
    backgroundWindow = [menu valueForKey:@"backgroundWindow"];
    backgroundView = [menu valueForKey:@"backgroundView"];
    popMenuView = [menu valueForKey:@"popMenuView"];
  } @catch (__unused NSException *exception) {
  }

  BOOL menuVisible = popMenuView && popMenuView.window && !popMenuView.hidden && popMenuView.alpha >= 0.05;
  if ((!onScreen || !menuVisible) && backgroundWindow && !backgroundWindow.hidden) {
    NSLog(@"[JLYTouchFixV2] cleanup FTPopOverMenu backgroundWindow onScreen=%d menuVisible=%d", onScreen, menuVisible);
    backgroundWindow.userInteractionEnabled = NO;
    backgroundWindow.hidden = YES;
    backgroundWindow.alpha = 0.0;
  }
  if ((!onScreen || !menuVisible) && backgroundView && backgroundView.superview) {
    backgroundView.userInteractionEnabled = NO;
    [backgroundView removeFromSuperview];
  }
}

static void JLYTFCleanupPluginViews(void) {
  UIApplication *app = [UIApplication sharedApplication];
  for (UIWindow *window in app.windows) {
    if (!window || window.hidden) {
      continue;
    }

    BOOL hasGestureLock = JLYTFViewTreeContains(window, "JLYGestureLock") || JLYTFViewTreeContains(window, "DBGuestureLock");
    if (hasGestureLock) {
      JLYTFHideWindow(window, @"gesture-lock");
      continue;
    }

    BOOL hasPopOver = JLYTFViewTreeContains(window, "FTPopOverMenu");
    if (hasPopOver && !JLYTFHasVisibleMenuView(window)) {
      JLYTFHideWindow(window, @"popover-background");
    }
  }
  JLYTFCleanupFTPopOverSingleton();
}

static BOOL JLYTFShouldPassThroughView(UIView *view) {
  if (!view) {
    return NO;
  }
  if (JLYTFNameContains([view class], "JLYGestureLock") || JLYTFNameContains([view class], "DBGuestureLock")) {
    return YES;
  }
  if (JLYTFNameContains([view class], "FTPopOverMenu") && !JLYTFHasVisibleMenuView(view)) {
    return YES;
  }
  return NO;
}

static BOOL JLYTF_UIControl_pointInside(id self, SEL _cmd, CGPoint point, UIEvent *event) {
  UIControl *control = (UIControl *)self;
  if (control.hidden || control.alpha < 0.01 || !control.userInteractionEnabled) {
    return NO;
  }
  CGRect bounds = control.bounds;
  BOOL inside = point.x >= bounds.origin.x && point.x <= bounds.origin.x + bounds.size.width &&
                point.y >= bounds.origin.y && point.y <= bounds.origin.y + bounds.size.height;
  if (!inside) {
    return NO;
  }

  NSTimeInterval now = CACurrentMediaTime();
  if (now - JLYTFLastHitLog > 2.0) {
    JLYTFLastHitLog = now;
    NSLog(@"[JLYTouchFixV2] UIControl pointInside restored hit=%@ bounds=%@ point=%@ enabled=%d",
          JLYTFClassChain(control), NSStringFromCGRect(control.bounds), NSStringFromCGPoint(point), control.enabled);
  }
  return YES;
}

static NSString *JLYTFControlTitle(UIControl *control) {
  if (!control) {
    return @"";
  }
  if ([control respondsToSelector:@selector(currentTitle)]) {
    NSString *title = ((NSString *(*)(id, SEL))objc_msgSend)(control, @selector(currentTitle));
    if (title.length) {
      return title;
    }
  }
  if ([control respondsToSelector:@selector(titleLabel)]) {
    id label = ((id (*)(id, SEL))objc_msgSend)(control, @selector(titleLabel));
    if ([label respondsToSelector:@selector(text)]) {
      NSString *text = ((NSString *(*)(id, SEL))objc_msgSend)(label, @selector(text));
      if (text.length) {
        return text;
      }
    }
  }
  return @"";
}

static void JLYTFLogControlActions(UIControl *control, NSString *reason) {
  NSTimeInterval now = CACurrentMediaTime();
  if (now - JLYTFLastActionLog < 0.15) {
    return;
  }
  JLYTFLastActionLog = now;

  NSMutableArray *items = [NSMutableArray array];
  NSSet *targets = [control allTargets];
  for (id target in targets) {
    NSArray<NSString *> *actions = [control actionsForTarget:target forControlEvent:UIControlEventTouchUpInside];
    if (!actions.count) {
      actions = [control actionsForTarget:target forControlEvent:UIControlEventTouchDown];
    }
    [items addObject:[NSString stringWithFormat:@"target=%@ actions=%@", JLYTFClassChain(target), [actions componentsJoinedByString:@","]]];
  }

  NSLog(@"[JLYTouchFixV2] control %@ class=%@ title=%@ frame=%@ targets=%@",
        reason, JLYTFClassChain(control), JLYTFControlTitle(control), NSStringFromCGRect(control.frame),
        [items componentsJoinedByString:@" | "]);
}

static BOOL JLYTF_UIApplication_sendAction(id self, SEL _cmd, SEL action, id target, id sender, UIEvent *event) {
  if ([sender isKindOfClass:[UIControl class]]) {
    JLYTFLogControlActions((UIControl *)sender, [NSString stringWithFormat:@"UIApplication action=%@ to=%@", NSStringFromSelector(action), JLYTFClassChain(target)]);
  } else {
    NSTimeInterval now = CACurrentMediaTime();
    if (now - JLYTFLastActionLog > 0.15) {
      JLYTFLastActionLog = now;
      NSLog(@"[JLYTouchFixV2] UIApplication action=%@ to=%@ sender=%@",
            NSStringFromSelector(action), JLYTFClassChain(target), JLYTFClassChain(sender));
    }
  }
  return orig_UIApplication_sendAction ? orig_UIApplication_sendAction(self, _cmd, action, target, sender, event) : NO;
}

static void JLYTF_UIControl_sendAction(id self, SEL _cmd, SEL action, id target, UIEvent *event) {
  JLYTFLogControlActions((UIControl *)self, [NSString stringWithFormat:@"UIControl action=%@ to=%@", NSStringFromSelector(action), JLYTFClassChain(target)]);
  if (orig_UIControl_sendAction) {
    orig_UIControl_sendAction(self, _cmd, action, target, event);
  }
}

static UIView *JLYTF_UIView_hitTest(id self, SEL _cmd, CGPoint point, UIEvent *event) {
  if (JLYTFShouldPassThroughView((UIView *)self)) {
    return nil;
  }
  UIView *hit = orig_UIView_hitTest ? orig_UIView_hitTest(self, _cmd, point, event) : nil;
  if (JLYTFShouldPassThroughView(hit)) {
    return nil;
  }
  return hit;
}

static void JLYTF_UIWindow_sendEvent(id self, SEL _cmd, UIEvent *event) {
  if (orig_UIWindow_sendEvent) {
    orig_UIWindow_sendEvent(self, _cmd, event);
  }
  NSSet *touches = [event allTouches];
  UITouch *touch = touches.anyObject;
  if (touch.phase == UITouchPhaseBegan) {
    JLYTFLogWindows();
    CGPoint point = [touch locationInView:(UIView *)self];
    UIView *hit = [(UIView *)self hitTest:point withEvent:event];
    NSLog(@"[JLYTouchFixV2] touch began window=%@ point=%@ hit=%@ frame=%@ alpha=%.2f hidden=%d user=%d",
          JLYTFClassChain(self), NSStringFromCGPoint(point), JLYTFClassChain(hit),
          hit ? NSStringFromCGRect(hit.frame) : @"nil", hit ? hit.alpha : 0.0,
          hit ? hit.hidden : 0, hit ? hit.userInteractionEnabled : 0);
  }
}

static void JLYTF_FTPopOverMenu_dismiss(id self, SEL _cmd) {
  if (orig_FTPopOverMenu_dismiss) {
    orig_FTPopOverMenu_dismiss(self, _cmd);
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    JLYTFCleanupFTPopOverSingleton();
  });
}

static void JLYTFNoopVoid(id self, SEL _cmd) {
  NSLog(@"[JLYTouchFixV2] suppress %@", NSStringFromSelector(_cmd));
}

static void JLYTFSwizzleInstance(Class cls, SEL sel, IMP imp, IMP *orig) {
  Method method = class_getInstanceMethod(cls, sel);
  if (!method) {
    NSLog(@"[JLYTouchFixV2] missing method %@ on %@", NSStringFromSelector(sel), NSStringFromClass(cls));
    return;
  }
  if (orig) {
    *orig = method_getImplementation(method);
  }
  method_setImplementation(method, imp);
  NSLog(@"[JLYTouchFixV2] swizzled %@ %@", NSStringFromClass(cls), NSStringFromSelector(sel));
}

static void JLYTFSwizzleClassVoidNoop(Class cls, SEL sel) {
  if (!cls) {
    return;
  }
  Class meta = object_getClass(cls);
  Method method = class_getClassMethod(cls, sel);
  if (!method) {
    return;
  }
  class_replaceMethod(meta, sel, (IMP)JLYTFNoopVoid, method_getTypeEncoding(method));
  NSLog(@"[JLYTouchFixV2] noop class %@ %@", NSStringFromClass(cls), NSStringFromSelector(sel));
}

static void JLYTFInstall(void) {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSLog(@"[JLYTouchFixV2] loaded");
    JLYTFSwizzleInstance([UIControl class], @selector(pointInside:withEvent:), (IMP)JLYTF_UIControl_pointInside, NULL);
    JLYTFSwizzleInstance([UIControl class], @selector(sendAction:to:forEvent:), (IMP)JLYTF_UIControl_sendAction, (IMP *)&orig_UIControl_sendAction);
    JLYTFSwizzleInstance([UIApplication class], @selector(sendAction:to:from:forEvent:), (IMP)JLYTF_UIApplication_sendAction, (IMP *)&orig_UIApplication_sendAction);
    JLYTFSwizzleInstance([UIView class], @selector(hitTest:withEvent:), (IMP)JLYTF_UIView_hitTest, (IMP *)&orig_UIView_hitTest);
    JLYTFSwizzleInstance([UIWindow class], @selector(sendEvent:), (IMP)JLYTF_UIWindow_sendEvent, (IMP *)&orig_UIWindow_sendEvent);
    JLYTFSwizzleInstance(NSClassFromString(@"FTPopOverMenu"), @selector(dismiss), (IMP)JLYTF_FTPopOverMenu_dismiss, (IMP *)&orig_FTPopOverMenu_dismiss);
    JLYTFSwizzleClassVoidNoop(NSClassFromString(@"JLYGestureLockView"), @selector(showGestureLockIfNeed));
  });
}

__attribute__((constructor))
static void JLYTouchFixEntry(void) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    JLYTFInstall();
    JLYTFCleanupPluginViews();
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) {
      JLYTFCleanupPluginViews();
    }];
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
  -install_name "$TOUCH_FIX_LOAD" \
  "$WORKDIR/JLYTouchFix.m" \
  -framework Foundation \
  -framework UIKit \
  -framework QuartzCore \
  -o "$TOUCH_FIX"

python3 - "$APP_DIR/$APP_BIN" "$TOUCH_FIX_LOAD" <<'PY'
import importlib.util
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
dylib_name = sys.argv[2]
data = bytearray(target.read_bytes())
if dylib_name.encode() in data:
    print(f"{target} already contains {dylib_name}")
    raise SystemExit(0)

spec = importlib.util.spec_from_file_location("patch_ipa", "scripts/patch_ipa.py")
patch_ipa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch_ipa)
injector = patch_ipa.MachOLoadCommandInjector(data)
target.write_bytes(injector.inject(dylib_name))
print(f"Injected {dylib_name} into {target}")
PY

python3 - "$LIBTEST" "$TOUCH_FIX_LOAD" <<'PY'
import importlib.util
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
dylib_name = sys.argv[2]
data = bytearray(target.read_bytes())
if dylib_name.encode() in data:
    print(f"{target} already contains {dylib_name}")
    raise SystemExit(0)

spec = importlib.util.spec_from_file_location("patch_ipa", "scripts/patch_ipa.py")
patch_ipa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch_ipa)
injector = patch_ipa.MachOLoadCommandInjector(data)
target.write_bytes(injector.inject(dylib_name))
print(f"Injected {dylib_name} into {target}")
PY

cat > "$WORKDIR/inert_addon.c" <<'C'
__attribute__((used)) static const char *jly_resign_marker[] = {
  "https://pee.jlyapp.cn",
  "/api/posts/app-list",
  "https://pee.jlyapp.cn/vip1/meet-list",
  "sm/meet/getmeetlist",
  "sm/matchmaker/recommend",
  "https://pee.jlyapp.cn/api/posts/all-app-list",
  "Circle/detailV1"
};
void jly_resign_marker_function(void) {}
C

clang -isysroot "$SDK" \
  -target arm64-apple-ios12.0 \
  -dynamiclib \
  -miphoneos-version-min=12.0 \
  "$WORKDIR/inert_addon.c" \
  -o "$APP_DIR/JLYSearchAddon.dylib"
cp "$APP_DIR/JLYSearchAddon.dylib" "$APP_DIR/cike.dylib"

python3 - "$APP_DIR/$APP_BIN" <<'PY'
import importlib.util
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
addon = "@executable_path/JLYSearchAddon.dylib"
data = bytearray(target.read_bytes())
if addon.encode() in data:
    raise SystemExit(0)
spec = importlib.util.spec_from_file_location("patch_ipa", "scripts/patch_ipa.py")
patch_ipa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch_ipa)
injector = patch_ipa.MachOLoadCommandInjector(data)
target.write_bytes(injector.inject(addon))
PY

if [[ -n "${MOBILEPROVISION_BASE64:-}" ]]; then
  echo "$MOBILEPROVISION_BASE64" | base64 --decode > "$APP_DIR/embedded.mobileprovision"
fi

ENTITLEMENTS="$WORKDIR/entitlements.plist"
if [[ -f "$APP_DIR/embedded.mobileprovision" ]]; then
  security cms -D -i "$APP_DIR/embedded.mobileprovision" > "$WORKDIR/profile.plist" || true
  /usr/libexec/PlistBuddy -x -c 'Print Entitlements' "$WORKDIR/profile.plist" > "$ENTITLEMENTS" || true
fi

IDENTITY="${CODESIGN_IDENTITY:--}"
echo "Signing identity: ${IDENTITY}"
if [[ -n "${SIGNING_CERT_P12_BASE64:-}" ]]; then
  security create-keychain -p "" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "" "$KEYCHAIN_PATH"
  echo "$SIGNING_CERT_P12_BASE64" | base64 --decode > "$WORKDIR/signing.p12"
  security import "$WORKDIR/signing.p12" -k "$KEYCHAIN_PATH" -P "${SIGNING_CERT_PASSWORD:-}" -T /usr/bin/codesign
  security list-keychains -d user -s "$KEYCHAIN_PATH" login.keychain-db
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN_PATH"
fi

sign_target() {
  local target="$1"
  if [[ -s "$ENTITLEMENTS" && "$target" == "$APP_DIR" ]]; then
    codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$target"
  else
    codesign --force --sign "$IDENTITY" "$target"
  fi
}

if [[ -d "$APP_DIR/Frameworks" ]]; then
  find "$APP_DIR/Frameworks" -type f \( -perm -111 -o -name '*.dylib' \) -print0 | while IFS= read -r -d '' file; do
    sign_target "$file" || true
  done
  find "$APP_DIR/Frameworks" -maxdepth 1 -name '*.framework' -type d -print0 | while IFS= read -r -d '' framework; do
    sign_target "$framework" || true
  done
fi

find "$APP_DIR" -maxdepth 1 -name '*.dylib' -type f -print0 | while IFS= read -r -d '' dylib; do
  sign_target "$dylib"
done

sign_target "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
otool -l "$LIBTEST" | grep -F "$MIAOTAO_LOAD"
otool -l "$APP_DIR/$APP_BIN" | grep -F "$TOUCH_FIX_LOAD"
otool -l "$LIBTEST" | grep -F "$TOUCH_FIX_LOAD"
grep -q 'libmiaotao 2.dylib' "$APP_DIR/_CodeSignature/CodeResources"
grep -q 'libJLYTouchFix.dylib' "$APP_DIR/_CodeSignature/CodeResources"

mkdir -p "$(dirname "$OUTPUT_IPA")"
(
  cd "$WORKDIR/ipa"
  ditto -c -k --sequesterRsrc --keepParent Payload "$OLDPWD/$OUTPUT_IPA"
)

echo "Built $OUTPUT_IPA"
