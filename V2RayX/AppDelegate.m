//
//  AppDelegate.m
//  V2RayX
//
//  Copyright © 2016年 Cenmrev. All rights reserved.
//

#import "AppDelegate.h"
#import "GCDWebServer.h"
#import "GCDWebServerDataResponse.h"
#import "ConfigWindowController.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import "ServerProfile.h"
#import "MutableDeepCopying.h"

#define kUseAllServer -10

@interface AppDelegate () {
    GCDWebServer *webServer;
    ConfigWindowController *configWindowController;

    dispatch_queue_t taskQueue;
    dispatch_source_t dispatchPacSource;
    FSEventStreamRef fsEventStream;
    
    NSData* v2rayJSONconfig;
}

@end

@implementation AppDelegate

static AppDelegate *appDelegate;

- (NSData*)v2rayJSONconfig {
    return v2rayJSONconfig;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    
    // check helper
    if (![self installHelper:false]) {
        [[NSApplication sharedApplication] terminate:nil];// installation failed or stopped by user,
    };
    
    // initialize UI
    _statusBarItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    [_statusBarItem setMenu:_statusBarMenu];
    [_statusBarItem setHighlightMode:YES];
    _pacModeItem.tag = pacMode;
    _globalModeItem.tag = globalMode;
    _manualModeItem.tag = manualMode;

    
    // initialize variables
    NSNumber* setingVersion = [[NSUserDefaults standardUserDefaults] objectForKey:@"setingVersion"];
    if(setingVersion == nil || [setingVersion integerValue] != kV2RayXSettingVersion) {
        NSAlert *noServerAlert = [[NSAlert alloc] init];
        [noServerAlert setMessageText:@"If you are running V2RayX for the first time, ignore this message. \nSorry, unknown settings!\nAll V2RayX settings will be reset."];
        [noServerAlert runModal];
        [self writeDefaultSettings]; //explicitly write default settings to user defaults file
    }
    
    v2rayJSONconfig = [[NSData alloc] init];
    [self addObserver:self forKeyPath:@"selectedPacFileName" options:NSKeyValueObservingOptionNew context:nil];
    [self readDefaults];
    
    // create a serial queue used for NSTask operations
    taskQueue = dispatch_queue_create("cenmrev.v2rayx.nstask", DISPATCH_QUEUE_SERIAL);
    
    plistPath = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayX/cenmrev.v2rayx.v2ray-core.plist",NSHomeDirectory()];

    // prepare directory
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSString *pacDir = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayX/pac", NSHomeDirectory()];
    //create application support directory and pac directory
    if (![fileManager fileExistsAtPath:pacDir]) {
        [fileManager createDirectoryAtPath:pacDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    // Create Log Dir
    do {
        NSString* logDirName = [NSString stringWithFormat:@"cenmrev.v2rayx.log.%@",
                                [[NSUUID UUID] UUIDString]];
        logDirPath = [NSString stringWithFormat:@"%@%@", NSTemporaryDirectory(), logDirName];
    } while ([fileManager fileExistsAtPath:logDirPath]);
    [fileManager createDirectoryAtPath:logDirPath withIntermediateDirectories:YES attributes:nil error:nil];
    [fileManager createFileAtPath:[NSString stringWithFormat:@"%@/access.log", logDirPath] contents:nil attributes:nil];
    [fileManager createFileAtPath:[NSString stringWithFormat:@"%@/error.log", logDirPath] contents:nil attributes:nil];
    
    // set up pac server
    __weak typeof(self) weakSelf = self;
    //http://stackoverflow.com/questions/14556605/capturing-self-strongly-in-this-block-is-likely-to-lead-to-a-retain-cycle
    webServer = [[GCDWebServer alloc] init];
    [webServer addHandlerForMethod:@"GET" path:@"/proxy.pac" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest* request) {
        return [GCDWebServerDataResponse responseWithData:[weakSelf pacData] contentType:@"application/x-ns-proxy-autoconfig"];
    }];
    [webServer addHandlerForMethod:@"GET" path:@"/config.json" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse * _Nullable(__kindof GCDWebServerRequest * _Nonnull request) {
        return [GCDWebServerDataResponse responseWithData:[weakSelf v2rayJSONconfig] contentType:@"application/json"];
    }];
    [webServer startWithPort:webServerPort bonjourName:nil];
    
    // start proxy
    [self didChangeStatus:self];
    
    appDelegate = self;
    
    // resume the service when mac wakes up
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(didChangeStatus:) name:NSWorkspaceDidWakeNotification object:NULL];
    
}

