#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <string.h>
#import <BulletinBoard/BulletinBoard.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "WXNotificationRecord.h"
#import "WXRuleEngine.h"
#import "../Shared/WXPreferences.h"
#import "../Shared/WXLogStore.h"
#import "../Shared/WXNotificationHistoryBridge.h"

static NSDictionary *WXCurrentPreferences = nil;
static dispatch_queue_t WXPreferencesQueue = nil;
// v2.9.0 保活区块：Immortalizer 核心收编（反挂起+防杀，仅微信）+ BBBulletin 横幅发布器
static BOOL WXKeepAliveEnabledFlag = NO;
static unsigned long long WXLastBulletinDestinations = 0;
// v0.14 声音三级取音：微信原声 → 任意真实公告声 → 静默
static id WXWeChatSound = nil;
static id WXLastAnySound = nil;
static void *WXBBServerQueueSpecificKey = &WXBBServerQueueSpecificKey;
static dispatch_queue_t WXBlockedActionQueue = nil;
static NSMutableDictionary<NSString *, NSNumber *> *WXBlockedActionTimestamps = nil;
static dispatch_queue_t WXBlockedIdentityQueue = nil;
static NSMutableDictionary<NSString *, NSDictionary *> *WXBlockedIdentityCache = nil;
static dispatch_queue_t WXNotificationHistoryQueue = nil;
static NSMutableDictionary<NSString *, NSDictionary *> *WXNotificationHistoryEntriesByKey = nil;
static NSMutableDictionary<NSString *, id> *WXNotificationHistoryDataProviders = nil;
static __unsafe_unretained id WXCurrentBBServer = nil;
typedef void (*WXWithdrawByRecordIDFunction)(id dataProvider, NSString *recordID);
typedef void (*WXWithdrawByPublisherBulletinIDFunction)(id dataProvider, NSString *publisherBulletinID);
typedef void (^WXBooleanCompletionBlock)(BOOL value);
typedef void (^WXBooleanErrorCompletionBlock)(BOOL value, NSError *error);
static void WXClearTransientBlockedCaches(void);
static void WXPerformSyncOrInlineOnBBServerQueue(dispatch_block_t block);
static void WXReplaceNotificationHistoryMirrorEntriesForBundleIdentifier(NSString *bundleIdentifier,
                                                                         NSArray<NSDictionary *> *entries);
static void WXPersistNotificationHistoryMirrorEntriesLocked(void);

static NSDictionary *WXCopyPreferencesSnapshot(void) {
    __block NSDictionary *snapshot = nil;
    dispatch_sync(WXPreferencesQueue, ^{
        snapshot = WXCurrentPreferences ?: [WXPreferences defaultPreferences];
    });
    return snapshot;
}

static NSArray<NSDictionary *> *WXWeChatTargetList(void) {
    NSDictionary *prefs = WXCopyPreferencesSnapshot();
    NSArray *list = prefs[WXWeChatTargetsListKey];
    if ([list isKindOfClass:[NSArray class]]) return list;
    // 旧版迁移：逗号分隔字符串 → 每个一个全量目标
    NSString *raw = prefs[WXWeChatTargetsKey];
    if (![raw isKindOfClass:[NSString class]] || raw.length == 0) return @[];
    NSMutableArray<NSDictionary *> *migrated = [NSMutableArray array];
    for (NSString *piece in [raw componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",，;； "]]) {
        NSString *t = [piece stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length > 0) [migrated addObject:@{ @"id": t, @"contains": @[], @"exclude": @[] }];
    }
    return migrated;
}

static NSString *WXWeChatContainerPath(void) {
    @try {
        NSString *appsDir = @"/var/mobile/Containers/Data/Application";
        NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appsDir error:nil];
        for (NSString *d in dirs) {
            NSString *meta = [appsDir stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%@/.com.apple.mobile_container_manager.metadata.plist", d]];
            NSDictionary *pDict = [NSDictionary dictionaryWithContentsOfFile:meta];
            NSString *infoId = pDict[@"MCMMetadataIdentifier"];
            if ([infoId isKindOfClass:[NSString class]] && [infoId isEqualToString:@"com.tencent.xin"]) {
                return [appsDir stringByAppendingPathComponent:d];
            }
        }
    } @catch (NSException *e) { }
    return nil;
}

static NSString *WXTextForScope(NSString *scope, WXNotificationRecord *record) {
    if ([scope isEqualToString:WXRuleScopeTitle]) return record.title ?: @"";
    if ([scope isEqualToString:WXRuleScopeSubtitle]) return record.subtitle ?: @"";
    if ([scope isEqualToString:WXRuleScopeMessage]) return record.messageText ?: @"";
    return record.joinedText ?: @"";
}

static NSArray *WXEnabledEntries(NSArray *entries) {
    if (![entries isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *entry in entries) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *enabledVal = entry[@"Enabled"] ?: entry[@"enabled"];
        if (enabledVal != nil && ![enabledVal boolValue]) continue; // 未启用规则不计入
        [out addObject:entry];
    }
    return out;
}

static BOOL WXEntryListMatches(NSArray *entries, NSString *scope, WXNotificationRecord *record) {
    for (NSDictionary *entry in WXEnabledEntries(entries)) {
        NSString *ruleText = [entry isKindOfClass:[NSDictionary class]] ? ([entry[@"text"] isKindOfClass:[NSString class]] ? entry[@"text"] : @"") : (NSString *)entry;
        NSString *entryScope = [entry isKindOfClass:[NSDictionary class]] ? ([entry[@"scope"] isKindOfClass:[NSString class]] ? entry[@"scope"] : @"") : @"";
        NSString *haystack = WXTextForScope(entryScope.length ? entryScope : scope, record);
        if (ruleText.length > 0 && [haystack rangeOfString:ruleText].location != NSNotFound) return YES;
    }
    return NO;
}

// 转发去重：带 ID 的通知永久去重；无 ID 的按内容 30 秒窗口去重
static NSMutableSet<NSString *> *WXForwardedIDs = nil;
static NSMutableDictionary<NSString *, NSDate *> *WXForwardedTextMap = nil;
static dispatch_queue_t WXForwardedQueue = nil;

static void WXInitForwardedStore(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        WXForwardedIDs = [NSMutableSet set];
        WXForwardedTextMap = [NSMutableDictionary dictionary];
        WXForwardedQueue = dispatch_queue_create("com.mos.wxrelay.dedupe", DISPATCH_QUEUE_SERIAL);
    });
}

