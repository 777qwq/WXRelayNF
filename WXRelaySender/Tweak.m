/**
 * WXRelaySender — 微信端发送器（并入 WXRelay v1.7.0）
 *
 * 职责（单一）：
 *   1. 监听 darwin com.mos.wxrelay.task + 启动补发
 *   2. 消费 wxrelay_tasks JSON（targets+text）→ 进程内私 API 直发（v2.3.0 去懒猫）
 *   3. 锁屏存活交给 AppData 真后台（v2.5.1 移除内置保活）
 * 匹配逻辑全部在 SB 端（WXRelay 主体），本进程不做任何规则判断。
 * 日志：微信沙盒 tmp/wxrelay.log
 */
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>

static void wrLog(NSString *msg) {
    @try {
        static NSDateFormatter *f = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.dateFormat = @"HH:mm:ss"; });
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [f stringFromDate:[NSDate date]], msg];
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    } @catch (NSException *e) { }
}


// ===== 模块C：通知复活（保活态原生横幅，v0.15 并入） =====
// 实测（WXRelayProbe 3.x + WXRelayNF 2.2.7/2.2.8，iOS 16.3）：
//   保活使 usernoted 把微信当"活跃 app"→ 通知呈现决策下放到进程内
//   UNUserNotificationCenter delegate（willPresent），微信返回缺 banner
//   → 有声音震动、无横幅无角标。修复：swizzle delegate 的 willPresent，
//   按真实前台状态改答案：微信真前台→透传（走微信自己设置）；非前台→
//   强制 banner+list+sound（原生路径，零伪造）。真前台判定由 SB 侧
//   （WXRelayTweak）写共享文件，本模块只读。
static BOOL WRBannerFixDone = NO;
static Class WRLastDelegateClass = nil;

static NSString *WRPrefsPath(void) {
    return @"/var/mobile/Library/Preferences/com.777qwq.wxrelay.plist";
}

static BOOL WRBannerEnabled(void) {
    @try {
        NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:WRPrefsPath()];
        id v = p[@"ShowBanner"];
        return v ? [v boolValue] : YES; // 默认开
    } @catch (NSException *e) { return YES; }
}

// SB 侧写共享文件判真前台（v0.16 权威版定义在后）
static BOOL WRUserLookingAtWeChat(void);

static void WRAddWillPresent(void) {
    id center = ((id(*)(id,SEL))objc_msgSend)(objc_getClass("UNUserNotificationCenter"), @selector(currentNotificationCenter));
    if (!center) return;
    id dlg = ((id(*)(id,SEL))objc_msgSend)(center, @selector(delegate));
    Class cur = dlg ? object_getClass(dlg) : nil;
    if (WRBannerFixDone && cur == WRLastDelegateClass) return; // 同一个 delegate，已处理
    if (WRBannerFixDone && cur != WRLastDelegateClass)
        wrLog([NSString stringWithFormat:@"bannerfix: delegate changed %@ -> %@ — re-arm",
              NSStringFromClass(WRLastDelegateClass), NSStringFromClass(cur)]);
    WRBannerFixDone = NO;
    WRLastDelegateClass = cur;
    if (!WRBannerEnabled()) return;
    @try {
        if (!dlg) return;
        Class cls = object_getClass(dlg);
        SEL sel = NSSelectorFromString(@"userNotificationCenter:willPresentNotification:withCompletionHandler:");
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) {
            wrLog(@"bannerfix: delegate lacks willPresent — adding");
            struct objc_method_description d =
                protocol_getMethodDescription(@protocol(UNUserNotificationCenterDelegate), sel, NO, YES);
            IMP blk = imp_implementationWithBlock(^(id self, id c2, UNNotification *n, void (^handler)(NSUInteger)) {
                wrLog([NSString stringWithFormat:@"bannerfix: willPresent(added) %@ -> banner+list+sound",
                       n.request.content.title ?: @"(nil)"]);
                handler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList
                      | UNNotificationPresentationOptionSound);
            });
            BOOL ok = class_addMethod(cls, sel, blk, d.types ?: "v@:@@@@?");
            wrLog([NSString stringWithFormat:@"bannerfix: addMethod on %@ -> %d", NSStringFromClass(cls), ok]);
            WRBannerFixDone = ok;
            return;
        }
        // 已实现：拦截，按真实前台状态决定透传或强制横幅
        IMP orig = method_getImplementation(m);
        IMP blk = imp_implementationWithBlock(^(id self, id c2, UNNotification *n, void (^handler)(NSUInteger)) {
            BOOL looking = WRUserLookingAtWeChat();
            if (looking) {
                wrLog([NSString stringWithFormat:@"bannerfix: wechat foreground -> pass-through (%@)",
                       n.request.content.title ?: @"(nil)"]);
                ((void (*)(id, SEL, id, UNNotification *, void (^)(NSUInteger)))orig)
                    (self, @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:), c2, n, handler);
                return;
            }
            void (^wrapped)(NSUInteger) = ^(NSUInteger opts) {
                static NSMutableDictionary *recent = nil;
                static dispatch_once_t onceT;
                dispatch_once(&onceT, ^{ recent = [NSMutableDictionary dictionary]; });
                NSString *key = [NSString stringWithFormat:@"%@|%@", n.request.content.title ?: @"", n.request.content.body ?: @""];
                NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                NSTimeInterval lastT = [recent[key] doubleValue];
                if (now - lastT < 3.0) {
                    wrLog([NSString stringWithFormat:@"bannerfix: dedupe hit (%@) — passthrough", n.request.content.title]);
                    handler(opts);
                    return;
                }
                recent[key] = @(now);
                NSUInteger forced = opts | UNNotificationPresentationOptionBanner
                                        | UNNotificationPresentationOptionList
                                        | UNNotificationPresentationOptionSound;
                wrLog([NSString stringWithFormat:@"bannerfix: background -> orig=%lu forced=%lu (%@)",
                       (unsigned long)opts, (unsigned long)forced, n.request.content.title ?: @"(nil)"]);
                handler(forced);
            };
            ((void (*)(id, SEL, id, UNNotification *, void (^)(NSUInteger)))orig)
                (self, @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:), c2, n, wrapped);
        });
        method_setImplementation(m, blk);
        wrLog([NSString stringWithFormat:@"bannerfix: willPresent swizzled on %@ (foreground passthrough / background force)", NSStringFromClass(cls)]);
        WRBannerFixDone = YES;
    } @catch (NSException *e) {
        wrLog([NSString stringWithFormat:@"bannerfix EXC: %@", e.name]);
    }
}

