//
//  MPTouchIdCompositeKeyStore.m
//  MacPass
//
//  Created by Julius Zint on 14.03.21.
//  Copyright © 2021 HicknHack Software GmbH. All rights reserved.
//
#import "MPSettingsHelper.h"
#import "MPTouchIdCompositeKeyStore.h"
#import "MPConstants.h"
#import "MPSettingsHelper.h"

#import "NSError+Messages.h"

@interface MPTouchIdCompositeKeyStore ()
@property (readonly, strong) NSMutableDictionary* keys;
@property (nonatomic) MPTouchIDKeyStorage touchIdEnabledState;
- (BOOL)_createAndAddRSAKeyPair:(NSError **)error;
@end

@implementation MPTouchIdCompositeKeyStore

+ (instancetype)defaultStore {
  static MPTouchIdCompositeKeyStore *instance;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[MPTouchIdCompositeKeyStore alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if(self) {
    _keys = [[NSMutableDictionary alloc] init];
    [self bind:NSStringFromSelector(@selector(touchIdEnabledState))
      toObject:NSUserDefaultsController.sharedUserDefaultsController
   withKeyPath:[MPSettingsHelper defaultControllerPathForKey:kMPSettingsKeyTouchIdEnabled]
       options:nil];
  }
  return self;
}

- (void)setTouchIdEnabledState:(MPTouchIDKeyStorage)touchIdEnabledState {
  switch(touchIdEnabledState) {
    case MPTouchIDKeyStorageTransient:
      // clear persistent store
      [self _clearPersistenCompositeKeyData];
      break;
    case MPTouchIDKeyStoragePersistent:
      // clear transient store
      [self.keys removeAllObjects];
      break;
    default:
      // clear persitent and transient store
      [self _clearPersistenCompositeKeyData];
      [self.keys removeAllObjects];
  }
  _touchIdEnabledState = touchIdEnabledState;
}

- (BOOL)saveCompositeKey:(KPKCompositeKey *)compositeKey forDocumentKey:(NSString *)documentKey error:(NSError *__autoreleasing  _Nullable *)error {
  NSError *encryptionError;
  NSData *encryptedCompositeKey = [self encryptedDataForCompositeKey:compositeKey error:&encryptionError];
  if(!encryptedCompositeKey) {
    NSLog(@"Unable to encrypt composite key: %@", encryptionError);
    if(error != NULL) {
      *error = encryptionError;
    }
    return NO;
  }

  switch(self.touchIdEnabledState) {
    case MPTouchIDKeyStorageTransient:
      [self _clearPersistenCompositeKeyData];
      if(nil != encryptedCompositeKey) {
        self.keys[documentKey] = encryptedCompositeKey;
      }
      break;
    case MPTouchIDKeyStoragePersistent:
      self.keys[documentKey] = nil;
      if(nil != encryptedCompositeKey) {
        [self _persistCompositeKeyData:encryptedCompositeKey forDocumentKey:documentKey];
      }
      break;
    case MPTouchIDKeyStorageDisabled:
      [self _clearPersistenCompositeKeyData];
      self.keys[documentKey] = nil;
      break;
    default:
      NSAssert(NO,@"Unsupported internal touchID preferences value.");
      break;
  }
  return YES;
}
- (NSData *)loadEncryptedCompositeKeyForDocumentKey:(NSString *)documentKey {
  NSInteger touchIdMode = [NSUserDefaults.standardUserDefaults integerForKey:kMPSettingsKeyTouchIdEnabled];
  NSData* transientKey  = self.keys[documentKey];
  NSData* persistentKey = [self _persitentCompositeKeyDataForDocumentKey:documentKey];
  if(nil == transientKey && nil == persistentKey) {
    return nil;
  }
  if(nil == transientKey || nil == persistentKey) {
    return transientKey == nil ? persistentKey : transientKey;
  }
  if(touchIdMode == NSControlStateValueOn) {
    return persistentKey;
  }
  return transientKey;
}

- (KPKCompositeKey *)compositeKeyForEncryptedKeyData:(NSData *)data error:(NSError *__autoreleasing  _Nullable *)error {
  if(nil == data) {
    return nil;
  }
  
  NSData* tag = [MPTouchIdUnlockPrivateKeyTag dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *queryPrivateKey = @{
    (id)kSecClass: (id)kSecClassKey,
    (id)kSecAttrApplicationTag: tag,
    (id)kSecAttrKeyType: (id)kSecAttrKeyTypeRSA,
    (id)kSecReturnRef: @YES,
  };
  SecKeyRef privateKey = NULL;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)queryPrivateKey, (CFTypeRef *)&privateKey);
  if(status != errSecSuccess) {
    if(error != NULL) {
      NSString* description = CFBridgingRelease(SecCopyErrorMessageString(status, NULL));
      *error = [NSError errorWithCode:status description:description];
    }
    if(privateKey) {
      CFRelease(privateKey);
    }
    return nil;
  }
  
  SecKeyAlgorithm algorithm = kSecKeyAlgorithmRSAEncryptionOAEPSHA256AESGCM;
  BOOL canDecrypt = SecKeyIsAlgorithmSupported(privateKey, kSecKeyOperationTypeDecrypt, algorithm);
  if(!canDecrypt) {
    if(error != NULL) {
      *error = [NSError errorWithCode:MPErrorTouchIdUnsupportedKeyForEncrpytion description:NSLocalizedString(@"ERROR_TOUCH_ID_UNSUPPORTED_KEY", @"The key stored for TouchID is not suitable for encrpytion")];
    }
    if(privateKey) {
      CFRelease(privateKey);
    }
    return nil;
  }
  
  CFErrorRef errorRef = NULL; // FIXME: Release?
  NSData* clearText = (NSData*)CFBridgingRelease(SecKeyCreateDecryptedData(privateKey, algorithm, (__bridge CFDataRef)data, &errorRef));
  if(clearText) {
    return [NSKeyedUnarchiver unarchiveObjectWithData:clearText];
  }
  if(error != NULL) {
    *error = CFBridgingRelease(errorRef);
  }
  if(privateKey) {
    CFRelease(privateKey);
  }
  return nil;
}