static BOOL WXMarkForwardedIfNew(WXNotificationRecord *record) {
    WXInitForwardedStore();
    __block BOOL isNew = NO;
    dispatch_sync(WXForwardedQueue, ^{
        NSDate *now = [NSDate date];
        NSString *nid = record.bulletinID ?: record.recordID;
        if (nid.length > 0) {
            // 带 ID：永久去重
            if ([WXForwardedIDs containsObject:nid]) { isNew = NO; return; }
            [WXForwardedIDs addObject:nid];
        }
        // 内容 30 秒窗口：对所有通知生效（重发会换 ID，仅 ID 去重不够）
        NSString *text = record.joinedText ?: @"";
        if (text.length == 0) { isNew = YES; return; }
        NSDate *seen = WXForwardedTextMap[text];
        if (seen && now.timeIntervalSince1970 - seen.timeIntervalSince1970 < 30) { isNew = NO; return; }
        WXForwardedTextMap[text] = now;
        // 清理过期
        NSMutableArray *stale = [NSMutableArray array];
        [WXForwardedTextMap enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSDate *t, BOOL *stop) {
            if (now.timeIntervalSince1970 - t.timeIntervalSince1970 >= 30) [stale addObject:k];
        }];
        [WXForwardedTextMap removeObjectsForKeys:stale];
        isNew = YES;
    });
    return isNew;
}

static void WXAppendBlockedLog(WXNotificationRecord *record, WXMatchResult *result);

static void WXReloadPreferences(void);

// v2.4.6 目标级来源 App 白名单：bundleID 数组等值匹配（picker 勾选），空数组=不限
static BOOL WXTargetAllowsApp(NSDictionary *target, WXNotificationRecord *record) {
    NSArray *apps = [target[@"apps"] isKindOfClass:[NSArray class]] ? target[@"apps"] : @[];
    if (apps.count == 0) return YES;
    NSString *bid = (record.bundleIdentifier ?: @"").lowercaseString;
    if (bid.length == 0) return NO;
    for (NSString *a in apps) {
        if ([a isKindOfClass:[NSString class]] && [a.lowercaseString isEqualToString:bid]) return YES;
    }
    return NO;
}

// v2.8.0 模块B：微信端消息源旗标（15 分钟内=微信进程活着，通知源让位，防双发）
static BOOL WXWeChatMsgSourceAlive(void) {
    NSString *container = WXWeChatContainerPath();
    if (!container) return NO;
    NSString *path = [container stringByAppendingPathComponent:@"tmp/wxrelay_msgsource.flag"];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!attrs) return NO;
    NSDate *mtime = attrs[NSFileModificationDate];
    return mtime && [[NSDate date] timeIntervalSinceDate:mtime] < 900.0;
}

// v2.8.0 模块B：微信端消息 spool → record → 现有匹配管线
static void WXForwardMatchedRecordToWeChat(WXNotificationRecord *record);
static void WXPublishKeepAliveBulletin(NSString *title, NSString *subtitle, NSString *body, NSString *bulletinID);

static void WXPumpWeChatMsgSpool(void) {
    @try {
        NSString *container = WXWeChatContainerPath();
        if (!container) return;
        NSString *dir = [container stringByAppendingPathComponent:@"tmp/wxrelay_msgs"];
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
        if (files.count == 0) return;
        for (NSString *fn in files) {
            if (![fn hasSuffix:@".json"]) continue;
            NSString *p = [dir stringByAppendingPathComponent:fn];
            NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:p]
                options:NSJSONReadingAllowFragments error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            NSString *bid = [d[@"bid"] isKindOfClass:[NSString class]] ? d[@"bid"] : @"";
            NSString *title = [d[@"title"] isKindOfClass:[NSString class]] ? d[@"title"] : @"";
            if (bid.length == 0 || title.length == 0) continue;
            WXNotificationRecord *record = [[WXNotificationRecord alloc] init];
            record.bundleIdentifier = bid;
            record.sectionID = bid;
            record.title = title;
            record.subtitle = [d[@"subtitle"] isKindOfClass:[NSString class]] ? d[@"subtitle"] : @"";
            record.body = [d[@"body"] isKindOfClass:[NSString class]] ? d[@"body"] : @"";
            record.message = record.body;
            // v2.8.4 补齐匹配文本：手动 record 不填 joinedText = 匹配引擎拿空串
            NSString *sub = record.subtitle ?: @"";
            NSMutableArray *parts = [NSMutableArray array];
            if (record.title.length) [parts addObject:record.title];
            if (sub.length && ![sub isEqualToString:record.title]) [parts addObject:sub];
            if (record.body.length) [parts addObject:record.body];
            record.joinedText = [parts componentsJoinedByString:@"\n"];
            record.messageText = record.body;
            // v0.7 保活精准化：微信自报场景 pid → 建反挂起映射
            record.bulletinID = [d[@"msgid"] isKindOfClass:[NSString class]] ? d[@"msgid"] : nil;
            // v2.9.0 保活横幅：保活开启时微信不发本地通知，由 SB 侧代发原生公告
            if (WXKeepAliveEnabledFlag) {
                WXPublishKeepAliveBulletin(record.title, record.subtitle, record.body, record.bulletinID);
            }
            WXForwardMatchedRecordToWeChat(record);
        }
    } @catch (NSException *e) { }
}

static void WXWeChatMsgSpoolCallback(CFNotificationCenterRef __unused c, void __unused *o,
                                     CFStringRef __unused n, const void __unused *obj, CFDictionaryRef __unused ui) {
    @autoreleasepool { WXPumpWeChatMsgSpool(); }
}

