//
//  MPDocument+Search.m
//  MacPass
//
//  Created by Michael Starke on 25.02.14.
//  Copyright (c) 2014 HicknHack Software GmbH. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

#import "MPDocument.h"
#import "MPDocumentWindowController.h"

#import "KeePassKit/KeePassKit.h"

#import "MPFlagsHelper.h"
#import <objc/runtime.h>

NSString *const MPDocumentDidEnterSearchNotification  = @"com.hicknhack.macpass.MPDocumentDidEnterSearchNotification";
NSString *const MPDocumentDidChangeSearchFlags        = @"com.hicknhack.macpass.MPDocumentDidChangeSearchFlagsNotification";
NSString *const MPDocumentDidExitSearchNotification   = @"com.hicknhack.macpass.MPDocumentDidExitSearchNotification";

NSString *const MPDocumentDidChangeSearchResults      = @"com.hicknhack.macpass.MPDocumentDidChangeSearchResults";

NSString *const kMPDocumentSearchResultsKey           = @"kMPDocumentSearchResultsKey";

static const void *kMPSearchGenerationKey = &kMPSearchGenerationKey;

static NSUInteger _MPSearchGeneration(MPDocument *document) {
  NSNumber *value = objc_getAssociatedObject(document, kMPSearchGenerationKey);
  return value.unsignedIntegerValue;
}

static NSUInteger _MPAdvanceSearchGeneration(MPDocument *document) {
  NSUInteger generation = _MPSearchGeneration(document) + 1;
  objc_setAssociatedObject(document, kMPSearchGenerationKey, @(generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return generation;
}

@implementation MPDocument (Search)


- (void)enterSearchWithContext:(MPEntrySearchContext *)context {
  /* the search context is loaded via defaults */
  self.searchContext = context;
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateSearch:) name:KPKTreeDidAddEntryNotification object:self.tree];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateSearch:) name:KPKTreeDidAddGroupNotification object:self.tree];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateSearch:) name:KPKTreeDidRemoveEntryNotification object:self.tree];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateSearch:) name:KPKTreeDidRemoveGroupNotification object:self.tree];

  [NSNotificationCenter.defaultCenter postNotificationName:MPDocumentDidEnterSearchNotification object:self];
  [self updateSearch:self];
  /* clear selection */
  self.selectedEntries = nil;
}

#pragma mark Actions
- (IBAction)performCustomSearch:(id)sender {
  [self enterSearchWithContext:[MPEntrySearchContext userContext]];
}

- (void)updateSearch:(id)sender {
  if(NO == self.hasSearch) {
    [self enterSearchWithContext:[MPEntrySearchContext userContext]];
    return; // We get called back!
  }
  MPDocumentWindowController *windowController = self.windowControllers.firstObject;
  self.searchContext.searchString = windowController.searchField.stringValue ?: @"";
  MPEntrySearchContext *searchContext = [self.searchContext copy];
  NSUInteger searchGeneration = _MPAdvanceSearchGeneration(self);
  MPDocument __weak *weakSelf = self;
  dispatch_queue_t backgroundQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
  dispatch_async(backgroundQueue, ^{
    MPDocument *strongSelf = weakSelf;
    if(!strongSelf) {
      return;
    }
    NSArray *results = [strongSelf _findEntriesMatchingSearch:searchContext];
    dispatch_async(dispatch_get_main_queue(), ^{
      if(!weakSelf.hasSearch || _MPSearchGeneration(weakSelf) != searchGeneration) {
        return; // Ignore stale search result updates.
      }
      [NSNotificationCenter.defaultCenter postNotificationName:MPDocumentDidChangeSearchResults object:weakSelf userInfo:@{ kMPDocumentSearchResultsKey: results }];
    });
  });
}

- (void)exitSearch:(id)sender {
  
  [NSNotificationCenter.defaultCenter removeObserver:self name:KPKTreeDidAddEntryNotification object:self.tree];
  [NSNotificationCenter.defaultCenter removeObserver:self name:KPKTreeDidAddGroupNotification object:self.tree];
  [NSNotificationCenter.defaultCenter removeObserver:self name:KPKTreeDidRemoveEntryNotification object:self.tree];
  [NSNotificationCenter.defaultCenter removeObserver:self name:KPKTreeDidRemoveGroupNotification object:self.tree];
  _MPAdvanceSearchGeneration(self);
  
  self.searchContext = nil;
  [NSNotificationCenter.defaultCenter postNotificationName:MPDocumentDidExitSearchNotification object:self];
}

- (void)toggleSearchFlags:(id)sender {
  if(![sender respondsToSelector:@selector(tag)]) {
    return; // We need to read the button tag
  }
  if(![sender respondsToSelector:@selector(state)]) {
    return; // We need to read the button state
  }
  MPEntrySearchFlags toggleFlag = [sender tag];
  MPEntrySearchFlags newFlags = MPEntrySearchNone;
  BOOL isSingleFlag = toggleFlag & MPEntrySearchSingleFlags;
  
  NSControlStateValue state;
  if([sender isKindOfClass:NSButton.class]) {
    state = ((NSButton *)sender).state;
  }
  else {
    NSAssert([sender isKindOfClass:NSMenuItem.class], @"Internal inconsitency. Did expect NSMenuItem expected, but got %@", [sender class]);
    state = ((NSMenuItem *)sender).state;
    /* Manually toggle the state since the popupbuttoncell doesn't do it like we want it to */
    state = state == NSControlStateValueOn ? NSControlStateValueOff : NSControlStateValueOn;
  }
 
  switch(state) {
    case NSControlStateValueOff:
      toggleFlag ^= MPEntrySearchAllCombineableFlags;
      newFlags = isSingleFlag ? MPEntrySearchNone : (self.searchContext.searchFlags & toggleFlag);
      break;
    case NSControlStateValueOn:
      if(isSingleFlag ) {
        newFlags = toggleFlag; // This has to be either expired or double passwords
      }
      else {
        /* always mask the double passwords in case another button was pressed */
        newFlags = self.searchContext.searchFlags | toggleFlag;
        newFlags &= (MPEntrySearchSingleFlags ^ MPEntrySearchAllFlags);
      }
      break;
    default:
      NSAssert(NO, @"Internal state is inconsistent");
      return;
  }
  if(newFlags != self.searchContext.searchFlags) {
    self.searchContext.searchFlags = (newFlags == MPEntrySearchNone) ? MPEntrySearchTitles : newFlags;
    [NSNotificationCenter.defaultCenter postNotificationName:MPDocumentDidChangeSearchFlags object:self];
    [self updateSearch:self];
  }
}