static void WRNoteSentText(NSString *text);
static NSString *WRStr(id v);
static volatile BOOL WRInSend = NO;

// v2.3.2 路A：备注/昵称 → wxid，**仅精准匹配**（不做包含/前缀）；解析失败返回 nil，绝不裸发
static NSString *WRResolveTargetID(NSString *targetId) {
    @try {
        Class CContactMgr = objc_getClass("CContactMgr");
        Class MMServiceCenter = objc_getClass("MMServiceCenter");
        if (!CContactMgr || !MMServiceCenter) return nil;
        id center = ((id(*)(id,SEL))objc_msgSend)(MMServiceCenter, @selector(defaultCenter));
        id mgr = center ? ((id(*)(id,SEL,id))objc_msgSend)(center, @selector(getService:), CContactMgr) : nil;
        if (!mgr) return nil;
        // 8.0.50 实证：getContactByDisplayName 不存在，直接走列表精准扫描
        // v2.4.0 备注优先：第一轮备注精准（备注盖昵称，与微信显示语义一致）；零命中才扫昵称；撞名弃用
        if (![mgr respondsToSelector:@selector(getContactList:contactType:)]) return nil;
        id list = ((id(*)(id,SEL,unsigned int,unsigned int))objc_msgSend)(mgr, @selector(getContactList:contactType:), 0xFFFFFFFFu, 0u);
        if (![list isKindOfClass:[NSArray class]]) return nil;
        __block id hit = nil; __block unsigned int hits = 0;
        // 第一轮：备注
        for (id c in list) {
            if (![c respondsToSelector:@selector(m_nsRemark)]) continue;
            id rem = ((id(*)(id,SEL))objc_msgSend)(c, @selector(m_nsRemark));
            if ([rem isKindOfClass:[NSString class]] && [(NSString *)rem isEqualToString:targetId]) { hit = c; hits++; if (hits > 1) break; }
        }
        if (hits > 1) { wrLog([NSString stringWithFormat:@"resolve '%@' ambiguous remark (%u), skip", targetId, hits]); return nil; }
        // 第二轮：备注零命中才扫昵称
        if (hits == 0) {
            for (id c in list) {
                if (![c respondsToSelector:@selector(m_nsNickName)]) continue;
                id nick = ((id(*)(id,SEL))objc_msgSend)(c, @selector(m_nsNickName));
                if ([nick isKindOfClass:[NSString class]] && [(NSString *)nick isEqualToString:targetId]) { hit = c; hits++; if (hits > 1) break; }
            }
            if (hits > 1) { wrLog([NSString stringWithFormat:@"resolve '%@' ambiguous nick (%u), skip", targetId, hits]); return nil; }
        }
        if (hits == 1 && hit && [hit respondsToSelector:@selector(m_nsUsrName)]) {
            id wxid = ((id(*)(id,SEL))objc_msgSend)(hit, @selector(m_nsUsrName));
            if ([wxid isKindOfClass:[NSString class]] && [(NSString *)wxid length] > 0) {
                wrLog([NSString stringWithFormat:@"resolve '%@' -> %@", targetId, wxid]);
                return wxid;
            }
        }
        return nil;
    } @catch (NSException *e) { return nil; }
}

