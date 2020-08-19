//
//  STPPaymentCardNumberTextFieldViewModel.m
//  Stripe
//
//  Created by Jack Flintermann on 7/21/15.
//  Copyright (c) 2015 Stripe, Inc. All rights reserved.
//

#import "STPPaymentCardNumberTextFieldViewModel.h"

#import "NSString+Stripe.h"
#import "STPCardValidator+Private.h"
#import "STPPostalCodeValidator.h"

@implementation STPPaymentCardNumberTextFieldViewModel

- (void)setCardNumber:(NSString *)cardNumber {
    NSString *sanitizedNumber = [STPCardValidator sanitizedNumericStringForString:cardNumber];
    STPCardBrand brand = [STPCardValidator brandForNumber:sanitizedNumber];
    NSInteger maxLength = [STPCardValidator maxLengthForCardBrand:brand];
    _cardNumber = [sanitizedNumber stp_safeSubstringToIndex:maxLength];
}

- (nullable NSString *)compressedCardNumberWithPlaceholder:(nullable NSString *)placeholder {
    NSString *cardNumber = self.cardNumber;
    if (cardNumber.length == 0) {
        cardNumber = placeholder ?: self.defaultPlaceholder;
    }

    STPCardBrand currentBrand = [STPCardValidator brandForNumber:cardNumber];
    if ([self validationStateForField:STPCardFieldTypeNumber] == STPCardValidationStateValid) {
        // Use fragment length
        NSUInteger length = [STPCardValidator fragmentLengthForCardBrand:currentBrand];
        NSUInteger index = cardNumber.length - length;

        if (index < cardNumber.length) {
            return [cardNumber stp_safeSubstringFromIndex:index];
        }
    } else {
        // use the card number format
        NSArray<NSNumber *> *cardNumberFormat = [STPCardValidator cardNumberFormatForCardNumber:cardNumber];

        NSUInteger index = 0;
        for (NSNumber *segment in cardNumberFormat) {
            NSUInteger segmentLength = [segment unsignedIntegerValue];
            if (index + segmentLength >= cardNumber.length) {
                return [cardNumber stp_safeSubstringFromIndex:index];
            }
            index += segmentLength;
        }
    }

    return nil;
}

- (STPCardBrand)brand {
    return [STPCardValidator brandForNumber:self.cardNumber];
}

- (STPCardValidationState)validationStateForField:(STPCardFieldType)fieldType {
    return [STPCardValidator validationStateForNumber:self.cardNumber validatingCardBrand:YES];
}

- (BOOL)isValid {
    return ([self validationStateForField:STPCardFieldTypeNumber] == STPCardValidationStateValid);
}

- (NSString *)defaultPlaceholder {
    return @"Kartın Numarası";
}

+ (NSSet<NSString *> *)keyPathsForValuesAffectingValid {
    return [NSSet setWithArray:@[
                                 NSStringFromSelector(@selector(cardNumber)),
                                 NSStringFromSelector(@selector(brand))
                                 ]];
}

@end
