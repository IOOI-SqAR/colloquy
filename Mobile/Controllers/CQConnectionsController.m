#import "CQConnectionsController.h"

#import "CQAlertView.h"
#import "CQAnalyticsController.h"
#import "CQBouncerSettings.h"
#import "CQBouncerConnection.h"
#import "CQBouncerCreationViewController.h"
#import "CQBouncerEditViewController.h"
#import "CQChatController.h"
#import "CQChatRoomController.h"
#import "CQColloquyApplication.h"
#import "CQConnectionsNavigationController.h"
#import "CQConnectionCreationViewController.h"
#import "CQConnectionEditViewController.h"
#import "CQConnectionsViewController.h"
#import "CQKeychain.h"

#import <ChatCore/MVChatConnection.h>
#import <ChatCore/MVChatRoom.h>

NSString *CQConnectionsControllerAddedConnectionNotification = @"CQConnectionsControllerAddedConnectionNotification";
NSString *CQConnectionsControllerChangedConnectionNotification = @"CQConnectionsControllerChangedConnectionNotification";
NSString *CQConnectionsControllerRemovedConnectionNotification = @"CQConnectionsControllerRemovedConnectionNotification";
NSString *CQConnectionsControllerMovedConnectionNotification = @"CQConnectionsControllerMovedConnectionNotification";
NSString *CQConnectionsControllerAddedBouncerSettingsNotification = @"CQConnectionsControllerAddedBouncerSettingsNotification";
NSString *CQConnectionsControllerRemovedBouncerSettingsNotification = @"CQConnectionsControllerRemovedBouncerSettingsNotification";

#if ENABLE(SECRETS)
typedef void (*IOServiceInterestCallback)(void *context, mach_port_t service, uint32_t messageType, void *messageArgument);

mach_port_t IORegisterForSystemPower(void *context, void *notificationPort, IOServiceInterestCallback callback, mach_port_t *notifier);
CFRunLoopSourceRef IONotificationPortGetRunLoopSource(void *notify);
int IOAllowPowerChange(mach_port_t kernelPort, long notification);
int IOCancelPowerChange(mach_port_t kernelPort, long notification);

#define kIOMessageSystemWillSleep 0xe0000280
#define kIOMessageCanSystemSleep 0xe0000270

static mach_port_t rootPowerDomainPort;
#endif

@interface CQConnectionsController (CQConnectionsControllerPrivate)
- (void) _loadConnectionList;
#if ENABLE(SECRETS)
- (void) _powerStateMessageReceived:(natural_t) messageType withArgument:(long) messageArgument;
#endif
@end

#pragma mark -

#if ENABLE(SECRETS)
static void powerStateChange(void *context, mach_port_t service, natural_t messageType, void *messageArgument) {       
	CQConnectionsController *self = context;
	[self _powerStateMessageReceived:messageType withArgument:(long)messageArgument];
}
#endif

#pragma mark -

#define CannotConnectToBouncerConnectionTag 1
#define CannotConnectToBouncerTag 2
#define HelpAlertTag 3

#define ChannelKeyTextFieldTag 4
#define NickservPasswordTextFieldTag 5

@implementation CQConnectionsController
+ (void) userDefaultsChanged {
	[UIApplication sharedApplication].idleTimerDisabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"CQIdleTimerDisabled"];
}

+ (void) initialize {
	static BOOL userDefaultsInitialized;

	if (userDefaultsInitialized)
		return;

	userDefaultsInitialized = YES;

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(userDefaultsChanged) name:NSUserDefaultsDidChangeNotification object:nil];

	[self userDefaultsChanged];
}

+ (CQConnectionsController *) defaultController {
	static BOOL creatingSharedInstance = NO;
	static CQConnectionsController *sharedInstance = nil;

	if (!sharedInstance && !creatingSharedInstance) {
		creatingSharedInstance = YES;
		sharedInstance = [[self alloc] init];
	}

	return sharedInstance;
}

#pragma mark -

- (id) init {
	if (!(self = [super init]))
		return nil;

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_applicationDidReceiveMemoryWarning) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_applicationWillTerminate) name:UIApplicationWillTerminateNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_willConnect:) name:MVChatConnectionWillConnectNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_didConnect:) name:MVChatConnectionDidConnectNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_didDisconnect:) name:MVChatConnectionDidDisconnectNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_didNotConnect:) name:MVChatConnectionDidNotConnectNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_errorOccurred:) name:MVChatConnectionErrorNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_deviceTokenRecieved:) name:CQColloquyApplicationDidRecieveDeviceTokenNotification object:nil];

#if TARGET_IPHONE_SIMULATOR
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_gotRawConnectionMessage:) name:MVChatConnectionGotRawMessageNotification object:nil];
#endif

#if ENABLE(SECRETS)
	mach_port_t powerNotifier = 0;
	void *notificationPort = NULL;
	rootPowerDomainPort = IORegisterForSystemPower(self, &notificationPort, powerStateChange, &powerNotifier);

	CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(notificationPort), kCFRunLoopCommonModes);
#endif

	_connectionsNavigationController = [[CQConnectionsNavigationController alloc] init];

	_connections = [[NSMutableSet alloc] initWithCapacity:10];
	_bouncers = [[NSMutableArray alloc] initWithCapacity:2];
	_directConnections = [[NSMutableArray alloc] initWithCapacity:5];
	_bouncerConnections = [[NSMutableSet alloc] initWithCapacity:2];
	_bouncerChatConnections = [[NSMutableDictionary alloc] initWithCapacity:2];

	[self _loadConnectionList];

	return self;
}

- (void) dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];

	[_connectionsNavigationController release];
	[_connections release];
	[_directConnections release];
	[_bouncerConnections release];
	[_bouncerChatConnections release];

	[super dealloc];
}

#pragma mark -

- (BOOL) handleOpenURL:(NSURL *) url {
	if ((![url.scheme isCaseInsensitiveEqualToString:@"irc"] && ![url.scheme isCaseInsensitiveEqualToString:@"ircs"]) || !url.host.length)
		return NO;

	NSString *target = @"";
	if (url.fragment.length) target = [@"#" stringByAppendingString:[url.fragment stringByDecodingIllegalURLCharacters]];
	else if (url.path.length > 1) target = [[url.path substringFromIndex:1] stringByDecodingIllegalURLCharacters];

	NSArray *possibleConnections = [self connectionsForServerAddress:url.host];

	for (MVChatConnection *connection in possibleConnections) {
		if (url.user.length && (![url.user isEqualToString:connection.preferredNickname] || ![url.user isEqualToString:connection.nickname]))
			continue;
		if ([url.port unsignedShortValue] && [url.port unsignedShortValue] != connection.serverPort)
			continue;

		[connection connectAppropriately];

		if (target.length) {
			[[CQChatController defaultController] showChatControllerWhenAvailableForRoomNamed:target andConnection:connection];
			[connection joinChatRoomNamed:target];
		} else [[CQColloquyApplication sharedApplication] showConnections:nil];

		return YES;
	}

	if (url.user.length) {
		MVChatConnection *connection = [[MVChatConnection alloc] initWithURL:url];

		[self addConnection:connection];

		[connection connect];

		if (target.length) {
			[[CQChatController defaultController] showChatControllerWhenAvailableForRoomNamed:target andConnection:connection];
			[connection joinChatRoomNamed:target];
		} else [[CQColloquyApplication sharedApplication] showConnections:nil];

		[connection release];

		return YES;
	}

	[self showConnectionCreationViewForURL:url];

	return YES;
}

#pragma mark -

- (void) showNewConnectionPrompt:(id) sender {
	UIActionSheet *sheet = [[UIActionSheet alloc] init];
	sheet.delegate = self;
	sheet.tag = 1;

	[sheet addButtonWithTitle:NSLocalizedString(@"IRC Connection", @"IRC Connection button title")];
	[sheet addButtonWithTitle:NSLocalizedString(@"Colloquy Bouncer", @"Colloquy Bouncer button title")];

	sheet.cancelButtonIndex = [sheet addButtonWithTitle:NSLocalizedString(@"Cancel", @"Cancel button title")];

	[[CQColloquyApplication sharedApplication] showActionSheet:sheet forSender:sender animated:YES];

	[sheet release];	
}