// v2.3.0 直发：进程内私 API，走微信原生发送管线（CMessageMgr AddMsg），不再依赖懒猫 handleOpenURL
// 参考：DKWechatHelper sendMsg（8.x 实战）+ iWeChat dump 头；真机签名待验证
static BOOL WRSendMessage(NSString *targetId, NSString *text) {
    if (WRInSend) return NO; // 防重入
    WRInSend = YES;
    @try {
        // v2.3.2 安全线：解析失败绝不裸发（防错发）；标准 id 格式直通不走解析
        BOOL isPlainID = [targetId isEqualToString:@"filehelper"] || [targetId hasSuffix:@"@chatroom"]
            || [targetId hasPrefix:@"wxid_"] || [targetId hasPrefix:@"gh_"];
        NSString *resolved = isPlainID ? targetId : WRResolveTargetID(targetId);
        if (!resolved) { wrLog([NSString stringWithFormat:@"resolve failed, skip '%@'", targetId]); { WRInSend = NO; return NO; } }
        targetId = resolved;
        Class MMServiceCenter = objc_getClass("MMServiceCenter");
        Class CMessageMgr = objc_getClass("CMessageMgr");
        Class CMessageWrap = objc_getClass("CMessageWrap");
        Class SettingUtil = objc_getClass("SettingUtil");
        if (!MMServiceCenter || !CMessageMgr || !CMessageWrap || !SettingUtil) {
            wrLog(@"send: private class missing");
            { WRInSend = NO; return NO; }
        }
        id center = ((id(*)(id,SEL))objc_msgSend)(MMServiceCenter, @selector(defaultCenter));
        id fromUsr = ((id(*)(id,SEL,long long))objc_msgSend)(SettingUtil, @selector(getLocalUsrName:), 0);
        if (!center || !fromUsr) { wrLog(@"send: center/self missing"); { WRInSend = NO; return NO; } }
        if (![center respondsToSelector:@selector(getService:)]) { wrLog(@"send: no getService"); { WRInSend = NO; return NO; } }
        id mgr = ((id(*)(id,SEL,id))objc_msgSend)(center, @selector(getService:), CMessageMgr);
        if (!mgr) { wrLog(@"send: no CMessageMgr"); { WRInSend = NO; return NO; } }
        if (![(id)CMessageWrap respondsToSelector:@selector(alloc)]) { wrLog(@"send: no wrap alloc"); { WRInSend = NO; return NO; } }
        id wrap = ((id(*)(id,SEL))objc_msgSend)((id)CMessageWrap, @selector(alloc));
        wrap = ((id(*)(id,SEL,long long))objc_msgSend)(wrap, @selector(initWithMsgType:), (long long)1);
        if (!wrap) { wrLog(@"send: wrap init failed"); { WRInSend = NO; return NO; } }
        ((void(*)(id,SEL,id))objc_msgSend)(wrap, @selector(setM_nsFromUsr:), fromUsr);
        ((void(*)(id,SEL,id))objc_msgSend)(wrap, @selector(setM_nsContent:), text);
        ((void(*)(id,SEL,id))objc_msgSend)(wrap, @selector(setM_nsToUsr:), targetId);
        ((void(*)(id,SEL,unsigned int))objc_msgSend)(wrap, @selector(setM_uiMesLocalID:), 11u);
        ((void(*)(id,SEL,_Bool))objc_msgSend)(wrap, @selector(setM_uiStatus:), YES);
        // 时间戳：优先 MMNewSessionMgr GenSendMsgTime，失败则用系统时间
        Class MMNewSessionMgr = objc_getClass("MMNewSessionMgr");
        unsigned int ctime = (unsigned int)[[NSDate date] timeIntervalSince1970];
        if (MMNewSessionMgr) {
            id sm = ((id(*)(id,SEL,id))objc_msgSend)(center, @selector(getService:), MMNewSessionMgr);
            if (sm && [sm respondsToSelector:@selector(GenSendMsgTime)])
                ctime = ((unsigned int(*)(id,SEL))objc_msgSend)(sm, @selector(GenSendMsgTime));
        }
        ((void(*)(id,SEL,unsigned int))objc_msgSend)(wrap, @selector(setM_uiCreateTime:), ctime);
        ((void(*)(id,SEL,id,id))objc_msgSend)(mgr, @selector(AddMsg:MsgWrap:), targetId, wrap);
        WRNoteSentText(text);
        wrLog([NSString stringWithFormat:@"send ok -> %@ (len=%lu)", targetId, (unsigned long)text.length]);
        WRInSend = NO;
        return YES;
    } @catch (NSException *e) {
        wrLog([NSString stringWithFormat:@"send EXC: %@ %@", e.name, e.reason]);
        { WRInSend = NO; return NO; }
    }
}

static void WRFlushTasks(void) {
    @try {
        NSString *taskDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay_tasks"];
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:taskDir error:nil];
        if (!files.count) return;
        wrLog([NSString stringWithFormat:@"flush %lu task(s)", (unsigned long)files.count]);
        for (NSString *fn in files) {
            if (![fn hasSuffix:@".json"]) continue;
            NSString *p = [taskDir stringByAppendingPathComponent:fn];
            NSDictionary *task = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:p]
                options:NSJSONReadingAllowFragments error:nil];
            if ([task isKindOfClass:[NSDictionary class]]) {
                // v2.4.0 items 格式：[{id, text}]（SB 端按目标动作生成）；兼容旧 targets+text
                id items = task[@"items"];
                if ([items isKindOfClass:[NSArray class]] && [(NSArray *)items count] > 0) {
                    for (NSDictionary *it in items)
                        if ([it isKindOfClass:[NSDictionary class]]
                            && [it[@"id"] isKindOfClass:[NSString class]]
                            && [it[@"text"] isKindOfClass:[NSString class]])
                            WRSendMessage(it[@"id"], it[@"text"]);
                } else {
                    NSString *text = task[@"text"];
                    NSArray *targets = task[@"targets"];
                    if ([text isKindOfClass:[NSString class]] && [targets isKindOfClass:[NSArray class]]) {
                        for (NSString *target in targets)
                            if ([target isKindOfClass:[NSString class]]) WRSendMessage(target, text);
                    }
                }
            }
            [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
        }
        wrLog(@"flush done");
    } @catch (NSException *e) { wrLog([NSString stringWithFormat:@"flush EXC %@", e.name]); }
}


