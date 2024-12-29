//
//  BuildSettingExtractor.m
//  BuildSettingExtractor
//
//  Created by James Dempsey on 1/30/15.
//  Copyright (c) 2015 Tapas Software. All rights reserved.
//

#import "BuildSettingExtractor.h"
#import "BuildSettingCommentGenerator.h"
#import "BuildSettingInfoSource.h"
#import "Constants+Categories.h"

static NSSet *XcodeCompatibilityVersionStringSet(void) {
    static NSSet *_compatibilityVersionStringSet;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _compatibilityVersionStringSet = [NSSet setWithObjects:@"Xcode 3.2", @"Xcode 6.3", @"Xcode 8.0", @"Xcode 9.3", @"Xcode 10.0", @"Xcode 11.0", @"Xcode 11.4", @"Xcode 12.0", @"Xcode 13.0", @"Xcode 14.0", @"Xcode 15.0", nil];
    });
    return _compatibilityVersionStringSet;
}

@interface BuildSettingExtractor ()
@property (strong) NSMutableDictionary *buildSettingsByTarget;
@property (strong) NSDictionary *objects;
@property (nullable) NSString *validatedProjectConfigName;
@property BOOL extractionSuccessful;

@property (strong) BuildSettingCommentGenerator *buildSettingCommentGenerator;
@end

@implementation BuildSettingExtractor

+ (NSString *)defaultSharedConfigName {
    return @"Shared";
}

+ (NSString *)defaultProjectConfigName {
    return @"Project";
}

+ (NSString *)defaultNameSeparator {
    return @"-";
}

+ (NSString *)defaultDestinationFolderName {
    return @"xcconfig";
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sharedConfigName = [[self class] defaultSharedConfigName];
        _projectConfigName = [[self class] defaultProjectConfigName];
        _nameSeparator = [[self class] defaultNameSeparator];
        _buildSettingsByTarget = [[NSMutableDictionary alloc] init];
        _buildSettingCommentGenerator = nil;
        _validatedProjectConfigName = nil;
        _extractionSuccessful = NO;
    }
    return self;
}

/* Given a dictionary and key whose value is an array of object identifiers, return the identified objects in an array */
- (NSArray *)objectArrayForDictionary:(NSDictionary *)dict key:(NSString *)key {
    NSArray *identifiers = dict[key];
    NSMutableArray *objectArray = [[NSMutableArray alloc] init];
    for (NSString *identifier in identifiers) {
        id obj = self.objects[identifier];
        [objectArray addObject:obj];
    }
    return objectArray;
}


+ (BOOL)validateDestinationFolder:(NSURL *)destinationURL error:(NSError **)error {

    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtURL:destinationURL includingPropertiesForKeys:@[NSURLTypeIdentifierKey] options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants errorHandler:nil];

    BOOL foundBuildConfigFile = NO;

    NSURL *currentURL = nil;
    while (currentURL = [enumerator nextObject]) {
        // Only check three levels deep, in case user chooses something like the home folder
        if (enumerator.level > 3) {
            [enumerator skipDescendants];
            continue;
        }
        NSString *typeIdentifier = nil;
        NSError *resourceError = nil;
        [currentURL getResourceValue:&typeIdentifier forKey:NSURLTypeIdentifierKey error:&resourceError];
        if ([typeIdentifier isEqualToString:[NSString tps_buildConfigurationFileTypeIdentifier]]) {
            foundBuildConfigFile = YES;
            break;
        }
    }
    
    BOOL isValid = !foundBuildConfigFile;

    if (foundBuildConfigFile) {
        if (error) {
            *error = [NSError errorForDestinationContainsBuildConfigFiles];
        }
    }
    
    return isValid;
}


