#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef O_EVTONLY
#define O_EVTONLY O_RDONLY
#endif

static const NSUInteger kMPMMaxEventLog = 160;
static const NSUInteger kMPMMaxFilesTracked = 4500;
static const NSUInteger kMPMMaxDepthPerRoot = 5;
static const NSUInteger kMPMMaxEventsPerRefresh = 18;
static const NSTimeInterval kMPMEventCoalescingDelay = 0.18;
static const unsigned long kMPMVnodeMask = DISPATCH_VNODE_WRITE |
                                           DISPATCH_VNODE_DELETE |
                                           DISPATCH_VNODE_RENAME |
                                           DISPATCH_VNODE_ATTRIB |
                                           DISPATCH_VNODE_EXTEND |
                                           DISPATCH_VNODE_REVOKE;

@interface SpringBoard : UIApplication
@end

@interface MPMPassThroughWindow : UIWindow
@property (nonatomic, copy) NSArray<UIView *> *touchableViews;
@end

@interface MPMFileState : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) unsigned long long size;
@property (nonatomic, assign) long long modTime;
@property (nonatomic, assign) NSUInteger mode;
@property (nonatomic, assign) unsigned long long device;
@property (nonatomic, assign) unsigned long long inode;
@property (nonatomic, assign, getter=isDirectory) BOOL directory;
@property (nonatomic, assign, getter=isPlist) BOOL plist;
@end

@interface MPMWatchNode : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) dispatch_source_t source;
@property (nonatomic, assign) int fileDescriptor;
@property (nonatomic, assign, getter=isDirectory) BOOL directory;
@end

@interface MPMOverlayController : NSObject
+ (instancetype)sharedInstance;
- (void)installOverlayIfNeeded;
@end

@interface MPMOverlayController ()
@property (nonatomic, strong) MPMPassThroughWindow *window;
@property (nonatomic, strong) UIView *hudView;
@property (nonatomic, strong) UIView *hudHeaderView;
@property (nonatomic, strong) UILabel *hudTitleLabel;
@property (nonatomic, strong) UILabel *hudStatusLabel;
@property (nonatomic, strong) UITextView *hudBodyTextView;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIButton *launcherButton;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) dispatch_queue_t monitorQueue;
@property (nonatomic, strong) NSMutableDictionary<NSString *, MPMWatchNode *> *watchNodes;
@property (nonatomic, strong) NSMutableDictionary<NSString *, MPMFileState *> *liveSnapshot;
@property (nonatomic, strong) NSMutableArray<NSString *> *eventLog;
@property (nonatomic, copy) NSArray<NSString *> *watchRoots;
@property (nonatomic, assign) NSUInteger trackedFileCount;
@property (nonatomic, assign) NSUInteger truncatedFileCount;
@property (nonatomic, assign) BOOL installed;
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, assign) BOOL refreshScheduled;
@property (nonatomic, assign) BOOL hasLoadedInitialSnapshot;
@property (nonatomic, assign) BOOL hudExpanded;
@property (nonatomic, assign) BOOL launcherHidden;
@end

@implementation MPMPassThroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == nil || hitView == self || hitView == self.rootViewController.view) {
        return nil;
    }

    for (UIView *allowedView in self.touchableViews) {
        if (allowedView.hidden || allowedView.alpha < 0.01 || allowedView.window != self) {
            continue;
        }

        if (hitView == allowedView || [hitView isDescendantOfView:allowedView]) {
            return hitView;
        }
    }

    return nil;
}

@end

@implementation MPMFileState
@end

@implementation MPMWatchNode
@end

static UIWindowScene *MPMActiveScene(void) {
    NSSet<UIScene *> *scenes = UIApplication.sharedApplication.connectedScenes;
    for (UIScene *scene in scenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }

    for (UIScene *scene in scenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            return (UIWindowScene *)scene;
        }
    }

    return nil;
}

static NSString *MPMTimestamp(void) {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss";
    });
    return [formatter stringFromDate:[NSDate date]];
}

static NSString *MPMCompactPath(NSString *path, NSUInteger maxLength) {
    if (path.length <= maxLength) {
        return path;
    }

    if (maxLength <= 3) {
        return @"...";
    }

    NSUInteger tailLength = maxLength - 3;
    return [@"..." stringByAppendingString:[path substringFromIndex:path.length - tailLength]];
}

static NSString *MPMModeString(NSUInteger mode) {
    return [NSString stringWithFormat:@"%04lo", (unsigned long)mode];
}

static NSString *MPMEventLine(NSString *type, NSString *path, NSString *details) {
    NSString *compactPath = MPMCompactPath(path, 72);
    if (details.length > 0) {
        return [NSString stringWithFormat:@"[%@] %@  %@  %@", MPMTimestamp(), type, compactPath, details];
    }
    return [NSString stringWithFormat:@"[%@] %@  %@", MPMTimestamp(), type, compactPath];
}

static void MPMAppendLimitedEvent(NSMutableArray<NSString *> *events, NSUInteger *droppedCount, NSString *eventLine) {
    if (eventLine.length == 0) {
        return;
    }

    if (events.count < kMPMMaxEventsPerRefresh) {
        [events addObject:eventLine];
    } else if (droppedCount != NULL) {
        *droppedCount += 1;
    }
}