static void WXForwardMatchedRecordToWeChat(WXNotificationRecord *record) {
    // v2.4.9：转发前强制读最新 prefs（锁屏 darwin 排队可能跳过更新）
    WXReloadPreferences();
    // v2.8.2 模块B：微信通知让位，但 wxmsg_ 前缀的 B 记录免检（否则自堵）
    if ([record.bundleIdentifier isEqualToString:@"com.tencent.xin"] && WXWeChatMsgSourceAlive()
        && ![record.bulletinID hasPrefix:@"wxmsg_"]) return;
    if (!WXMarkForwardedIfNew(record)) return;
    NSArray<NSDictionary *> *targets = WXWeChatTargetList();
    if (targets.count == 0) return;
    NSString *text = record.joinedText.length > 0 ? record.joinedText : record.messageText;
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array]; // [{id, text}]
    for (NSDictionary *target in targets) {
        if (![target isKindOfClass:[NSDictionary class]]) continue;
        NSString *tid = [target[@"id"] isKindOfClass:[NSString class]] ? target[@"id"] : @"";
        BOOL enabled = target[@"enabled"] == nil ? YES : [target[@"enabled"] boolValue];
        if (!(tid.length && enabled)) continue;
        // v2.4.3 目标级来源 App 白名单
        if (!WXTargetAllowsApp(target, record)) continue;
        NSArray *exclude = WXEnabledEntries(target[@"exclude"]);
        if (exclude.count > 0 && WXEntryListMatches(exclude, WXRuleScopeMessage, record)) continue; // 排除一票否决
        NSArray *contains = WXEnabledEntries(target[@"contains"]);
        if (contains.count == 0) {
            // 留空=全量转发（纯转发，无回复）
            if (text.length) [items addObject:@{ @"id": tid, @"text": text }];
            continue;
        }
        // 逐规则判定：命中的规则若有 reply → 转发原文一次 + 各发一条回复（占位符展开）
        __block BOOL anyHit = NO; __block BOOL forwarded = NO;
        for (NSDictionary *entry in contains) {
            NSString *ruleText = [entry isKindOfClass:[NSDictionary class]] ? ([entry[@"text"] isKindOfClass:[NSString class]] ? entry[@"text"] : @"") : (NSString *)entry;
            if (ruleText.length == 0) continue;
            NSString *entryScope = [entry isKindOfClass:[NSDictionary class]] ? ([entry[@"scope"] isKindOfClass:[NSString class]] ? entry[@"scope"] : @"") : @"";
            NSString *haystack = WXTextForScope(entryScope.length ? entryScope : WXRuleScopeMessage, record);
            if ([haystack rangeOfString:ruleText].location == NSNotFound) continue;
            anyHit = YES;
            // v2.7.7 语义：回复框留空=纯转发；填了=纯回复（不转发），文本原样发送
            NSString *replyOnly = [entry isKindOfClass:[NSDictionary class]] ? ([entry[@"replyOnly"] isKindOfClass:[NSString class]] ? entry[@"replyOnly"] : @"") : @"";
            BOOL isReplyOnly = [[replyOnly stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] > 0;
            if (!isReplyOnly && !forwarded && text.length) { [items addObject:@{ @"id": tid, @"text": text }]; forwarded = YES; continue; }
            if (isReplyOnly && replyOnly.length > 0) [items addObject:@{ @"id": tid, @"text": replyOnly }];
        }
        if (!anyHit) continue;
    }
    if (items.count == 0) return;
    @autoreleasepool {
        WXMatchResult *logResult = [[WXMatchResult alloc] init];
        logResult.shouldBlock = YES;
        logResult.matchedMode = @"forward";
        WXAppendBlockedLog(record, logResult);
    }
    NSString *container = WXWeChatContainerPath();
    if (!container) return;
    @try {
        NSString *taskDir = [container stringByAppendingPathComponent:@"tmp/wxrelay_tasks"];
        [[NSFileManager defaultManager] createDirectoryAtPath:taskDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *fn = [NSString stringWithFormat:@"task_%@.json", [[NSUUID UUID] UUIDString]];
        NSDictionary *task = @{ @"items": items,
            @"ts": [NSString stringWithFormat:@"%f", [NSDate date].timeIntervalSince1970] };
        NSData *data = [NSJSONSerialization dataWithJSONObject:task options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:[taskDir stringByAppendingPathComponent:fn] atomically:YES];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)@"com.mos.wxrelay.task", NULL, NULL, YES);
    } @catch (NSException *e) { }
}

static void WXUpdatePreferencesSnapshot(NSDictionary *preferences) {
    dispatch_sync(WXPreferencesQueue, ^{
        WXCurrentPreferences = [preferences copy];
    });
    id ka = preferences[WXKeepAliveEnabledKey];
    WXKeepAliveEnabledFlag = [ka respondsToSelector:@selector(boolValue)] ? [ka boolValue] : NO;
}

static void WXReloadPreferences(void) {
    WXUpdatePreferencesSnapshot([WXPreferences loadPreferences]);
    WXClearTransientBlockedCaches();
}

static void WXPreferencesChangedCallback(CFNotificationCenterRef center,
                                         void *observer,
                                         CFStringRef name,
                                         const void *object,
                                         CFDictionaryRef userInfo) {
    WXReloadPreferences();
}

static NSMutableDictionary *WXBuildBlockedLogEntry(WXNotificationRecord *record, WXMatchResult *result) {
    if (!result.shouldBlock) {
        return nil;
    }

    NSMutableDictionary *logEntry = [[record dictionaryRepresentation] mutableCopy];
    if (result.matchedScope.length > 0) {
        logEntry[WXLogMatchedScopeKey] = result.matchedScope;
    }
    if (result.matchedMode.length > 0) {
        logEntry[WXLogMatchedModeKey] = result.matchedMode;
    }
    if (result.matchedPattern.length > 0) {
        logEntry[WXLogMatchedPatternKey] = result.matchedPattern;
    }

    return logEntry;
}

static void WXAppendBlockedLog(WXNotificationRecord *record, WXMatchResult *result) {
    if (!result.shouldBlock) {
        return;
    }

    NSMutableDictionary *logEntry = WXBuildBlockedLogEntry(record, result);
    [WXLogStore appendBlockedEntry:logEntry];
}

static id WXCallObject(id obj, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!obj || !selector || ![obj respondsToSelector:selector]) {
        return nil;
    }

    return ((id (*)(id, SEL))objc_msgSend)(obj, selector);
}