- (void) showBouncerCreationView:(id) sender {
	CQBouncerCreationViewController *bouncerCreationViewController = [[CQBouncerCreationViewController alloc] init];
	[[CQColloquyApplication sharedApplication] presentModalViewController:bouncerCreationViewController animated:YES];
	[bouncerCreationViewController release];
}

- (void) showConnectionCreationView:(id) sender {
	[self showConnectionCreationViewForURL:nil];
}

- (void) showConnectionCreationViewForURL:(NSURL *) url {
	CQConnectionCreationViewController *connectionCreationViewController = [[CQConnectionCreationViewController alloc] init];
	connectionCreationViewController.url = url;
	[[CQColloquyApplication sharedApplication] presentModalViewController:connectionCreationViewController animated:YES];
	[connectionCreationViewController release];
}

#pragma mark -

- (void) actionSheet:(UIActionSheet *) actionSheet clickedButtonAtIndex:(NSInteger) buttonIndex {
	if (buttonIndex == actionSheet.cancelButtonIndex)
		return;

	if (buttonIndex == 0)
		[self showConnectionCreationView:nil];
	else if (buttonIndex == 1)
		[self showBouncerCreationView:nil];
}

#pragma mark -

- (void) alertView:(UIAlertView *) alertView clickedButtonAtIndex:(NSInteger) buttonIndex {
	if (buttonIndex == alertView.cancelButtonIndex)
		return;

	if (alertView.tag == CannotConnectToBouncerConnectionTag) {
		MVChatConnection *connection = ((CQAlertView *)alertView).userInfo;
		[connection connectDirectly];
		return;
	}

	if (alertView.tag == CannotConnectToBouncerTag) {
		CQBouncerSettings *settings = ((CQAlertView *)alertView).userInfo;
		[_connectionsNavigationController editBouncer:settings];
		[[CQColloquyApplication sharedApplication] showConnections:nil];
		return;
	}

	if (alertView.tag == HelpAlertTag) {
		[[CQColloquyApplication sharedApplication] showHelp:nil];
		return;
	}

	NSArray *inputFields = ((CQAlertView *)alertView).inputFields;
	if (!inputFields.count)
		return;

	NSString *response = ((UITextField *)[inputFields objectAtIndex:0]).text;
	if (!response.length)
		return;

	NSNotification *notification = ((CQAlertView *)alertView).userInfo;
	MVChatConnection *connection = notification.object;

	if (alertView.tag == ChannelKeyTextFieldTag) {
		NSError *error = [[notification userInfo] objectForKey:@"error"];
		NSString *room = [[error userInfo] objectForKey:@"room"];

		[[CQChatController defaultController] showChatControllerWhenAvailableForRoomNamed:room andConnection:connection];
		[connection joinChatRoomNamed:room withPassphrase:response];

		[[CQKeychain standardKeychain] setPassword:response forServer:connection.uniqueIdentifier area:room];
	}
}

#pragma mark -

- (void) bouncerConnection:(CQBouncerConnection *) connection didRecieveConnectionInfo:(NSDictionary *) info {
	NSMutableArray *connections = [_bouncerChatConnections objectForKey:connection.settings.identifier];
	if (!connections) {
		connections = [[NSMutableArray alloc] initWithCapacity:5];
		[_bouncerChatConnections setObject:connections forKey:connection.settings.identifier];
		[connections release];
	}

	NSString *connectionIdentifier = [info objectForKey:@"connectionIdentifier"];
	if (!connectionIdentifier.length)
		return;

	MVChatConnection *chatConnection = nil;
	for (MVChatConnection *currentChatConnection in connections) {
		if ([currentChatConnection.bouncerConnectionIdentifier isEqualToString:connectionIdentifier]) {
			chatConnection = currentChatConnection;
			break;
		}
	}

	BOOL newConnection = NO;
	if (!chatConnection) {
		chatConnection = [[MVChatConnection alloc] initWithType:MVChatConnectionIRCType];

		chatConnection.bouncerIdentifier = connection.settings.identifier;
		chatConnection.bouncerConnectionIdentifier = connectionIdentifier;

		chatConnection.bouncerType = connection.settings.type;
		chatConnection.bouncerServer = connection.settings.server;
		chatConnection.bouncerServerPort = connection.settings.serverPort;
		chatConnection.bouncerUsername = connection.settings.username;
		chatConnection.bouncerPassword = connection.settings.password;

		chatConnection.pushNotifications = YES;

		newConnection = YES;

		[connections addObject:chatConnection];
		[_connections addObject:chatConnection];

		[chatConnection release];
	}

	[chatConnection setPersistentInformationObject:[NSNumber numberWithBool:YES] forKey:@"stillExistsOnBouncer"];

	chatConnection.server = [info objectForKey:@"serverAddress"];
	chatConnection.serverPort = [[info objectForKey:@"serverPort"] unsignedShortValue];
	chatConnection.preferredNickname = [info objectForKey:@"nickname"];
	if ([[info objectForKey:@"nicknamePassword"] length])
		chatConnection.nicknamePassword = [info objectForKey:@"nicknamePassword"];
	chatConnection.username = [info objectForKey:@"username"];
	if ([[info objectForKey:@"password"] length])
		chatConnection.password = [info objectForKey:@"password"];
	chatConnection.secure = [[info objectForKey:@"secure"] boolValue];
	chatConnection.alternateNicknames = [info objectForKey:@"alternateNicknames"];
	chatConnection.encoding = [[info objectForKey:@"encoding"] unsignedIntegerValue];

	NSDictionary *notificationInfo = [NSDictionary dictionaryWithObject:chatConnection forKey:@"connection"];
	if (newConnection)
		[[NSNotificationCenter defaultCenter] postNotificationName:CQConnectionsControllerAddedConnectionNotification object:self userInfo:notificationInfo];
	else [[NSNotificationCenter defaultCenter] postNotificationName:CQConnectionsControllerChangedConnectionNotification object:self userInfo:notificationInfo];
}

- (void) bouncerConnectionDidFinishConnectionList:(CQBouncerConnection *) connection {
	NSMutableArray *connections = [_bouncerChatConnections objectForKey:connection.settings.identifier];
	if (!connections.count)
		return;

	NSMutableArray *deletedConnections = [[NSMutableArray alloc] init];

	for (MVChatConnection *chatConnection in connections) {
		if (![[chatConnection persistentInformationObjectForKey:@"stillExistsOnBouncer"] boolValue])
			[deletedConnections addObject:chatConnection];
		[chatConnection removePersistentInformationObjectForKey:@"stillExistsOnBouncer"];
	}

	for (MVChatConnection *chatConnection in deletedConnections) {
		NSUInteger index = [connections indexOfObjectIdenticalTo:chatConnection];
		[connections removeObjectAtIndex:index];

		NSDictionary *notificationInfo = [NSDictionary dictionaryWithObjectsAndKeys:chatConnection, @"connection", [NSNumber numberWithUnsignedInteger:index], @"index", nil];
		[[NSNotificationCenter defaultCenter] postNotificationName:CQConnectionsControllerRemovedConnectionNotification object:self userInfo:notificationInfo];
	}

	[deletedConnections release];
}

- (void) bouncerConnectionDidDisconnect:(CQBouncerConnection *) connection withError:(NSError *) error {
	NSMutableArray *connections = [_bouncerChatConnections objectForKey:connection.settings.identifier];

	if (error && (!connections.count || [connection.userInfo isEqual:@"manual-refresh"])) {
		CQAlertView *alert = [[CQAlertView alloc] init];

		alert.tag = CannotConnectToBouncerTag;
		alert.userInfo = connection.settings;
		alert.delegate = self;
		alert.title = NSLocalizedString(@"Can't Connect to Bouncer", @"Can't Connect to Bouncer alert title");
		alert.message = [NSString stringWithFormat:NSLocalizedString(@"Can't connect to the bouncer \"%@\". Check the bouncer settings and try again.", @"Can't connect to bouncer alert message"), connection.settings.displayName];

		alert.cancelButtonIndex = [alert addButtonWithTitle:NSLocalizedString(@"Dismiss", @"Dismiss alert button title")];

		[alert addButtonWithTitle:NSLocalizedString(@"Settings", @"Settings alert button title")];

		[alert show];

		[alert release];
	}

	connection.delegate = nil;

	[_bouncerConnections removeObject:connection];
}