static BOOL MPMPathHasAnyPrefix(NSString *path, NSArray<NSString *> *prefixes) {
    for (NSString *prefix in prefixes) {
        if ([path hasPrefix:prefix]) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *MPMWatchRootCandidates(void) {
    return @[
        @"/var/mobile/Library/Preferences",
        @"/var/preferences",
        @"/var/jb/Library/Preferences",
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries",
        @"/var/jb/usr/lib/TweakInject",
        @"/var/jb/etc",
        @"/var/mobile/Documents"
    ];
}

static NSArray<NSString *> *MPMExistingWatchRoots(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *roots = [NSMutableArray array];

    for (NSString *candidate in MPMWatchRootCandidates()) {
        BOOL isDirectory = NO;
        if ([fileManager fileExistsAtPath:candidate isDirectory:&isDirectory] && isDirectory) {
            [roots addObject:candidate];
        }
    }

    return roots;
}

static NSArray<NSString *> *MPMExistingDiscoveryDirectories(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableOrderedSet<NSString *> *directories = [NSMutableOrderedSet orderedSet];

    for (NSString *candidate in MPMWatchRootCandidates()) {
        NSString *parent = candidate.stringByDeletingLastPathComponent;
        if (parent.length == 0) {
            continue;
        }

        BOOL isDirectory = NO;
        if ([fileManager fileExistsAtPath:parent isDirectory:&isDirectory] && isDirectory) {
            [directories addObject:parent];
        }
    }

    return directories.array;
}

static BOOL MPMShouldSkipDirectory(NSString *path, NSUInteger depth) {
    if (depth >= kMPMMaxDepthPerRoot) {
        return YES;
    }

    NSArray<NSString *> *skipPrefixes = @[
        @"/var/mobile/Library/Caches",
        @"/var/mobile/Media",
        @"/var/mobile/Containers/Bundle",
        @"/var/mobile/Containers/Shared/AppGroup",
        @"/var/mobile/Containers/Shared/SystemGroup",
        @"/var/db",
        @"/tmp",
        @"/var/tmp",
        @"/var/jb/var/mobile/Library/Caches"
    ];

    if (MPMPathHasAnyPrefix(path, skipPrefixes)) {
        return YES;
    }

    NSString *lastComponent = path.lastPathComponent.lowercaseString;
    NSSet<NSString *> *skipNames = [NSSet setWithArray:@[
        @"caches",
        @"tmp",
        @"media",
        @"logs",
        @"splashboard",
        @"webkit"
    ]];

    return [skipNames containsObject:lastComponent];
}

static BOOL MPMShouldTrackFile(NSString *path) {
    NSArray<NSString *> *skipPrefixes = @[
        @"/var/mobile/Library/Caches",
        @"/var/mobile/Media",
        @"/tmp",
        @"/var/tmp",
        @"/var/jb/var/mobile/Library/Caches"
    ];

    return !MPMPathHasAnyPrefix(path, skipPrefixes);
}

static MPMFileState *MPMFileStateFromStat(NSString *path, const struct stat *fileStat) {
    if (fileStat == NULL) {
        return nil;
    }

    MPMFileState *state = [[MPMFileState alloc] init];
    state.path = path;
    state.size = (unsigned long long)fileStat->st_size;
    state.modTime = (long long)fileStat->st_mtime;
    state.mode = (NSUInteger)(fileStat->st_mode & 07777);
    state.device = (unsigned long long)fileStat->st_dev;
    state.inode = (unsigned long long)fileStat->st_ino;
    state.directory = S_ISDIR(fileStat->st_mode);
    state.plist = !state.isDirectory && [path.pathExtension.lowercaseString isEqualToString:@"plist"];
    return state;
}

static NSString *MPMIdentityKey(MPMFileState *state) {
    if (state == nil || state.inode == 0) {
        return nil;
    }

    return [NSString stringWithFormat:@"%llu:%llu", state.device, state.inode];
}

static NSString *MPMEntryLabel(MPMFileState *state) {
    if (state.isDirectory) {
        return @"dir";
    }

    if (state.isPlist) {
        return @"plist";
    }

    return @"file";
}

static NSDictionary<NSString *, MPMFileState *> *MPMReadFileSnapshot(NSArray<NSString *> *roots,
                                                                     NSMutableDictionary<NSString *, NSNumber *> *watchPaths,
                                                                     NSUInteger *truncatedCount) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableDictionary<NSString *, MPMFileState *> *snapshot = [NSMutableDictionary dictionary];
    BOOL limitReached = NO;

    if (truncatedCount != NULL) {
        *truncatedCount = 0;
    }

    for (NSString *root in roots) {
        if (watchPaths != nil) {
            watchPaths[root] = @YES;
        }

        if (limitReached) {
            break;
        }

        NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtPath:root];
        NSString *relativePath = nil;

        while ((relativePath = [enumerator nextObject])) {
            NSString *fullPath = [root stringByAppendingPathComponent:relativePath];
            struct stat fileStat;
            if (lstat(fullPath.fileSystemRepresentation, &fileStat) != 0) {
                continue;
            }

            BOOL isDirectory = S_ISDIR(fileStat.st_mode);
            NSUInteger depth = relativePath.pathComponents.count;
            if (isDirectory) {
                if (watchPaths != nil) {
                    watchPaths[fullPath] = @YES;
                }

                if (snapshot.count >= kMPMMaxFilesTracked) {
                    limitReached = YES;
                    if (truncatedCount != NULL) {
                        *truncatedCount += 1;
                    }
                    break;
                }

                MPMFileState *directoryState = MPMFileStateFromStat(fullPath, &fileStat);
                if (directoryState != nil && !MPMShouldSkipDirectory(fullPath, depth)) {
                    snapshot[fullPath] = directoryState;
                }

                if (MPMShouldSkipDirectory(fullPath, depth)) {
                    [enumerator skipDescendants];
                }
                continue;
            }

            if (depth > kMPMMaxDepthPerRoot || !MPMShouldTrackFile(fullPath)) {
                continue;
            }

            if (snapshot.count >= kMPMMaxFilesTracked) {
                limitReached = YES;
                if (truncatedCount != NULL) {
                    *truncatedCount += 1;
                }
                break;
            }

            MPMFileState *state = MPMFileStateFromStat(fullPath, &fileStat);
            if (state == nil) {
                continue;
            }

            snapshot[fullPath] = state;
            if (watchPaths != nil) {
                watchPaths[fullPath] = @NO;
            }
        }
    }

    return snapshot;
}

