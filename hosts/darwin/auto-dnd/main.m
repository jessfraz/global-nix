#import <AppKit/AppKit.h>
#import <EventKit/EventKit.h>
#import <Foundation/Foundation.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#include <math.h>

static NSString *const ShortcutName = @"Auto DND Apply (Nix v2)";
static const NSTimeInterval LeadTime = 120;

@interface Meeting : NSObject
@property(nonatomic, copy) NSString *key;
@property(nonatomic, strong) NSDate *start;
@property(nonatomic, strong) NSDate *end;
@end
@implementation Meeting
@end

// Select the last-ending event in the current connected meeting block. Giving
// macOS that event lets its own "Event Ends" assertion expire DND, including
// when the helper exits. No broad "turn Focus off" operation is needed.
static Meeting *CurrentMeeting(NSArray<Meeting *> *meetings, NSDate *now) {
  NSArray<Meeting *> *sorted = [meetings sortedArrayUsingComparator:^NSComparisonResult(Meeting *a, Meeting *b) {
    return [a.start compare:b.start];
  }];
  Meeting *target = nil;
  NSDate *boundary = [now dateByAddingTimeInterval:LeadTime];
  for (Meeting *meeting in sorted) {
    if ([meeting.end compare:now] != NSOrderedDescending) continue;
    if ([meeting.start compare:boundary] == NSOrderedDescending) break;
    if (!target || [meeting.end compare:target.end] == NSOrderedDescending) target = meeting;
    boundary = target.end;
  }
  return target;
}

@interface Planner : NSObject
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *attempted;
@property(nonatomic, strong) NSDate *appliedUntil;
@property(nonatomic, copy) NSString *appliedKey;
- (Meeting *)actionForMeetings:(NSArray<Meeting *> *)meetings now:(NSDate *)now;
- (NSDate *)nextCheckForMeetings:(NSArray<Meeting *> *)meetings now:(NSDate *)now;
@end
@implementation Planner
- (instancetype)init {
  self = [super init];
  if (self) _attempted = [NSMutableDictionary dictionary];
  return self;
}
- (Meeting *)actionForMeetings:(NSArray<Meeting *> *)meetings now:(NSDate *)now {
  if (self.appliedKey) {
    Meeting *applied = nil;
    for (Meeting *meeting in meetings) if ([meeting.key isEqualToString:self.appliedKey]) applied = meeting;
    self.appliedUntil = applied.end;
    if (!applied) self.appliedKey = nil;
  }
  for (NSString *key in self.attempted.allKeys) {
    if (self.attempted[key].doubleValue < now.timeIntervalSince1970) [self.attempted removeObjectForKey:key];
  }
  Meeting *meeting = CurrentMeeting(meetings, now);
  if (!meeting || self.attempted[meeting.key] || [self.appliedUntil compare:now] == NSOrderedDescending) return nil;
  return meeting;
}
- (NSDate *)nextCheckForMeetings:(NSArray<Meeting *> *)meetings now:(NSDate *)now {
  NSDate *next = [now dateByAddingTimeInterval:3600];
  NSMutableArray<NSDate *> *boundaries = [NSMutableArray array];
  for (Meeting *meeting in meetings) {
    [boundaries addObject:[meeting.start dateByAddingTimeInterval:-LeadTime]];
    [boundaries addObject:[meeting.end dateByAddingTimeInterval:1]];
  }
  if (self.appliedUntil) [boundaries addObject:[self.appliedUntil dateByAddingTimeInterval:1]];
  for (NSDate *date in boundaries) {
    if ([date compare:now] == NSOrderedDescending && [date compare:next] == NSOrderedAscending) next = date;
  }
  return next;
}
@end

static void Log(NSString *message) {
  fprintf(stderr, "auto-dnd: %s\n", message.UTF8String);
}