#pragma mark -

- (void) _applicationDidReceiveMemoryWarning {
	for (MVChatConnection *connection in _connections)
		[connection purgeCaches];
}

- (void) _applicationWillTerminate {
	[self saveConnections];

	for (MVChatConnection *connection in _connections)
		[connection disconnectWithReason:[MVChatConnection defaultQuitMessage]];
}

#if TARGET_IPHONE_SIMULATOR
- (void) _gotRawConnectionMessage:(NSNotification *) notification {
	MVChatConnection *connection = notification.object;
	NSString *message = [[notification userInfo] objectForKey:@"message"];
	BOOL outbound = [[[notification userInfo] objectForKey:@"outbound"] boolValue];

	if (connection.bouncerType == MVChatConnectionColloquyBouncer)
		NSLog(@"%@ (via %@): %@ %@", connection.server, connection.bouncerServer, (outbound ? @"<<" : @">>"), message);
	else NSLog(@"%@: %@ %@", connection.server, (outbound ? @"<<" : @">>"), message);
}
#endif

- (void) _willConnect:(NSNotification *) notification {
	MVChatConnection *connection = notification.object;

	++_connectingCount;

	[UIApplication sharedApplication].idleTimerDisabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"CQIdleTimerDisabled"];
	[UIApplication sharedApplication].networkActivityIndicatorVisible = YES;

	[connection removePersistentInformationObjectForKey:@"pushState"];

	NSMutableArray *rooms = [connection.automaticJoinedRooms mutableCopy];

	NSArray *previousRooms = [connection persistentInformationObjectForKey:@"previousRooms"];
	if (previousRooms.count) {
		[rooms addObjectsFromArray:previousRooms];
		[connection removePersistentInformationObjectForKey:@"previousRooms"];
	}

	CQBouncerSettings *bouncerSettings = connection.bouncerSettings;
	if (bouncerSettings) {
		connection.bouncerType = bouncerSettings.type;
		connection.bouncerServer = bouncerSettings.server;
		connection.bouncerServerPort = bouncerSettings.serverPort;
		connection.bouncerUsername = bouncerSettings.username;
		connection.bouncerPassword = bouncerSettings.password;
	}

	if (connection.temporaryDirectConnection && ![[connection persistentInformationObjectForKey:@"tryBouncerFirst"] boolValue])
		connection.bouncerType = MVChatConnectionNoBouncer;

	[connection sendPushNotificationCommands];

	if (connection.bouncerType == MVChatConnectionColloquyBouncer) {
		connection.bouncerDeviceIdentifier = [UIDevice currentDevice].uniqueIdentifier;

		[connection sendRawMessageWithFormat:@"BOUNCER set encoding %u", connection.encoding];

		if (connection.nicknamePassword.length)
			[connection sendRawMessageWithFormat:@"BOUNCER set nick-password :%@", connection.nicknamePassword];
		else [connection sendRawMessage:@"BOUNCER set nick-password"];

		if (connection.alternateNicknames.count) {
			NSString *nicks = [connection.alternateNicknames componentsJoinedByString:@" "];
			[connection sendRawMessageWithFormat:@"BOUNCER set alt-nicks %@", nicks];
		} else [connection sendRawMessage:@"BOUNCER set alt-nicks"];

		[connection sendRawMessage:@"BOUNCER autocommands clear"];

		if (connection.automaticCommands.count && rooms.count)
			[connection sendRawMessage:@"BOUNCER autocommands start"];
	}

	NSString *command = nil;
	NSString *arguments = nil;
	NSScanner *scanner = nil;
	for (NSString *fullCommand in connection.automaticCommands) {
		scanner = [NSScanner scannerWithString:fullCommand];
		[scanner setCharactersToBeSkipped:nil];

		command = nil;
		arguments = nil;

		scanner.scanLocation = 1;
		[scanner scanUpToCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:&command];
		[scanner scanCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] maxLength:1 intoString:NULL];

		arguments = [fullCommand substringFromIndex:scanner.scanLocation];
		arguments = [arguments stringByReplacingOccurrencesOfString:@"%@" withString:connection.preferredNickname];

		[connection sendCommand:command withArguments:arguments];
	}

	NSUInteger roomCount = rooms.count;
	if (roomCount) {
		NSString *key = nil;
		NSString *room = nil;
		for (NSUInteger i = 0; i < roomCount; i++) {
			room = [rooms objectAtIndex:i];
			key = [[CQKeychain standardKeychain] passwordForServer:connection.uniqueIdentifier area:room];

			if (key.length) {
				room = [NSString stringWithFormat:@"%@ %@", room, key];
				[rooms replaceObjectAtIndex:i withObject:room];
			}
		}

		[connection joinChatRoomsNamed:rooms];
	}

	if (connection.bouncerType == MVChatConnectionColloquyBouncer && connection.automaticCommands.count && rooms.count)
		[connection sendRawMessage:@"BOUNCER autocommands stop"];

	[rooms release];
}

- (void) _didConnectOrDidNotConnect:(NSNotification *) notification {
	[UIApplication sharedApplication].networkActivityIndicatorVisible = NO;

	if (!_connectedCount && !_connectingCount)
		[UIApplication sharedApplication].idleTimerDisabled = NO;
}

- (void) _didNotConnect:(NSNotification *) notification {
	[self _didConnectOrDidNotConnect:notification];

	MVChatConnection *connection = notification.object;
	BOOL userDisconnected = [[notification.userInfo objectForKey:@"userDisconnected"] boolValue];
	BOOL tryBouncerFirst = [[connection persistentInformationObjectForKey:@"tryBouncerFirst"] boolValue];

	[connection removePersistentInformationObjectForKey:@"tryBouncerFirst"];

	if (!userDisconnected && tryBouncerFirst) {
		[connection connect];
		return;
	}

	if (connection.reconnectAttemptCount > 0 || userDisconnected)
		return;

	CQAlertView *alert = [[CQAlertView alloc] init];

	if (connection.directConnection) {
		alert.tag = HelpAlertTag;
		alert.delegate = self;

		alert.title = NSLocalizedString(@"Can't Connect to Server", @"Can't Connect to Server alert title");
		alert.message = [NSString stringWithFormat:NSLocalizedString(@"Can't connect to the server \"%@\".", @"Cannot connect alert message"), connection.displayName];

		alert.cancelButtonIndex = [alert addButtonWithTitle:NSLocalizedString(@"Dismiss", @"Dismiss alert button title")];

		[alert addButtonWithTitle:NSLocalizedString(@"Help", @"Help button title")];
	} else {
		alert.tag = CannotConnectToBouncerConnectionTag;
		alert.userInfo = connection;
		alert.delegate = self;

		alert.title = NSLocalizedString(@"Can't Connect to Bouncer", @"Can't Connect to Bouncer alert title");
		alert.message = [NSString stringWithFormat:NSLocalizedString(@"Can't connect to the server \"%@\" via \"%@\". Would you like to connect directly?", @"Connect directly alert message"), connection.displayName, connection.bouncerSettings.displayName];

		alert.cancelButtonIndex = [alert addButtonWithTitle:NSLocalizedString(@"Dismiss", @"Dismiss alert button title")];

		[alert addButtonWithTitle:NSLocalizedString(@"Connect", @"Connect button title")];
	}

	[alert show];

	[alert release];
}

- (void) _didConnect:(NSNotification *) notification {
	++_connectedCount;

	[self _didConnectOrDidNotConnect:notification];

	MVChatConnection *connection = notification.object;
	[connection removePersistentInformationObjectForKey:@"tryBouncerFirst"];

	if (!connection.directConnection)
		connection.temporaryDirectConnection = NO;
}

- (void) _didDisconnect:(NSNotification *) notification {
	if (_connectedCount)
		--_connectedCount;
	if (!_connectedCount && !_connectingCount)
		[UIApplication sharedApplication].idleTimerDisabled = NO;
}