static NSArray<NSString *> *MPMBuildEventDiff(NSDictionary<NSString *, MPMFileState *> *previousSnapshot,
                                              NSDictionary<NSString *, MPMFileState *> *latestSnapshot,
                                              BOOL isInitialRefresh,
                                              NSArray<NSString *> *roots) {
    NSMutableArray<NSString *> *newEvents = [NSMutableArray array];
    NSUInteger droppedEvents = 0;

    if (isInitialRefresh) {
        MPMAppendLimitedEvent(newEvents,
                              &droppedEvents,
                              [NSString stringWithFormat:@"[%@] READY  watching %lu roots and %lu entries",
                               MPMTimestamp(),
                               (unsigned long)roots.count,
                               (unsigned long)latestSnapshot.count]);
    }

    NSArray<NSString *> *sortedNewPaths = [[latestSnapshot allKeys] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    NSArray<NSString *> *sortedOldPaths = [[previousSnapshot allKeys] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    NSMutableDictionary<NSString *, NSMutableArray<MPMFileState *> *> *addedByIdentity = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *pairedAddedPaths = [NSMutableSet set];
    NSMutableSet<NSString *> *pairedRemovedPaths = [NSMutableSet set];

    for (NSString *path in sortedNewPaths) {
        if (previousSnapshot[path] != nil) {
            continue;
        }

        MPMFileState *newState = latestSnapshot[path];
        NSString *identityKey = MPMIdentityKey(newState);
        if (identityKey == nil) {
            continue;
        }

        NSMutableArray<MPMFileState *> *bucket = addedByIdentity[identityKey];
        if (bucket == nil) {
            bucket = [NSMutableArray array];
            addedByIdentity[identityKey] = bucket;
        }
        [bucket addObject:newState];
    }

    for (NSString *path in sortedOldPaths) {
        if (latestSnapshot[path] != nil) {
            continue;
        }

        MPMFileState *oldState = previousSnapshot[path];
        NSString *identityKey = MPMIdentityKey(oldState);
        NSMutableArray<MPMFileState *> *bucket = identityKey != nil ? addedByIdentity[identityKey] : nil;
        MPMFileState *renameTarget = bucket.firstObject;

        if (renameTarget == nil) {
            continue;
        }

        [bucket removeObjectAtIndex:0];
        if (bucket.count == 0 && identityKey != nil) {
            [addedByIdentity removeObjectForKey:identityKey];
        }

        [pairedRemovedPaths addObject:path];
        [pairedAddedPaths addObject:renameTarget.path];

        NSString *renameDetails = oldState.isDirectory
            ? [NSString stringWithFormat:@"dir -> %@",
               MPMCompactPath(renameTarget.path, 44)]
            : [NSString stringWithFormat:@"-> %@",
               MPMCompactPath(renameTarget.path, 48)];
        MPMAppendLimitedEvent(newEvents, &droppedEvents, MPMEventLine(@"RENAME", path, renameDetails));

        BOOL contentChanged = !renameTarget.isDirectory &&
                              (oldState.modTime != renameTarget.modTime || oldState.size != renameTarget.size);
        BOOL modeChanged = oldState.mode != renameTarget.mode;

        if (contentChanged) {
            NSString *eventType = renameTarget.isPlist ? @"PLIST" : @"WRITE";
            NSString *details = [NSString stringWithFormat:@"size %llu -> %llu",
                                 oldState.size,
                                 renameTarget.size];
            MPMAppendLimitedEvent(newEvents, &droppedEvents, MPMEventLine(eventType, renameTarget.path, details));
        }

        if (modeChanged) {
            NSString *details = [NSString stringWithFormat:@"%@ -> %@",
                                 MPMModeString(oldState.mode),
                                 MPMModeString(renameTarget.mode)];
            MPMAppendLimitedEvent(newEvents, &droppedEvents, MPMEventLine(@"ATTRIB", renameTarget.path, details));
        }
    }

    for (NSString *path in sortedNewPaths) {
        if (previousSnapshot[path] != nil || [pairedAddedPaths containsObject:path]) {
            continue;
        }

        MPMFileState *newState = latestSnapshot[path];
        NSString *details = newState.isDirectory ? MPMEntryLabel(newState) : nil;
        MPMAppendLimitedEvent(newEvents, &droppedEvents, MPMEventLine(@"NEW", path, details));
    }

    for (NSString *path in sortedOldPaths) {
        if (latestSnapshot[path] != nil || [pairedRemovedPaths containsObject:path]) {
            continue;
        }

        MPMFileState *oldState = previousSnapshot[path];
        NSString *details = oldState.isDirectory ? MPMEntryLabel(oldState) : nil;
        MPMAppendLimitedEvent(newEvents, &droppedEvents, MPMEventLine(@"DEL", path, details));
    }

    for (NSString *path in sortedNewPaths) {
        MPMFileState *oldState = previousSnapshot[path];
        MPMFileState *newState = latestSnapshot[path];
        if (oldState == nil || newState == nil) {
            continue;
        }

        if (oldState.isDirectory != newState.isDirectory) {
            NSString *oldDetails = oldState.isDirectory ? MPMEntryLabel(oldState) : nil;
            NSString *newDetails = newState.isDirectory ? MPMEntryLabel(newState) : nil;
            MPMAppendLimitedEvent(newEvents, &droppedEvents, MPMEventLine(@"DEL", path, oldDetails));
            MPMAppendLimitedEvent(newEvents, &droppedEvents, MPMEventLine(@"NEW", path, newDetails));
            continue;
        }

        BOOL contentChanged = !newState.isDirectory &&
                              (oldState.modTime != newState.modTime || oldState.size != newState.size);
        BOOL modeChanged = oldState.mode != newState.mode;

        if (contentChanged) {
            NSString *eventType = newState.isPlist ? @"PLIST" : @"WRITE";
            NSString *details = [NSString stringWithFormat:@"size %llu -> %llu",
                                 oldState.size,
                                 newState.size];
            MPMAppendLimitedEvent(newEvents, &droppedEvents, MPMEventLine(eventType, path, details));
        }

        if (modeChanged) {
            NSString *details = [NSString stringWithFormat:@"%@ -> %@",
                                 MPMModeString(oldState.mode),
                                 MPMModeString(newState.mode)];
            MPMAppendLimitedEvent(newEvents, &droppedEvents, MPMEventLine(@"ATTRIB", path, details));
        }
    }

    if (droppedEvents > 0) {
        [newEvents addObject:[NSString stringWithFormat:@"[%@] MORE  +%lu additional changes",
                              MPMTimestamp(),
                              (unsigned long)droppedEvents]];
    }

    return newEvents;
}

@implementation MPMOverlayController

+ (instancetype)sharedInstance {
    static MPMOverlayController *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _eventLog = [NSMutableArray array];
        _watchRoots = @[];
        _watchNodes = [NSMutableDictionary dictionary];
        _liveSnapshot = [NSMutableDictionary dictionary];
        _monitorQueue = dispatch_queue_create("com.devil.miniprocmon.filemonitor", DISPATCH_QUEUE_SERIAL);
        _launcherHidden = YES;
    }
    return self;
}

- (void)installOverlayIfNeeded {
    if (self.installed) {
        return;
    }

    UIWindowScene *scene = MPMActiveScene();
    if (scene == nil) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self installOverlayIfNeeded];
        });
        return;
    }

    self.window = [[MPMPassThroughWindow alloc] initWithWindowScene:scene];
    self.window.frame = UIScreen.mainScreen.bounds;
    self.window.windowLevel = UIWindowLevelStatusBar + 15.0;
    self.window.backgroundColor = UIColor.clearColor;
    self.window.clipsToBounds = NO;

    UIViewController *rootController = [[UIViewController alloc] init];
    rootController.view.backgroundColor = UIColor.clearColor;
    self.window.rootViewController = rootController;

    [self buildHUD];
    [self buildLauncherButton];
    [self buildPanel];
    [self updateTouchableViews];

    self.window.hidden = NO;

    self.installed = YES;
    [self refreshDisplay];
    [self startMonitoring];
}