- (NSData *)encryptedDataForCompositeKey:(KPKCompositeKey *)compositeKey error:(NSError *__autoreleasing  _Nullable *)error {
  NSData* keyData = [NSKeyedArchiver archivedDataWithRootObject:compositeKey];
  NSData* tag = [MPTouchIdUnlockPublicKeyTag dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *getquery = @{
    (id)kSecClass: (id)kSecClassKey,
    (id)kSecAttrApplicationTag: tag,
    (id)kSecAttrKeyType: (id)kSecAttrKeyTypeRSA,
    (id)kSecReturnRef: @YES,
  };
  SecKeyRef publicKey = NULL;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)getquery, (CFTypeRef *)&publicKey);
  if (status != errSecSuccess) {
    NSError *keyCreationError = nil;
    [self _createAndAddRSAKeyPair:&keyCreationError];
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)getquery, (CFTypeRef *)&publicKey);
    if (status != errSecSuccess) {
      NSString* description = CFBridgingRelease(SecCopyErrorMessageString(status, NULL));
      NSLog(@"Error while trying to query public key from Keychain: %@", description);
      if(error != NULL) {
        *error = keyCreationError ?: [NSError errorWithCode:status description:description];
      }
      return nil;
    }
  }
  SecKeyAlgorithm algorithm = kSecKeyAlgorithmRSAEncryptionOAEPSHA256AESGCM;
  BOOL canEncrypt = SecKeyIsAlgorithmSupported(publicKey, kSecKeyOperationTypeEncrypt, algorithm);
  NSData *encryptedKey;
  if(canEncrypt) {
    CFErrorRef cfError = NULL;
    encryptedKey = (NSData*)CFBridgingRelease(SecKeyCreateEncryptedData(publicKey, algorithm, (__bridge CFDataRef)keyData, &cfError));
    if (!encryptedKey) {
      NSError *err = CFBridgingRelease(cfError);
      NSLog(@"Error while trying to encrypt the CompositeKey for TouchID unlock: %@", [err description]);
      if(error != NULL) {
        *error = err;
      }
    }
  }
  else {
    NSLog(@"The key retreived from the Keychain is unable to encrypt data");
    if(error != NULL) {
      *error = [NSError errorWithCode:MPErrorTouchIdUnsupportedKeyForEncrpytion description:NSLocalizedString(@"ERROR_TOUCH_ID_UNSUPPORTED_KEY", @"The key stored for TouchID is not suitable for encrpytion")];
    }
  }
  if (publicKey)  {
    CFRelease(publicKey);
  }
  return encryptedKey;
}