static void WRTaskNotifyCallback(CFNotificationCenterRef __unused c, void __unused *o,
                                 CFStringRef __unused n, const void __unused *obj, CFDictionaryRef __unused ui) {
    @autoreleasepool { WRFlushTasks(); }
}


// ===== v2.8.0 模块B：消息源（AsyncOnAddMsg 全覆盖）=====
// 管线：微信收消息 → 组 record JSON → 落 wxrelay_msgs + darwin 呼 SB → SB 匹配 → 现有任务通道回微信
// v0.3 banner: post local notification when in background (UILocalNotification)
// v0.16：UN 请求通道（原生头像/点击直达），前台判定读 SB 写的共享文件
// （applicationState 被 Immortalizer 伪造成 Active，不可信——0.15 实测门禁全灭）
// ===== v0.23 探针：UIKit 场景层真值记录（通知流+2s 快照） =====
static NSMutableString *WRProbeLog = nil;

static void WRProbeFlush(void) {
    @try {
        if (!WRProbeLog) return;
        NSString *fp2 = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay_probe_wx.txt"] copy];
        [WRProbeLog writeToFile:fp2 atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) { }
}

static void WRProbeAppend(NSString *line) {
    @try {
        static NSDateFormatter *df = nil;
        if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"HH:mm:ss"; }
        if (!WRProbeLog) WRProbeLog = [NSMutableString new];
        [WRProbeLog appendFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], line];
        if (WRProbeLog.length > 14000) [WRProbeLog deleteCharactersInRange:NSMakeRange(0, 7000)];
        WRProbeFlush();
    } @catch (NSException *e) { }
}

// ===== v0.24 帧流探针：后台 app 的 display link 被 iOS 停调，
// 若切走后帧断流，"帧流活着"=真前台（Immortalizer 伪造不了 render server） =====
@interface WRFrameTap : NSObject
@property (nonatomic, assign) int frames;
@end
@implementation WRFrameTap
- (void)tick:(CADisplayLink *)dl { _frames++; }
@end

static WRFrameTap *WRFrameTapInst = nil;

static void WRProbeFrameStart(void) {
    if (WRFrameTapInst) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (WRFrameTapInst) return;
        WRFrameTapInst = [[WRFrameTap alloc] init];
        Class dlc = objc_getClass("CADisplayLink");
        if (!dlc) { WRProbeAppend(@"frame: no CADisplayLink"); return; }
        CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:WRFrameTapInst selector:@selector(tick:)];
        if (!dl) { WRProbeAppend(@"frame: no displayLink"); return; }
        [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        WRProbeAppend(@"frame: displayLink armed (commonModes)");
    });
}

static void WRProbeStart(void) {
    @try {
        WRProbeAppend(@"=== 0.24 wx probe start ===");
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        for (NSString *nm in @[@"UIApplicationWillResignActiveNotification",
                               @"UIApplicationDidBecomeActiveNotification",
                               @"UIApplicationWillEnterForegroundNotification",
                               @"UIApplicationDidEnterBackgroundNotification"]) {
            [nc addObserverForName:nm object:nil queue:nil usingBlock:^(NSNotification *note) {
                WRProbeAppend([NSString stringWithFormat:@"EVT %@", nm]);
            }];
        }
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
        if (t) {
            dispatch_source_set_timer(t, DISPATCH_TIME_NOW, 2.0 * NSEC_PER_SEC, 1.0 * NSEC_PER_SEC);
            dispatch_source_set_event_handler(t, ^{
                @try {
                    UIApplication *app = [UIApplication sharedApplication];
                    id scene = nil;
                    long st = -1, sc = -9;
                    @try { st = (long)app.applicationState; } @catch (NSException *e) { st = -2; }
                    @try { scene = [app valueForKey:@"keyWindowScene"]; } @catch (NSException *e) { }
                    if (scene) {
                        @try { sc = [(NSNumber *)[scene valueForKey:@"activationState"] longValue]; } @catch (NSException *e) { sc = -8; }
                    }
                    long fr = -1;
                    @try { fr = WRFrameTapInst.frames; WRFrameTapInst.frames = 0; } @catch (NSException *e) { }
                    WRProbeAppend([NSString stringWithFormat:@"SNAP appState=%ld sceneAct=%ld frames2s=%ld", st, sc, fr]);
                } @catch (NSException *e) { }
            });
            dispatch_resume(t);
        }
    } @catch (NSException *e) { }
}

// v0.22 触摸真值：Immortalizer 把系统侧"微信前台状态"全伪造，唯一幸存真值=触摸事件
// 只流向用户正在看的 app。sendEvent 记录最后触摸时间。
static NSTimeInterval WRLastTouchAt = 0;