- (BOOL)installHelper:(BOOL)force {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (!force && [fileManager fileExistsAtPath:kV2RayXHelper] && [self isSysconfVersionOK]) {
        // helper already installed
        return YES;
    }
    NSAlert *installAlert = [[NSAlert alloc] init];
    [installAlert addButtonWithTitle:@"Install"];
    [installAlert addButtonWithTitle:@"Quit"];
    [installAlert setMessageText:@"V2RayX needs to install a small tool to /Library/Application Support/V2RayX/ with administrator privileges to set system proxy quickly.\nOtherwise you need to type in the administrator password every time you change system proxy through V2RayX."];
    if ([installAlert runModal] == NSAlertFirstButtonReturn) {
        NSLog(@"start install");
        NSString *helperPath = [NSString stringWithFormat:@"%@/%@", [[NSBundle mainBundle] resourcePath], @"install_helper.sh"];
        NSLog(@"run install script: %@", helperPath);
        NSDictionary *error;
        NSString *script = [NSString stringWithFormat:@"do shell script \"bash %@\" with administrator privileges", helperPath];
        NSAppleScript *appleScript = [[NSAppleScript new] initWithSource:script];
        if ([appleScript executeAndReturnError:&error]) {
            NSLog(@"installation success");
            return YES;
        } else {
            NSLog(@"installation failure");
            //unknown failure
            return NO;
        }
    } else {
        // stopped by user
        return NO;
    }
}

- (BOOL)isSysconfVersionOK {
    NSTask *task;
    task = [[NSTask alloc] init];
    [task setLaunchPath:kV2RayXHelper];
    
    NSArray *args;
    args = [NSArray arrayWithObjects:@"-v", nil];
    [task setArguments: args];
    
    NSPipe *pipe;
    pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    
    NSFileHandle *fd;
    fd = [pipe fileHandleForReading];
    
    [task launch];
    
    NSData *data;
    data = [fd readDataToEndOfFile];
    
    NSString *str;
    str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    if (![str isEqualToString:VERSION]) {
        return NO;
    }
    return YES;
}

- (void)readDefaults {
    // just read defaults, didChangeStatus will handle invalid parameters.
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary* appStatus = nilCoalescing([defaults objectForKey:@"appStatus"], @{});
    
    proxyState = [nilCoalescing(appStatus[@"proxyState"], @(NO)) boolValue]; //turn off proxy as default
    proxyMode = [nilCoalescing(appStatus[@"proxyMode"], @(manualMode)) integerValue];
    selectedServerIndex = [nilCoalescing(appStatus[@"selectedServerIndex"], @0) integerValue];
    selectedCusServerIndex = [nilCoalescing(appStatus[@"selectedCusServerIndex"], @0) integerValue];
    _selectedRoutingSet = [nilCoalescing(appStatus[@"selectedRoutingSet"], @0) integerValue];
    useMultipleServer = [nilCoalescing(appStatus[@"useMultipleServer"], @(NO)) boolValue];
    useCusProfile = [nilCoalescing(appStatus[@"useCusProfile"], @(NO)) boolValue];
    self.selectedPacFileName = nilCoalescing(appStatus[@"selectedPacFileName"], @"pac.js");
    
    logLevel = nilCoalescing([defaults objectForKey:@"logLevel"], @"none");
    localPort = [nilCoalescing([defaults objectForKey:@"localPort"], @1081) integerValue]; //use 1081 as default local port
    httpPort = [nilCoalescing([defaults objectForKey:@"httpPort"], @8001) integerValue]; //use 8001 as default local http port
    udpSupport = [nilCoalescing([defaults objectForKey:@"udpSupport"], @(NO)) boolValue];// do not support udp as default
    shareOverLan = [nilCoalescing([defaults objectForKey:@"shareOverLan"],@(NO)) boolValue];
    dnsString = nilCoalescing([defaults objectForKey:@"dnsString"], @"localhost");
    
    profiles = [[NSMutableArray alloc] init];
    if ([[defaults objectForKey:@"profiles"] isKindOfClass:[NSArray class]] && [[defaults objectForKey:@"profiles"] count] > 0) {
        for (NSDictionary* aProfile in [defaults objectForKey:@"profiles"]) {
            [profiles addObject:aProfile];
        }
    }
    
    cusProfiles = [[NSMutableArray alloc] init];
    if ([[defaults objectForKey:@"cusProfiles"] isKindOfClass:[NSArray class]] && [[defaults objectForKey:@"cusProfiles"] count] > 0) {
        for (id cusPorfile in [defaults objectForKey:@"cusProfiles"]) {
            if ([cusPorfile isKindOfClass:[NSString class]]) {
                [cusProfiles addObject:cusPorfile];
            }
        }
    }
    
    _routingRuleSets = [@[ROUTING_GLOBAL, ROUTING_DIRECT, ROUTING_BYPASSCN_PRIVATE_APPLE] mutableDeepCopy];
    if ([[defaults objectForKey:@"routingRuleSets"] isKindOfClass:[NSArray class]] && [[defaults objectForKey:@"routingRuleSets"] count] > 0) {
        _routingRuleSets = [[defaults objectForKey:@"routingRuleSets"] mutableDeepCopy];
    }
}

