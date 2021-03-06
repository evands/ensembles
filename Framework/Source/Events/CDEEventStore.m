//
//  CDEEventStore.m
//  Test App iOS
//
//  Created by Drew McCormack on 4/15/13.
//  Copyright (c) 2013 The Mental Faculty B.V. All rights reserved.
//

#import "CDEEventStore.h"
#import "CDEDefines.h"
#import "CDEStoreModificationEvent.h"


NSString * const kCDEPersistentStoreIdentifierKey = @"persistentStoreIdentifier";
NSString * const kCDECloudFileSystemIdentityKey = @"cloudFileSystemIdentity";
NSString * const kCDEIncompleteEventIdentifiersKey = @"incompleteEventIdentifiers";
NSString * const kCDEVerifiesStoreRegistrationInCloudKey = @"verifiesStoreRegistrationInCloud";

static NSString *defaultPathToEventDataRootDirectory = nil;


@interface CDEEventStore ()

@property (nonatomic, copy, readwrite) NSString *pathToEventStoreRootDirectory;
@property (nonatomic, strong, readonly) NSString *pathToEventStore;
@property (nonatomic, strong, readonly) NSString *pathToBlobsDirectory;
@property (nonatomic, strong, readonly) NSString *pathToStoreInfoFile;
@property (nonatomic, copy, readwrite) NSString *persistentStoreIdentifier;
@property (nonatomic, assign, readwrite) CDERevisionNumber lastSaveRevision;
@property (nonatomic, assign, readwrite) CDERevisionNumber lastMergeRevision;

@end


@implementation CDEEventStore {
    NSMutableDictionary *incompleteEventIdentifiers;
    NSRecursiveLock *lock;
}

@synthesize ensembleIdentifier = ensembleIdentifier;
@synthesize managedObjectContext = managedObjectContext;
@synthesize persistentStoreIdentifier = persistentStoreIdentifier;
@synthesize pathToEventDataRootDirectory = pathToEventDataRootDirectory;
@synthesize cloudFileSystemIdentityToken = cloudFileSystemIdentityToken;
@synthesize verifiesStoreRegistrationInCloud = verifiesStoreRegistrationInCloud;

+ (void)initialize
{
    if ([CDEEventStore class] == self) {
        NSArray *urls = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask];
        NSString *appSupportDir = [(NSURL *)urls.lastObject path];
        NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
        if (!bundleIdentifier) bundleIdentifier = @"com.mentalfaculty.ensembles.tests";
        NSString *path = [appSupportDir stringByAppendingPathComponent:bundleIdentifier];
        path = [path stringByAppendingPathComponent:@"com.mentalfaculty.ensembles.eventdata"];
        [self setDefaultPathToEventDataRootDirectory:path];
    }
}