static NSString *RunShortcuts(NSArray<NSString *> *arguments, NSError **error) {
  NSFileManager *files = NSFileManager.defaultManager;
  NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
  if (![files createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:error]) return nil;
  NSURL *output = [directory URLByAppendingPathComponent:@"output"];
  [files createFileAtPath:output.path contents:nil attributes:@{NSFilePosixPermissions: @0600}];
  NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:output error:error];
  if (!handle) { [files removeItemAtURL:directory error:NULL]; return nil; }
  NSTask *task = [[NSTask alloc] init];
  task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/shortcuts"];
  task.arguments = arguments;
  task.standardOutput = handle;
  task.standardError = NSFileHandle.fileHandleWithNullDevice;
  BOOL launched = [task launchAndReturnError:error];
  if (launched) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    while (task.running && deadline.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.05];
    if (task.running) {
      [task terminate];
      NSDate *grace = [NSDate dateWithTimeIntervalSinceNow:2];
      while (task.running && grace.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.05];
      if (task.running) kill(task.processIdentifier, SIGKILL);
    }
    [task waitUntilExit];
  }
  [handle closeFile];
  NSString *result = nil;
  if (launched && task.terminationStatus == 0) {
    NSFileHandle *reader = [NSFileHandle fileHandleForReadingFromURL:output error:error];
    if (reader) {
      NSData *data = [reader readDataOfLength:65537];
      [reader closeFile];
      if (data.length <= 65536) result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
  }
  if (launched && !result && error) {
    *error = [NSError errorWithDomain:@"AutoDND" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Shortcuts failed, timed out, or returned invalid output"}];
  }
  [files removeItemAtURL:directory error:NULL];
  return result;
}

@interface Agent : NSObject
@property(nonatomic, strong) EKEventStore *store;
@property(nonatomic, strong) Planner *planner;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) NSString *calendarName;
@property(nonatomic, copy) NSString *personalAccount;
@property(nonatomic, strong) NSURL *stateURL;
@property(nonatomic, strong) NSFileHandle *lockHandle;
@property(nonatomic) BOOL waitingForImport;
@property(nonatomic) BOOL shortcutReady;
@property(nonatomic) BOOL checkOnly;
@property(nonatomic) BOOL listOnly;
@property(nonatomic) BOOL checkShortcut;
- (void)start;
- (void)refresh;
@end