- (void) writeDefaultSettings {
    NSDictionary *defaultSettings =
    @{
      @"setingVersion": [NSNumber numberWithInteger:kV2RayXSettingVersion],
      @"appStatus": @{
              @"proxyState": [NSNumber numberWithBool:NO],
              @"proxyMode": @(manualMode),
              @"selectedServerIndex": [NSNumber numberWithInteger:0],
              @"selectedCusServerIndex": [NSNumber numberWithInteger:-1],
              @"useCusProfile": @NO,
              @"selectedRoutingSet":@0,
              @"useMultipleServer": @NO,
              @"selectedPacFileName": @"pac.js"
              },
      @"logLevel": @"none",
      @"localPort": [NSNumber numberWithInteger:1081],
      @"httpPort": [NSNumber numberWithInteger:8001],
      @"udpSupport": [NSNumber numberWithBool:NO],
      @"shareOverLan": [NSNumber numberWithBool:NO],
      @"dnsString": @"localhost",
      @"profiles":@[
              [[[ServerProfile alloc] init] outboundProfile]
              ],
      @"cusProfiles": @[],
      @"routingRuleSets": @[ROUTING_DIRECT, ROUTING_GLOBAL, ROUTING_BYPASSCN_PRIVATE_APPLE],
      };
    for (NSString* key in [defaultSettings allKeys]) {
        [[NSUserDefaults standardUserDefaults] setObject:defaultSettings[key] forKey:key];
    }
}

- (NSData*) pacData {
    return [NSData dataWithContentsOfFile:[NSString stringWithFormat:@"%@/Library/Application Support/V2RayX/pac/%@",NSHomeDirectory(), selectedPacFileName]];
}

- (void)saveAppStatus {
    NSDictionary* status = @{
                             @"proxyState": @(proxyState),
                             @"proxyMode": @(proxyMode),
                             @"selectedServerIndex": @(selectedServerIndex),
                             @"selectedCusServerIndex": @(selectedCusServerIndex),
                             @"useCusProfile": @(useCusProfile),
                             @"selectedRoutingSet":@(_selectedRoutingSet),
                             @"useMultipleServer": @(useMultipleServer),
                             @"selectedPacFileName": selectedPacFileName
                             };
    [[NSUserDefaults standardUserDefaults] setObject:status forKey:@"appStatus"];
}

- (void)saveConfigInfo {
    dispatch_async(taskQueue, ^{
        NSDictionary *settings =
        @{
          @"setingVersion": [NSNumber numberWithInteger:kV2RayXSettingVersion],
          @"logLevel": self.logLevel,
          @"localPort": @(self.localPort),
          @"httpPort": @(self.httpPort),
          @"udpSupport": @(self.udpSupport),
          @"shareOverLan": @(self.shareOverLan),
          @"dnsString": self.dnsString,
          @"profiles":self.profiles,
          @"cusProfiles": self.cusProfiles,
          @"routingRuleSets": self.routingRuleSets
          };
        for (NSString* key in [settings allKeys]) {
            [[NSUserDefaults standardUserDefaults] setObject:settings[key] forKey:key];
        }
        NSLog(@"Settings saved.");
    });
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    //stop monitor pac
    if (dispatchPacSource) {
        dispatch_source_cancel(dispatchPacSource);
    }
    //unload v2ray
    runCommandLine(@"/bin/launchctl", @[@"unload", plistPath]);
    NSLog(@"V2RayX quiting, V2Ray core unloaded.");
    //remove log file
    [[NSFileManager defaultManager] removeItemAtPath:logDirPath error:nil];
    //save application status
    [self saveAppStatus];
    //turn off proxy
    if (proxyState && proxyMode != manualMode) {
        [self restoreSystemProxy];//restore system proxy
    }
}

- (IBAction)showHelp:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://www.v2ray.com"]];
}

// v2rayx status part

// back up system proxy state when V2RayX starts to take control of
// macOS's proxy settings, which means:
// 1. proxy status is On and not changed, but proxy mode changes from manual to non-manual => happens when didChangeMode
// or 2. proxy status was off and now is turned on, and the proxy mode is non-manual => happens when didChangeStatus
// restore system proxy state when V2RayX stops taking control of macOS's proxy settings, which means:
// 1. proxy state is On and not changed, but proxy mode changes from non-manual mode to manual mode => happens when didChangeMode
// or 2. proxy state was on and now is turned off, and the proxy mode is non-manual => happens when didChangeStatus