- (void)buildHUD {
    CGRect bounds = UIScreen.mainScreen.bounds;
    CGFloat width = MIN(CGRectGetWidth(bounds) - 24.0, 344.0);
    self.hudView = [[UIView alloc] initWithFrame:CGRectMake((CGRectGetWidth(bounds) - width) / 2.0, 54.0, width, 110.0)];
    self.hudView.backgroundColor = [UIColor colorWithRed:0.05 green:0.07 blue:0.10 alpha:0.84];
    self.hudView.layer.cornerRadius = 18.0;
    self.hudView.layer.borderWidth = 1.0;
    self.hudView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    self.hudView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.hudView.layer.shadowOpacity = 0.18;
    self.hudView.layer.shadowRadius = 12.0;
    self.hudView.layer.shadowOffset = CGSizeMake(0.0, 6.0);
    self.hudView.userInteractionEnabled = YES;

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    blurView.frame = self.hudView.bounds;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blurView.layer.cornerRadius = 18.0;
    blurView.clipsToBounds = YES;
    [self.hudView addSubview:blurView];

    self.hudHeaderView = [[UIView alloc] initWithFrame:CGRectZero];
    self.hudHeaderView.backgroundColor = UIColor.clearColor;
    [self.hudView addSubview:self.hudHeaderView];

    self.hudTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.hudTitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    self.hudTitleLabel.textColor = UIColor.whiteColor;
    self.hudTitleLabel.text = @"MiniFileMon";
    [self.hudHeaderView addSubview:self.hudTitleLabel];

    self.hudStatusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.hudStatusLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
    self.hudStatusLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.68];
    self.hudStatusLabel.text = @"Preparing vnode monitor...";
    [self.hudHeaderView addSubview:self.hudStatusLabel];

    self.hudBodyTextView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.hudBodyTextView.backgroundColor = UIColor.clearColor;
    self.hudBodyTextView.textColor = [UIColor colorWithRed:0.65 green:0.95 blue:0.79 alpha:1.0];
    self.hudBodyTextView.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightMedium];
    self.hudBodyTextView.textContainerInset = UIEdgeInsetsZero;
    self.hudBodyTextView.textContainer.lineFragmentPadding = 0.0;
    self.hudBodyTextView.editable = NO;
    self.hudBodyTextView.selectable = NO;
    self.hudBodyTextView.scrollEnabled = NO;
    self.hudBodyTextView.alwaysBounceVertical = NO;
    self.hudBodyTextView.showsVerticalScrollIndicator = NO;
    self.hudBodyTextView.text = @"Waiting for file events...";
    [self.hudView addSubview:self.hudBodyTextView];

    UIPanGestureRecognizer *hudPanGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleHUDPan:)];
    [self.hudHeaderView addGestureRecognizer:hudPanGesture];

    UILongPressGestureRecognizer *hudLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleHUDLongPress:)];
    hudLongPress.minimumPressDuration = 0.45;
    [self.hudHeaderView addGestureRecognizer:hudLongPress];

    UITapGestureRecognizer *hudDoubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(togglePanel)];
    hudDoubleTap.numberOfTapsRequired = 2;
    [self.hudHeaderView addGestureRecognizer:hudDoubleTap];

    [self.window.rootViewController.view addSubview:self.hudView];
    [self refreshHUDLayoutAnimated:NO];
}