- (NSArray *)extractBuildSettingsFromProject:(NSURL *)projectWrapperURL error:(NSError **)error {

    NSMutableArray *nonFatalErrors = [[NSMutableArray alloc] init];
    
    [self.buildSettingsByTarget removeAllObjects];

    if (self.includeBuildSettingInfoComments) {

        NSError *infoSourceError = nil;
        BuildSettingInfoSource *infoSource = [BuildSettingInfoSource resolvedBuildSettingInfoSourceWithStyle:BuildSettingInfoSourceStyleStandard customURL:nil error:&infoSourceError];

        if (infoSource) {
            self.buildSettingCommentGenerator = [[BuildSettingCommentGenerator alloc] initWithBuildSettingInfoSource:infoSource];
        } else {
            // If no info source, fallback to basic formatting
            self.includeBuildSettingInfoComments = NO;
            self.linesBetweenSettings = 0;
        }
        
        if (infoSourceError) {
            [nonFatalErrors addObject:infoSourceError];
        }
    }

    NSURL *projectFileURL = [projectWrapperURL URLByAppendingPathComponent:@"project.pbxproj"];

    NSData *fileData = [NSData dataWithContentsOfURL:projectFileURL options:0 error:error];
    if (!fileData) {
        return nil;
    }
        
    NSDictionary *projectPlist = [NSPropertyListSerialization propertyListWithData:fileData options:NSPropertyListImmutable format:NULL error:error];
    if (!projectPlist) {
        return nil;
    }
            
    // Get root object (project)
    self.objects = projectPlist[@"objects"];
    NSDictionary *rootObject = self.objects[projectPlist[@"rootObject"]];

    // Check compatibility version
    NSString *compatibilityVersion = rootObject[@"compatibilityVersion"];
    if (![XcodeCompatibilityVersionStringSet() containsObject:compatibilityVersion]) {
        if (error) {
            *error = [NSError errorForUnsupportedProjectURL:projectWrapperURL fileVersion:compatibilityVersion];
        }
        return nil;
    }
            
    // Get project targets
    NSArray *targets = [self objectArrayForDictionary:rootObject key:@"targets"];
    
    // Validate project config name to guard against name conflicts with target names
    NSError *nameValdationError = nil;
    NSArray *targetNames = [targets valueForKeyPath:@"name"];
    self.validatedProjectConfigName = [self validatedProjectConfigNameWithTargetNames:targetNames error: &nameValdationError];
    
    if (nameValdationError) {
        [nonFatalErrors addObject:nameValdationError];
    }
    
    // Get project settings
    NSString *buildConfigurationListID = rootObject[@"buildConfigurationList"];
    NSDictionary *projectSettings = [self buildSettingStringsByConfigurationForBuildConfigurationListID:buildConfigurationListID];

    self.buildSettingsByTarget[self.validatedProjectConfigName] = projectSettings;
    
    // Begin check that the project file has some settings
    BOOL projectFileHasSettings = projectSettings.tps_containsBuildSettings;

    // Add project targets
    for (NSDictionary *target in targets) {
        NSString *targetName = target[@"name"];
        buildConfigurationListID = target[@"buildConfigurationList"];
        NSDictionary *targetSettings = [self buildSettingStringsByConfigurationForBuildConfigurationListID:buildConfigurationListID];
        if (!projectFileHasSettings) { projectFileHasSettings = targetSettings.tps_containsBuildSettings; }

        self.buildSettingsByTarget[targetName] = targetSettings;

    }
    
    if (!projectFileHasSettings) {
        if (error) {
            *error = [NSError errorForNoSettingsFoundInProject: [projectWrapperURL lastPathComponent]];
        }
        return nil;
    }


    self.extractionSuccessful = YES;
    return nonFatalErrors;
}

// This will return a validated project config name to guard against naming conflicts with targets
// If a conflict is found, the project config files will have "-Project-Settings" appended to the
// provided project config name, using the user-specified name separator between words.
- (NSString *)validatedProjectConfigNameWithTargetNames:(NSArray *)targetNames error:(NSError **)error {
    NSString *validatedProjectConfigName = self.projectConfigName;
    if ([targetNames containsObject:self.projectConfigName]) {
        validatedProjectConfigName = [validatedProjectConfigName stringByAppendingFormat:@"%@Project%@Settings", self.nameSeparator, self.nameSeparator];
        if (error) {
            *error = [NSError errorForNameConflictWithName:self.projectConfigName validatedName:validatedProjectConfigName];
        }
    }
    return validatedProjectConfigName;
}