static void WRInstallTouchHook(void) {
    @try {
        Class c = objc_getClass("UIApplication");
        SEL s = @selector(sendEvent:);
        Method m = class_getInstanceMethod(c, s);
        if (!m) { wrLog(@"touch hook: no sendEvent"); return; }
        IMP orig = method_getImplementation(m);
        IMP blk = imp_implementationWithBlock(^(id self2, UIEvent *event) {
            @try {
                if (event.allTouches.count > 0)
                    WRLastTouchAt = [[NSDate date] timeIntervalSince1970];
            } @catch (NSException *e) { }
            ((void(*)(id,SEL,UIEvent*))orig)(self2, @selector(sendEvent:), event);
        });
        method_setImplementation(m, blk);
        wrLog(@"touch hook installed (sendEvent)");
    } @catch (NSException *e) {
        wrLog([NSString stringWithFormat:@"touch hook EXC %@", e.name]);
    }
}

static BOOL WRUserLookingAtWeChat(void) {
    if (WRLastTouchAt <= 0) return NO; // 冷启动后未触摸过：不在看
    return ([[NSDate date] timeIntervalSince1970] - WRLastTouchAt) < 90.0;
}

static NSString *WRAvatarCacheFile(NSString *wxid) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"wxavatar_%@.dat", [wxid valueForKey:@"hash"]]];
}

// 头像：本地缓存优先，否则拉 CContact 头像 URL（2 秒预算，失败退纯文本横幅）
static NSData *WRAvatarData(NSString *wxid) {
    @try {
        if (wxid.length == 0) return nil;
        NSString *cache = WRAvatarCacheFile(wxid);
        NSData *cached = [NSData dataWithContentsOfFile:cache];
        if (cached.length > 100) return cached;
        id mgr = ((id(*)(id,SEL))objc_msgSend)(objc_getClass("MMServiceCenter"), @selector(defaultCenter));
        Class CContactMgr = objc_getClass("CContactMgr");
        if (!mgr || !CContactMgr) return nil;
        id cm = ((id(*)(id,SEL,id))objc_msgSend)(mgr, @selector(getService:), CContactMgr);
        if (!cm) return nil;
        id contact = ((id(*)(id,SEL,id))objc_msgSend)(cm, @selector(getContactByName:), wxid);
        if (!contact || ![contact respondsToSelector:@selector(m_nsHeadImgUrl)]) return nil;
        NSString *url = WRStr([contact valueForKey:@"m_nsHeadImgUrl"]);
        if (url.length == 0 || ![url hasPrefix:@"http"]) return nil;
        NSData *d = [NSData dataWithContentsOfURL:[NSURL URLWithString:url]];
        if (d.length > 100) { [d writeToFile:cache atomically:YES]; return d; }
    } @catch (NSException *e) { }
    return nil;
}

static dispatch_queue_t WRBannerQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.777qwq.wxrelay.banner", DISPATCH_QUEUE_SERIAL); });
    return q;
}

static NSTimeInterval WRLastBannerPost = 0;

// v0.19：整条投递链（含头像下载）全部在串行后台队列执行，钩子线程零阻塞；
// 限流 0.8s 防洪峰（usernoted 过载疑似会杀微信）。
static void WRPostBannerInner(NSString *title, NSString *body, NSString *threadId);

static void WRPostBanner(NSString *title, NSString *body, NSString *threadId) {
    NSString *t = [title copy]; NSString *b = [body copy]; NSString *tid = [threadId copy];
    dispatch_async(WRBannerQueue(), ^{
        @try {
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            if (now - WRLastBannerPost < 0.8) { wrLog(@"banner: rate-limited, drop"); return; }
            WRLastBannerPost = now;
            WRPostBannerInner(t, b, tid);
        } @catch (NSException *e) {
            wrLog([NSString stringWithFormat:@"banner q EXC %@", e.name]);
        }
    });
}