-(void)backupSystemProxy {
    SCPreferencesRef prefRef = SCPreferencesCreate(nil, CFSTR("V2RayX"), nil);
    NSDictionary* sets = (__bridge NSDictionary *)SCPreferencesGetValue(prefRef, kSCPrefNetworkServices);
    [sets writeToURL:[NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/Library/Application Support/V2RayX/system_proxy_backup.plist",NSHomeDirectory()]] atomically:NO];
}

-(void)restoreSystemProxy {
    dispatch_async(taskQueue, ^{
        runCommandLine(kV2RayXHelper,@[@"restore"]);
    });
}

- (IBAction)didChangeStatus:(id)sender {
    NSInteger previousStatus = proxyState;
    // sender can be
    // 1. self, when app is launched
    // 2. menuitem, when a user click on an item
    // 3. configwindow controller
    if (sender == _enableV2rayItem) {
        proxyState = !proxyState;
    }
    // make sure current status parameter is valid
    selectedServerIndex = MIN((NSInteger)profiles.count - 1, selectedServerIndex);
    selectedCusServerIndex = MIN((NSInteger)cusProfiles.count - 1, selectedCusServerIndex );
    _selectedRoutingSet = MIN((NSInteger)_routingRuleSets.count - 1, _selectedRoutingSet);
    
    NSLog(@"%ld, %ld", selectedServerIndex, selectedCusServerIndex);
    if (selectedServerIndex == -1 && selectedCusServerIndex == -1) {
        proxyState = false;
    } else if (selectedCusServerIndex == -1) {
        useCusProfile = false;
    } else if (selectedServerIndex == -1) {
        useCusProfile = true;
    }
    if (proxyMode != manualMode) {
        if (previousStatus == false && proxyState == true) {
            [self backupSystemProxy];
        } else if (previousStatus == true && proxyState == false ) {
            [self restoreSystemProxy];
        }
    }
    [self coreConfigDidChange:self];
    if (proxyState == true) {
        [self toggleCore];
        [self updateSystemProxy];
    } else {
        [self unloadV2ray];
    }
    [self updateMenus];
    [self updatePacMenuList];
}

- (IBAction)didChangeMode:(id)sender {
    if (proxyState == true && proxyMode == manualMode && [sender tag] != manualMode) {
        [self backupSystemProxy];
    }
    if (proxyState == true && proxyMode != manualMode && [sender tag] == manualMode) {
        [self restoreSystemProxy];
    }
    proxyMode = [sender tag];
    [self updateMenus];
    if (sender == _pacModeItem) {
        [self updatePacMenuList];
    }
    if (proxyState == true) {
        [self updateSystemProxy]; // need rewrite
    }
}

- (void)updateMenus {
    if (proxyState) {
        [_v2rayStatusItem setTitle:@"v2ray-core: loaded"];
        [_enableV2rayItem setTitle:@"Unload core"];
        NSImage *icon = [NSImage imageNamed:@"statusBarIcon"];
        [icon setTemplate:YES];
        [_statusBarItem setImage:icon];
    } else {
        [_v2rayStatusItem setTitle:@"v2ray-core: unloaded"];
        [_enableV2rayItem setTitle:@"Load core"];
        [_statusBarItem setImage:[NSImage imageNamed:@"statusBarIcon_disabled"]];
    }
    [_pacModeItem setState:proxyMode == pacMode];
    [_manualModeItem setState:proxyMode == manualMode];
    [_globalModeItem setState:proxyMode == globalMode];
}

- (void)updatePacMenuList {
    NSLog(@"updatePacMenuList");
    [_pacListMenu removeAllItems];
    NSString *pacDir = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayX/pac", NSHomeDirectory()];
    
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray *allPath =[manager subpathsAtPath:pacDir];
    int i = 0;
    for (NSString *subPath in allPath) {
        NSString *extString = [subPath pathExtension];
        if (![extString  isEqual: @"js"]){
            continue;
        }
        NSString *itemTitle = subPath;
        NSMenuItem *newItem = [[NSMenuItem alloc] initWithTitle:itemTitle action:@selector(switchPac:) keyEquivalent:@""];
        newItem.state = [itemTitle isEqualToString:selectedPacFileName];
        [newItem setTag:i];
        [_pacListMenu addItem:newItem];
        i++;
    }
    [_pacListMenu addItem:[NSMenuItem separatorItem]];
    [_pacListMenu addItem:_editPacMenuItem];
}

- (IBAction)editPac:(id)sender {
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/Library/Application Support/V2RayX/pac/%@",NSHomeDirectory(), selectedPacFileName]]]];
}

- (IBAction)resetPac:(id)sender {
    NSAlert *resetAlert = [[NSAlert alloc] init];
    [resetAlert setMessageText:@"The pac file will be reset to the original one coming with V2RayX. Are you sure to proceed?"];
    [resetAlert addButtonWithTitle:@"Yes"];
    [resetAlert addButtonWithTitle:@"Cancel"];
    NSModalResponse response = [resetAlert runModal];
    if(response == NSAlertFirstButtonReturn) {
        NSString* simplePac = [[NSBundle mainBundle] pathForResource:@"simple" ofType:@"pac"];
        NSString* pacPath = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayX/pac/%@",NSHomeDirectory(), selectedPacFileName];
        if ([[NSFileManager defaultManager] isWritableFileAtPath:pacPath]) {
            [[NSData dataWithContentsOfFile:simplePac] writeToFile:pacPath atomically:YES];
        } else {
            NSAlert* writePacAlert = [[NSAlert alloc] init];
            [writePacAlert setMessageText:[NSString stringWithFormat:@"%@ is not writable!", pacPath]];
            [writePacAlert runModal];
        }
    }
}

- (void)switchPac:(id)sender {
    [self setSelectedPacFileName:[sender title]];
    [self didChangeMode:_pacModeItem];
}

-(void)updateSystemProxy {
    NSArray *arguments;
    if (proxyState) {
        if (proxyMode == pacMode) { // pac mode
            // close system proxy first to refresh pac file
            dispatch_async(taskQueue, ^{
                runCommandLine(kV2RayXHelper, @[@"off"]);
            });
            arguments = @[@"auto"];
        } else {
            if (proxyMode == manualMode) { // manualMode mode
                arguments = @[@"-v"]; // do nothing
            } else { // global mode
                if(useMultipleServer || !useCusProfile) {
                    arguments = @[@"global", [NSString stringWithFormat:@"%ld", localPort], [NSString stringWithFormat:@"%ld", httpPort]];
                } else {
                    NSInteger cusHttpPort = 0;
                    NSInteger cusSocksPort = 0;
                    NSDictionary* cusJson = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:cusProfiles[selectedCusServerIndex]] options:0 error:nil];
                    if (cusJson[@"inboundDetour"] != nil && [cusJson[@"inboundDetour"] isKindOfClass:[NSArray class]]) {
                        for (NSDictionary *inboundDetour in cusJson[@"inboundDetour"]) {
                            if ([inboundDetour[@"protocol"] isEqualToString:@"http"]) {
                                cusHttpPort = [inboundDetour[@"port"] integerValue];
                            }
                            if ([inboundDetour[@"protocol"] isEqualToString:@"socks"]) {
                                cusSocksPort = [inboundDetour[@"port"] integerValue];
                            }
                        }
                    }
                    if ([cusJson[@"inbound"][@"protocol"] isEqualToString:@"http"]) {
                        cusHttpPort = [cusJson[@"inbound"][@"port"] integerValue];
                    }
                    if ([cusJson[@"inbound"][@"protocol"] isEqualToString:@"socks"]) {
                        cusSocksPort = [cusJson[@"inbound"][@"port"] integerValue];
                    }
                    NSLog(@"socks: %ld, http: %ld", cusSocksPort, cusHttpPort);
                    arguments = @[@"global", [NSString stringWithFormat:@"%ld", cusSocksPort], [NSString stringWithFormat:@"%ld", cusHttpPort]];
                }
            }
        }
        dispatch_async(taskQueue, ^{
            runCommandLine(kV2RayXHelper,arguments);
        });
    } else {
        ; // do nothing
    }
    NSLog(@"system proxy state:%@,%ld",proxyState?@"on":@"off", (long)proxyMode);
}