- (BOOL)_createAndAddRSAKeyPair:(NSError **)saveError {
  CFErrorRef cfError = NULL;
  NSString* publicKeyLabel =  @"MacPass TouchID Feature Public Key";
  NSString* privateKeyLabel = @"MacPass TouchID Feature Private Key";
  NSData* publicKeyTag =  [MPTouchIdUnlockPublicKeyTag  dataUsingEncoding:NSUTF8StringEncoding];
  NSData* privateKeyTag = [MPTouchIdUnlockPrivateKeyTag dataUsingEncoding:NSUTF8StringEncoding];
  SecAccessControlRef access = NULL;
  if (@available(macOS 10.13.4, *)) {
    SecAccessControlCreateFlags flags = kSecAccessControlBiometryCurrentSet;
    access = SecAccessControlCreateWithFlags(kCFAllocatorDefault,
                                             kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                             flags,
                                             &cfError);
    if(access == NULL) {
      NSError *err = CFBridgingRelease(cfError);
      NSLog(@"Error while trying to create AccessControl for TouchID unlock feature: %@", [err description]);
      if(saveError != NULL) {
        *saveError = err;
      }
      return NO;
    }
    NSDictionary* attributes = @{
      (id)kSecAttrKeyType:        (id)kSecAttrKeyTypeRSA,
      (id)kSecAttrKeySizeInBits:  @2048,
      (id)kSecAttrSynchronizable: @NO,
      (id)kSecPrivateKeyAttrs:
           @{ (id)kSecAttrIsPermanent:    @YES,
              (id)kSecAttrApplicationTag: privateKeyTag,
              (id)kSecAttrLabel: privateKeyLabel,
              (id)kSecAttrAccessControl:  (__bridge id)access
            },
      (id)kSecPublicKeyAttrs:
           @{ (id)kSecAttrIsPermanent:    @YES,
              (id)kSecAttrApplicationTag: publicKeyTag,
              (id)kSecAttrLabel: publicKeyLabel,
            },
    };
    SecKeyRef result = SecKeyCreateRandomKey((__bridge CFDictionaryRef)attributes, &cfError);
    if(result == NULL) {
      NSError *err = CFBridgingRelease(cfError);
      NSLog(@"Error while trying to create a RSA keypair for TouchID unlock feature: %@", [err description]);
      if(saveError != NULL) {
        *saveError = err;
      }
      CFRelease(access);
      return NO;
    }
    else {
      CFRelease(result);
    }
    CFRelease(access);
    return YES;
  }
  else {
    if(saveError != NULL) {
      *saveError = [NSError errorWithCode:MPErrorTouchIdUnsupportedKeyForEncrpytion description:NSLocalizedString(@"ERROR_TOUCH_ID_UNSUPPORTED_KEY", @"The key stored for TouchID is not suitable for encrpytion")];
    }
    return NO;
  }
}

- (NSData *)_persitentCompositeKeyDataForDocumentKey:(NSString *)key {
  if(key.length == 0) {
    return nil;
  }
  return [NSUserDefaults.standardUserDefaults objectForKey:kMPSettingsKeyTouchIdEncryptedKeyStore][key];
}

- (void)_persistCompositeKeyData:(NSData *)data forDocumentKey:(NSString *)key {
  if(data.length == 0 || key.length == 0) {
    return;
  }
  NSMutableDictionary *dict = [[NSUserDefaults.standardUserDefaults objectForKey:kMPSettingsKeyTouchIdEncryptedKeyStore] mutableCopy];
  if(nil == dict) {
    dict = [[NSMutableDictionary alloc] init];
  }
  dict[key] = data;
  [NSUserDefaults.standardUserDefaults setObject:[dict copy] forKey:kMPSettingsKeyTouchIdEncryptedKeyStore];
}

- (void)_clearPersistenCompositeKeyData {
  [NSUserDefaults.standardUserDefaults removeObjectForKey:kMPSettingsKeyTouchIdEncryptedKeyStore];
}

@end