static NSString *WXNormalizedStringValue(id value) {
    if (!value) {
        return nil;
    }

    NSString *stringValue = nil;
    if ([value isKindOfClass:[NSString class]]) {
        stringValue = value;
    } else if ([value respondsToSelector:@selector(stringValue)]) {
        id response = ((id (*)(id, SEL))objc_msgSend)(value, @selector(stringValue));
        if ([response isKindOfClass:[NSString class]]) {
            stringValue = response;
        }
    }

    return [stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static void WXClearTransientBlockedCaches(void) {
    if (WXBlockedActionQueue) {
        dispatch_sync(WXBlockedActionQueue, ^{
            [WXBlockedActionTimestamps removeAllObjects];
        });
    }

    if (WXBlockedIdentityQueue) {
        dispatch_sync(WXBlockedIdentityQueue, ^{
            [WXBlockedIdentityCache removeAllObjects];
        });
    }
}

static NSString *WXNotificationHistoryRecordKeyFromRecord(WXNotificationRecord *record) {
    if (!record) {
        return nil;
    }

    NSString *bundleIdentifier = WXNormalizedStringValue(record.bundleIdentifier);
    NSString *bulletinID = WXNormalizedStringValue(record.bulletinID);
    NSString *recordID = WXNormalizedStringValue(record.recordID);
    NSString *publisherBulletinID = WXNormalizedStringValue(record.publisherBulletinID);
    NSString *title = WXNormalizedStringValue(record.title);
    NSString *message = WXNormalizedStringValue(record.messageText.length > 0 ? record.messageText : record.joinedText);

    if (bulletinID.length > 0) {
        return [NSString stringWithFormat:@"%@|bulletin|%@", bundleIdentifier ?: @"", bulletinID];
    }
    if (recordID.length > 0) {
        return [NSString stringWithFormat:@"%@|record|%@", bundleIdentifier ?: @"", recordID];
    }
    if (publisherBulletinID.length > 0) {
        return [NSString stringWithFormat:@"%@|publisher|%@", bundleIdentifier ?: @"", publisherBulletinID];
    }
    if (bundleIdentifier.length == 0 || (title.length == 0 && message.length == 0)) {
        return nil;
    }
    return [NSString stringWithFormat:@"%@|content|%@|%@", bundleIdentifier, title ?: @"", message ?: @""];
}

// 与 WXReplaceNotificationHistoryMirrorEntriesForBundleIdentifier 一致的字段提取，
// 供不需要重建 WXNotificationRecord 的批量合并路径使用。
static NSString *WXNotificationHistoryRecordKeyFromDictionaryEntry(NSDictionary *entry) {
    if (![entry isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSString *bundleIdentifier = WXNormalizedStringValue(entry[WXLogBundleIdentifierKey]);
    NSString *bulletinID = WXNormalizedStringValue(entry[WXLogBulletinIDKey]);
    NSString *recordID = WXNormalizedStringValue(entry[WXLogRecordIDKey]);
    NSString *publisherBulletinID = WXNormalizedStringValue(entry[WXLogPublisherBulletinIDKey]);
    NSString *title = WXNormalizedStringValue(entry[WXLogTitleKey]);
    NSString *message = WXNormalizedStringValue(entry[WXLogMessageKey]) ?: WXNormalizedStringValue(entry[WXLogBodyKey]);
    NSString *joinedText = WXNormalizedStringValue(entry[WXLogJoinedTextKey]);
    if (message.length == 0) {
        message = joinedText;
    }

    if (bulletinID.length > 0) {
        return [NSString stringWithFormat:@"%@|bulletin|%@", bundleIdentifier ?: @"", bulletinID];
    }
    if (recordID.length > 0) {
        return [NSString stringWithFormat:@"%@|record|%@", bundleIdentifier ?: @"", recordID];
    }
    if (publisherBulletinID.length > 0) {
        return [NSString stringWithFormat:@"%@|publisher|%@", bundleIdentifier ?: @"", publisherBulletinID];
    }
    if (bundleIdentifier.length == 0 || (title.length == 0 && message.length == 0)) {
        return nil;
    }
    return [NSString stringWithFormat:@"%@|content|%@|%@", bundleIdentifier, title ?: @"", message ?: @""];
}

static NSDictionary *WXNotificationHistoryDictionaryFromRecord(WXNotificationRecord *record) {
    if (!record) {
        return nil;
    }

    NSMutableDictionary *entry = [[record dictionaryRepresentation] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (record.timestamp) {
        entry[WXLogTimestampKey] = @([record.timestamp timeIntervalSince1970]);
    }
    return [entry copy];
}

static NSArray<NSDictionary *> *WXSortedNotificationHistoryEntriesFromDictionaryEntries(NSArray<NSDictionary *> *entries) {
    return [entries sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
        NSTimeInterval lhsTimestamp = [lhs[WXLogTimestampKey] respondsToSelector:@selector(doubleValue)] ? [lhs[WXLogTimestampKey] doubleValue] : 0;
        NSTimeInterval rhsTimestamp = [rhs[WXLogTimestampKey] respondsToSelector:@selector(doubleValue)] ? [rhs[WXLogTimestampKey] doubleValue] : 0;
        if (lhsTimestamp > rhsTimestamp) {
            return NSOrderedAscending;
        }
        if (lhsTimestamp < rhsTimestamp) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
}

static void WXPersistNotificationHistoryMirrorEntriesLocked(void) {
    NSArray<NSDictionary *> *entries = WXSortedNotificationHistoryEntriesFromDictionaryEntries([WXNotificationHistoryEntriesByKey allValues]);
    NSString *snapshotPath = WXNotificationHistorySnapshotFilePath();
    NSString *directoryPath = [snapshotPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:directoryPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [entries writeToFile:snapshotPath atomically:YES];
}

static void WXRememberNotificationHistoryDataProvider(id dataProvider) {
    NSString *sectionIdentifier = WXNormalizedStringValue(WXCallObject(dataProvider, @"sectionIdentifier"));
    if (sectionIdentifier.length == 0) {
        sectionIdentifier = WXNormalizedStringValue(WXCallObject(dataProvider, @"sectionID"));
    }
    if (sectionIdentifier.length == 0) {
        return;
    }

    dispatch_sync(WXNotificationHistoryQueue, ^{
        WXNotificationHistoryDataProviders[sectionIdentifier] = dataProvider;
    });
}

static void WXPrimeNotificationHistoryForDataProvider(id dataProvider) {
    NSString *bundleIdentifier = WXNormalizedStringValue(WXCallObject(dataProvider, @"sectionIdentifier"));
    if (bundleIdentifier.length == 0) {
        bundleIdentifier = WXNormalizedStringValue(WXCallObject(dataProvider, @"sectionID"));
    }
    if (bundleIdentifier.length == 0) {
        return;
    }

    @try {
        NSSet *bulletins = nil;
        if ([dataProvider respondsToSelector:@selector(bulletinsFilteredBy:count:lastCleared:)]) {
            bulletins = ((id (*)(id, SEL, NSUInteger, NSUInteger, id))objc_msgSend)(dataProvider,
                                                                                     @selector(bulletinsFilteredBy:count:lastCleared:),
                                                                                     0,
                                                                                     200,
                                                                                     nil);
        }
        if (![bulletins isKindOfClass:[NSSet class]]) {
            return;
        }

        NSMutableArray<NSDictionary *> *entries = [NSMutableArray arrayWithCapacity:bulletins.count];
        for (id bulletin in bulletins) {
            WXNotificationRecord *record = [WXNotificationRecord recordFromBulletin:bulletin];
            if (record.bundleIdentifier.length == 0) {
                record.bundleIdentifier = bundleIdentifier;
            }
            NSDictionary *entry = WXNotificationHistoryDictionaryFromRecord(record);
            if (entry) {
                [entries addObject:entry];
            }
        }

        WXReplaceNotificationHistoryMirrorEntriesForBundleIdentifier(bundleIdentifier,
                                                                     WXSortedNotificationHistoryEntriesFromDictionaryEntries(entries));
    } @catch (NSException *exception) {
        // Silently fail if notification history priming fails - this is non-critical functionality
    }
}

static void WXRememberNotificationHistoryDataProviderForSectionFromServer(id server, NSString *sectionIdentifier) {
    if (!server || sectionIdentifier.length == 0) {
        return;
    }

    @try {
        SEL selector = NSSelectorFromString(@"dataProviderForSectionID:");
        if (![server respondsToSelector:selector]) {
            return;
        }

        id dataProvider = ((id (*)(id, SEL, id))objc_msgSend)(server, selector, sectionIdentifier);
        if (dataProvider) {
            WXRememberNotificationHistoryDataProvider(dataProvider);
            WXPrimeNotificationHistoryForDataProvider(dataProvider);
        }
    } @catch (NSException *exception) {
        // Silently fail if notification history tracking fails - this is non-critical functionality
    }
}

static NSArray<NSDictionary *> *WXNotificationHistoryMirrorEntriesForBundleIdentifier(NSString *bundleIdentifier, NSUInteger limit) {
    __block NSArray<NSDictionary *> *entries = nil;
    dispatch_sync(WXNotificationHistoryQueue, ^{
        NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
        [WXNotificationHistoryEntriesByKey enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *entry, BOOL *stop) {
            NSString *entryBundleIdentifier = [entry[WXLogBundleIdentifierKey] isKindOfClass:[NSString class]] ? entry[WXLogBundleIdentifierKey] : @"";
            if (![entryBundleIdentifier isEqualToString:bundleIdentifier]) {
                return;
            }
            [matches addObject:entry];
        }];
        NSArray<NSDictionary *> *sortedEntries = WXSortedNotificationHistoryEntriesFromDictionaryEntries(matches);
        if (limit > 0 && sortedEntries.count > limit) {
            sortedEntries = [sortedEntries subarrayWithRange:NSMakeRange(0, limit)];
        }
        entries = sortedEntries;
    });
    return entries ?: @[];
}

static void WXReplaceNotificationHistoryMirrorEntriesForBundleIdentifier(NSString *bundleIdentifier,
                                                                         NSArray<NSDictionary *> *entries) {
    if (bundleIdentifier.length == 0) {
        return;
    }

    dispatch_sync(WXNotificationHistoryQueue, ^{
        NSMutableArray<NSString *> *keysToRemove = [NSMutableArray array];
        [WXNotificationHistoryEntriesByKey enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *entry, BOOL *stop) {
            NSString *entryBundleIdentifier = [entry[WXLogBundleIdentifierKey] isKindOfClass:[NSString class]] ? entry[WXLogBundleIdentifierKey] : @"";
            if ([entryBundleIdentifier isEqualToString:bundleIdentifier]) {
                [keysToRemove addObject:key];
            }
        }];
        if (keysToRemove.count > 0) {
            [WXNotificationHistoryEntriesByKey removeObjectsForKeys:keysToRemove];
        }

        for (NSDictionary *entry in entries) {
            if (![entry isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            WXNotificationRecord *record = [[WXNotificationRecord alloc] init];
            record.bundleIdentifier = [entry[WXLogBundleIdentifierKey] isKindOfClass:[NSString class]] ? entry[WXLogBundleIdentifierKey] : bundleIdentifier;
            record.sectionID = [entry[WXLogSectionIDKey] isKindOfClass:[NSString class]] ? entry[WXLogSectionIDKey] : nil;
            record.bulletinID = [entry[WXLogBulletinIDKey] isKindOfClass:[NSString class]] ? entry[WXLogBulletinIDKey] : nil;
            record.recordID = [entry[WXLogRecordIDKey] isKindOfClass:[NSString class]] ? entry[WXLogRecordIDKey] : nil;
            record.publisherBulletinID = [entry[WXLogPublisherBulletinIDKey] isKindOfClass:[NSString class]] ? entry[WXLogPublisherBulletinIDKey] : nil;
            record.title = [entry[WXLogTitleKey] isKindOfClass:[NSString class]] ? entry[WXLogTitleKey] : nil;
            record.subtitle = [entry[WXLogSubtitleKey] isKindOfClass:[NSString class]] ? entry[WXLogSubtitleKey] : nil;
            record.header = [entry[WXLogHeaderKey] isKindOfClass:[NSString class]] ? entry[WXLogHeaderKey] : nil;
            record.body = [entry[WXLogBodyKey] isKindOfClass:[NSString class]] ? entry[WXLogBodyKey] : nil;
            record.message = [entry[WXLogMessageKey] isKindOfClass:[NSString class]] ? entry[WXLogMessageKey] : nil;
            record.messageText = WXNormalizedStringValue(entry[WXLogMessageKey]) ?: WXNormalizedStringValue(entry[WXLogBodyKey]) ?: @"";
            record.joinedText = [entry[WXLogJoinedTextKey] isKindOfClass:[NSString class]] ? entry[WXLogJoinedTextKey] : @"";
            NSTimeInterval timestamp = [entry[WXLogTimestampKey] respondsToSelector:@selector(doubleValue)] ? [entry[WXLogTimestampKey] doubleValue] : [[NSDate date] timeIntervalSince1970];
            record.timestamp = [NSDate dateWithTimeIntervalSince1970:timestamp];

            NSString *recordKey = WXNotificationHistoryRecordKeyFromRecord(record);
            if (recordKey.length > 0) {
                WXNotificationHistoryEntriesByKey[recordKey] = entry;
            }
        }
        WXPersistNotificationHistoryMirrorEntriesLocked();
    });
}

static NSArray<NSDictionary *> *WXNotificationHistoryLiveEntriesForBundleIdentifier(NSString *bundleIdentifier, NSUInteger limit) {
    __block NSArray<NSDictionary *> *resultEntries = nil;

    @try {
        WXPerformSyncOrInlineOnBBServerQueue(^{
            __block id dataProvider = nil;
            dispatch_sync(WXNotificationHistoryQueue, ^{
                dataProvider = WXNotificationHistoryDataProviders[bundleIdentifier];
            });
            if (!dataProvider && WXCurrentBBServer) {
                WXRememberNotificationHistoryDataProviderForSectionFromServer(WXCurrentBBServer, bundleIdentifier);
                dispatch_sync(WXNotificationHistoryQueue, ^{
                    dataProvider = WXNotificationHistoryDataProviders[bundleIdentifier];
                });
            }
            if (!dataProvider) {
                return;
            }

            NSSet *bulletins = nil;
            if ([dataProvider respondsToSelector:@selector(bulletinsFilteredBy:count:lastCleared:)]) {
                NSUInteger count = limit > 0 ? limit : 200;
                bulletins = ((id (*)(id, SEL, NSUInteger, NSUInteger, id))objc_msgSend)(dataProvider,
                                                                                         @selector(bulletinsFilteredBy:count:lastCleared:),
                                                                                         0,
                                                                                         count,
                                                                                         nil);
            }
            if (![bulletins isKindOfClass:[NSSet class]]) {
                return;
            }

            NSMutableArray<NSDictionary *> *entries = [NSMutableArray arrayWithCapacity:bulletins.count];
            for (id bulletin in bulletins) {
                WXNotificationRecord *record = [WXNotificationRecord recordFromBulletin:bulletin];
                if (record.bundleIdentifier.length == 0) {
                    record.bundleIdentifier = bundleIdentifier;
                }
                NSDictionary *entry = WXNotificationHistoryDictionaryFromRecord(record);
                if (entry) {
                    [entries addObject:entry];
                }
            }

            NSArray<NSDictionary *> *sortedEntries = WXSortedNotificationHistoryEntriesFromDictionaryEntries(entries);
            WXReplaceNotificationHistoryMirrorEntriesForBundleIdentifier(bundleIdentifier, sortedEntries);
            if (limit > 0 && sortedEntries.count > limit) {
                sortedEntries = [sortedEntries subarrayWithRange:NSMakeRange(0, limit)];
            }
            resultEntries = sortedEntries;
        });
    } @catch (NSException *exception) {
        // Silently fail if notification history retrieval fails - this is non-critical functionality
        resultEntries = nil;
    }

    return resultEntries;
}

static void WXPostNotificationHistoryRefreshStatus(NSString *requestIdentifier,
                                                   NSString *bundleIdentifier,
                                                   NSString *source,
                                                   NSString *errorMessage) {
    if (requestIdentifier.length == 0 || bundleIdentifier.length == 0) {
        return;
    }

    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    status[WXNotificationHistoryRequestIdentifierKey] = requestIdentifier;
    status[WXNotificationHistoryBundleIdentifierKey] = bundleIdentifier;
    status[WXNotificationHistorySourceKey] = source.length > 0 ? source : WXNotificationHistorySourceMirror;
    status[WXNotificationHistoryUpdatedAtKey] = @([[NSDate date] timeIntervalSince1970]);
    if (errorMessage.length > 0) {
        status[WXNotificationHistoryErrorKey] = errorMessage;
    }

    NSString *statusPath = WXNotificationHistoryRefreshStatusFilePath();
    NSString *directoryPath = [statusPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:directoryPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [status writeToFile:statusPath atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (CFStringRef)WXNotificationHistoryRefreshCompletedNotification,
                                         NULL,
                                         NULL,
                                         YES);
}

// 全局扫描：遍历已注册的全部 dataProvider，逐个 section 取实时条目，
// 合并后整体写回快照镜像。任一 section 失败时跳过该 section，其余继续。
static void WXProcessNotificationHistoryRefreshRequestForAllApps(NSString *requestIdentifier, NSUInteger limit) {
    __block NSArray<NSString *> *bundleIdentifiers = nil;
    dispatch_sync(WXNotificationHistoryQueue, ^{
        bundleIdentifiers = [WXNotificationHistoryDataProviders allKeys];
    });

    NSMutableArray<NSDictionary *> *allEntries = [NSMutableArray array];
    __block BOOL anyLive = NO;

    for (NSString *sectionIdentifier in bundleIdentifiers) {
        @try {
            NSArray<NSDictionary *> *sectionEntries = WXNotificationHistoryLiveEntriesForBundleIdentifier(sectionIdentifier, limit);
            if (sectionEntries.count > 0) {
                [allEntries addObjectsFromArray:sectionEntries];
                anyLive = YES;
            }
        } @catch (NSException *exception) {
            // 单个 section 失败不影响其余应用的历史刷新。
        }
    }

    NSString *source = anyLive ? WXNotificationHistorySourceLive : WXNotificationHistorySourceMirror;
    if (allEntries.count > 0) {
        dispatch_sync(WXNotificationHistoryQueue, ^{
            NSMutableArray<NSString *> *keysToRemove = [NSMutableArray array];
            [WXNotificationHistoryEntriesByKey enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *entry, BOOL *stop) {
                NSString *entryBundleIdentifier = [entry[WXLogBundleIdentifierKey] isKindOfClass:[NSString class]] ? entry[WXLogBundleIdentifierKey] : @"";
                if ([bundleIdentifiers containsObject:entryBundleIdentifier]) {
                    [keysToRemove addObject:key];
                }
            }];
            if (keysToRemove.count > 0) {
                [WXNotificationHistoryEntriesByKey removeObjectsForKeys:keysToRemove];
            }

            for (NSDictionary *entry in allEntries) {
                if (![entry isKindOfClass:[NSDictionary class]]) {
                    continue;
                }
                NSString *recordKey = WXNotificationHistoryRecordKeyFromDictionaryEntry(entry);
                if (recordKey.length > 0) {
                    WXNotificationHistoryEntriesByKey[recordKey] = entry;
                }
            }
            WXPersistNotificationHistoryMirrorEntriesLocked();
        });
    }

    WXPostNotificationHistoryRefreshStatus(requestIdentifier, WXNotificationHistoryAllAppsIdentifier, source, nil);
}

static void WXProcessNotificationHistoryRefreshRequest(void) {
    NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:WXNotificationHistoryRefreshRequestFilePath()];
    if (![request isKindOfClass:[NSDictionary class]]) {
        return;
    }

    NSString *requestIdentifier = WXNormalizedStringValue(request[WXNotificationHistoryRequestIdentifierKey]);
    NSString *bundleIdentifier = WXNormalizedStringValue(request[WXNotificationHistoryBundleIdentifierKey]);
    NSUInteger limit = [request[WXNotificationHistoryLimitKey] respondsToSelector:@selector(unsignedIntegerValue)] ?
        [request[WXNotificationHistoryLimitKey] unsignedIntegerValue] :
        200;
    if (requestIdentifier.length == 0 || bundleIdentifier.length == 0) {
        return;
    }

    if ([bundleIdentifier isEqualToString:WXNotificationHistoryAllAppsIdentifier]) {
        WXProcessNotificationHistoryRefreshRequestForAllApps(requestIdentifier, limit);
        return;
    }

    NSArray<NSDictionary *> *liveEntries = WXNotificationHistoryLiveEntriesForBundleIdentifier(bundleIdentifier, limit);
    NSString *source = liveEntries ? WXNotificationHistorySourceLive : WXNotificationHistorySourceMirror;
    if (!liveEntries) {
        (void)WXNotificationHistoryMirrorEntriesForBundleIdentifier(bundleIdentifier, limit);
    }

    WXPostNotificationHistoryRefreshStatus(requestIdentifier, bundleIdentifier, source, nil);
}

static void WXNotificationHistoryRefreshRequestCallback(CFNotificationCenterRef center,
                                                        void *observer,
                                                        CFStringRef name,
                                                        const void *object,
                                                        CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            WXProcessNotificationHistoryRefreshRequest();
        }
    });
}

static dispatch_queue_t WXBBServerQueue(void) {
    static dispatch_queue_t cachedQueue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        __unsafe_unretained dispatch_queue_t *queuePointer = (__unsafe_unretained dispatch_queue_t *)dlsym(RTLD_DEFAULT, "__BBServerQueue");
        if (queuePointer) {
            cachedQueue = *queuePointer;
            dispatch_queue_set_specific(cachedQueue,
                                        WXBBServerQueueSpecificKey,
                                        WXBBServerQueueSpecificKey,
                                        NULL);
        }
    });
    return cachedQueue;
}

static void WXPerformSyncOrInlineOnBBServerQueue(dispatch_block_t block) {
    dispatch_queue_t queue = WXBBServerQueue();
    if (!queue) {
        block();
        return;
    }

    if (dispatch_get_specific(WXBBServerQueueSpecificKey) == WXBBServerQueueSpecificKey) {
        block();
        return;
    }

    dispatch_sync(queue, block);
}

%group WXDispatcherHooks

%hook NCNotificationDispatcher

- (void)postNotificationWithRequest:(id)request {
    // WXRelay：不做任何拦截，统一放行（捕获与转发在 BBServer 层）
    %orig;
}

%end

%end

%group WXBulletinHooks

%hook BBServer

- (void)_addDataProvider:(id)dataProvider sortSectionsNow:(BOOL)sortSections {
    // v0.13：BBServer 开机注册数据源时必然经过这里——确定性捕获实例（不等真实通知流量）
    if (!WXCurrentBBServer) WXCurrentBBServer = self;
    @try {
        if (dataProvider) {
            WXRememberNotificationHistoryDataProvider(dataProvider);
            WXPrimeNotificationHistoryForDataProvider(dataProvider);
        }
    } @catch (NSException *exception) {
        // Silently fail if notification history tracking fails - this is non-critical functionality
    }
    %orig;
}

- (void)publishBulletinRequest:(id)request destinations:(unsigned long long)destinations {
    // v2.9.0 保活横幅：捕获 BBServer 实例与真实目的地掩码
    if (!WXCurrentBBServer) WXCurrentBBServer = self;
    if (destinations != 0) WXLastBulletinDestinations = destinations;
    @try {
        id snd = [request valueForKey:@"sound"];
        if (snd) { WXLastAnySound = snd; }
        NSString *sec = [request valueForKey:@"sectionIdentifier"];
        if ([sec isEqualToString:@"com.tencent.xin"] && snd) WXWeChatSound = snd;
    } @catch (NSException *e) { }
    WXNotificationRecord *record = [WXNotificationRecord recordFromNotificationRequest:request];
    WXForwardMatchedRecordToWeChat(record);
    %orig;
}

- (void)_publishBulletinRequest:(id)request forSectionID:(id)sectionIdentifier forDestinations:(unsigned long long)destinations {
    if (!WXCurrentBBServer) WXCurrentBBServer = self;
    if (destinations != 0) WXLastBulletinDestinations = destinations;
    @try {
        id snd = [request valueForKey:@"sound"];
        if (snd) { WXLastAnySound = snd; }
        if ([sectionIdentifier isEqualToString:@"com.tencent.xin"] && snd) WXWeChatSound = snd;
    } @catch (NSException *e) { }
        %orig;
}

- (void)updateSection:(id)sectionIdentifier inFeed:(unsigned long long)feed withBulletinRequests:(id)bulletinRequests {
    %orig;
}

- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations {
    if (!WXCurrentBBServer) WXCurrentBBServer = self;
    if (destinations != 0) WXLastBulletinDestinations = destinations;
    @try {
        id snd = [bulletin valueForKey:@"sound"];
        if (snd) { WXLastAnySound = snd; }
        NSString *sec = [bulletin valueForKey:@"sectionIdentifier"];
        if ([sec isEqualToString:@"com.tencent.xin"] && snd) WXWeChatSound = snd;
    } @catch (NSException *e) { }
    WXNotificationRecord *record = [WXNotificationRecord recordFromBulletin:bulletin];
    WXForwardMatchedRecordToWeChat(record);
    %orig;
}

- (void)_modifyBulletin:(id)bulletin {
        %orig;
}

- (void)_addBulletin:(id)bulletin {
        %orig;
}

- (void)_sendAddBulletin:(id)bulletin toFeeds:(unsigned long long)feeds {
        %orig;
}

- (void)_sendModifyBulletin:(id)bulletin toFeeds:(unsigned long long)feeds {
        %orig;
}

- (void)_sendBulletinUpdate:(id)update {
        %orig;
}

- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations alwaysToLockScreen:(BOOL)alwaysToLockScreen {
    WXNotificationRecord *record = [WXNotificationRecord recordFromBulletin:bulletin];
    WXForwardMatchedRecordToWeChat(record);
    %orig;
}

%end

%end

// ===== v2.9.0 保活横幅发布器（BBBulletin 路线，探针 0.8/0.9 已真机验证）=====
static void WXPublishKeepAliveBulletin(NSString *title, NSString *subtitle, NSString *body, NSString *bulletinID) {
    @try {
        if (!WXCurrentBBServer) return;
        // v0.12：掩码兜底 0x1ce（探针实测：banner+锁屏+通知中心全目的地），无真实流量也能发
        unsigned long long mask = WXLastBulletinDestinations ?: 0x1ceULL;
        Class bulletinCls = objc_getClass("BBBulletin");
        Class actionCls = objc_getClass("BBAction");
        if (!bulletinCls || !actionCls) return;
        id b = [[bulletinCls alloc] init];
        NSDate *now = [NSDate date];
        void (^setKVC)(id, NSString *, id) = ^(id obj, NSString *key, id val) {
            @try { [(NSObject *)obj setValue:val forKey:key]; } @catch (NSException *e) { }
        };
        setKVC(b, @"sectionID", @"com.tencent.xin");
        setKVC(b, @"title", title.length ? title : @"微信");
        if (subtitle.length) setKVC(b, @"subtitle", subtitle);
        setKVC(b, @"message", body ?: @"");
        setKVC(b, @"showsMessagePreview", @YES);
        setKVC(b, @"publicationDate", now);
        setKVC(b, @"date", now);
        setKVC(b, @"lastInterruptDate", now);
        setKVC(b, @"recordID", [[NSUUID UUID] UUIDString]);
        setKVC(b, @"publisherBulletinID", [[NSUUID UUID] UUIDString]);
        // 用消息 msgid 做横幅 ID：同一消息重复投递自动合并（修一条消息两条横幅）
        setKVC(b, @"bulletinID", bulletinID.length ? bulletinID : [@"wxmsg_" stringByAppendingString:[[NSUUID UUID] UUIDString]]);
        // v0.14 声音三级取音：微信原声 → 任意真实公告声 → nil
        id snd = WXWeChatSound ?: WXLastAnySound;
        if (snd) setKVC(b, @"sound", snd);
        id action = [actionCls performSelector:@selector(actionWithLaunchBundleID:callblock:)
                                    withObject:@"com.tencent.xin" withObject:nil];
        if (action) setKVC(b, @"defaultAction", action);
        id server = WXCurrentBBServer;
        dispatch_async(WXBBServerQueue(), ^{
            SEL sel = @selector(publishBulletinRequest:destinations:);
            IMP imp = [server methodForSelector:sel];
            void (*fn)(id, SEL, id, unsigned long long) = (void (*)(id, SEL, id, unsigned long long))imp;
            fn(server, sel, b, mask);
        });
    } @catch (NSException *e) { }
}

%group WXKeepAliveHooks

// v0.10 保活双腿还原（Immortalizer 原版组合，单腿两次实证不足）：
// 腿1 全局反挂起（拦截失活原因写入——全局，与原版一致）
%hook UIMutableApplicationSceneSettings
- (void)setDeactivationReasons:(unsigned long long)arg1 {
    if (WXKeepAliveEnabledFlag && arg1 != 0) return;
    %orig;
}
%end

// 腿2 FBScene 精准阻断（仅微信：吞后台化设置更新）
%hook FBScene
- (void)updateSettings:(id)arg1 withTransitionContext:(id)arg2 completion:(id)arg3 {
    if (WXKeepAliveEnabledFlag && arg2 == nil) {
        NSString *bid = nil;
        @try {
            id process = [(id)self performSelector:@selector(clientProcess)];
            bid = [process valueForKey:@"bundleIdentifier"];
        } @catch (NSException *e) { }
        if ([bid isEqualToString:@"com.tencent.xin"]) return;
    }
    %orig;
}
%end

%hook SBFluidSwitcherItemContainer
- (void)setKillable:(BOOL)arg1 {
    BOOL shouldTerminate = arg1;
    if (WXKeepAliveEnabledFlag) {
        @try {
            id appLayout = [(id)self performSelector:@selector(appLayout)];
            NSDictionary *bundles = nil;
            SEL itemsSel = NSSelectorFromString(@"itemsToLayoutAttributesMap");
            if ([appLayout respondsToSelector:itemsSel]) {
                IMP itemsImp = [appLayout methodForSelector:itemsSel];
                bundles = ((id (*)(id, SEL))itemsImp)(appLayout, itemsSel);
            } else {
                Ivar ivar = class_getInstanceVariable(object_getClass(appLayout), "_rolesToLayoutItemsMap");
                if (ivar) bundles = object_getIvar(appLayout, ivar);
            }
            for (id displayItem in bundles) {
                NSString *bid = nil;
                @try { bid = [displayItem valueForKey:@"bundleIdentifier"]; } @catch (NSException *e) { }
                if ([bid isEqualToString:@"com.tencent.xin"]) { shouldTerminate = NO; break; }
            }
        } @catch (NSException *e) { }
    }
    %orig(shouldTerminate);
}
%end

%end

%group WXObserverHooks

%hook BBObserver

- (void)updateBulletin:(id)updateTransaction withReply:(id)reply {
    %orig;
}

- (void)_queue_updateAddBulletin:(id)update withReply:(id)reply {
    %orig;
}

- (void)_queue_updateModifyBulletin:(id)update withReply:(id)reply {
    %orig;
}

%end

%end

%group WXObserverServerProxyHooks

%hook BBObserverServerProxy

- (void)updateBulletin:(id)updateTransaction withHandler:(id)handler {
    %orig;
}

%end

%end

%group WXObserverClientProxyHooks

%hook BBObserverClientProxy

- (void)updateBulletin:(id)updateTransaction withHandler:(id)handler {
    %orig;
}

%end

%end

%group WXDataProviderProxyHooks

%hook BBDataProviderProxy

- (void)addBulletin:(id)bulletin forDestinations:(unsigned long long)destinations {
        %orig;
}

- (void)modifyBulletin:(id)bulletin {
        %orig;
}

%end

%end

%group WXRemoteDataProviderHooks

%hook BBRemoteDataProvider

- (void)addBulletin:(id)bulletin forDestinations:(unsigned long long)destinations {
        %orig;
}

- (void)modifyBulletin:(id)bulletin {
        %orig;
}

%end

%end



%ctor {
    @autoreleasepool {
        WXPreferencesQueue = dispatch_queue_create("com.777qwq.wxrelay.preferences", DISPATCH_QUEUE_SERIAL);
        WXBlockedActionQueue = dispatch_queue_create("com.777qwq.wxrelay.blocked-actions", DISPATCH_QUEUE_SERIAL);
        WXBlockedActionTimestamps = [NSMutableDictionary dictionary];
        WXBlockedIdentityQueue = dispatch_queue_create("com.777qwq.wxrelay.blocked-identities", DISPATCH_QUEUE_SERIAL);
        WXBlockedIdentityCache = [NSMutableDictionary dictionary];
        WXNotificationHistoryQueue = dispatch_queue_create("com.777qwq.wxrelay.history", DISPATCH_QUEUE_SERIAL);
        WXNotificationHistoryEntriesByKey = [NSMutableDictionary dictionary];
        WXNotificationHistoryDataProviders = [NSMutableDictionary dictionary];
        WXReloadPreferences();

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        WXPreferencesChangedCallback,
                                        (CFStringRef)WXPreferencesChangedDarwinNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        WXNotificationHistoryRefreshRequestCallback,
                                        (CFStringRef)WXNotificationHistoryRefreshRequestNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        // v2.8.0 模块B：微信消息 spool 到货
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        WXWeChatMsgSpoolCallback,
                                        (CFStringRef)@"com.777qwq.wxrelay.msg",
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        if (objc_getClass("NCNotificationDispatcher")) {
            %init(WXDispatcherHooks);
        }

        if (objc_getClass("BBServer")) {
            %init(WXBulletinHooks);
        }
        if (objc_getClass("UIMutableApplicationSceneSettings") && objc_getClass("SBFluidSwitcherItemContainer")) {
            %init(WXKeepAliveHooks);
        }
        if (objc_getClass("BBObserver")) {
            %init(WXObserverHooks);
        }
        if (objc_getClass("BBObserverServerProxy")) {
            %init(WXObserverServerProxyHooks);
        }
        if (objc_getClass("BBObserverClientProxy")) {
            %init(WXObserverClientProxyHooks);
        }
        if (objc_getClass("BBDataProviderProxy")) {
            %init(WXDataProviderProxyHooks);
        }
        if (objc_getClass("BBRemoteDataProvider")) {
            %init(WXRemoteDataProviderHooks);
        }
    }
}