// core part

- (void)updateRuleSetMenuList {
    [_ruleSetMenuList removeAllItems];
    NSInteger i = 0;
    for (NSDictionary* rule in _routingRuleSets) {
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:rule[@"name"] action:@selector(switchRoutingSet:) keyEquivalent:@""];
        item.tag = i;
        item.state = i == _selectedRoutingSet;
        [_ruleSetMenuList addItem:item];
        i += 1;
    }
}

- (void)updateServerMenuList {
    [_serverListMenu removeAllItems];
    if ([profiles count] == 0 && [cusProfiles count] == 0) {
        [_serverListMenu addItem:[[NSMenuItem alloc] initWithTitle:@"no available servers, please add server profiles through config window." action:nil keyEquivalent:@""]];
    } else {
        int i = 0;
        for (NSDictionary *p in profiles) {
            NSString *itemTitle = [NSString stringWithFormat:@"%@:%@",p[@"protocol"], p[@"tag"]];
            NSMenuItem *newItem = [[NSMenuItem alloc] initWithTitle:itemTitle action:@selector(switchServer:) keyEquivalent:@""];
            [newItem setTag:i];
            if (useMultipleServer){
                newItem.state = 0;
            } else {
                newItem.state = (!useCusProfile && i == selectedServerIndex);
            }
            [_serverListMenu addItem:newItem];
            i += 1;
        }
        if([profiles count] > 1) {
            NSMenuItem *newItem = [[NSMenuItem alloc] initWithTitle:@"Use All" action:@selector(switchServer:) keyEquivalent:@""];
            [newItem setTag:kUseAllServer];
            newItem.state = useMultipleServer;
            [_serverListMenu addItem:newItem];
        }
        [_serverListMenu addItem:[NSMenuItem separatorItem]];
        for (NSString* cusProfilePath in cusProfiles) {
            NSString *itemTitle = [[cusProfilePath componentsSeparatedByString:@"/"] lastObject];
            NSMenuItem *newItem = [[NSMenuItem alloc] initWithTitle:itemTitle action:@selector(switchServer:) keyEquivalent:@""];
            [newItem setTag:i];
            if (useMultipleServer){
                newItem.state = 0;
            } else {
                newItem.state = (useCusProfile && i - [profiles count] == selectedCusServerIndex)? 1 : 0;
            }
            [_serverListMenu addItem:newItem];
            i += 1;
        }
    }
}