- (CGSize)hudSizeForExpandedState:(BOOL)expanded {
    CGRect bounds = self.window.rootViewController.view.bounds;
    CGFloat width = MIN(CGRectGetWidth(bounds) - 24.0, expanded ? 372.0 : 344.0);
    CGFloat height = expanded ? MIN(CGRectGetHeight(bounds) * 0.48, 330.0) : 110.0;
    return CGSizeMake(width, height);
}

- (void)refreshHUDLayoutAnimated:(BOOL)animated {
    if (self.hudView == nil) {
        return;
    }

    CGRect bounds = self.window.rootViewController.view.bounds;
    UIEdgeInsets safeInsets = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        safeInsets = self.window.safeAreaInsets;
    }

    CGSize targetSize = [self hudSizeForExpandedState:self.hudExpanded];
    CGPoint center = self.hudView.superview != nil ? self.hudView.center : CGPointMake(CGRectGetMidX(bounds), safeInsets.top + 54.0);
    CGFloat sideInset = 12.0;
    CGFloat topInset = MAX(18.0, safeInsets.top + 8.0);
    CGFloat bottomInset = MAX(18.0, safeInsets.bottom + 8.0);
    CGFloat minCenterX = sideInset + targetSize.width / 2.0;
    CGFloat maxCenterX = CGRectGetWidth(bounds) - sideInset - targetSize.width / 2.0;
    CGFloat minCenterY = topInset + targetSize.height / 2.0;
    CGFloat maxCenterY = CGRectGetHeight(bounds) - bottomInset - targetSize.height / 2.0;

    if (maxCenterX < minCenterX) {
        center.x = CGRectGetMidX(bounds);
    } else {
        center.x = MAX(minCenterX, MIN(maxCenterX, center.x));
    }

    if (maxCenterY < minCenterY) {
        center.y = CGRectGetMidY(bounds);
    } else {
        center.y = MAX(minCenterY, MIN(maxCenterY, center.y));
    }

    CGRect targetFrame = CGRectMake(center.x - targetSize.width / 2.0,
                                    center.y - targetSize.height / 2.0,
                                    targetSize.width,
                                    targetSize.height);

    void (^applyLayout)(void) = ^{
        self.hudView.frame = targetFrame;
        self.hudView.layer.cornerRadius = self.hudExpanded ? 22.0 : 18.0;
        CGFloat headerHeight = 40.0;
        self.hudHeaderView.frame = CGRectMake(14.0, 10.0, targetSize.width - 28.0, headerHeight);
        self.hudTitleLabel.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(self.hudHeaderView.bounds), 20.0);
        self.hudStatusLabel.frame = CGRectMake(0.0, 20.0, CGRectGetWidth(self.hudHeaderView.bounds), 16.0);
        CGFloat bodyY = CGRectGetMaxY(self.hudHeaderView.frame) + 6.0;
        self.hudBodyTextView.frame = CGRectMake(14.0, bodyY, targetSize.width - 28.0, targetSize.height - bodyY - 12.0);
        self.hudBodyTextView.scrollEnabled = self.hudExpanded;
        self.hudBodyTextView.showsVerticalScrollIndicator = self.hudExpanded;
        self.hudBodyTextView.alwaysBounceVertical = self.hudExpanded;
    };

    if (animated) {
        [UIView animateWithDuration:0.22 animations:applyLayout];
    } else {
        applyLayout();
    }
}

- (void)buildLauncherButton {
    CGFloat buttonSize = 52.0;
    CGRect bounds = UIScreen.mainScreen.bounds;
    self.launcherButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.launcherButton.frame = CGRectMake(CGRectGetWidth(bounds) - buttonSize - 16.0,
                                           CGRectGetHeight(bounds) - buttonSize - 124.0,
                                           buttonSize,
                                           buttonSize);
    self.launcherButton.backgroundColor = [UIColor colorWithRed:0.10 green:0.33 blue:0.64 alpha:0.92];
    self.launcherButton.layer.cornerRadius = buttonSize / 2.0;
    self.launcherButton.layer.borderWidth = 1.0;
    self.launcherButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
    self.launcherButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.launcherButton.layer.shadowOpacity = 0.25;
    self.launcherButton.layer.shadowRadius = 10.0;
    self.launcherButton.layer.shadowOffset = CGSizeMake(0.0, 4.0);
    self.launcherButton.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightBold];
    [self.launcherButton setTitle:@"FM" forState:UIControlStateNormal];
    [self.launcherButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.launcherButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [self.launcherButton addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    self.launcherButton.hidden = self.launcherHidden;
    self.launcherButton.alpha = self.launcherHidden ? 0.0 : 1.0;

    UIPanGestureRecognizer *dragGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleButtonDrag:)];
    [self.launcherButton addGestureRecognizer:dragGesture];

    [self.window.rootViewController.view addSubview:self.launcherButton];
}