// Designated
- (instancetype)initWithEnsembleIdentifier:(NSString *)newIdentifier pathToEventDataRootDirectory:(NSString *)rootDirectory
{
    NSParameterAssert(newIdentifier != nil);
    self = [super init];
    if (self) {
        pathToEventDataRootDirectory = [rootDirectory copy];
        if (!pathToEventDataRootDirectory) pathToEventDataRootDirectory = [self.class defaultPathToEventDataRootDirectory];
        
        ensembleIdentifier = [newIdentifier copy];
        incompleteEventIdentifiers = nil;
        
        [self restoreStoreMetadata];

        NSError *error;
        if (self.persistentStoreIdentifier && ![self setupCoreDataStack:&error] ) {
            CDELog(CDELoggingLevelError, @"Could not setup core data stack for event store: %@", error);
            return nil;
        }
        
        lock = [[NSRecursiveLock alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


#pragma mark - Locking

- (void)lock
{
    [lock lock];
}

- (void)unlock
{
    [lock unlock];
}

- (BOOL)tryLock
{
    return [lock tryLock];
}


#pragma mark - Store Metadata

- (void)saveStoreMetadata
{
    NSDictionary *dictionary = @{};
    if (self.persistentStoreIdentifier) {
        NSData *identityData = [NSKeyedArchiver archivedDataWithRootObject:self.cloudFileSystemIdentityToken];
        dictionary = @{
           kCDEPersistentStoreIdentifierKey : self.persistentStoreIdentifier,
           kCDECloudFileSystemIdentityKey : identityData,
           kCDEIncompleteEventIdentifiersKey : incompleteEventIdentifiers,
           kCDEVerifiesStoreRegistrationInCloudKey : @(self.verifiesStoreRegistrationInCloud)
        };
    }
    
    if (![dictionary writeToFile:self.pathToStoreInfoFile atomically:YES]) {
        CDELog(CDELoggingLevelError, @"Could not write store info file");
    }
}

- (void)restoreStoreMetadata
{
    NSString *path = self.pathToStoreInfoFile;
    NSDictionary *storeMetadata = [NSDictionary dictionaryWithContentsOfFile:path];
    if (storeMetadata) {
        NSData *identityData = storeMetadata[kCDECloudFileSystemIdentityKey];
        cloudFileSystemIdentityToken = identityData ? [NSKeyedUnarchiver unarchiveObjectWithData:identityData] : nil;
        persistentStoreIdentifier = storeMetadata[kCDEPersistentStoreIdentifierKey];
        incompleteEventIdentifiers = [storeMetadata[kCDEIncompleteEventIdentifiersKey] mutableCopy];
        
        NSNumber *value = storeMetadata[kCDEVerifiesStoreRegistrationInCloudKey];
        verifiesStoreRegistrationInCloud = value ? value.boolValue : NO;
    }
    else {
        cloudFileSystemIdentityToken = nil;
        persistentStoreIdentifier = nil;
        incompleteEventIdentifiers = nil;
        verifiesStoreRegistrationInCloud = YES;
    }
    
    if (!incompleteEventIdentifiers) {
        incompleteEventIdentifiers = [NSMutableDictionary dictionary];
    }
}


#pragma mark - Incomplete Events

- (void)registerIncompleteEventIdentifier:(NSString *)identifier isMandatory:(BOOL)mandatory
{
    [incompleteEventIdentifiers setObject:@(mandatory) forKey:identifier];
    [self saveStoreMetadata];
}

- (void)deregisterIncompleteEventIdentifier:(NSString *)identifier
{
    [incompleteEventIdentifiers removeObjectForKey:identifier];
    [self saveStoreMetadata];
}

- (NSArray *)incompleteEventIdentifiers
{
    return [incompleteEventIdentifiers.allKeys copy];
}

- (NSArray *)incompleteMandatoryEventIdentifiers
{
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:incompleteEventIdentifiers.count];
    for (NSString *identifier in incompleteEventIdentifiers) {
        if ([incompleteEventIdentifiers[identifier] boolValue]) {
            [result addObject:identifier];
        }
    }
    return result;
}


#pragma mark - Revisions

- (CDERevisionNumber)lastRevisionNumberForEventRevisionPredicate:(NSPredicate *)predicate
{
    __block CDERevisionNumber result = -1;
    [self.managedObjectContext performBlockAndWait:^{
        NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:@"CDEEventRevision"];
        request.predicate = predicate;
        request.propertiesToFetch = @[@"revisionNumber"];
        
        NSError *error = nil;
        NSArray *revisions = [self.managedObjectContext executeFetchRequest:request error:&error];
        if (!revisions) @throw [NSException exceptionWithName:CDEException reason:@"Failed to fetch revisions" userInfo:nil];
        
        if (revisions.count > 0) {
            NSNumber *max = [revisions valueForKeyPath:@"@max.revisionNumber"];
            result = max.longLongValue;
        }
    }];
    CDERevisionNumber returnNumber = result;
    return returnNumber;
}

- (CDERevisionNumber)lastMergeRevision
{
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"persistentStoreIdentifier = %@ AND storeModificationEvent.type = %d", self.persistentStoreIdentifier, CDEStoreModificationEventTypeMerge];
    CDERevisionNumber result = [self lastRevisionNumberForEventRevisionPredicate:predicate];
    return result;
}

- (CDERevisionNumber)lastSaveRevision
{
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"persistentStoreIdentifier = %@ AND storeModificationEvent.type = %d", self.persistentStoreIdentifier, CDEStoreModificationEventTypeSave];
    CDERevisionNumber result = [self lastRevisionNumberForEventRevisionPredicate:predicate];
    return result;
}

- (CDERevisionNumber)lastRevision
{
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"persistentStoreIdentifier = %@", self.persistentStoreIdentifier];
    CDERevisionNumber result = [self lastRevisionNumberForEventRevisionPredicate:predicate];
    return result;
}


#pragma mark - Flushing out queued operations