@implementation Agent
- (instancetype)init {
  self = [super init];
  if (self) {
    _store = [[EKEventStore alloc] init];
    _planner = [[Planner alloc] init];
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    _stateURL = [[support URLByAppendingPathComponent:@"Auto DND"] URLByAppendingPathComponent:@"state.plist"];
  }
  return self;
}
- (void)schedule:(NSDate *)date {
  [self.timer invalidate];
  self.timer = [NSTimer scheduledTimerWithTimeInterval:MAX(1, date.timeIntervalSinceNow) target:self selector:@selector(refresh) userInfo:nil repeats:NO];
  self.timer.tolerance = 0.5;
}
- (BOOL)saveState {
  NSDictionary *state = @{
    @"attempted": self.planner.attempted,
    @"appliedUntil": self.planner.appliedUntil ?: NSDate.distantPast,
    @"appliedKey": self.planner.appliedKey ?: @"",
  };
  NSError *error = nil;
  NSData *data = [NSPropertyListSerialization dataWithPropertyList:state format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
  if (!data || ![data writeToURL:self.stateURL options:NSDataWritingAtomic error:&error]) {
    Log(@"Could not persist meeting state; stopping to avoid repeated Focus changes");
    return NO;
  }
  return YES;
}
- (BOOL)prepareShortcut {
  if (self.shortcutReady) return YES;
  NSError *error = nil;
  NSString *installed = RunShortcuts(@[@"list"], &error);
  if (!installed) { Log(error.localizedDescription); return NO; }
  if ([[installed componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] containsObject:ShortcutName]) { self.shortcutReady = YES; return YES; }
  if (self.waitingForImport) return NO;
  self.waitingForImport = YES;
  NSURL *source = [NSBundle.mainBundle URLForResource:@"shortcut" withExtension:@"json"];
  NSData *json = source ? [NSData dataWithContentsOfURL:source options:0 error:&error] : nil;
  id definition = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:&error] : nil;
  NSData *plist = definition ? [NSPropertyListSerialization dataWithPropertyList:definition format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error] : nil;
  NSURL *unsignedURL = [self.stateURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"apply-unsigned.shortcut"];
  NSURL *signedURL = [self.stateURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:[ShortcutName stringByAppendingPathExtension:@"shortcut"]];
  if (!plist || ![plist writeToURL:unsignedURL options:NSDataWritingAtomic error:&error]) { Log(@"Could not prepare the bundled Focus shortcut"); return NO; }
  if (!RunShortcuts(@[@"sign", @"--mode", @"anyone", @"--input", unsignedURL.path, @"--output", signedURL.path], &error)) { Log(error.localizedDescription); return NO; }
  if (![NSWorkspace.sharedWorkspace openURL:signedURL]) { Log(@"Could not open the bundled Focus shortcut for import"); return NO; }
  Log(@"Add ‘Auto DND Apply (Nix v2)’ in Shortcuts. Calendar watching starts after import.");
  return NO;
}
- (void)beginWatching {
  if (self.listOnly) {
    for (EKCalendar *calendar in [self.store calendarsForEntityType:EKEntityTypeEvent]) {
      printf("%s | source: %s | subscribed: %s\n", calendar.title.UTF8String, calendar.source.title.UTF8String, calendar.subscribed ? "yes" : "no");
    }
    [NSApp terminate:nil];
    return;
  }
  NSError *error = nil;
  if (![NSFileManager.defaultManager createDirectoryAtURL:self.stateURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:&error]) { Log(error.localizedDescription); [NSApp terminate:nil]; return; }
  if (!self.checkOnly) {
    NSURL *lockURL = [self.stateURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"agent.lock"];
    int descriptor = open(lockURL.fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (descriptor < 0) { Log(@"Could not open the single-instance lock"); [NSApp terminate:nil]; return; }
    if (flock(descriptor, LOCK_EX | LOCK_NB) != 0) { close(descriptor); Log(@"Another Auto DND agent is already running"); [NSApp terminate:nil]; return; }
    self.lockHandle = [[NSFileHandle alloc] initWithFileDescriptor:descriptor closeOnDealloc:YES];
  }
  NSData *data = [NSData dataWithContentsOfURL:self.stateURL];
  if (data) {
    id state = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:&error];
    if (![state isKindOfClass:NSDictionary.class] || ![state[@"attempted"] isKindOfClass:NSDictionary.class] || ![state[@"appliedUntil"] isKindOfClass:NSDate.class]) { Log(@"Invalid saved meeting state; refusing to replace a possible manual Focus override"); [NSApp terminate:nil]; return; }
    for (id key in state[@"attempted"]) {
      if (![key isKindOfClass:NSString.class] || ![state[@"attempted"][key] isKindOfClass:NSNumber.class]) { Log(@"Invalid saved meeting state"); [NSApp terminate:nil]; return; }
    }
    self.planner.attempted = [state[@"attempted"] mutableCopy];
    self.planner.appliedUntil = state[@"appliedUntil"];
    if ([state[@"appliedKey"] isKindOfClass:NSString.class] && [state[@"appliedKey"] length]) self.planner.appliedKey = state[@"appliedKey"];
  }
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(changed:) name:EKEventStoreChangedNotification object:self.store];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(changed:) name:NSSystemClockDidChangeNotification object:nil];
  [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(changed:) name:NSWorkspaceDidWakeNotification object:nil];
  [self refresh];
}
- (void)start {
  EKAuthorizationStatus status = [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
  if (status == EKAuthorizationStatusNotDetermined) {
    [self.store requestFullAccessToEventsWithCompletion:^(BOOL granted, NSError *error) {
      (void)error;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (granted) [self beginWatching];
        else { Log(@"Calendar access is required; allow Auto DND in System Settings > Privacy & Security > Calendars, then relaunch it"); if (self.checkOnly || self.listOnly) exit(1); [NSApp terminate:nil]; }
      });
    }];
  } else if (status == EKAuthorizationStatusFullAccess) [self beginWatching];
  else { Log(@"Calendar access is unavailable; allow Auto DND in Privacy & Security > Calendars, then relaunch it"); if (self.checkOnly || self.listOnly) exit(1); [NSApp terminate:nil]; }
}
- (void)changed:(NSNotification *)notification {
  (void)notification;
  [self schedule:[NSDate dateWithTimeIntervalSinceNow:1]];
}
- (void)refresh {
  if ((!self.checkOnly || self.checkShortcut) && ![self prepareShortcut]) { [self schedule:[NSDate dateWithTimeIntervalSinceNow:30]]; return; }
  NSMutableArray<EKCalendar *> *calendars = [NSMutableArray array];
  NSUInteger workCount = 0, personalCount = 0;
  NSArray<EKCalendar *> *availableCalendars = [self.store calendarsForEntityType:EKEntityTypeEvent];
  for (EKCalendar *calendar in availableCalendars) {
    if ([calendar.title isEqualToString:self.calendarName] && [calendar.source.title isEqualToString:self.calendarName]) { [calendars addObject:calendar]; workCount++; }
    else if ([calendar.source.title isEqualToString:self.personalAccount] && calendar.allowsContentModifications && !calendar.subscribed) { [calendars addObject:calendar]; personalCount++; }
  }
  if (workCount != 1 || personalCount == 0) {
    Log(@"The configured work calendar and editable personal calendars must be synced; Focus was left alone");
    if (self.checkOnly) exit(1);
    else [self schedule:[NSDate dateWithTimeIntervalSinceNow:3600]];
    return;
  }
  NSDate *now = NSDate.date;
  NSPredicate *predicate = [self.store predicateForEventsWithStartDate:now endDate:[now dateByAddingTimeInterval:86400] calendars:calendars];
  NSMutableArray<Meeting *> *meetings = [NSMutableArray array];
  NSUInteger allDayCount = 0;
  for (EKEvent *event in [self.store eventsMatchingPredicate:predicate]) {
    if (event.allDay) allDayCount++;
    if (event.allDay || event.status == EKEventStatusCanceled || !event.eventIdentifier || [event.endDate compare:now] != NSOrderedDescending) continue;
    Meeting *meeting = [[Meeting alloc] init];
    meeting.key = [NSString stringWithFormat:@"%@/%.0f", event.eventIdentifier, event.startDate.timeIntervalSince1970];
    meeting.start = event.startDate;
    meeting.end = event.endDate;
    [meetings addObject:meeting];
  }
  Meeting *action = [self.planner actionForMeetings:meetings now:now];
  if (self.checkOnly && !self.checkShortcut) {
    printf("Calendar access OK; work calendars: %lu; editable personal calendars: %lu; timed events: %lu; all-day events ignored: %lu; Focus action due: %s\n", (unsigned long)workCount, (unsigned long)personalCount, (unsigned long)meetings.count, (unsigned long)allDayCount, action ? "yes" : "no");
    [NSApp terminate:nil];
    return;
  }
  if (self.checkShortcut && !action) action = meetings.firstObject;
  if (self.checkShortcut && !action) { Log(@"No timed event is available to validate the actuator; the check was not run"); exit(2); }
  if (action) {
    // Shortcuts cannot resolve a dynamic Calendar filter reliably. Exact bounds
    // are sufficient only if they identify this selected event uniquely across
    // the entire store; the actuator independently requires exactly one match.
    NSPredicate *identityQuery = [self.store predicateForEventsWithStartDate:[action.start dateByAddingTimeInterval:-1] endDate:[action.start dateByAddingTimeInterval:1] calendars:nil];
    NSUInteger matches = 0;
    BOOL selectedFound = NO;
    for (EKEvent *event in [self.store eventsMatchingPredicate:identityQuery]) {
      if (event.allDay || event.status == EKEventStatusCanceled) continue;
      if (fabs([event.startDate timeIntervalSinceDate:action.start]) < 1 && fabs([event.endDate timeIntervalSinceDate:action.end]) < 1) {
        matches++;
        NSString *key = [NSString stringWithFormat:@"%@/%.0f", event.eventIdentifier, event.startDate.timeIntervalSince1970];
        if ([key isEqualToString:action.key]) selectedFound = YES;
      }
    }
    if (matches != 1 || !selectedFound) {
      Log(@"The selected event's time bounds are ambiguous or changed; Focus was left alone");
      if (self.checkShortcut) exit(1);
      [self schedule:[NSDate dateWithTimeIntervalSinceNow:3600]];
      return;
    }
    // Record the attempt before invoking the external actuator. A crash or a
    // manual Focus override must not turn one meeting into repeated retries.
    if (!self.checkShortcut) {
      self.planner.attempted[action.key] = @(action.end.timeIntervalSince1970);
      if (![self saveState]) { [NSApp terminate:nil]; return; }
    }
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    NSDictionary *input = @{@"start": [formatter stringFromDate:action.start], @"end": [formatter stringFromDate:action.end], @"command": self.checkShortcut ? @"check" : @"apply"};
    NSURL *inputURL = [self.stateURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:[NSString stringWithFormat:@"meeting-%@.json", NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    NSData *inputData = [NSJSONSerialization dataWithJSONObject:input options:0 error:&error];
    if (!inputData || ![inputData writeToURL:inputURL options:NSDataWritingAtomic error:&error]) { Log(@"Could not prepare meeting time; Focus was left alone"); if (self.checkShortcut) exit(1); }
    else {
      NSString *result = [RunShortcuts(@[@"run", ShortcutName, @"--input-path", inputURL.path], &error) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
      if ([result isEqualToString:@"enabled"]) { self.planner.appliedUntil = action.end; self.planner.appliedKey = action.key; Log(@"Enabled DND until the meeting block ends"); }
      else if ([result isEqualToString:@"skipped"]) Log(@"Preserved the existing Focus");
      else if (self.checkShortcut && [result isEqualToString:@"found"]) Log(@"Bundled shortcut found the selected event; Focus was left alone");
      else if (self.checkShortcut) Log([NSString stringWithFormat:@"Actuator check failed: %@; input retained for diagnosis", result ?: error.localizedDescription]);
      else Log(@"The Focus shortcut did not apply DND; this meeting will not be retried automatically");
      if (!self.checkShortcut || [result isEqualToString:@"found"]) [NSFileManager.defaultManager removeItemAtURL:inputURL error:NULL];
      if (!self.checkShortcut && ![self saveState]) { [NSApp terminate:nil]; return; }
      if (self.checkShortcut && ![result isEqualToString:@"found"]) exit(1);
    }
  }
  if (self.checkShortcut) { [NSApp terminate:nil]; return; }
  [self schedule:[self.planner nextCheckForMeetings:meetings now:now]];
}
- (void)dealloc {
  [self.timer invalidate];
  [NSNotificationCenter.defaultCenter removeObserver:self];
  [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}
@end

static Meeting *Fixture(NSString *key, double start, double end) {
  Meeting *meeting = [[Meeting alloc] init];
  meeting.key = key;
  meeting.start = [NSDate dateWithTimeIntervalSince1970:start];
  meeting.end = [NSDate dateWithTimeIntervalSince1970:end];
  return meeting;
}

static int TestPlanner(void) {
  int failures = 0;
#define CHECK(condition, message) do { if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); failures++; } } while (0)
  NSDate *now = [NSDate dateWithTimeIntervalSince1970:1000];
  Meeting *first = Fixture(@"first", 1120, 2000);
  Meeting *overlap = Fixture(@"overlap", 1900, 2500);
  Meeting *later = Fixture(@"later", 3000, 4000);
  Planner *planner = [[Planner alloc] init];
  CHECK(CurrentMeeting(@[], now) == nil, "empty calendar leaves Focus alone");
  CHECK(CurrentMeeting(@[Fixture(@"expired", 800, 1000)], now) == nil, "event end is exclusive");
  CHECK(CurrentMeeting(@[Fixture(@"future", 1121, 2000)], now) == nil, "no activation before the two-minute lead");
  CHECK(CurrentMeeting(@[later, overlap, first], now) == overlap, "overlapping meetings use the last-ending event");
  CHECK(CurrentMeeting(@[first], [NSDate dateWithTimeIntervalSince1970:1500]) == first, "wake during an ongoing meeting activates DND");
  CHECK((CurrentMeeting(@[Fixture(@"short", 1120, 1500), first], now) == first), "simultaneous starts select the later end");
  CHECK([planner actionForMeetings:@[first] now:now] == first, "a new meeting produces one action");
  planner.attempted[first.key] = @(first.end.timeIntervalSince1970);
  CHECK([planner actionForMeetings:@[first] now:now] == nil, "calendar notifications do not repeat a handled action");
  Planner *restarted = [[Planner alloc] init];
  NSData *saved = [NSPropertyListSerialization dataWithPropertyList:planner.attempted format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
  restarted.attempted = [[NSPropertyListSerialization propertyListWithData:saved options:0 format:NULL error:NULL] mutableCopy];
  CHECK([restarted actionForMeetings:@[first] now:now] == nil, "persisted attempts preserve manual override after restart");
  planner.appliedUntil = first.end;
  planner.appliedKey = first.key;
  CHECK(([planner actionForMeetings:@[first, overlap] now:now] == nil), "an active meeting assertion is not refreshed");
  CHECK([planner actionForMeetings:@[overlap] now:[NSDate dateWithTimeIntervalSince1970:2001]] == overlap, "a newly added overlap continues after the previous assertion expires");
  planner.appliedUntil = first.end;
  planner.appliedKey = first.key;
  CHECK([[planner nextCheckForMeetings:@[later] now:now] isEqualToDate:[NSDate dateWithTimeIntervalSince1970:2001]], "the owned expiry remains a wake boundary");
  CHECK([[[[Planner alloc] init] nextCheckForMeetings:@[later] now:now] isEqualToDate:[NSDate dateWithTimeIntervalSince1970:2880]], "idle helper sleeps until the next meeting lead time");
  CHECK([planner actionForMeetings:@[overlap] now:[NSDate dateWithTimeIntervalSince1970:1800]] == overlap, "removing the owned event does not retain its stale expiry");
  planner.appliedUntil = first.end;
  planner.appliedKey = first.key;
  first.end = [NSDate dateWithTimeIntervalSince1970:1700];
  CHECK(([planner actionForMeetings:@[first, overlap] now:[NSDate dateWithTimeIntervalSince1970:1800]] == overlap), "shortening the owned event does not suppress the next meeting");
  printf("Planner tests: %s\n", failures ? "FAILED" : "passed (15 cases)");
#undef CHECK
  return failures ? 1 : 0;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc == 2 && strcmp(argv[1], "--test") == 0) return TestPlanner();
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    NSURL *configURL = [NSBundle.mainBundle URLForResource:@"config" withExtension:@"json"];
    NSData *configData = configURL ? [NSData dataWithContentsOfURL:configURL] : nil;
    id config = configData ? [NSJSONSerialization JSONObjectWithData:configData options:0 error:NULL] : nil;
    if (![config isKindOfClass:NSDictionary.class] || ![config[@"workCalendar"] isKindOfClass:NSString.class] || ![config[@"personalAccount"] isKindOfClass:NSString.class]) { Log(@"The app's Nix calendar configuration is missing or invalid"); return 2; }
    [NSApplication sharedApplication];
    Agent *agent = [[Agent alloc] init];
    agent.calendarName = config[@"workCalendar"];
    agent.personalAccount = config[@"personalAccount"];
    agent.checkOnly = [arguments containsObject:@"--check"];
    agent.listOnly = [arguments containsObject:@"--list-calendars"];
    agent.checkShortcut = [arguments containsObject:@"--check-shortcut"];
    if (agent.checkShortcut) agent.checkOnly = YES;
    [agent start];
    [NSApp run];
  }
  return 0;
}