static void WRPostBannerInner(NSString *title, NSString *body, NSString *threadId) {
    @try {
        BOOL looking = WRUserLookingAtWeChat();
        wrLog([NSString stringWithFormat:@"banner: decide touchAge=%.0fs looking=%d ('%@')",
              WRLastTouchAt > 0 ? [[NSDate date] timeIntervalSince1970] - WRLastTouchAt : -1, looking, title ?: @""]);
        if (looking) { wrLog(@"banner: user in WeChat — skip"); return; }
        Class UNC = objc_getClass("UNUserNotificationCenter");
        if (!UNC) { wrLog(@"banner: no UNUserNotificationCenter"); return; }
        id center = ((id(*)(id,SEL))objc_msgSend)(UNC, @selector(currentNotificationCenter));
        if (!center) return;
        Class contentCls = objc_getClass("UNMutableNotificationContent");
        if (!contentCls) return;
        id content = [[contentCls alloc] init];
        if (title.length) [content setTitle:title];
        if (body.length) [content setBody:body];
        [content setSound:((id(*)(id,SEL))objc_msgSend)(objc_getClass("UNNotificationSound"), @selector(defaultSound))];
        if (threadId.length) [content setThreadIdentifier:threadId];
        [content setUserInfo:@{@"wxrelay": @YES}];
        // v0.17 头像附件（banner 右侧缩略图）+ 角标
        if (threadId.length) {
            NSData *av = WRAvatarData(threadId);
            if (av.length) {
                NSString *avFile = [NSTemporaryDirectory() stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"wxav_%@.png", [[NSUUID UUID] UUIDString]]];
                [av writeToFile:avFile atomically:YES];
                Class attCls = objc_getClass("UNNotificationAttachment");
                if (attCls) {
                    NSError *__autoreleasing aerr = nil;
                    id att = ((id(*)(id,SEL,id,id,id,id*))objc_msgSend)(attCls, @selector(attachmentWithIdentifier:URL:options:error:),
                        @"avatar", [NSURL fileURLWithPath:avFile], nil, &aerr);
                    if (att) {
                        [content setAttachments:[NSArray arrayWithObject:att]];
                        wrLog(@"banner: avatar attached");
                    } else wrLog([NSString stringWithFormat:@"banner: attach ERR %@", aerr.localizedDescription ?: @""]);
                }
            }
        }
        NSUInteger cur = (NSUInteger)((long(*)(id,SEL))objc_msgSend)([UIApplication sharedApplication], @selector(applicationIconBadgeNumber));
        [content setBadge:@(cur + 1)];
        Class trigCls = objc_getClass("UNTimeIntervalNotificationTrigger");
        id trigger = ((id(*)(id,SEL,double,BOOL))objc_msgSend)(trigCls, @selector(triggerWithTimeInterval:repeats:), 0.05, NO);
        Class reqCls = objc_getClass("UNNotificationRequest");
        id req = ((id(*)(id,SEL,id,id,id))objc_msgSend)(reqCls, @selector(requestWithIdentifier:content:trigger:),
            [NSString stringWithFormat:@"wxr-%.0f", [[NSDate date] timeIntervalSince1970] * 100], content, trigger);
        [content release];
        ((void(*)(id,SEL,id,id))objc_msgSend)(center, @selector(addNotificationRequest:withCompletionHandler:), req,
            ^(NSError *err){ if (err) wrLog([NSString stringWithFormat:@"banner add ERR: %@", err.localizedDescription]); });
        wrLog([NSString stringWithFormat:@"banner: UN posted '%@'", title ?: @""]);
    } @catch (NSException *e) {
        wrLog([NSString stringWithFormat:@"banner EXC %@", e.name]);
    }
}