- (void)buildPanel {
    CGRect bounds = UIScreen.mainScreen.bounds;
    CGFloat width = MIN(CGRectGetWidth(bounds) - 24.0, 360.0);
    CGFloat height = MIN(CGRectGetHeight(bounds) * 0.56, 380.0);
    self.panelView = [[UIView alloc] initWithFrame:CGRectMake((CGRectGetWidth(bounds) - width) / 2.0,
                                                              CGRectGetHeight(bounds) - height - 96.0,
                                                              width,
                                                              height)];
    self.panelView.backgroundColor = [UIColor colorWithRed:0.06 green:0.08 blue:0.11 alpha:0.96];
    self.panelView.layer.cornerRadius = 22.0;
    self.panelView.layer.borderWidth = 1.0;
    self.panelView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
    self.panelView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.panelView.layer.shadowOpacity = 0.30;
    self.panelView.layer.shadowRadius = 18.0;
    self.panelView.layer.shadowOffset = CGSizeMake(0.0, 8.0);
    self.panelView.hidden = YES;
    self.panelView.alpha = 0.0;
    self.panelView.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    blurView.frame = self.panelView.bounds;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blurView.layer.cornerRadius = 22.0;
    blurView.clipsToBounds = YES;
    [self.panelView addSubview:blurView];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(18.0, 16.0, width - 120.0, 24.0)];
    self.titleLabel.font = [UIFont systemFontOfSize:19.0 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = UIColor.whiteColor;
    self.titleLabel.text = @"MiniFileMon";
    [self.panelView addSubview:self.titleLabel];

    self.subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(18.0, 40.0, width - 36.0, 18.0)];
    self.subtitleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    self.subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.64];
    self.subtitleLabel.text = @"Event-driven: create / delete / rename / write / attrib";
    [self.panelView addSubview:self.subtitleLabel];

    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    closeButton.frame = CGRectMake(width - 50.0, 14.0, 34.0, 34.0);
    closeButton.layer.cornerRadius = 17.0;
    closeButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    closeButton.titleLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightSemibold];
    [closeButton setTitle:@"x" forState:UIControlStateNormal];
    [closeButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [closeButton addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:closeButton];

    UIButton *syncButton = [UIButton buttonWithType:UIButtonTypeSystem];
    syncButton.frame = CGRectMake(width - 104.0, 14.0, 46.0, 34.0);
    syncButton.layer.cornerRadius = 17.0;
    syncButton.backgroundColor = [UIColor colorWithRed:0.18 green:0.44 blue:0.74 alpha:0.90];
    syncButton.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    [syncButton setTitle:@"SYNC" forState:UIControlStateNormal];
    [syncButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [syncButton addTarget:self action:@selector(forceRefresh) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:syncButton];

    self.textView = [[UITextView alloc] initWithFrame:CGRectMake(14.0, 70.0, width - 28.0, height - 84.0)];
    self.textView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.18];
    self.textView.textColor = [UIColor colorWithRed:0.75 green:0.96 blue:0.82 alpha:1.0];
    self.textView.layer.cornerRadius = 16.0;
    self.textView.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
    self.textView.editable = NO;
    self.textView.selectable = NO;
    self.textView.textContainerInset = UIEdgeInsetsMake(14.0, 12.0, 14.0, 12.0);
    self.textView.text = @"Preparing vnode monitor...";
    [self.panelView addSubview:self.textView];

    [self.window.rootViewController.view addSubview:self.panelView];
}

- (void)updateTouchableViews {
    NSMutableArray<UIView *> *touchableViews = [NSMutableArray array];
    if (self.hudView != nil) {
        [touchableViews addObject:self.hudView];
    }
    if (!self.launcherHidden && self.launcherButton != nil) {
        [touchableViews addObject:self.launcherButton];
    }
    if (self.panelView != nil) {
        [touchableViews addObject:self.panelView];
    }
    self.window.touchableViews = touchableViews;
}

- (void)startMonitoring {
    __weak __typeof(self) weakSelf = self;
    dispatch_async(self.monitorQueue, ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }

        [strongSelf rebuildMonitoringState];
    });
}

- (void)handleWatchEventForPath:(NSString *)path isDirectory:(BOOL)isDirectory flags:(unsigned long)flags {
    (void)path;
    (void)isDirectory;
    (void)flags;
    [self scheduleCoalescedRefresh];
}

- (void)scheduleCoalescedRefresh {
    if (self.refreshScheduled) {
        return;
    }

    self.refreshScheduled = YES;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kMPMEventCoalescingDelay * NSEC_PER_SEC)),
                   self.monitorQueue,
                   ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }

        strongSelf.refreshScheduled = NO;
        [strongSelf rebuildMonitoringState];
    });
}