- (void) _deviceTokenRecieved:(NSNotification *) notification {
	for (MVChatConnection *connection in _connections)
		[connection sendPushNotificationCommands]; 
}

- (void) _errorOccurred:(NSNotification *) notification {
	NSError *error = [[notification userInfo] objectForKey:@"error"];

	NSString *errorTitle = nil;
	switch (error.code) {
		case MVChatConnectionRoomIsFullError:
		case MVChatConnectionInviteOnlyRoomError:
		case MVChatConnectionBannedFromRoomError:
		case MVChatConnectionRoomPasswordIncorrectError:
		case MVChatConnectionIdentifyToJoinRoomError:
			errorTitle = NSLocalizedString(@"Can't Join Room", @"Can't join room alert title");
			break;
		case MVChatConnectionCantSendToRoomError:
			errorTitle = NSLocalizedString(@"Can't Send Message", @"Can't send message alert title");
			break;
		case MVChatConnectionCantChangeUsedNickError:
			errorTitle = NSLocalizedString(@"Nickname in use", "Nickname in use alert title");
			break;
		case MVChatConnectionCantChangeNickError:
			errorTitle = NSLocalizedString(@"Can't Change Nickname", "Can't change nickname alert title");
			break;
		case MVChatConnectionRoomDoesNotSupportModesError:
			errorTitle = NSLocalizedString(@"Room Modes Unsupported", "Room modes not supported alert title");
			break;
		case MVChatConnectionNickChangedByServicesError:
			errorTitle = NSLocalizedString(@"Nickname Changed", "Nick changed by server alert title");
			break;
	}

	if (!errorTitle) return;

	MVChatConnection *connection = notification.object;
	NSString *roomName = [[error userInfo] objectForKey:@"room"];
	MVChatRoom *room = (roomName ? [connection chatRoomWithName:roomName] : nil);

	NSString *errorMessage = nil;
	NSString *placeholder = nil;
	NSUInteger tag = 0;
	switch (error.code) {
		case MVChatConnectionRoomIsFullError:
			errorMessage = [NSString stringWithFormat:NSLocalizedString(@"The room \"%@\" on \"%@\" is full.", "Room is full alert message"), room.displayName, connection.displayName];
			break;
		case MVChatConnectionInviteOnlyRoomError:
			errorMessage = [NSString stringWithFormat:NSLocalizedString(@"The room \"%@\" on \"%@\" is invite-only.", "Room is invite-only alert message"), room.displayName, connection.displayName];
			break;
		case MVChatConnectionBannedFromRoomError:
			errorMessage = [NSString stringWithFormat:NSLocalizedString(@"You are banned from \"%@\" on \"%@\".", "Banned from room alert message"), room.displayName, connection.displayName];
			break;
		case MVChatConnectionRoomPasswordIncorrectError:
			errorMessage = [NSString stringWithFormat:NSLocalizedString(@"The room \"%@\" on \"%@\" is password protected, and you didn't supply the correct password.", "Room is full alert message"), room.displayName, connection.displayName];
			placeholder = NSLocalizedString(@"Channel Key", @"Channel Key textfield placeholder");
			tag = ChannelKeyTextFieldTag;
			break;
		case MVChatConnectionCantSendToRoomError:
			errorMessage = [NSString stringWithFormat:NSLocalizedString(@"Can't send messages to \"%@\" due to some room restriction.", "Cant send message alert message"), room.displayName];
			break;
		case MVChatConnectionRoomDoesNotSupportModesError:
			errorMessage = [NSString stringWithFormat:NSLocalizedString(@"The room \"%@\" on \"%@\" doesn't support modes.", "Room does not support modes alert message"), room.displayName, connection.displayName];
			break;
		case MVChatConnectionIdentifyToJoinRoomError:
			errorMessage = [NSString stringWithFormat:NSLocalizedString(@"Identify with network services to join \"%@\" on \"%@\".", "Identify to join room alert message"), room.displayName, connection.displayName];
			placeholder = NSLocalizedString(@"NickServ Password", @"NickServ Password textfield placeholder");
			tag = NickservPasswordTextFieldTag;
			break;
		case MVChatConnectionCantChangeNickError:
			if (room) errorMessage = [NSString stringWithFormat:NSLocalizedString(@"Can't change your nickname while in \"%@\" on \"%@\". Leave the room and try again.", "Can't change nick because of room alert message" ), room.displayName, connection.displayName];
			else errorMessage = [NSString stringWithFormat:NSLocalizedString(@"Can't change nicknames too fast on \"%@\", wait and try again.", "Can't change nick too fast alert message"), connection.displayName];
			break;
		case MVChatConnectionCantChangeUsedNickError:
			errorMessage = [NSString stringWithFormat:NSLocalizedString(@"Services won't let you change your nickname to \"%@\" on \"%@\".", "Services won't let you change your nickname alert message"), [[error userInfo] objectForKey:@"newnickname"], connection.displayName];
			break;
		case MVChatConnectionNickChangedByServicesError:
			errorMessage = [NSString stringWithFormat:NSLocalizedString(@"Your nickname is being changed on \"%@\" because you didn't identify.", "Username was changed by server alert message"), connection.displayName];
			break;
	}

	if (!errorMessage)
		errorMessage = error.localizedDescription;

	if (!errorMessage) return;

	CQAlertView *alert = [[CQAlertView alloc] init];
	alert.tag = tag ? tag : HelpAlertTag;
	alert.delegate = self;
	alert.title = errorTitle;
	alert.message = errorMessage;
	alert.userInfo = notification;

	alert.cancelButtonIndex = [alert addButtonWithTitle:NSLocalizedString(@"Dismiss", @"Dismiss alert button title")];

	NSString *buttonTitle = nil;
	if (tag) {
		[alert addTextFieldWithPlaceholder:placeholder tag:tag secureTextEntry:YES];

		buttonTitle = (tag == ChannelKeyTextFieldTag) ? NSLocalizedString(@"Join", @"Join button title") : NSLocalizedString(@"Connect", @"Connect button title");
	} else buttonTitle = NSLocalizedString(@"Help", @"Help button title");

	[alert addButtonWithTitle:buttonTitle];

	[alert show];

	[alert release];
}

#pragma mark -