- (void)flush:(NSError * __autoreleasing *)error
{
    [self saveStoreMetadata];
    [self.managedObjectContext performBlockAndWait:^{
        [managedObjectContext save:error];
    }];
}


#pragma mark - Removing and Installing

- (BOOL)prepareNewEventStore:(NSError * __autoreleasing *)error
{
    [self removeEventStore];
    
    // Directories
    BOOL success = [self createEventStoreDirectoriesIfNecessary:error];
    if (!success) return NO;
    
    // Core Data Stack. 
    success = [self setupCoreDataStack:error];
    if (!success) return NO;
    
    // Store store info
    persistentStoreIdentifier = [[NSProcessInfo processInfo] globallyUniqueString];
    incompleteEventIdentifiers = [NSMutableDictionary dictionary];
    [self saveStoreMetadata];
    
    return YES;
}

- (BOOL)removeEventStore
{
    self.persistentStoreIdentifier = nil;
    incompleteEventIdentifiers = nil;
    [self tearDownCoreDataStack];
    return [[NSFileManager defaultManager] removeItemAtPath:self.pathToEventStoreRootDirectory error:NULL];
}

- (BOOL)containsEventData
{
    return self.persistentStoreIdentifier && self.managedObjectContext;
}


#pragma mark - Paths

+ (NSString *)defaultPathToEventDataRootDirectory
{
    return defaultPathToEventDataRootDirectory;
}

+ (void)setDefaultPathToEventDataRootDirectory:(NSString *)newPath
{
    NSParameterAssert(newPath != nil);
    defaultPathToEventDataRootDirectory = [newPath copy];
}

- (NSString *)pathToEventStoreRootDirectory
{
    NSString *path = [self.pathToEventDataRootDirectory stringByAppendingPathComponent:self.ensembleIdentifier];
    return path;
}

- (NSString *)pathToEventStore
{
    return [self.pathToEventStoreRootDirectory stringByAppendingPathComponent:@"events.sqlite"];
}

- (NSString *)pathToStoreInfoFile
{
    return [self.pathToEventStoreRootDirectory stringByAppendingPathComponent:@"store.plist"];
}

- (BOOL)createDirectoryIfNecessary:(NSString *)path error:(NSError * __autoreleasing *)error
{
    BOOL success = YES;
    BOOL isDir;
    if ( ![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] ) {
        success = [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:error];
    }
    else if (!isDir) {
        success = NO;
    }
    return success;
}

- (BOOL)createEventStoreDirectoriesIfNecessary:(NSError * __autoreleasing *)error
{
    NSString *path = [self pathToEventStoreRootDirectory];
    if (![self createDirectoryIfNecessary:path error:error]) return NO;
    
    return YES;
}


#pragma mark - Core Data Stack

- (BOOL)setupCoreDataStack:(NSError * __autoreleasing *)error
{
    NSURL *modelURL = [[NSBundle bundleForClass:[CDEEventStore class]] URLForResource:@"CDEEventStoreModel" withExtension:@"momd"];
    NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    
    NSURL *storeURL = [NSURL fileURLWithPath:self.pathToEventStore];
    NSDictionary *options = @{NSMigratePersistentStoresAutomaticallyOption: @YES, NSInferMappingModelAutomaticallyOption: @YES};
    NSPersistentStore *store = [coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:options error:error];
    if (!store) return NO;
    
    managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    [managedObjectContext performBlockAndWait:^{
        managedObjectContext.persistentStoreCoordinator = coordinator;
        managedObjectContext.undoManager = nil;
    }];
    
    BOOL success = managedObjectContext != nil;
    if (success) [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(managedObjectContextDidSave:) name:NSManagedObjectContextDidSaveNotification object:nil];
    return success;
}

- (void)tearDownCoreDataStack
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSManagedObjectContextDidSaveNotification object:nil];
    [managedObjectContext performBlockAndWait:^{
        [managedObjectContext reset];
    }];
    managedObjectContext = nil;
}


#pragma mark - Merging Changes

- (void)managedObjectContextDidSave:(NSNotification *)notif
{
    NSManagedObjectContext *context = notif.object;
    if (context.parentContext == self.managedObjectContext) {
        [self.managedObjectContext performBlockAndWait:^{
            [self.managedObjectContext mergeChangesFromContextDidSaveNotification:notif];
        }];
    }
}


@end