- (void)rebuildMonitoringState {
    NSArray<NSString *> *roots = MPMExistingWatchRoots();
    NSMutableDictionary<NSString *, NSNumber *> *desiredWatchPaths = [NSMutableDictionary dictionary];
    NSUInteger truncatedCount = 0;
    NSDictionary<NSString *, MPMFileState *> *latestSnapshot = MPMReadFileSnapshot(roots, desiredWatchPaths, &truncatedCount);

    for (NSString *discoveryPath in MPMExistingDiscoveryDirectories()) {
        if (desiredWatchPaths[discoveryPath] == nil) {
            desiredWatchPaths[discoveryPath] = @YES;
        }
    }

    [self syncWatchNodesWithDesiredPaths:desiredWatchPaths];

    NSDictionary<NSString *, MPMFileState *> *previousSnapshot = [self.liveSnapshot copy];
    BOOL isInitialRefresh = !self.hasLoadedInitialSnapshot;
    self.liveSnapshot = [latestSnapshot mutableCopy];
    self.hasLoadedInitialSnapshot = YES;

    NSArray<NSString *> *newEvents = MPMBuildEventDiff(previousSnapshot, latestSnapshot, isInitialRefresh, roots);

    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) innerSelf = weakSelf;
        if (innerSelf == nil) {
            return;
        }

        innerSelf.watchRoots = roots;
        innerSelf.trackedFileCount = latestSnapshot.count;
        innerSelf.truncatedFileCount = truncatedCount;

        for (NSString *eventLine in newEvents) {
            [innerSelf appendEvent:eventLine];
        }

        [innerSelf refreshDisplay];

        if (newEvents.count > 0) {
            [innerSelf pulseHUD];
        }
    });
}

- (void)handleButtonDrag:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.window.rootViewController.view];
    CGPoint center = self.launcherButton.center;
    center.x += translation.x;
    center.y += translation.y;

    CGRect bounds = self.window.rootViewController.view.bounds;
    CGFloat halfWidth = CGRectGetWidth(self.launcherButton.bounds) / 2.0;
    CGFloat halfHeight = CGRectGetHeight(self.launcherButton.bounds) / 2.0;
    center.x = MAX(halfWidth + 8.0, MIN(CGRectGetWidth(bounds) - halfWidth - 8.0, center.x));
    center.y = MAX(halfHeight + 54.0, MIN(CGRectGetHeight(bounds) - halfHeight - 18.0, center.y));

    self.launcherButton.center = center;
    [gesture setTranslation:CGPointZero inView:self.window.rootViewController.view];
}

- (void)handleHUDPan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.window.rootViewController.view];
    CGPoint center = self.hudView.center;
    center.x += translation.x;
    center.y += translation.y;

    CGRect bounds = self.window.rootViewController.view.bounds;
    UIEdgeInsets safeInsets = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        safeInsets = self.window.safeAreaInsets;
    }

    CGFloat sideInset = 12.0;
    CGFloat topInset = MAX(18.0, safeInsets.top + 8.0);
    CGFloat bottomInset = MAX(18.0, safeInsets.bottom + 8.0);
    CGFloat halfWidth = CGRectGetWidth(self.hudView.bounds) / 2.0;
    CGFloat halfHeight = CGRectGetHeight(self.hudView.bounds) / 2.0;
    center.x = MAX(sideInset + halfWidth, MIN(CGRectGetWidth(bounds) - sideInset - halfWidth, center.x));
    center.y = MAX(topInset + halfHeight, MIN(CGRectGetHeight(bounds) - bottomInset - halfHeight, center.y));

    self.hudView.center = center;
    [gesture setTranslation:CGPointZero inView:self.window.rootViewController.view];
}

- (void)handleHUDLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }

    self.hudExpanded = !self.hudExpanded;
    [self refreshHUD];
    [self refreshHUDLayoutAnimated:YES];
}

- (void)togglePanel {
    self.panelVisible = !self.panelVisible;

    if (self.panelVisible) {
        [self refreshPanelText];
        self.panelView.hidden = NO;
        self.panelView.transform = CGAffineTransformMakeScale(0.96, 0.96);
        [UIView animateWithDuration:0.20 animations:^{
            self.panelView.alpha = 1.0;
            self.panelView.transform = CGAffineTransformIdentity;
        }];
    } else {
        [UIView animateWithDuration:0.16 animations:^{
            self.panelView.alpha = 0.0;
        } completion:^(BOOL finished) {
            self.panelView.hidden = YES;
        }];
    }
}

- (void)syncWatchNodesWithDesiredPaths:(NSDictionary<NSString *, NSNumber *> *)desiredWatchPaths {
    NSSet<NSString *> *desiredPaths = [NSSet setWithArray:desiredWatchPaths.allKeys];
    NSArray<NSString *> *existingPaths = [self.watchNodes.allKeys copy];

    for (NSString *path in existingPaths) {
        if ([desiredPaths containsObject:path]) {
            continue;
        }

        MPMWatchNode *node = self.watchNodes[path];
        [self.watchNodes removeObjectForKey:path];
        if (node.source != nil) {
            dispatch_source_cancel(node.source);
        }
    }

    for (NSString *path in desiredWatchPaths) {
        BOOL isDirectory = [desiredWatchPaths[path] boolValue];
        MPMWatchNode *existingNode = self.watchNodes[path];
        if (existingNode != nil) {
            if (existingNode.isDirectory == isDirectory) {
                continue;
            }

            [self.watchNodes removeObjectForKey:path];
            if (existingNode.source != nil) {
                dispatch_source_cancel(existingNode.source);
            }
        }

        [self registerWatchForPath:path isDirectory:isDirectory];
    }
}