- (MVChatConnection *) _chatConnectionWithDictionaryRepresentation:(NSDictionary *) info {
	MVChatConnection *connection = nil;

	MVChatConnectionType type = MVChatConnectionIRCType;
	if ([[info objectForKey:@"type"] isEqualToString:@"icb"])
		type = MVChatConnectionICBType;
	else if ([[info objectForKey:@"type"] isEqualToString:@"irc"])
		type = MVChatConnectionIRCType;
	else if ([[info objectForKey:@"type"] isEqualToString:@"silc"])
		type = MVChatConnectionSILCType;
	else if ([[info objectForKey:@"type"] isEqualToString:@"xmpp"])
		type = MVChatConnectionXMPPType;

	if ([info objectForKey:@"url"])
		connection = [[MVChatConnection alloc] initWithURL:[NSURL URLWithString:[info objectForKey:@"url"]]];
	else connection = [[MVChatConnection alloc] initWithServer:[info objectForKey:@"server"] type:type port:[[info objectForKey:@"port"] unsignedShortValue] user:[info objectForKey:@"nickname"]];

	if (!connection)
		return nil;

	if ([info objectForKey:@"uniqueIdentifier"]) connection.uniqueIdentifier = [info objectForKey:@"uniqueIdentifier"];

	NSMutableDictionary *persistentInformation = [[NSMutableDictionary alloc] init];
	[persistentInformation addEntriesFromDictionary:[info objectForKey:@"persistentInformation"]];

	if ([info objectForKey:@"automatic"])
		[persistentInformation setObject:[info objectForKey:@"automatic"] forKey:@"automatic"];
	if ([info objectForKey:@"push"])
		[persistentInformation setObject:[info objectForKey:@"push"] forKey:@"push"];
	if ([info objectForKey:@"rooms"])
		[persistentInformation setObject:[info objectForKey:@"rooms"] forKey:@"rooms"];
	if ([info objectForKey:@"previousRooms"])
		[persistentInformation setObject:[info objectForKey:@"previousRooms"] forKey:@"previousRooms"];
	if ([info objectForKey:@"description"])
		[persistentInformation setObject:[info objectForKey:@"description"] forKey:@"description"];
	if ([info objectForKey:@"commands"] && ((NSString *)[info objectForKey:@"commands"]).length)
		[persistentInformation setObject:[[info objectForKey:@"commands"] componentsSeparatedByString:@"\n"] forKey:@"commands"];
	if ([info objectForKey:@"bouncer"])
		[persistentInformation setObject:[info objectForKey:@"bouncer"] forKey:@"bouncerIdentifier"];

	connection.persistentInformation = persistentInformation;

	[persistentInformation release];

	connection.proxyType = [[info objectForKey:@"proxy"] unsignedLongValue];
	connection.secure = [[info objectForKey:@"secure"] boolValue];

	if ([[info objectForKey:@"encoding"] unsignedLongValue])
		connection.encoding = [[info objectForKey:@"encoding"] unsignedLongValue];
	else connection.encoding = [MVChatConnection defaultEncoding];

	if (!CFStringIsEncodingAvailable(CFStringConvertNSStringEncodingToEncoding(connection.encoding)))
		connection.encoding = [MVChatConnection defaultEncoding];

	if ([info objectForKey:@"realName"]) connection.realName = [info objectForKey:@"realName"];
	if ([info objectForKey:@"nickname"]) connection.nickname = [info objectForKey:@"nickname"];
	if ([info objectForKey:@"username"]) connection.username = [info objectForKey:@"username"];
	if ([info objectForKey:@"alternateNicknames"])
		connection.alternateNicknames = [info objectForKey:@"alternateNicknames"];

	[connection loadPasswordsFromKeychain];

	if ([info objectForKey:@"nicknamePassword"]) connection.nicknamePassword = [info objectForKey:@"nicknamePassword"];
	if ([info objectForKey:@"password"]) connection.password = [info objectForKey:@"password"];

	if ([info objectForKey:@"bouncerConnectionIdentifier"]) connection.bouncerConnectionIdentifier = [info objectForKey:@"bouncerConnectionIdentifier"];

	CQBouncerSettings *bouncerSettings = [self bouncerSettingsForIdentifier:connection.bouncerIdentifier];
	if (bouncerSettings) {
		connection.bouncerType = bouncerSettings.type;
		connection.bouncerServer = bouncerSettings.server;
		connection.bouncerServerPort = bouncerSettings.serverPort;
		connection.bouncerUsername = bouncerSettings.username;
		connection.bouncerPassword = bouncerSettings.password;
	}

	if (connection.temporaryDirectConnection)
		connection.bouncerType = MVChatConnectionNoBouncer;

	if ((!bouncerSettings || bouncerSettings.pushNotifications) && connection.pushNotifications)
		[[CQColloquyApplication sharedApplication] registerForRemoteNotifications];

	return [connection autorelease];
}

- (NSMutableDictionary *) _dictionaryRepresentationForConnection:(MVChatConnection *) connection {
	NSMutableDictionary *info = [[NSMutableDictionary alloc] initWithCapacity:15];

	NSMutableDictionary *persistentInformation = [connection.persistentInformation mutableCopy];
	if ([persistentInformation objectForKey:@"automatic"])
		[info setObject:[persistentInformation objectForKey:@"automatic"] forKey:@"automatic"];
	if ([persistentInformation objectForKey:@"push"])
		[info setObject:[persistentInformation objectForKey:@"push"] forKey:@"push"];
	if ([[persistentInformation objectForKey:@"rooms"] count])
		[info setObject:[persistentInformation objectForKey:@"rooms"] forKey:@"rooms"];
	if ([[persistentInformation objectForKey:@"description"] length])
		[info setObject:[persistentInformation objectForKey:@"description"] forKey:@"description"];
	if ([[persistentInformation objectForKey:@"commands"] count])
		[info setObject:[[persistentInformation objectForKey:@"commands"] componentsJoinedByString:@"\n"] forKey:@"commands"];
	if ([persistentInformation objectForKey:@"bouncerIdentifier"])
		[info setObject:[persistentInformation objectForKey:@"bouncerIdentifier"] forKey:@"bouncer"];

	[persistentInformation removeObjectForKey:@"automatic"];
	[persistentInformation removeObjectForKey:@"push"];
	[persistentInformation removeObjectForKey:@"pushState"];
	[persistentInformation removeObjectForKey:@"rooms"];
	[persistentInformation removeObjectForKey:@"previousRooms"];
	[persistentInformation removeObjectForKey:@"description"];
	[persistentInformation removeObjectForKey:@"commands"];
	[persistentInformation removeObjectForKey:@"bouncerIdentifier"];

	NSDictionary *chatState = [[CQChatController defaultController] persistentStateForConnection:connection];
	if (chatState.count)
		[info setObject:chatState forKey:@"chatState"];

	if (persistentInformation.count)
		[info setObject:persistentInformation forKey:@"persistentInformation"];

	[persistentInformation release];

	[info setObject:[NSNumber numberWithBool:connection.connected] forKey:@"wasConnected"];

	NSSet *joinedRooms = connection.joinedChatRooms;
	if (connection.connected && joinedRooms.count) {
		NSMutableArray *previousJoinedRooms = [[NSMutableArray alloc] init];

		for (MVChatRoom *room in joinedRooms) {
			if (room && room.name && !(room.modes & MVChatRoomInviteOnlyMode))
				[previousJoinedRooms addObject:room.name];
		}

		[previousJoinedRooms removeObjectsInArray:[info objectForKey:@"rooms"]];

		if (previousJoinedRooms.count)
			[info setObject:previousJoinedRooms forKey:@"previousRooms"];

		[previousJoinedRooms release];
	}

	[info setObject:connection.uniqueIdentifier forKey:@"uniqueIdentifier"];
	[info setObject:connection.server forKey:@"server"];
	[info setObject:connection.urlScheme forKey:@"type"];
	[info setObject:[NSNumber numberWithBool:connection.secure] forKey:@"secure"];
	[info setObject:[NSNumber numberWithLong:connection.proxyType] forKey:@"proxy"];
	[info setObject:[NSNumber numberWithLong:connection.encoding] forKey:@"encoding"];
	[info setObject:[NSNumber numberWithUnsignedShort:connection.serverPort] forKey:@"port"];
	if (connection.realName) [info setObject:connection.realName forKey:@"realName"];
	if (connection.username) [info setObject:connection.username forKey:@"username"];
	if (connection.preferredNickname) [info setObject:connection.preferredNickname forKey:@"nickname"];
	if (connection.bouncerConnectionIdentifier) [info setObject:connection.bouncerConnectionIdentifier forKey:@"bouncerConnectionIdentifier"];

	if (connection.alternateNicknames.count)
		[info setObject:connection.alternateNicknames forKey:@"alternateNicknames"];

	return [info autorelease];
}