static NSString *WRStr(id v) {
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static NSString *WRContactDisplayName(NSString *wxid) {
    if (wxid.length == 0) return wxid;
    @try {
        Class CContactMgr = objc_getClass("CContactMgr");
        Class MMServiceCenter = objc_getClass("MMServiceCenter");
        if (!CContactMgr || !MMServiceCenter) return wxid;
        id center = ((id(*)(id,SEL))objc_msgSend)(MMServiceCenter, @selector(defaultCenter));
        id mgr = center ? ((id(*)(id,SEL,id))objc_msgSend)(center, @selector(getService:), CContactMgr) : nil;
        if (!mgr || ![mgr respondsToSelector:@selector(getSelfContact)]) return wxid;
        // 按表精准扫：先备注后昵称（与路径A同名语义）
        if (![mgr respondsToSelector:@selector(getContactList:contactType:)]) return wxid;
        id list = ((id(*)(id,SEL,unsigned int,unsigned int))objc_msgSend)(mgr, @selector(getContactList:contactType:), 0xFFFFFFFFu, 0u);
        if (![list isKindOfClass:[NSArray class]]) return wxid;
        __block NSString *remark = nil, *nick = nil;
        for (id c in list) {
            if (![c respondsToSelector:@selector(m_nsUsrName)]) continue;
            NSString *u = WRStr([c valueForKey:@"m_nsUsrName"]);
            if (![u isEqualToString:wxid]) continue;
            if ([c respondsToSelector:@selector(m_nsRemark)]) remark = WRStr([c valueForKey:@"m_nsRemark"]);
            if ([c respondsToSelector:@selector(m_nsNickName)]) nick = WRStr([c valueForKey:@"m_nsNickName"]);
            break;
        }
        NSString *name = remark.length ? remark : (nick.length ? nick : nil);
        return name ?: wxid;
    } @catch (NSException *e) { return wxid; }
}

static NSString *WRSelfWxid = nil;

static void WRResolveSelfWxid(void) {
    @try {
        Class CContactMgr = objc_getClass("CContactMgr");
        Class MMServiceCenter = objc_getClass("MMServiceCenter");
        if (!CContactMgr || !MMServiceCenter) return;
        id center = ((id(*)(id,SEL))objc_msgSend)(MMServiceCenter, @selector(defaultCenter));
        id mgr = center ? ((id(*)(id,SEL,id))objc_msgSend)(center, @selector(getService:), CContactMgr) : nil;
        if (!mgr || ![mgr respondsToSelector:@selector(getSelfContact)]) return;
        id me = ((id(*)(id,SEL))objc_msgSend)(mgr, @selector(getSelfContact));
        if ([me respondsToSelector:@selector(m_nsUsrName)])
            WRSelfWxid = [[me valueForKey:@"m_nsUsrName"] retain]; // MRC: static strong must retain
        wrLog([NSString stringWithFormat:@"B: self wxid=%@", WRSelfWxid]);
    } @catch (NSException *e) { }
}

static void WRWriteMsgSourceFlag(void) {
    @try {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay_msgsource.flag"];
        [[NSString stringWithFormat:@"%f", [[NSDate date] timeIntervalSince1970]] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) { }
}

static NSMutableSet<NSString *> *WRLastSentTexts = nil;
static pthread_mutex_t WRLastSentMutex = PTHREAD_MUTEX_INITIALIZER;

// v2.8.6 ctor 急切初始化：静态强引用建一次永不重赋（防 over-release 僵尸）
static void WRInitLastSentStore(void) {
    pthread_mutex_lock(&WRLastSentMutex);
    if (!WRLastSentTexts) WRLastSentTexts = [[NSMutableSet alloc] init];
    pthread_mutex_unlock(&WRLastSentMutex);
}

static void WRNoteSentText(NSString *text) {
    if (!WRLastSentTexts) WRInitLastSentStore();
    pthread_mutex_lock(&WRLastSentMutex);
    [WRLastSentTexts addObject:text ?: @""];
    if (WRLastSentTexts.count > 64) {
        NSString *oldest = [WRLastSentTexts anyObject];
        if (oldest) [WRLastSentTexts removeObject:oldest];
    }
    pthread_mutex_unlock(&WRLastSentMutex);
}

static BOOL WRTextWasRecentlySent(NSString *text) {
    if (!text.length) return NO;
    if (!WRLastSentTexts) WRInitLastSentStore();
    pthread_mutex_lock(&WRLastSentMutex);
    BOOL hit = [WRLastSentTexts containsObject:text];
    pthread_mutex_unlock(&WRLastSentMutex);
    return hit;
}

// v2.8.5 发送中旗标：B hook 见旗标直接跳过（重入/回声釜底抽薪）

// v0.7 保活精准化：微信自报家门（自己场景的 persistenceIdentifier，与 SB 反挂起对象同源）
static NSString *WRWeChatScenePID(void) {
    @try {
        NSSet *scenes = [[UIApplication sharedApplication] connectedScenes];
        for (UIScene *scene in scenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                NSString *pid = scene.session.persistentIdentifier;
                if (pid.length) return pid;
            }
        }
    } @catch (NSException *e) { }
    return nil;
}

// v0.8 保活精准化：微信主动定期上报场景 ID 到文件（不等消息，开了保活就生效）
static void WRReportScenePIDToFile(void) {
    @try {
        NSString *pid = WRWeChatScenePID();
        if (pid.length == 0) return;
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay_scenepid"];
        [pid writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) { }
}


static void WRSpoolMsgRecord(NSDictionary *record) {
    WRReportScenePIDToFile();
    @try {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay_msgs"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [dir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"msg_%@.json", [[NSUUID UUID] UUIDString]]];
        NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
        if (data) { [data writeToFile:path atomically:YES];
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                CFSTR("com.777qwq.wxrelay.msg"), NULL, NULL, YES); }
    } @catch (NSException *e) {
        wrLog([NSString stringWithFormat:@"spool EXC %@", e.name]);
    }
}

static IMP WRAsyncOnAddMsgOrig = NULL;
static NSString *WRHookedSelectorName = nil;

static void WRAsyncOnAddMsgHook(id self, SEL _cmd, id arg1, id wrap) {
    if (WRAsyncOnAddMsgOrig) ((void(*)(id,SEL,id,id))WRAsyncOnAddMsgOrig)(self, _cmd, arg1, wrap);
    @try {
        // 候选参数序归一：单参候选时 wrap 落在 arg1
        if ([WRHookedSelectorName isEqualToString:@"OnNewMessage:"]) wrap = arg1;
        if (WRInSend) return; // 发送中：跳过本次回声/重入
        if (![wrap isKindOfClass:[objc_getClass("CMessageWrap") class]]) return;
        WRWriteMsgSourceFlag();
        // 只收文本（v1）；系统消息/媒体后续需要再说
        unsigned int msgType = 0;
        if ([wrap respondsToSelector:@selector(m_uiMessageType)]) msgType = ((unsigned int(*)(id,SEL))objc_msgSend)(wrap, @selector(m_uiMessageType));
        if (msgType != 1) return;
        NSString *content = [wrap respondsToSelector:@selector(m_nsContent)] ? WRStr([wrap valueForKey:@"m_nsContent"]) : nil;
        if (content.length == 0) return;
        // 自发消息防线：官方 isSender 位 + 已发文本 60 秒回显双保险，杜绝回环
        BOOL isSender = NO;
        if ([wrap respondsToSelector:@selector(m_bIsSender)]) isSender = ((BOOL(*)(id,SEL))objc_msgSend)(wrap, @selector(m_bIsSender));
        if (isSender || WRTextWasRecentlySent(content)) return;
        NSString *fromUsr = [wrap respondsToSelector:@selector(m_nsFromUsr)] ? WRStr([wrap valueForKey:@"m_nsFromUsr"]) : nil;
        NSString *actualUsr = [wrap respondsToSelector:@selector(m_nsActualUsr)] ? WRStr([wrap valueForKey:@"m_nsActualUsr"]) : nil;
        if (fromUsr.length == 0) return;
        // v2.8.7 自身消息防线：来源 wxid 是自己（单聊直发 / 群聊 actualUsr）一律跳过
        if (WRSelfWxid.length && ([fromUsr isEqualToString:WRSelfWxid]
            || (actualUsr.length && [actualUsr isEqualToString:WRSelfWxid]))) return;
        BOOL isGroup = [fromUsr hasSuffix:@"@chatroom"];
        NSString *chatName = WRContactDisplayName(fromUsr);
        NSString *speaker = isGroup ? WRContactDisplayName(actualUsr ?: @"") : nil;
        NSString *title = chatName ?: fromUsr;
        NSString *subtitle = isGroup ? (speaker ?: @"") : @"";
        // v0.3 banner: background incoming message
        {
            NSString *bt = title;
            if (isGroup && subtitle.length) bt = [NSString stringWithFormat:@"%@ - %@", bt, subtitle];
            NSString *threadId = WRStr([wrap valueForKey:@"m_nsFromUsr"]) ?: @"";
            WRPostBanner(bt, content, threadId);
        }
        NSString *msgID = [wrap respondsToSelector:@selector(m_nsMsgId)] ? WRStr([wrap valueForKey:@"m_nsMsgId"]) : nil;
        if (msgID.length == 0) msgID = [NSString stringWithFormat:@"%u-%lu", (unsigned int)msgType, (unsigned long)[content hash]];
        WRSpoolMsgRecord(@{
            @"bid": @"com.tencent.xin",
            @"scenepid": WRWeChatScenePID(),
            @"title": title,
            @"subtitle": subtitle,
            @"body": content,
            @"msgid": [NSString stringWithFormat:@"wxmsg_%@", msgID],
        });
        wrLog([NSString stringWithFormat:@"B hooked: %@ (%@)", title, isGroup ? @"group" : @"chat"]);
    } @catch (NSException *e) {
        wrLog([NSString stringWithFormat:@"B EXC: %@ %@", e.name, e.reason]);
    }
}

static BOOL WRHookMsgSourceSelector(Class CMessageMgr, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!sel || ![CMessageMgr instancesRespondToSelector:sel]) return NO;
    Method m = class_getInstanceMethod(CMessageMgr, sel);
    if (!m) return NO;
    if (WRAsyncOnAddMsgOrig) return YES; // 已挂在别的候选上
    WRAsyncOnAddMsgOrig = method_getImplementation(m);
    method_setImplementation(m, (IMP)WRAsyncOnAddMsgHook);
    WRHookedSelectorName = [name retain]; // MRC 同上
    wrLog([NSString stringWithFormat:@"B: hooked %@", name]);
    return YES;
}