#pragma mark Search
- (NSArray *)_findEntriesMatchingSearch:(MPEntrySearchContext *)context {
  NSString *searchString = context.searchString ?: @"";
  /* Empty search must not filter: show every entry. */
  if(searchString.length == 0) {
    return [self.root searchableChildEntries];
  }
  /* Filter double passwords */
  if(MPIsFlagSetInOptions(MPEntrySearchDoublePasswords, context.searchFlags)) {
    NSMutableDictionary *passwordToEntryMap = [[NSMutableDictionary alloc] initWithCapacity:100];
    /* Build up a usage map */
    for(KPKEntry *entry in self.root.searchableChildEntries) {
      /* skip entries without passwords */
      if(entry.password.length > 0) {
        NSMutableSet *entrySet = passwordToEntryMap[entry.password];
        if(entrySet) {
          [entrySet addObject:entry];
        }
        else {
          passwordToEntryMap[entry.password] = [NSMutableSet setWithObject:entry];
        }
      }
    }
    /* check for usage count */
    NSMutableArray *doublePasswords = [[NSMutableArray alloc] init];
    for(NSString *password in passwordToEntryMap.allKeys) {
      NSSet *entrySet = passwordToEntryMap[password];
      if(entrySet.count > 1) {
        [doublePasswords addObjectsFromArray:entrySet.allObjects];
      }
    }
    return doublePasswords;
  }
  if(MPIsFlagSetInOptions(MPEntrySearchExpiredEntries, context.searchFlags)) {
    NSPredicate *expiredPredicate = [NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
      KPKNode *node = evaluatedObject;
      return node.timeInfo.isExpired;
    }];
    return [[self.root searchableChildEntries] filteredArrayUsingPredicate:expiredPredicate];
  }
  /* Filter using predicates */
  NSArray *predicates = [self _filterPredicatesWithString:searchString searchFlags:context.searchFlags];
  if(predicates.count > 0) {
    NSPredicate *fullFilter = [NSCompoundPredicate orPredicateWithSubpredicates:predicates];
    return [[self.root searchableChildEntries] filteredArrayUsingPredicate:fullFilter];
  }
  /* No filter, just return everything */
  return [self.root searchableChildEntries];
}

- (NSArray *)_filterPredicatesWithString:(NSString *)string searchFlags:(MPEntrySearchFlags)searchFlags {
  NSMutableArray *prediactes = [[NSMutableArray alloc] initWithCapacity:4];
  
  BOOL searchInAllAttributes = MPIsFlagSetInOptions(MPEntrySearchAllAttributes, searchFlags);
  
  
  if(MPIsFlagSetInOptions(MPEntrySearchTitles, searchFlags)) {
    [prediactes addObject:[NSPredicate predicateWithFormat:@"SELF.title CONTAINS[cd] %@", string]];
  }
  if(MPIsFlagSetInOptions(MPEntrySearchUsernames, searchFlags)) {
    [prediactes addObject:[NSPredicate predicateWithFormat:@"SELF.username CONTAINS[cd] %@", string]];
  }
  if(MPIsFlagSetInOptions(MPEntrySearchUrls, searchFlags)) {
    [prediactes addObject:[NSPredicate predicateWithFormat:@"SELF.url CONTAINS[cd] %@", string]];
  }
  if(MPIsFlagSetInOptions(MPEntrySearchPasswords, searchFlags)) {
    [prediactes addObject:[NSPredicate predicateWithFormat:@"SELF.password CONTAINS[cd] %@", string]];
  }
  if(MPIsFlagSetInOptions(MPEntrySearchNotes, searchFlags)) {
    [prediactes addObject:[NSPredicate predicateWithFormat:@"SELF.notes CONTAINS[cd] %@", string]];
  }
  if(searchInAllAttributes) {
    [prediactes addObject:[NSPredicate predicateWithFormat:@"SELF.tagsString CONTAINS[cd] %@", string]];
    [prediactes addObject:[NSPredicate predicateWithFormat:@"SELF.uuid.UUIDString CONTAINS[cd] %@", string]];

    NSPredicate *allAttributesPredicate = [NSPredicate predicateWithBlock:^BOOL(id  _Nullable evaluatedObject, NSDictionary<NSString *,id> * _Nullable bindings) {
      KPKEntry *entry = evaluatedObject;
      for(KPKAttribute *attribute in entry.attributes) {
        if([attribute.value rangeOfString:string options:NSCaseInsensitiveSearch].location != NSNotFound) {
          return YES;
        }
      }
      return NO;
    }];
    
    [prediactes addObject:allAttributesPredicate];
  }
  
  return prediactes;
}

@end