- (IBAction)coreConfigDidChange:(id)sender {
    if (proxyState == true) {
        if (!useMultipleServer && useCusProfile) {
            v2rayJSONconfig = [NSData dataWithContentsOfFile:cusProfiles[selectedCusServerIndex]];
        } else {
            NSDictionary *fullConfig = [self generateConfigFile];
            v2rayJSONconfig = [NSJSONSerialization dataWithJSONObject:fullConfig options:NSJSONWritingPrettyPrinted error:nil];
        }
        [self generateLaunchdPlist:plistPath];
        [self toggleCore];
    }
    [self updateServerMenuList];
    [self updateRuleSetMenuList];
}

-(void)toggleCore {
    dispatch_async(taskQueue, ^{
        runCommandLine(@"/bin/launchctl",  @[@"unload", self->plistPath]);
        runCommandLine(@"/bin/launchctl",  @[@"load", self->plistPath]);
    });
}

- (IBAction)showConfigWindow:(id)sender {
    if (configWindowController) {
        [configWindowController close];
    }
    configWindowController =[[ConfigWindowController alloc] initWithWindowNibName:@"ConfigWindow"];
    configWindowController.appDelegate = self;
    [configWindowController showWindow:self];
    [NSApp activateIgnoringOtherApps:YES];
    [configWindowController.window makeKeyAndOrderFront:nil];
}

-(IBAction)switchRoutingSet:(id)sender {
    _selectedRoutingSet = [sender tag];
    [self coreConfigDidChange:self];
}

- (void)switchServer:(id)sender {
    if ([sender tag] >= 0 && [sender tag] < [profiles count]) {
        [self setUseMultipleServer:NO];
        [self setUseCusProfile:NO];
        [self setSelectedServerIndex:[sender tag]];
    } else if ([sender tag] >= [profiles count] && [sender tag] < [profiles count] + [cusProfiles count]) {
        [self setUseMultipleServer:NO];
        [self setUseCusProfile:YES];
        [self setSelectedCusServerIndex:[sender tag] - [profiles count]];
    } else if ([sender tag] == kUseAllServer) {
        [self setUseMultipleServer:YES];
    }
    NSLog(@"use cus pro:%hhd, select %ld, select cus %ld", useCusProfile, (long)selectedServerIndex, selectedCusServerIndex);
    [self coreConfigDidChange:self];
}

-(void)unloadV2ray {
    dispatch_async(taskQueue, ^{
        runCommandLine(@"/bin/launchctl", @[@"unload", self->plistPath]);
        NSLog(@"V2Ray core unloaded.");
    });
}