/* Writes an xcconfig file for each target / configuration combination to the specified directory.
 */
- (BOOL)writeConfigFilesToDestinationFolder:(NSURL *)destinationURL error:(NSError **)error {
    
    // It is a programming error to try to write before extracting or to call this method after extracting build settings has failed.
    if (!self.extractionSuccessful) {
        [NSException raise:NSInternalInconsistencyException format:@"The method -writeConfigFilesToDestinationFolder:error: was called before successful completion of -extractBuildSettingsFromProject:error:. Callers of this method must call -extractBuildSettingsFromProject:error: first and check for a non-nil return value indicating success."];
    }

    __block BOOL success = YES;
    __block NSError *blockError = nil;
    
    [self.buildSettingsByTarget enumerateKeysAndObjectsUsingBlock:^(id targetName, id obj, BOOL *stop) {
        [obj enumerateKeysAndObjectsUsingBlock:^(id configName, id settings, BOOL *stop) {

            NSString *filename = [self configFilenameWithTargetName:targetName configName:configName];

            NSString *configFileString = @"";

            // Add header comment
//            NSString *headerComment = [self headerCommentForFilename:filename];
//            if (headerComment) {
//                configFileString = [configFileString stringByAppendingString:headerComment];
//            }

            // If the config name is not the shared config, we need to import the shared config
            if (![configName isEqualToString:self.sharedConfigName]) {
                NSString *configFilename = [self configFilenameWithTargetName:targetName configName:self.sharedConfigName];
                NSString *includeDirective = [NSString stringWithFormat:@"\n\n#include \"%@\"", configFilename];
                configFileString = [configFileString stringByAppendingString:includeDirective];
            }

            configFileString = [configFileString stringByAppendingString:@"\n\n"];
            configFileString = [configFileString stringByAppendingString:settings];

            // Trim whitespace and newlines
            configFileString = [configFileString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

            BOOL isProcessingProjectConfigFiles = [targetName isEqualToString:self.validatedProjectConfigName];
            BOOL currentTargetCanUseFolder = isProcessingProjectConfigFiles ? self.projectFolderEnabled : YES;
            
            NSURL *fileURL = nil;
            if (self.targetFoldersEnabled && currentTargetCanUseFolder) {
                fileURL = [destinationURL URLByAppendingPathComponent:targetName];
                success = [[NSFileManager defaultManager] createDirectoryAtURL:fileURL withIntermediateDirectories:YES attributes:nil error:&blockError];
                fileURL = [fileURL URLByAppendingPathComponent:filename];
            } else {
                fileURL = [destinationURL URLByAppendingPathComponent:filename];
            }

            // Don't write to file if directory creation failed
            if (success) {
                success = [configFileString writeToURL:fileURL atomically:YES encoding:NSUTF8StringEncoding error:&blockError];
            }
            // If we failed to write a configuration, stop iterating through this target's configurations
            if (!success) { *stop = YES; }
        }];
        
        // If we failed writing a target's configurations, stop iterating through targets
        if (!success) { *stop = YES; }
    }];
    
    if (!success && error) {
        *error = blockError;
    }
    
    return success;
}

// Given the target name and config name returns the xcconfig filename to be used.
- (NSString *)configFilenameWithTargetName:(NSString *)targetName configName:(NSString *)configName {

    // Use empty separator if there is no config name
    NSString *separator = configName.length ? self.nameSeparator: @"";

    NSString *filename = [NSString stringWithFormat:@"%@%@%@.xcconfig", targetName, separator, configName];
    
    // Replace all spaces in filename with separator.
    filename = [filename stringByReplacingOccurrencesOfString:@" " withString:self.nameSeparator];

    return filename;
}

// Given the filename generate the header comment
- (NSString *)headerCommentForFilename:(NSString *)filename {
    NSString *headerComment = @"";

    NSString *dateString = [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterNoStyle];

    headerComment = [headerComment stringByAppendingString:@"//\n"];
    headerComment = [headerComment stringByAppendingFormat:@"// %@\n", filename];
    headerComment = [headerComment stringByAppendingString:@"//\n"];
    headerComment = [headerComment stringByAppendingFormat:@"// Generated by BuildSettingExtractor on %@\n", dateString];
    headerComment = [headerComment stringByAppendingString:@"// https://buildsettingextractor.com\n"];
    headerComment = [headerComment stringByAppendingString:@"//"];

    return headerComment;
}


/* Given a build setting dictionary, returns a string representation of the build settings, suitable for an xcconfig file. */
- (NSString *)stringRepresentationOfBuildSettings:(NSDictionary *)buildSettings {
    return [BuildSettingExtractor stringRepresentationOfBuildSettings:buildSettings includeBuildSettingInfoComments:self.includeBuildSettingInfoComments alignBuildSettingValues:self.alignBuildSettingValues linesBetweenSettings:self.linesBetweenSettings commentGenerator:self.buildSettingCommentGenerator];
}

/* Given a build setting dictionary and a set of options, returns a string representation of the build settings, suitable for an xcconfig file. Logic is shared between generating xcconfig files and providing a formatting example. */
+ (NSString *)stringRepresentationOfBuildSettings:(NSDictionary *)buildSettings includeBuildSettingInfoComments:(BOOL)includeBuildSettingInfoComments alignBuildSettingValues:(BOOL)alignBuildSettingValues linesBetweenSettings:(NSInteger)linesBetweenSettings commentGenerator:(BuildSettingCommentGenerator *) buildSettingCommentGenerator {
    NSMutableString *string = [[NSMutableString alloc] init];

    // Sort build settings by name for easier reading and testing. Case insensitive compare should stay stable regardess of locale.
    NSArray *sortedKeys = [[buildSettings allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];

    NSUInteger maxKeyLength = 0;
    if (alignBuildSettingValues) {
        for (NSString *key in sortedKeys) {
            maxKeyLength = MAX(maxKeyLength, key.length);
        }
    }
    
    BOOL firstKey = YES;
    NSString *previousKey = nil;
    for (NSString *key in sortedKeys) {
        id value = buildSettings[key];

        // If same base setting name as previous key, this is a conditional build setting.
        // Don't put newlines between them and don't repeat the build setting info comment.
        BOOL sameBaseSettingName = [previousKey tps_baseBuildSettingNameIsEqualTo:key]; // nil previousKey returns nil aka NO
        
        if (!firstKey && !sameBaseSettingName){
            for (NSInteger i = 0; i < linesBetweenSettings; i++) {
                [string appendString:@"\n"];
            }
        }

        if (includeBuildSettingInfoComments && !sameBaseSettingName) {
            NSString *comment = [buildSettingCommentGenerator commentForBuildSettingWithName:key];
            [string appendString:comment];
        }
        
        [string appendString:key];
        if (alignBuildSettingValues) {
            for (NSUInteger currentLength = key.length; currentLength < maxKeyLength; currentLength++) {
                [string appendString:@" "];
            }
        }

        if ([value isKindOfClass:[NSString class]]) {
            [string appendFormat:@" = %@\n", value];

        } else if ([value isKindOfClass:[NSArray class]]) {
            [string appendFormat:@" = %@\n", [value componentsJoinedByString:@" "]];
        } else {
            [NSException raise:@"Should not get here!" format:@"Unexpected class: %@ in %s", [value class], __PRETTY_FUNCTION__];
        }

        previousKey = key;
        firstKey = NO;
    }
    
    return string;
}

/* Given a build configuration list ID, retrieves the list of build configurations, consolidates shared build settings into a shared configuration and returns a dictionary of build settings configurations as strings, keyed by configuration name. */
- (NSDictionary *)buildSettingStringsByConfigurationForBuildConfigurationListID:(NSString *)buildConfigurationListID {

    // Get the array of build configuration objects for the build configuration list ID
    NSDictionary *buildConfigurationList = self.objects[buildConfigurationListID];
    NSArray *projectBuildConfigurations = [self objectArrayForDictionary:buildConfigurationList key:@"buildConfigurations"];


    NSDictionary *buildSettingsByConfiguration = [self buildSettingsByConfigurationForConfigurations:projectBuildConfigurations];

    // Turn each build setting into a build setting string. Store by configuration name
    NSMutableDictionary *buildSettingStringsByConfiguration = [[NSMutableDictionary alloc] init];
    [buildSettingsByConfiguration enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        NSString *buildSettingsString = [self stringRepresentationOfBuildSettings:obj];
        [buildSettingStringsByConfiguration setValue:buildSettingsString forKey:key];

    }];
    return buildSettingStringsByConfiguration;

}


/* Given an array of build configuration dictionaries, removes common build settings into a shared build configuration and returns a dictionary of build settings dictionaries, keyed by configuration name.
 */
- (NSDictionary *)buildSettingsByConfigurationForConfigurations:(NSArray *)buildConfigurations {

    NSMutableDictionary *buildSettingsByConfiguration = [[NSMutableDictionary alloc] init];

    NSMutableDictionary *sharedBuildSettings = [[NSMutableDictionary alloc] init];
    NSDictionary *firstBuildSettings = nil;
    NSInteger index = 0;

    for (NSDictionary *buildConfiguration in buildConfigurations) {

        NSDictionary *buildSettings = buildConfiguration[@"buildSettings"];

        // Use first build settings as a starting point, represents all settings after first iteration
        if (index == 0) {
            firstBuildSettings = buildSettings;

        }

        // Second iteration, compare second against first build settings to come up with common items
        else if (index == 1){
            [firstBuildSettings enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                id otherObj = buildSettings[key];
                if ([obj isEqualTo:otherObj]) {
                    sharedBuildSettings[key] = obj;
                }
            }];
        }

        // Subsequent iteratons, remove common items that don't match current config settings
        else {
            [[sharedBuildSettings copy] enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                id otherObj = buildSettings[key];
                if (![obj isEqualTo:otherObj]) {
                    [sharedBuildSettings removeObjectForKey:key];
                }
            }];
        }

        index++;
    }

    [buildSettingsByConfiguration setValue:sharedBuildSettings forKey:self.sharedConfigName];

    NSArray *sharedKeys = [sharedBuildSettings allKeys];
    for (NSDictionary *projectBuildConfiguration in buildConfigurations) {
        NSString *configName = projectBuildConfiguration[@"name"];
        NSMutableDictionary *buildSettings = projectBuildConfiguration[@"buildSettings"];
        [buildSettings removeObjectsForKeys:sharedKeys];
        [buildSettingsByConfiguration setValue:buildSettings forKey:configName];
        
    }
    
    return buildSettingsByConfiguration;
}

+ (NSString *)exampleBuildFormattingStringForSettings:(NSDictionary *)settings includeBuildSettingInfoComments:(BOOL)includeBuildSettingInfoComments alignBuildSettingValues:(BOOL)alignBuildSettingValues linesBetweenSettings:(NSInteger)linesBetweenSettings {
    
    BuildSettingCommentGenerator *buildSettingCommentGenerator = nil;
    
    if (includeBuildSettingInfoComments) {

        NSError *infoSourceError = nil;
        BuildSettingInfoSource *infoSource = [BuildSettingInfoSource resolvedBuildSettingInfoSourceWithStyle:BuildSettingInfoSourceStyleStandard customURL:nil error:&infoSourceError];

        if (infoSource) {
            buildSettingCommentGenerator = [[BuildSettingCommentGenerator alloc] initWithBuildSettingInfoSource:infoSource];
        }
    }

    return [BuildSettingExtractor stringRepresentationOfBuildSettings:settings includeBuildSettingInfoComments:includeBuildSettingInfoComments alignBuildSettingValues:alignBuildSettingValues linesBetweenSettings:linesBetweenSettings commentGenerator:buildSettingCommentGenerator];
}

@end