static void WRInstallMsgSourceHook(void) {
    Class CMessageMgr = objc_getClass("CMessageMgr");
    if (!CMessageMgr) { wrLog(@"B: no CMessageMgr"); return; }
    // 多候选：8.x 各版本改名全试，命中即挂
    NSArray *candidates = @[@"AsyncOnAddMsg:Wrap:", @"AsyncOnAddMsg:MsgWrap:",
                            @"OnNewMessage:", @"AsyncOnAddMsgList:ListWrap:"];
    for (NSString *name in candidates) {
        if (WRHookMsgSourceSelector(CMessageMgr, name)) return;
    }
    // 全落空：吐出方法表里疑似收消息的入口，下轮锁定真名
    wrLog(@"B: none of candidates exist; class methods:");
    unsigned int count = 0;
    Method *methods = class_copyMethodList(object_getClass(CMessageMgr) ? CMessageMgr : CMessageMgr, &count);
    unsigned int shown = 0;
    for (unsigned int i = 0; i < count && shown < 12; i++) {
        NSString *n = NSStringFromSelector(method_getName(methods[i]));
        if ([n.lowercaseString containsString:@"addmsg"] || [n.lowercaseString containsString:@"newmessage"]) {
            wrLog([NSString stringWithFormat:@"B cand: %@", n]);
            shown++;
        }
    }
    free(methods);
    if (shown == 0) wrLog(@"B cand: (none matched addmsg/newmessage)");
}

// ===== v2.3.5 探针（一次性，验证解析链后删除）=====
__attribute__((constructor)) static void wxrelaySenderCtor(void) {
    @autoreleasepool {
        wrLog(@"WXRelaySender ctor");
        WRInitLastSentStore();
        WRInstallMsgSourceHook();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WRResolveSelfWxid(); // 等微信联系人服务就绪
            WRReportScenePIDToFile(); // v0.8 保活：场景就绪后立即上报
            WRInstallTouchHook(); // v0.22 触摸真值
            WRProbeStart(); // 探针：场景真值记录
            WRProbeFrameStart(); // v0.24：帧流探针
            WRAddWillPresent(); // 模块C：delegate 已注册，就地装载
        });
        // v0.8 保活：每次回前台刷新场景 ID 文件（场景会话可能变化）
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            WRReportScenePIDToFile();
        }];
        WRWriteMsgSourceFlag();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            WRTaskNotifyCallback, (__bridge CFStringRef)@"com.mos.wxrelay.task", NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WRAddWillPresent(); // 模块C兜底重试
            WRFlushTasks(); // 启动补发积压
            // v2.5.1：保活/轮询已移除，锁屏存活交给 AppData 真后台（用户拍板）
        });
    }
}