- (NSDictionary*)generateConfigFile {
    NSMutableDictionary* fullConfig = [NSMutableDictionary dictionaryWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"config-sample_new" ofType:@"plist"]];
    fullConfig[@"log"] = @{
                           @"access": [NSString stringWithFormat:@"%@/access.log", logDirPath],
                           @"error": [NSString stringWithFormat:@"%@/error.log", logDirPath],
                           @"loglevel": logLevel
                           };
    fullConfig[@"inbounds"][0][@"port"] = @(localPort);
    fullConfig[@"inbounds"][0][@"listen"] = shareOverLan ? @"0.0.0.0" : @"127.0.0.1";
    fullConfig[@"inbounds"][0][@"settings"][@"udp"] = [NSNumber numberWithBool:udpSupport];
    fullConfig[@"inbounds"][1][@"port"] = @(httpPort);
    fullConfig[@"inbounds"][1][@"listen"] = shareOverLan ? @"0.0.0.0" : @"127.0.0.1";
    
    NSArray* dnsArray = [dnsString componentsSeparatedByString:@","];
    if ([dnsArray count] > 0) {
        fullConfig[@"dns"][@"servers"] = dnsArray;
    } else {
        fullConfig[@"dns"][@"servers"] = @[@"localhost"];
    }
//    if (proxyMode == rules) {
    fullConfig[@"routing"] = [_routingRuleSets[_selectedRoutingSet] mutableDeepCopy];
    if (!useMultipleServer) {
        // replace tag main with current selected outbound tag
        NSString* currentMainTag = profiles[selectedServerIndex][@"tag"];
        for (NSMutableDictionary* aRule in fullConfig[@"routing"][@"rules"]) {
            if ([@"main" isEqualToString:aRule[@"outboundTag"]]) {
                aRule[@"outboundTag"] = currentMainTag;
            }
        }
    } else {
        // replace outbound tag main with balancetag
        for (NSMutableDictionary* aRule in fullConfig[@"routing"][@"rules"]) {
            if ([@"main" isEqualToString:aRule[@"outboundTag"]]) {
                [aRule removeObjectForKey:@"outboundTag"];
                [aRule setObject:@"balance" forKey:@"balancerTag"];
            }
        }
        
    }
    // deal with outbound
    NSMutableDictionary* configOutboundDict = [[NSMutableDictionary alloc] init];
    NSMutableDictionary* allOutbounds = [[NSMutableDictionary alloc] init]; // make sure tag is unique
    for (NSDictionary* outbound in profiles) {
        allOutbounds[outbound[@"tag"]] = [outbound mutableDeepCopy];
    }
    NSArray* allProxyTags = allOutbounds.allKeys;
    allOutbounds[@"direct"] = OUTBOUND_DIRECT;
    allOutbounds[@"decline"] = OUTBOUND_DECLINE;
//    NSLog(@"%@", allOutbounds);
    BOOL usebalance = false;
    for (NSDictionary* rule in fullConfig[@"routing"][@"rules"]) {
        if (rule[@"balancerTag"] && !rule[@"outboundTag"]) {
            // if any rule uses balancer, stop the loop and add a balancer to the routing part
            usebalance = true;
            break;
        } else {
            // pick up all mentioned outbounds in the routing rule set
            if (allOutbounds[rule[@"outboundTag"]]) {
                configOutboundDict[rule[@"outboundTag"]] = allOutbounds[rule[@"outboundTag"]];
            }
        }
    }
    if (usebalance) {
        // if balancer is used, add all outbounds into config file, and add all tags to the balancer selector
        fullConfig[@"routing"][@"balancers"] = @[@{
                                                     @"tag":@"balance",
                                                     @"selector": allProxyTags
                                                     }];
        fullConfig[@"outbounds"] = allOutbounds.allValues;
    } else {
        // otherwise, we convert all collected outbounds into an array
        fullConfig[@"outbounds"] = configOutboundDict.allValues;
    }
    return fullConfig;

}

-(void)generateLaunchdPlist:(NSString*)path {
    NSString* v2rayPath = [self getV2rayPath];
    NSLog(@"use core: %@", v2rayPath);
    NSString *configPath = [NSString stringWithFormat:@"http://127.0.0.1:%d/config.json", webServerPort];
    NSDictionary *runPlistDic = [[NSDictionary alloc] initWithObjects:@[@"v2rayproject.v2rayx.v2ray-core", @[v2rayPath, @"-config", configPath], [NSNumber numberWithBool:YES]] forKeys:@[@"Label", @"ProgramArguments", @"RunAtLoad"]];
    [runPlistDic writeToFile:path atomically:NO];
}

