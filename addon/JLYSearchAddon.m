#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *JLYSearchQuery;
static IMP OrigPaidPostsURLWithCountPageInfo;
static IMP OrigShowPaidVideoList;
static IMP OrigReloadPaidVideoList;

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

static void JLYSwizzle(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        return;
    }
    *original = method_getImplementation(method);
    method_setImplementation(method, replacement);
}

__attribute__((constructor))
static void JLYSearchAddonInit(void) {
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