- (void)registerWatchForPath:(NSString *)path isDirectory:(BOOL)isDirectory {
    if (path.length == 0 || self.watchNodes[path] != nil) {
        return;
    }

    int fileDescriptor = open(path.fileSystemRepresentation, O_EVTONLY);
    if (fileDescriptor < 0) {
        return;
    }

    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,
                                                      (uintptr_t)fileDescriptor,
                                                      kMPMVnodeMask,
                                                      self.monitorQueue);
    if (source == nil) {
        close(fileDescriptor);
        return;
    }

    MPMWatchNode *node = [[MPMWatchNode alloc] init];
    node.path = path;
    node.fileDescriptor = fileDescriptor;
    node.directory = isDirectory;
    node.source = source;

    __weak __typeof(self) weakSelf = self;
    NSString *watchedPath = [path copy];
    dispatch_source_set_event_handler(source, ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }

        unsigned long flags = dispatch_source_get_data(source);
        [strongSelf handleWatchEventForPath:watchedPath isDirectory:isDirectory flags:flags];
    });

    dispatch_source_set_cancel_handler(source, ^{
        close(fileDescriptor);
    });

    self.watchNodes[path] = node;
    dispatch_resume(source);
}

- (void)forceRefresh {
    __weak __typeof(self) weakSelf = self;
    dispatch_async(self.monitorQueue, ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }

        strongSelf.refreshScheduled = NO;
        [strongSelf rebuildMonitoringState];
    });
}

- (void)appendEvent:(NSString *)eventLine {
    if (eventLine.length == 0) {
        return;
    }

    [self.eventLog addObject:eventLine];
    while (self.eventLog.count > kMPMMaxEventLog) {
        [self.eventLog removeObjectAtIndex:0];
    }

    NSLog(@"[MiniFileMon] %@", eventLine);
}

- (NSArray<NSString *> *)latestHUDLines {
    if (self.eventLog.count == 0) {
        return @[@"Waiting for file events..."];
    }

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSInteger minimumIndex = MAX((NSInteger)self.eventLog.count - 3, 0);
    for (NSInteger index = self.eventLog.count - 1; index >= minimumIndex; index--) {
        [lines addObject:self.eventLog[(NSUInteger)index]];
    }

    return lines;
}

- (NSString *)fullHUDText {
    NSMutableString *output = [NSMutableString string];
    [output appendString:@"Long press top bar to resize\n"];
    [output appendString:@"Drag top bar to move\n"];
    [output appendString:@"Double tap top bar for panel\n"];

    [output appendString:@"\nRecent events\n-------------\n"];
    if (self.eventLog.count == 0) {
        [output appendString:@"(waiting for changes)\n"];
    } else {
        for (NSString *eventLine in self.eventLog.reverseObjectEnumerator) {
            [output appendFormat:@"%@\n", eventLine];
        }
    }

    [output appendString:@"\nWatch roots\n-----------\n"];
    if (self.watchRoots.count == 0) {
        [output appendString:@"(none found yet)\n"];
    } else {
        for (NSString *root in self.watchRoots) {
            [output appendFormat:@"%@\n", root];
        }
    }

    return output;
}

- (void)refreshHUD {
    NSString *status = [NSString stringWithFormat:@"%lu roots | %lu entries | vnode",
                        (unsigned long)self.watchRoots.count,
                        (unsigned long)self.trackedFileCount];
    if (self.truncatedFileCount > 0) {
        status = [status stringByAppendingFormat:@" | limit hit"];
    }

    if (self.watchRoots.count == 0) {
        status = @"No watch roots found yet";
    }

    self.hudTitleLabel.text = self.hudExpanded ? @"MiniFileMon  [Expanded]" : @"MiniFileMon";
    self.hudStatusLabel.text = status;
    self.hudBodyTextView.text = self.hudExpanded ? [self fullHUDText] : [[self latestHUDLines] componentsJoinedByString:@"\n"];
    self.hudBodyTextView.contentOffset = CGPointZero;
}

- (void)refreshPanelText {
    NSMutableString *output = [NSMutableString string];
    [output appendString:@"MiniFileMon\n"];
    [output appendString:@"Mode: event-driven vnode monitor\n"];
    [output appendFormat:@"Roots: %lu\n", (unsigned long)self.watchRoots.count];
    [output appendFormat:@"Entries tracked: %lu\n", (unsigned long)self.trackedFileCount];
    if (self.truncatedFileCount > 0) {
        [output appendString:@"Limit hit: yes\n"];
    }

    [output appendString:@"\nRecent events\n-------------\n"];
    if (self.eventLog.count == 0) {
        [output appendString:@"(waiting for changes)\n"];
    } else {
        for (NSString *eventLine in self.eventLog.reverseObjectEnumerator) {
            [output appendFormat:@"%@\n", eventLine];
        }
    }

    [output appendString:@"\nWatch roots\n-----------\n"];
    if (self.watchRoots.count == 0) {
        [output appendString:@"(none found yet)\n"];
    } else {
        for (NSString *root in self.watchRoots) {
            [output appendFormat:@"%@\n", root];
        }
    }

    self.textView.text = output;
    self.titleLabel.text = [NSString stringWithFormat:@"MiniFileMon (%lu)", (unsigned long)self.trackedFileCount];
}

- (void)refreshDisplay {
    [self refreshHUD];
    if (self.panelVisible) {
        [self refreshPanelText];
    }
}

- (void)pulseHUD {
    self.hudView.transform = CGAffineTransformIdentity;
    [UIView animateWithDuration:0.10 animations:^{
        self.hudView.transform = CGAffineTransformMakeScale(1.02, 1.02);
        self.hudView.layer.borderColor = [UIColor colorWithRed:0.40 green:0.78 blue:0.60 alpha:0.65].CGColor;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.20 animations:^{
            self.hudView.transform = CGAffineTransformIdentity;
            self.hudView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
        }];
    }];
}

@end

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[MPMOverlayController sharedInstance] installOverlayIfNeeded];
    });
}

%end