-(NSString*)getV2rayPath {
    NSString* defaultV2ray = [NSString stringWithFormat:@"%@/v2ray", [[NSBundle mainBundle] resourcePath]];
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSString* cusV2ray = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayX/v2ray-core/v2ray",NSHomeDirectory()];
    for (NSString* binary in @[@"v2ray", @"v2ctl"]) {
        NSString* fullpath = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayX/v2ray-core/%@",NSHomeDirectory(), binary];
        BOOL isDir = YES;
        if (![fileManager fileExistsAtPath:fullpath isDirectory:&isDir] || isDir || ![fileManager setAttributes:@{NSFilePosixPermissions: [NSNumber numberWithShort:0777]} ofItemAtPath:fullpath error:nil]) {
            return defaultV2ray;
        }
    }
    for (NSString* data in @[@"geoip.dat", @"geosite.dat"]) {
        NSString* fullpath = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayX/v2ray-core/%@",NSHomeDirectory(), data];
        BOOL isDir = YES;
        if (![fileManager fileExistsAtPath:fullpath isDirectory:&isDir] || isDir ) {
            return defaultV2ray;
        }
    }
    return cusV2ray;
    
}

- (IBAction)authorizeV2sys:(id)sender {
    [self installHelper:true];
}

- (IBAction)viewLog:(id)sender {
    if (!useCusProfile) {
        [[NSWorkspace sharedWorkspace] openFile:logDirPath];
    } else {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:[NSString stringWithFormat:@"Check %@.", cusProfiles[selectedCusServerIndex]]];
        [alert runModal];
    }
}

- (IBAction)copyExportCmd:(id)sender {
    if (!useCusProfile) {
        [[NSPasteboard generalPasteboard] clearContents];
        NSString* command = [NSString stringWithFormat:@"export http_proxy=\"http://127.0.0.1:%ld\"; export HTTP_PROXY=\"http://127.0.0.1:%ld\"; export https_proxy=\"http://127.0.0.1:%ld\"; export HTTPS_PROXY=\"http://127.0.0.1:%ld\"", httpPort, httpPort, httpPort, httpPort];
        [[NSPasteboard generalPasteboard] setString:command forType:NSStringPboardType];
    } else {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:[NSString stringWithFormat:@"Check %@.", cusProfiles[selectedCusServerIndex]]];
        [alert runModal];
    }
}

- (IBAction)viewConfigJson:(NSMenuItem *)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/config.json", webServerPort]]];
}

int runCommandLine(NSString* launchPath, NSArray* arguments) {
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:launchPath];
    [task setArguments:arguments];
    NSPipe *stdoutpipe = [NSPipe pipe];
    [task setStandardOutput:stdoutpipe];
    NSPipe *stderrpipe = [NSPipe pipe];
    [task setStandardError:stderrpipe];
    NSFileHandle *file;
    file = [stdoutpipe fileHandleForReading];
    [task launch];
    NSData *data;
    data = [file readDataToEndOfFile];
    NSString *string;
    string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (string.length > 0) {
        NSLog(@"%@", string);
    }
    file = [stderrpipe fileHandleForReading];
    data = [file readDataToEndOfFile];
    string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (string.length > 0) {
        NSLog(@"%@", string);
    }
    [task waitUntilExit];
    return task.terminationStatus;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([@"selectedPacFileName" isEqualToString:keyPath]) {
        NSLog(@"pac file is switched to %@", selectedPacFileName);
        if (dispatchPacSource) { //stop monitor previous pac
            dispatch_source_cancel(dispatchPacSource);
        }
        if (selectedPacFileName == nil || selectedPacFileName.length == 0) {
            return;
        }
        NSString* pacFullPath = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayX/pac/%@",NSHomeDirectory(), selectedPacFileName];
        if (![[NSFileManager defaultManager] fileExistsAtPath:pacFullPath]) {
            NSString* simplePac = [[NSBundle mainBundle] pathForResource:@"simple" ofType:@"pac"];
            [[NSFileManager defaultManager] copyItemAtPath:simplePac toPath:pacFullPath error:nil];
        }
        //https://randexdev.com/2012/03/how-to-detect-directory-changes-using-gcd/
        int fildes = open([pacFullPath cStringUsingEncoding:NSUTF8StringEncoding], O_RDONLY);
        dispatchPacSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fildes, DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
        dispatch_source_set_event_handler(dispatchPacSource, ^{
            NSLog(@"pac file changed");
            if (self.proxyMode == pacMode && self.proxyState == true) {
                [appDelegate updateSystemProxy];
                NSLog(@"refreshed system pacfile.");
            }
        });
        dispatch_resume(dispatchPacSource);
    }
}

@synthesize logDirPath;

@synthesize proxyState;
@synthesize proxyMode;
@synthesize localPort;
@synthesize httpPort;
@synthesize udpSupport;
@synthesize shareOverLan;
@synthesize selectedServerIndex;
@synthesize selectedPacFileName;
@synthesize dnsString;
@synthesize profiles;
@synthesize logLevel;
@synthesize cusProfiles;
@synthesize useCusProfile;
@synthesize selectedCusServerIndex;
@synthesize useMultipleServer;
@end