- (void) _loadConnectionList {
	if (_loadedConnections)
		return;

	_loadedConnections = YES;

	NSArray *bouncers = [[NSUserDefaults standardUserDefaults] arrayForKey:@"CQChatBouncers"];
	CQBouncerSettings *settings = nil;
	NSArray *connections = nil;
	MVChatConnection *connection = nil;
	NSMutableArray *bouncerChatConnections = [[NSMutableArray alloc] initWithCapacity:10];
	for (NSDictionary *info in bouncers) {
		settings = [[CQBouncerSettings alloc] initWithDictionaryRepresentation:info];
		if (!settings)
			continue;

		[_bouncers addObject:settings];

		// TEMP: read the bouncer password from the old account scheme using in the first beta.
		if (!settings.password.length)
			settings.password = [[CQKeychain standardKeychain] passwordForServer:settings.server area:settings.username];

		[bouncerChatConnections removeAllObjects];
		[_bouncerChatConnections setObject:bouncerChatConnections forKey:settings.identifier];

		connections = [info objectForKey:@"connections"];
		for (NSDictionary *info in connections) {
			connection = [self _chatConnectionWithDictionaryRepresentation:info];
			if (!connection)
				continue;

			[bouncerChatConnections addObject:connection];
			[_connections addObject:connection];

			if ([info objectForKey:@"chatState"])
				[[CQChatController defaultController] restorePersistentState:[info objectForKey:@"chatState"] forConnection:connection];
		}
	}

	[bouncerChatConnections release];
	[settings release];

	connections = [[NSUserDefaults standardUserDefaults] arrayForKey:@"MVChatBookmarks"];
	for (NSDictionary *info in connections) {
		connection = [self _chatConnectionWithDictionaryRepresentation:info];
		if (!connection)
			continue;

		// TEMP: skip any direct connections that have bouncer identifiers.
		if (connection.bouncerIdentifier.length)
			continue;

		[_directConnections addObject:connection];
		[_connections addObject:connection];

		if ([info objectForKey:@"chatState"])
			[[CQChatController defaultController] restorePersistentState:[info objectForKey:@"chatState"] forConnection:connection];
	}

	[self performSelector:@selector(_connectAutomaticConnections) withObject:nil afterDelay:0.5];

	if (_bouncers.count)
		[self performSelector:@selector(_refreshBouncerConnectionLists) withObject:nil afterDelay:1.];
}

- (void) _connectAutomaticConnections {
	for (MVChatConnection *connection in _connections)
		if (connection.automaticallyConnect)
			[connection connectAppropriately];
}

- (void) _refreshBouncerConnectionLists {
	[_bouncerConnections makeObjectsPerformSelector:@selector(disconnect)];
	[_bouncerConnections removeAllObjects];

	CQBouncerConnection *connection = nil;
	for (CQBouncerSettings *settings in _bouncers) {
		connection = [[CQBouncerConnection alloc] initWithBouncerSettings:settings];
		connection.delegate = self;

		[_bouncerConnections addObject:connection];

		[connection connect];

		[connection release];
	}
}

#if ENABLE(SECRETS)
- (void) _powerStateMessageReceived:(natural_t) messageType withArgument:(long) messageArgument {
	switch (messageType) {
	case kIOMessageSystemWillSleep:
		// System will go to sleep, we can't prevent it.
		for (MVChatConnection *connection in _connections)
			[connection disconnectWithReason:[MVChatConnection defaultQuitMessage]];
		break;
	case kIOMessageCanSystemSleep:
		// System wants to go to sleep, but we can cancel it if we have connected connections.
		if (_connectedCount || _connectingCount)
			IOCancelPowerChange(rootPowerDomainPort, messageArgument);
		else IOAllowPowerChange(rootPowerDomainPort, messageArgument);
		break;
	}
}
#endif

#pragma mark -

- (void) saveConnections {
	if (!_loadedConnections)
		return;

	NSUInteger pushConnectionCount = 0;
	NSUInteger roomCount = 0;

	NSMutableArray *connections = [[NSMutableArray alloc] initWithCapacity:_directConnections.count];
	NSMutableDictionary *connectionInfo = nil;
	for (MVChatConnection *connection in _directConnections) {
		connectionInfo = [self _dictionaryRepresentationForConnection:connection];
		if (!connectionInfo)
			continue;

		if (connection.pushNotifications)
			++pushConnectionCount;

		roomCount += connection.knownChatRooms.count;

		[connections addObject:connectionInfo];
		[connection savePasswordsToKeychain];
	}

	NSMutableArray *bouncers = [[NSMutableArray alloc] initWithCapacity:_bouncers.count];
	NSMutableDictionary *info = nil;
	NSMutableArray *bouncerConnections = [[NSMutableArray alloc] initWithCapacity:10];
	for (CQBouncerSettings *settings in _bouncers) {
		info = [settings dictionaryRepresentation];
		if (!info)
			continue;

		[bouncerConnections removeAllObjects];
		for (MVChatConnection *connection in [self bouncerChatConnectionsForIdentifier:settings.identifier]) {
			connectionInfo = [self _dictionaryRepresentationForConnection:connection];
			if (!connectionInfo)
				continue;

			if (settings.pushNotifications && connection.pushNotifications)
				++pushConnectionCount;

			roomCount += connection.knownChatRooms.count;

			[bouncerConnections addObject:connectionInfo];
			[connection savePasswordsToKeychain];
		}

		if (bouncerConnections.count)
			[info setObject:bouncerConnections forKey:@"connections"];
		[bouncerConnections release];

		[bouncers addObject:info];
	}

	[[NSUserDefaults standardUserDefaults] setObject:bouncers forKey:@"CQChatBouncers"];
	[[NSUserDefaults standardUserDefaults] setObject:connections forKey:@"MVChatBookmarks"];
	[[NSUserDefaults standardUserDefaults] synchronize];

	[[CQAnalyticsController defaultController] setObject:[NSNumber numberWithUnsignedInteger:roomCount] forKey:@"total-rooms"];
	[[CQAnalyticsController defaultController] setObject:[NSNumber numberWithUnsignedInteger:pushConnectionCount] forKey:@"total-push-connections"];
	[[CQAnalyticsController defaultController] setObject:[NSNumber numberWithUnsignedInteger:_connections.count] forKey:@"total-connections"];
	[[CQAnalyticsController defaultController] setObject:[NSNumber numberWithUnsignedInteger:_bouncers.count] forKey:@"total-bouncers"];

	[bouncers release];
	[connections release];
}

#pragma mark -

@synthesize connectionsNavigationController = _connectionsNavigationController;
@synthesize connections = _connections;
@synthesize directConnections = _directConnections;
@synthesize bouncers = _bouncers;

#pragma mark -

- (NSSet *) connectedConnections {
	NSMutableSet *result = [[NSMutableSet alloc] initWithCapacity:_connections.count];

	for (MVChatConnection *connection in _connections)
		if (connection.connected)
			[result addObject:connection];

	return [result autorelease];
}

- (MVChatConnection *) connectionForUniqueIdentifier:(NSString *) identifier {
	for (MVChatConnection *connection in _connections)
		if ([connection.uniqueIdentifier isEqualToString:identifier])
			return connection;
	return nil;
}

- (MVChatConnection *) connectionForServerAddress:(NSString *) address {
	NSArray *connections = [self connectionsForServerAddress:address];
	if (connections.count)
		return [connections objectAtIndex:0];
	return nil;
}

- (NSArray *) connectionsForServerAddress:(NSString *) address {
	NSMutableArray *result = [NSMutableArray arrayWithCapacity:_connections.count];

	address = [address stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@". \t\n"]];

	NSString *server = nil;
	NSRange range = {0, 0};
	for (MVChatConnection *connection in _connections) {
		if (!connection.connected)
			continue;
		server = connection.server;
		range = [server rangeOfString:address options:(NSCaseInsensitiveSearch | NSLiteralSearch | NSBackwardsSearch | NSAnchoredSearch) range:NSMakeRange(0, server.length)];
		if (range.location != NSNotFound && (range.location == 0 || [server characterAtIndex:(range.location - 1)] == '.'))
			[result addObject:connection];
	}

	for (MVChatConnection *connection in _connections) {
		server = connection.server;
		range = [server rangeOfString:address options:(NSCaseInsensitiveSearch | NSLiteralSearch | NSBackwardsSearch | NSAnchoredSearch) range:NSMakeRange(0, server.length)];
		if (range.location != NSNotFound && (range.location == 0 || [server characterAtIndex:(range.location - 1)] == '.'))
			[result addObject:connection];
	}

	return result;
}

- (BOOL) managesConnection:(MVChatConnection *) connection {
	return [_connections containsObject:connection];
}

#pragma mark -

- (void) addConnection:(MVChatConnection *) connection {
	[self insertConnection:connection atIndex:_directConnections.count];
}

- (void) insertConnection:(MVChatConnection *) connection atIndex:(NSUInteger) index {
	if (!connection) return;

	if (!_directConnections.count) {
		[[NSUserDefaults standardUserDefaults] setObject:connection.nickname forKey:@"CQDefaultNickname"];
		[[NSUserDefaults standardUserDefaults] setObject:connection.realName forKey:@"CQDefaultRealName"];
	}

	[_directConnections insertObject:connection atIndex:index];
	[_connections addObject:connection];

	NSDictionary *notificationInfo = [NSDictionary dictionaryWithObject:connection forKey:@"connection"];
	[[NSNotificationCenter defaultCenter] postNotificationName:CQConnectionsControllerAddedConnectionNotification object:self userInfo:notificationInfo];

	[self saveConnections];
}

- (void) moveConnectionAtIndex:(NSUInteger) oldIndex toIndex:(NSUInteger) newIndex {
	MVChatConnection *connection = [[_directConnections objectAtIndex:oldIndex] retain];

	[_directConnections removeObjectAtIndex:oldIndex];
	[_directConnections insertObject:connection atIndex:newIndex];

	NSDictionary *notificationInfo = [NSDictionary dictionaryWithObjectsAndKeys:connection, @"connection", [NSNumber numberWithUnsignedInteger:newIndex], @"index", [NSNumber numberWithUnsignedInteger:oldIndex], @"oldIndex", nil];
	[[NSNotificationCenter defaultCenter] postNotificationName:CQConnectionsControllerMovedConnectionNotification object:self userInfo:notificationInfo];

	[connection release];

	[self saveConnections];
}

- (void) removeConnection:(MVChatConnection *) connection {
	NSUInteger index = [_directConnections indexOfObjectIdenticalTo:connection];
	if (index != NSNotFound)
		[self removeConnectionAtIndex:index];
}

- (void) removeConnectionAtIndex:(NSUInteger) index {
	MVChatConnection *connection = [[_directConnections objectAtIndex:index] retain];
	if (!connection) return;

	[connection disconnectWithReason:[MVChatConnection defaultQuitMessage]];

	[_directConnections removeObjectAtIndex:index];
	[_connections removeObject:connection];

	NSDictionary *notificationInfo = [NSDictionary dictionaryWithObjectsAndKeys:connection, @"connection", [NSNumber numberWithUnsignedInteger:index], @"index", nil];
	[[NSNotificationCenter defaultCenter] postNotificationName:CQConnectionsControllerRemovedConnectionNotification object:self userInfo:notificationInfo];

	[connection release];

	[self saveConnections];
}

#pragma mark -

- (void) moveConnectionAtIndex:(NSUInteger) oldIndex toIndex:(NSUInteger) newIndex forBouncerIdentifier:(NSString *) identifier {
	NSMutableArray *connections = [_bouncerChatConnections objectForKey:identifier];
	MVChatConnection *connection = [[connections objectAtIndex:oldIndex] retain];

	[connections removeObjectAtIndex:oldIndex];
	[connections insertObject:connection atIndex:newIndex];

	NSDictionary *notificationInfo = [NSDictionary dictionaryWithObjectsAndKeys:connection, @"connection", [NSNumber numberWithUnsignedInteger:newIndex], @"index", nil];
	[[NSNotificationCenter defaultCenter] postNotificationName:CQConnectionsControllerMovedConnectionNotification object:self userInfo:notificationInfo];

	[connection release];

	[self saveConnections];
}

#pragma mark -

- (CQBouncerSettings *) bouncerSettingsForIdentifier:(NSString *) identifier {
	for (CQBouncerSettings *bouncer in _bouncers)
		if ([bouncer.identifier isEqualToString:identifier])
			return bouncer;
	return nil;
}

- (NSArray *) bouncerChatConnectionsForIdentifier:(NSString *) identifier {
	return [_bouncerChatConnections objectForKey:identifier];
}

#pragma mark -

- (void) refreshBouncerConnectionsWithBouncerSettings:(CQBouncerSettings *) settings {
	CQBouncerConnection *connection = [[CQBouncerConnection alloc] initWithBouncerSettings:settings];
	connection.delegate = self;
	connection.userInfo = @"manual-refresh";

	[_bouncerConnections addObject:connection];

	[connection connect];

	[connection release];
}

#pragma mark -

- (void) addBouncerSettings:(CQBouncerSettings *) bouncer {
	NSParameterAssert(bouncer != nil);

	[_bouncers addObject:bouncer];

	NSDictionary *notificationInfo = [NSDictionary dictionaryWithObject:bouncer forKey:@"bouncerSettings"];
	[[NSNotificationCenter defaultCenter] postNotificationName:CQConnectionsControllerAddedBouncerSettingsNotification object:self userInfo:notificationInfo];

	[self refreshBouncerConnectionsWithBouncerSettings:bouncer];
}

- (void) removeBouncerSettings:(CQBouncerSettings *) settings {
	[self removeBouncerSettingsAtIndex:[_bouncers indexOfObjectIdenticalTo:settings]];
}

- (void) removeBouncerSettingsAtIndex:(NSUInteger) index {
	CQBouncerSettings *bouncer = [[_bouncers objectAtIndex:index] retain];

	NSArray *connections = [[self bouncerChatConnectionsForIdentifier:bouncer.identifier] retain];
	for (MVChatConnection *connection in connections)
		[connection disconnectWithReason:[MVChatConnection defaultQuitMessage]];

	[_bouncers removeObjectAtIndex:index];
	[_bouncerChatConnections removeObjectForKey:bouncer.identifier];

	NSDictionary *notificationInfo = [NSDictionary dictionaryWithObjectsAndKeys:bouncer, @"bouncerSettings", [NSNumber numberWithUnsignedInteger:index], @"index", nil];
	[[NSNotificationCenter defaultCenter] postNotificationName:CQConnectionsControllerRemovedBouncerSettingsNotification object:self userInfo:notificationInfo];

	MVChatConnection *connection = nil;
	for (NSInteger i = (connections.count - 1); i >= 0; --i) {
		connection = [connections objectAtIndex:i];
		notificationInfo = [NSDictionary dictionaryWithObjectsAndKeys:connection, @"connection", [NSNumber numberWithUnsignedInteger:i], @"index", nil];
		[[NSNotificationCenter defaultCenter] postNotificationName:CQConnectionsControllerRemovedConnectionNotification object:self userInfo:notificationInfo];
	}

	[bouncer release];
	[connections release];
}
@end

#pragma mark -

@implementation MVChatConnection (CQConnectionsControllerAdditions)
+ (NSString *) defaultNickname {
	NSString *defaultNickname = [[NSUserDefaults standardUserDefaults] stringForKey:@"CQDefaultNickname"];
	if (defaultNickname.length)
		return defaultNickname;

#if TARGET_IPHONE_SIMULATOR
	return NSUserName();
#else
	static NSString *generatedNickname;
	if (!generatedNickname) {
		NSCharacterSet *badCharacters = [[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz1234567890"] invertedSet];
		NSArray *components = [[UIDevice currentDevice].name componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		for (NSString *compontent in components) {
			if ([compontent isCaseInsensitiveEqualToString:@"iPhone"] || [compontent isCaseInsensitiveEqualToString:@"iPod"] || [compontent isCaseInsensitiveEqualToString:@"iPad"])
				continue;
			if ([compontent isEqualToString:@"3G"] || [compontent isEqualToString:@"3GS"] || [compontent isEqualToString:@"S"] || [compontent isCaseInsensitiveEqualToString:@"Touch"])
				continue;
			if ([compontent hasCaseInsensitiveSuffix:@"'s"])
				compontent = [compontent substringWithRange:NSMakeRange(0, (compontent.length - 2))];
			if (!compontent.length)
				continue;
			generatedNickname = [[compontent stringByReplacingCharactersInSet:badCharacters withString:@""] copy];
			break;
		}
	}

	if (generatedNickname.length)
		return generatedNickname;

	return NSLocalizedString(@"ColloquyUser", @"Default nickname");
#endif
}

+ (NSString *) defaultRealName {
	NSString *defaultRealName = [[NSUserDefaults standardUserDefaults] stringForKey:@"CQDefaultRealName"];
	if (defaultRealName.length)
		return defaultRealName;

#if TARGET_IPHONE_SIMULATOR
	return NSFullUserName();
#else
	static NSString *generatedRealName;
	if (!generatedRealName) {
		// This might only work for English users, but it is fine for now.
		NSString *deviceName = [UIDevice currentDevice].name;
		NSRange range = [deviceName rangeOfString:@"'s" options:NSLiteralSearch];
		if (range.location != NSNotFound)
			generatedRealName = [[deviceName substringToIndex:range.location] copy];
	}

	if (generatedRealName.length)
		return generatedRealName;
#endif

	return NSLocalizedString(@"Colloquy User", @"Default real name");
}

+ (NSString *) defaultUsernameWithNickname:(NSString *) nickname {
	NSCharacterSet *badCharacters = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz"] invertedSet];
	NSString *username = [[nickname lowercaseString] stringByReplacingCharactersInSet:badCharacters withString:@""];
	if (username.length)
		return username;
	return @"mobile";
}

+ (NSString *) defaultQuitMessage {
	return [[NSUserDefaults standardUserDefaults] stringForKey:@"JVQuitMessage"];
}

+ (NSStringEncoding) defaultEncoding {
	return [[NSUserDefaults standardUserDefaults] integerForKey:@"JVChatEncoding"];
}

#pragma mark -

- (void) setDisplayName:(NSString *) name {
	NSParameterAssert(name != nil);

	if ([name isEqualToString:self.displayName])
		return;

	[self setPersistentInformationObject:name forKey:@"description"];
}

- (NSString *) displayName {
	NSString *name = [self persistentInformationObjectForKey:@"description"];
	if (!name.length)
		return self.server;
	return name;
}

#pragma mark -

- (void) setAutomaticJoinedRooms:(NSArray *) rooms {
	NSParameterAssert(rooms != nil);

	[self setPersistentInformationObject:rooms forKey:@"rooms"];
}

- (NSArray *) automaticJoinedRooms {
	return [self persistentInformationObjectForKey:@"rooms"];
}

#pragma mark -

- (void) setAutomaticCommands:(NSArray *) commands {
	NSParameterAssert(commands != nil);

	[self setPersistentInformationObject:commands forKey:@"commands"];
}

- (NSArray *) automaticCommands {
	return [self persistentInformationObjectForKey:@"commands"];
}

#pragma mark -

- (void) setAutomaticallyConnect:(BOOL) autoConnect {
	if (autoConnect == self.automaticallyConnect)
		return;

	[self setPersistentInformationObject:[NSNumber numberWithBool:autoConnect] forKey:@"automatic"];
}

- (BOOL) automaticallyConnect {
	return [[self persistentInformationObjectForKey:@"automatic"] boolValue];
}

#pragma mark -

- (void) setPushNotifications:(BOOL) push {
	if (push == self.pushNotifications)
		return;

	[self setPersistentInformationObject:[NSNumber numberWithBool:push] forKey:@"push"];
	
	[self sendPushNotificationCommands];
}

- (BOOL) pushNotifications {
	return [[self persistentInformationObjectForKey:@"push"] boolValue];
}

#pragma mark -

- (BOOL) isTemporaryDirectConnection {
	return [[self persistentInformationObjectForKey:@"direct"] boolValue];
}

- (void) setTemporaryDirectConnection:(BOOL) direct {
	if (direct == self.temporaryDirectConnection)
		return;

	[self setPersistentInformationObject:[NSNumber numberWithBool:direct] forKey:@"direct"];
}

- (BOOL) isDirectConnection {
	return (self.bouncerType == MVChatConnectionNoBouncer);
}

#pragma mark -

- (void) setBouncerSettings:(CQBouncerSettings *) settings {
	self.bouncerIdentifier = settings.identifier;
}

- (CQBouncerSettings *) bouncerSettings {
	return [[CQConnectionsController defaultController] bouncerSettingsForIdentifier:self.bouncerIdentifier];
}

#pragma mark -

- (void) setBouncerIdentifier:(NSString *) identifier {
	if ([identifier isEqualToString:self.bouncerIdentifier])
		return;

	if (identifier.length)
		[self setPersistentInformationObject:identifier forKey:@"bouncerIdentifier"];
	else [self removePersistentInformationObjectForKey:@"bouncerIdentifier"];
}

- (NSString *) bouncerIdentifier {
	return [self persistentInformationObjectForKey:@"bouncerIdentifier"];
}

#pragma mark -

- (void) savePasswordsToKeychain {
	// Remove old passwords using the previous account naming scheme.
	[[CQKeychain standardKeychain] removePasswordForServer:self.server area:self.preferredNickname];
	[[CQKeychain standardKeychain] removePasswordForServer:self.server area:@"<<server password>>"];

	// Store passwords using the new account naming scheme.
	[[CQKeychain standardKeychain] setPassword:self.nicknamePassword forServer:self.uniqueIdentifier area:[NSString stringWithFormat:@"Nickname %@", self.preferredNickname]];
	[[CQKeychain standardKeychain] setPassword:self.password forServer:self.uniqueIdentifier area:@"Server"];
}

- (void) loadPasswordsFromKeychain {
	NSString *password = nil;

	// Try reading passwords using the old account naming scheme.
	if ((password = [[CQKeychain standardKeychain] passwordForServer:self.server area:self.preferredNickname]) && password.length)
		self.nicknamePassword = password;

	if ((password = [[CQKeychain standardKeychain] passwordForServer:self.server area:@"<<server password>>"]) && password.length)
		self.password = password;

	// Try reading password using the name account naming scheme.
	if ((password = [[CQKeychain standardKeychain] passwordForServer:self.uniqueIdentifier area:[NSString stringWithFormat:@"Nickname %@", self.preferredNickname]]) && password.length)
		self.nicknamePassword = password;

	if ((password = [[CQKeychain standardKeychain] passwordForServer:self.uniqueIdentifier area:@"Server"]) && password.length)
		self.password = password;
}

#pragma mark -

- (void) connectAppropriately {
	[self setPersistentInformationObject:[NSNumber numberWithBool:YES] forKey:@"tryBouncerFirst"];

	[self connect];
}

- (void) connectDirectly {
	self.temporaryDirectConnection = YES;

	[self connect];
}

#pragma mark -

- (void) sendPushNotificationCommands {
	if (!self.connected && self.status != MVChatConnectionConnectingStatus)
		return;

	NSString *deviceToken = [CQColloquyApplication sharedApplication].deviceToken;
	if (!deviceToken.length)
		return;

	NSNumber *currentState = [self persistentInformationObjectForKey:@"pushState"];

	CQBouncerSettings *settings = self.bouncerSettings;
	if ((!settings || settings.pushNotifications) && self.pushNotifications && (!currentState || ![currentState boolValue])) {
		[self setPersistentInformationObject:[NSNumber numberWithBool:YES] forKey:@"pushState"];

		[self sendRawMessageWithFormat:@"PUSH add-device %@ :%@", deviceToken, [UIDevice currentDevice].name];

		[self sendRawMessage:@"PUSH service colloquy.mobi 7906"];

		[self sendRawMessageWithFormat:@"PUSH connection %@ :%@", self.uniqueIdentifier, self.displayName];

		NSArray *highlightWords = [CQColloquyApplication sharedApplication].highlightWords;
		for (NSString *highlightWord in highlightWords)
			[self sendRawMessageWithFormat:@"PUSH highlight-word :%@", highlightWord];

		NSString *sound = [[NSUserDefaults standardUserDefaults] stringForKey:@"CQSoundOnHighlight"];
		if (sound.length && ![sound isEqualToString:@"None"])
			[self sendRawMessageWithFormat:@"PUSH highlight-sound :%@.aiff", sound];
		else [self sendRawMessageWithFormat:@"PUSH highlight-sound none"];

		sound = [[NSUserDefaults standardUserDefaults] stringForKey:@"CQSoundOnPrivateMessage"];
		if (sound.length && ![sound isEqualToString:@"None"])
			[self sendRawMessageWithFormat:@"PUSH message-sound :%@.aiff", sound];
		else [self sendRawMessageWithFormat:@"PUSH message-sound none"];

		[self sendRawMessage:@"PUSH end-device"];
	} else if ((!currentState || [currentState boolValue])) {
		[self setPersistentInformationObject:[NSNumber numberWithBool:NO] forKey:@"pushState"];

		[self sendRawMessageWithFormat:@"PUSH remove-device :%@", deviceToken];
	}
}
@end
