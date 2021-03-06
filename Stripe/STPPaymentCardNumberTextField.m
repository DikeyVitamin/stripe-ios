//
//  STPPaymentCardNumberTextField.m
//  Stripe
//
//  Created by Jack Flintermann on 7/16/15.
//  Copyright (c) 2015 Stripe, Inc. All rights reserved.
//

#import <UIKit/UIKit.h>

#import "STPPaymentCardNumberTextField.h"

#import "NSArray+Stripe.h"
#import "NSString+Stripe.h"
#import "STPCardValidator+Private.h"
#import "STPFormTextField.h"
#import "STPImageLibrary.h"
#import "STPPaymentCardNumberTextFieldViewModel.h"
#import "STPPostalCodeValidator.h"
#import "Stripe.h"
#import "STPLocalizationUtils.h"
#import "STPAnalyticsClient.h"

@interface STPPaymentCardNumberTextField()<STPFormTextFieldDelegate>

@property (nonatomic, readwrite, weak) UIImageView *brandImageView;
@property (nonatomic, readwrite, weak) UIView *fieldsView;
@property (nonatomic, readwrite, weak) STPFormTextField *numberField;
@property (nonatomic, readwrite, strong) STPPaymentCardNumberTextFieldViewModel *viewModel;
@property (nonatomic, readwrite, strong) STPPaymentMethodCardParams *internalCardParams;
@property (nonatomic, strong) NSArray<STPFormTextField *> *allFields;
@property (nonatomic, readwrite, strong) STPFormTextField *sizingField;
@property (nonatomic, readwrite, strong) UILabel *sizingLabel;

/*
 These track the input parameters to the brand image setter so that we can
 later perform proper transition animations when new values are set
 */
@property (nonatomic, assign) STPCardFieldType currentBrandImageFieldType;
@property (nonatomic, assign) STPCardBrand currentBrandImageBrand;

/**
 This is a number-wrapped STPCardFieldType (or nil) that layout uses
 to determine how it should move/animate its subviews so that the chosen
 text field is fully visible.
 */
@property (nonatomic, copy) NSNumber *focusedTextFieldForLayout;

/*
 Creating and measuring the size of attributed strings is expensive so
 cache the values here.
 */
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *textToWidthCache;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *numberToWidthCache;

/**
 These bits lets us track beginEditing and endEditing for payment text field
 as a whole (instead of on a per-subview basis).
 
 DO NOT read this values directly. Use the return value from
 `getAndUpdateSubviewEditingTransitionStateFromCall:` which updates them all
 and returns you the correct current state for the method you are in.
 
 The state transitons in the should/did begin/end editing callbacks for all
 our subfields. If we get a shouldEnd AND a shouldBegin before getting either's
 matching didEnd/didBegin, then we are transitioning focus between our subviews
 (and so we ourselves should not consider us to have begun or ended editing).
 
 But if we get a should and did called on their own without a matching opposite
 pair (shouldBegin/didBegin or shouldEnd/didEnd) then we are transitioning
 into/out of our subviews from/to outside of ourselves
 */
@property (nonatomic, assign) BOOL isMidSubviewEditingTransitionInternal;
@property (nonatomic, assign) BOOL receivedUnmatchedShouldBeginEditing;
@property (nonatomic, assign) BOOL receivedUnmatchedShouldEndEditing;

@end

NS_INLINE CGFloat stp_ceilCGFloat(CGFloat x) {
#if CGFLOAT_IS_DOUBLE
    return ceil(x);
#else
    return ceilf(x);
#endif
}


@implementation STPPaymentCardNumberTextField

@synthesize font = _font;
@synthesize textColor = _textColor;
@synthesize textErrorColor = _textErrorColor;
@synthesize placeholderColor = _placeholderColor;
@synthesize borderColor = _borderColor;
@synthesize borderWidth = _borderWidth;
@synthesize cornerRadius = _cornerRadius;
@dynamic enabled;

CGFloat const STPPaymentCardNumberTextFieldDefaultPadding = 13;
CGFloat const STPPaymentCardNumberTextFieldDefaultInsets = 13;
CGFloat const STPPaymentCardNumberTextFieldMinimumPadding = 10;

#pragma mark initializers

+ (void)initialize {
    [[STPAnalyticsClient sharedClient] addClassToProductUsageIfNecessary:[self class]];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    // We're using ivars here because UIAppearance tracks when setters are
    // called, and won't override properties that have already been customized
    _borderColor = [self.class placeholderGrayColor];
    _cornerRadius = 5.0f;
    _borderWidth = 1.0f;
    
    self.layer.borderColor = [[_borderColor copy] CGColor];
    self.layer.cornerRadius = _cornerRadius;
    self.layer.borderWidth = _borderWidth;

    self.clipsToBounds = YES;

    _internalCardParams = [STPPaymentMethodCardParams new];
    _viewModel = [STPPaymentCardNumberTextFieldViewModel new];
    _sizingField = [self buildTextField];
    _sizingField.formDelegate = nil;
    _sizingLabel = [UILabel new];
    
    UIImageView *brandImageView = [[UIImageView alloc] initWithImage:self.brandImage];
    brandImageView.contentMode = UIViewContentModeCenter;
    brandImageView.backgroundColor = [UIColor clearColor];
    brandImageView.tintColor = self.placeholderColor;
    self.brandImageView = brandImageView;
    
    STPFormTextField *numberField = [self buildTextField];
    // This does not offer quick-type suggestions (as iOS 11.2), but does pick
    // the best keyboard (maybe other, hidden behavior?)
    numberField.textContentType = UITextContentTypeCreditCardNumber;
    numberField.autoFormattingBehavior = STPFormTextFieldAutoFormattingBehaviorCardNumbers;
    numberField.tag = STPCardFieldTypeNumber;
    numberField.accessibilityLabel = STPLocalizedString(@"card number", @"accessibility label for text field");
    self.numberField = numberField;
    self.numberPlaceholder = [self.viewModel defaultPlaceholder];

    UIView *fieldsView = [[UIView alloc] init];
    fieldsView.clipsToBounds = YES;
    fieldsView.backgroundColor = [UIColor clearColor];
    
    [self addSubview:self.numberField];

    [self addSubview:brandImageView];
    // On small screens, the number field fits ~4 numbers, and the brandImage is just as large.
    // Previously, taps on the brand image would *dismiss* the keyboard. Make it move to the numberField instead
    brandImageView.userInteractionEnabled = YES;
    [brandImageView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:numberField
                                                                                 action:@selector(becomeFirstResponder)]];

    self.focusedTextFieldForLayout = nil;
    [self resetSubviewEditingTransitionState];
    
    self.countryCode = [[NSLocale autoupdatingCurrentLocale] objectForKey:NSLocaleCountryCode];
}

- (STPPaymentCardNumberTextFieldViewModel *)viewModel {
    if (_viewModel == nil) {
        _viewModel = [STPPaymentCardNumberTextFieldViewModel new];
    }
    return _viewModel;
}

#pragma mark appearance properties

- (void)clearSizingCache {
    self.textToWidthCache = [NSMutableDictionary new];
    self.numberToWidthCache = [NSMutableDictionary new];
}

+ (UIColor *)placeholderGrayColor {
    #ifdef __IPHONE_13_0
        if (@available(iOS 13.0, *)) {
            return [UIColor systemGray2Color];
        }
    #endif
    
    return [UIColor lightGrayColor];
}

- (void)setBackgroundColor:(UIColor *)backgroundColor {
    [super setBackgroundColor:[backgroundColor copy]];
    self.numberField.backgroundColor = self.backgroundColor;
}

- (UIColor *)backgroundColor {
    UIColor *defaultColor = [UIColor whiteColor];
    #ifdef __IPHONE_13_0
        if (@available(iOS 13.0, *)) {
            defaultColor = [UIColor systemBackgroundColor];
        }
    #endif
    
    return [super backgroundColor] ?: defaultColor;
}

- (void)setFont:(UIFont *)font {
    _font = [font copy];
    
    for (UITextField *field in [self allFields]) {
        field.font = _font;
    }
    
    self.sizingField.font = _font;
    [self clearSizingCache];
    
    [self setNeedsLayout];
}

- (UIFont *)font {
    return _font ?: [UIFont systemFontOfSize:18];
}

- (void)setTextColor:(UIColor *)textColor {
    _textColor = [textColor copy];
    
    for (STPFormTextField *field in [self allFields]) {
        field.defaultColor = _textColor;
    }
}

- (void)setContentVerticalAlignment:(UIControlContentVerticalAlignment)contentVerticalAlignment {
    [super setContentVerticalAlignment:contentVerticalAlignment];
    for (UITextField *field in [self allFields]) {
        field.contentVerticalAlignment = contentVerticalAlignment;
    }
    switch (contentVerticalAlignment) {
        case UIControlContentVerticalAlignmentCenter:
            self.brandImageView.contentMode = UIViewContentModeCenter;
            break;
        case UIControlContentVerticalAlignmentBottom:
            self.brandImageView.contentMode = UIViewContentModeBottom;
            break;
        case UIControlContentVerticalAlignmentFill:
            self.brandImageView.contentMode = UIViewContentModeTop;
            break;
        case UIControlContentVerticalAlignmentTop:
            self.brandImageView.contentMode = UIViewContentModeTop;
            break;
    }
}

- (UIColor *)textColor {
    UIColor *defaultColor = [UIColor blackColor];
    #ifdef __IPHONE_13_0
        if (@available(iOS 13.0, *)) {
            defaultColor = [UIColor labelColor];
        }
    #endif

    return _textColor ?: defaultColor;
}

- (void)setTextErrorColor:(UIColor *)textErrorColor {
    _textErrorColor = [textErrorColor copy];
    
    for (STPFormTextField *field in [self allFields]) {
        field.errorColor = _textErrorColor;
    }
}

- (UIColor *)textErrorColor {
    UIColor *defaultColor = [UIColor redColor];
    #ifdef __IPHONE_13_0
        if (@available(iOS 13.0, *)) {
            defaultColor = [UIColor systemRedColor];
        }
    #endif
    
    return _textErrorColor ?: defaultColor;
}

- (void)setPlaceholderColor:(UIColor *)placeholderColor {
    _placeholderColor = [placeholderColor copy];
    self.brandImageView.tintColor = placeholderColor;
    
    for (STPFormTextField *field in [self allFields]) {
        field.placeholderColor = _placeholderColor;
    }
}

- (UIColor *)placeholderColor {
    return _placeholderColor ?: [self.class placeholderGrayColor];
}

- (void)setNumberPlaceholder:(NSString * __nullable)numberPlaceholder {
    _numberPlaceholder = [numberPlaceholder copy];
    self.numberField.placeholder = _numberPlaceholder;
}

- (void)setCursorColor:(UIColor *)cursorColor {
    self.tintColor = cursorColor;
}

- (UIColor *)cursorColor {
    return self.tintColor;
}

- (void)setBorderColor:(UIColor * __nullable)borderColor {
    _borderColor = borderColor;
    if (borderColor) {
        self.layer.borderColor = [[borderColor copy] CGColor];
    } else {
        self.layer.borderColor = [[UIColor clearColor] CGColor];
    }
}

- (UIColor * __nullable)borderColor {
    return _borderColor;
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    _cornerRadius = cornerRadius;
    self.layer.cornerRadius = cornerRadius;
}

- (CGFloat)cornerRadius {
    return _cornerRadius;
}

- (void)setBorderWidth:(CGFloat)borderWidth {
    _borderWidth = borderWidth;
    self.layer.borderWidth = borderWidth;
}

- (CGFloat)borderWidth {
    return _borderWidth;
}

- (void)setKeyboardAppearance:(UIKeyboardAppearance)keyboardAppearance {
    _keyboardAppearance = keyboardAppearance;
    for (STPFormTextField *field in [self allFields]) {
        field.keyboardAppearance = keyboardAppearance;
    }
}

- (void)setInputView:(UIView *)inputView {
    _inputView = inputView;

    for (STPFormTextField *field in [self allFields]) {
        field.inputView = inputView;
    }
}

- (void)setInputAccessoryView:(UIView *)inputAccessoryView {
    _inputAccessoryView = inputAccessoryView;
    
    for (STPFormTextField *field in [self allFields]) {
        field.inputAccessoryView = inputAccessoryView;
    }
}

#pragma mark UIControl

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    for (STPFormTextField *textField in [self allFields]) {
        textField.enabled = enabled;
    };
}

#pragma mark UIResponder & related methods

- (BOOL)isFirstResponder {
    return self.currentFirstResponderField != nil;
}

- (BOOL)canBecomeFirstResponder {
    STPFormTextField *firstResponder = [self currentFirstResponderField] ?: [self nextFirstResponderField];
    return [firstResponder canBecomeFirstResponder];
}

- (BOOL)becomeFirstResponder {
    STPFormTextField *firstResponder = [self currentFirstResponderField] ?: [self nextFirstResponderField];
    return [firstResponder becomeFirstResponder];
}

/**
 Returns the next text field to be edited, in priority order:

 1. If we're currently in a text field, returns the next one (ignoring postalCodeField if postalCodeEntryEnabled == NO)
 2. Otherwise, returns the first invalid field (either cycling back from the end or as it gains 1st responder)
 3. As a final fallback, just returns the last field
 */
- (nonnull STPFormTextField *)nextFirstResponderField {
    STPFormTextField *currentFirstResponder = [self currentFirstResponderField];
    if (currentFirstResponder) {
        NSUInteger index = [self.allFields indexOfObject:currentFirstResponder];
        if (index != NSNotFound) {
            STPFormTextField *nextField = [self.allFields stp_boundSafeObjectAtIndex:index + 1];
            if (nextField != nil) {
                return nextField;
            }
        }
    }

    return [self firstInvalidSubField];
}

- (nullable STPFormTextField *)firstInvalidSubField {
    if ([self.viewModel validationStateForField:STPCardFieldTypeNumber] != STPCardValidationStateValid) {
        return self.numberField;
    } else {
        return nil;
    }
}

- (STPFormTextField *)currentFirstResponderField {
    for (STPFormTextField *textField in [self allFields]) {
        if ([textField isFirstResponder]) {
            return textField;
        }
    }
    return nil;
}

- (BOOL)canResignFirstResponder {
    return [self.currentFirstResponderField canResignFirstResponder];
}

- (BOOL)resignFirstResponder {
    [super resignFirstResponder];
    BOOL success = [self.currentFirstResponderField resignFirstResponder];
    [self layoutViewsToFocusField:nil
             becomeFirstResponder:NO
                         animated:YES
                       completion:nil];
    [self updateImageForFieldType:STPCardFieldTypeNumber];
    return success;
}

- (STPFormTextField *)previousField {
    STPFormTextField *currentSubResponder = self.currentFirstResponderField;
    if (currentSubResponder) {
        NSUInteger index = [self.allFields indexOfObject:currentSubResponder];
        if (index != NSNotFound
            && index > 0) {
            return self.allFields[index - 1];
        }
    }
    return nil;
}

#pragma mark public convenience methods

- (void)clear {
    for (STPFormTextField *field in [self allFields]) {
        field.text = @"";
    }
    self.viewModel = [STPPaymentCardNumberTextFieldViewModel new];
    [self onChange];
    [self updateImageForFieldType:STPCardFieldTypeNumber];
    __weak typeof(self) weakSelf = self;
    [self layoutViewsToFocusField:@(STPCardFieldTypePostalCode)
             becomeFirstResponder:YES
                         animated:YES
                       completion:^(__unused BOOL completed){
        __strong typeof(self) strongSelf = weakSelf;
        if ([strongSelf isFirstResponder]) {
            [[strongSelf numberField] becomeFirstResponder];
        }
    }];
}

- (BOOL)isValid {
    return [self.viewModel isValid];
}

- (BOOL)valid {
    return self.isValid;
}

#pragma mark readonly variables

- (NSString *)cardNumber {
    return self.viewModel.cardNumber;
}

- (STPPaymentMethodCardParams *)cardParams {
    self.internalCardParams.number = self.cardNumber;
    self.internalCardParams.expMonth = @(self.expirationMonth);
    self.internalCardParams.expYear = @(self.expirationYear);
    self.internalCardParams.cvc = self.cvc;
    return [self.internalCardParams copy];
}

- (void)setCardParams:(STPPaymentMethodCardParams *)callersCardParams {
    /*
     Due to the way this class is written, programmatically setting field text
     behaves identically to user entering text (and will have the same forwarding
     on to next responder logic).

     We have some custom logic here in the main accesible programmatic setter
     to dance around this a bit. First we save what is the current responder
     at the time this method was called. Later logic after text setting should be:
     1. If we were not first responder, we should still not be first responder
        (but layout might need updating depending on PAN validity)
     2. If original field is still not valid, it is still first responder
        (manually reset it back to first responder)
     3. Otherwise the first subfield with invalid text should now be first responder
     */
    STPFormTextField *originalSubResponder = self.currentFirstResponderField;

    /*
     #1031 small footgun hiding here. Use copies to protect from mutations of
     `internalCardParams` in the `cardParams` property accessor and any mutations
     the app code might make to their `callersCardParams` object.
     */
    STPPaymentMethodCardParams *desiredCardParams = [callersCardParams copy];
    self.internalCardParams = [desiredCardParams copy];

    [self setText:desiredCardParams.number inField:STPCardFieldTypeNumber];
    BOOL expirationPresent = desiredCardParams.expMonth && desiredCardParams.expYear;
    if (expirationPresent) {
        NSString *text = [NSString stringWithFormat:@"%02lu%02lu",
                          (unsigned long)desiredCardParams.expMonth.integerValue,
                          (unsigned long)desiredCardParams.expYear.integerValue%100];
        [self setText:text inField:STPCardFieldTypeExpiration];
    } else {
        [self setText:@"" inField:STPCardFieldTypeExpiration];
    }
    [self setText:desiredCardParams.cvc inField:STPCardFieldTypeCVC];

    if ([self isFirstResponder]) {
        STPCardFieldType fieldType = originalSubResponder.tag;
        STPCardValidationState state = [self.viewModel validationStateForField:fieldType];

        if (state == STPCardValidationStateValid) {
            STPFormTextField *nextField = [self firstInvalidSubField];
            if (nextField) {
                [nextField becomeFirstResponder];
            } else {
                [self resignFirstResponder];
            }
        } else {
            [originalSubResponder becomeFirstResponder];
        }
    } else {
        [self layoutViewsToFocusField:nil
                 becomeFirstResponder:YES
                             animated:NO
                           completion:nil];
    }

    // update the card image, falling back to the number field image if not editing
    if ([self.numberField isFirstResponder]) {
        [self updateImageForFieldType:STPCardFieldTypeNumber];
    }
}

- (void)setText:(NSString *)text inField:(STPCardFieldType)field {
    NSString *nonNilText = text ?: @"";
    STPFormTextField *textField = self.numberField;
    textField.text = nonNilText;
}

- (CGFloat)numberFieldFullWidth {
    // Current longest possible pan is 16 digits which our standard sample fits
    if ([self.viewModel validationStateForField:STPCardFieldTypeNumber] == STPCardValidationStateValid) {
        return [self widthForCardNumber:self.viewModel.cardNumber];
    } else {
        return MAX([self widthForCardNumber:self.viewModel.cardNumber],
                   [self widthForCardNumber:self.viewModel.defaultPlaceholder]);
    }
}

- (CGSize)intrinsicContentSize {

    CGSize imageSize = self.brandImage.size;

    self.sizingField.text = self.viewModel.defaultPlaceholder;
    [self.sizingField sizeToFit];
    CGFloat textHeight = CGRectGetHeight(self.sizingField.frame);
    CGFloat imageHeight = imageSize.height + (STPPaymentCardNumberTextFieldDefaultInsets);
    CGFloat height = stp_ceilCGFloat((MAX(MAX(imageHeight, textHeight), 44)));

    CGFloat width = (STPPaymentCardNumberTextFieldDefaultInsets
                     + imageSize.width
                     + STPPaymentCardNumberTextFieldDefaultInsets
                     + [self numberFieldFullWidth]
                     + STPPaymentCardNumberTextFieldDefaultInsets
                     );

    width = stp_ceilCGFloat(width);

    return CGSizeMake(width, height);
}

typedef NS_ENUM(NSInteger, STPCardTextFieldState) {
    STPCardTextFieldStateVisible,
    STPCardTextFieldStateCompressed,
    STPCardTextFieldStateHidden,
};

- (CGFloat)minimumPaddingForViewsWithWidth:(CGFloat)width
                                       pan:(STPCardTextFieldState)panVisibility {

    CGFloat requiredWidth = 0;
    CGFloat paddingsRequired = -1;

    if (panVisibility != STPCardTextFieldStateHidden) {
        paddingsRequired += 1;
        requiredWidth += [self numberFieldFullWidth];
    }
    
    if (paddingsRequired > 0) {
        return stp_ceilCGFloat(((width - requiredWidth) / paddingsRequired));
    } else {
        return STPPaymentCardNumberTextFieldMinimumPadding;
    }
}

- (CGRect)brandImageRectForBounds:(CGRect)bounds {
    return CGRectMake(STPPaymentCardNumberTextFieldDefaultPadding, -1, self.brandImageView.image.size.width, bounds.size.height);
}

- (CGRect)fieldsRectForBounds:(CGRect)bounds {
    CGRect brandImageRect = [self brandImageRectForBounds:bounds];
    return CGRectMake(CGRectGetMaxX(brandImageRect), 0, CGRectGetWidth(bounds) - CGRectGetMaxX(brandImageRect), CGRectGetHeight(bounds));
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self recalculateSubviewLayout];
}

- (void)recalculateSubviewLayout {
        
    CGRect bounds = self.bounds;

    self.brandImageView.frame = [self brandImageRectForBounds:bounds];
    CGRect fieldsViewRect = [self fieldsRectForBounds:bounds];

    CGFloat availableFieldsWidth = CGRectGetWidth(fieldsViewRect) - (2 * STPPaymentCardNumberTextFieldDefaultInsets);

    // These values are filled in via the if statements and then used
    // to do the proper layout at the end
    CGFloat fieldsHeight = CGRectGetHeight(fieldsViewRect);
    CGFloat hPadding = STPPaymentCardNumberTextFieldDefaultPadding;
    __block STPCardTextFieldState panVisibility = STPCardTextFieldStateVisible;

    CGFloat (^calculateMinimumPaddingWithLocalVars)(void) = ^CGFloat() {
        return [self minimumPaddingForViewsWithWidth:availableFieldsWidth
                                                 pan:panVisibility];
    };

    hPadding = calculateMinimumPaddingWithLocalVars();

    if (hPadding >= STPPaymentCardNumberTextFieldMinimumPadding) {
        // Can just render everything at full size
        // Do Nothing
    } else {
        // Need to do selective view compression/hiding

        if (self.focusedTextFieldForLayout == nil) {
            /*
             No field is currently being edited -
             
             Render all fields visible:
             Show compressed PAN, visible CVC and expiry, fill remaining space
             with postal if necessary

             The most common way to be in this state is the user finished entry
             and has moved on to another field (so we want to show summary)
             but possibly some fields are invalid
             */
            while (hPadding < STPPaymentCardNumberTextFieldMinimumPadding) {
                // Try hiding things in this order
                if (panVisibility == STPCardTextFieldStateVisible) {
                    panVisibility = STPCardTextFieldStateCompressed;
                }else {
                    // Can't hide anything else, set to minimum and stop
                    hPadding = STPPaymentCardNumberTextFieldMinimumPadding;
                    break;
                }
                hPadding = calculateMinimumPaddingWithLocalVars();
            }
        } else {
            switch ((STPCardFieldType)self.focusedTextFieldForLayout.integerValue) {
                case STPCardFieldTypeNumber: {
                    /*
                     The user is entering PAN
                     
                     It must be fully visible. Everything else is optional
                     */

                   
                }
                    break;
                case STPCardFieldTypeExpiration: {
                    /*
                     The user is entering expiration date

                     It must be fully visible, and the next and previous fields
                     must be visible so they can be tapped over to
                     */
                    while (hPadding < STPPaymentCardNumberTextFieldMinimumPadding) {
                        if (panVisibility == STPCardTextFieldStateVisible) {
                            panVisibility = STPCardTextFieldStateCompressed;
                        }else {
                            hPadding = STPPaymentCardNumberTextFieldMinimumPadding;
                            break;
                        }
                        hPadding = calculateMinimumPaddingWithLocalVars();
                    }
                }
                    break;

                case STPCardFieldTypeCVC: {
                    /*
                     The user is entering CVC

                     It must be fully visible, and the next and previous fields
                     must be visible so they can be tapped over to (although
                     there might not be a next field)
                     */
                    while (hPadding < STPPaymentCardNumberTextFieldMinimumPadding) {
                        if (panVisibility == STPCardTextFieldStateVisible) {
                            panVisibility = STPCardTextFieldStateCompressed;
                        }else if (panVisibility == STPCardTextFieldStateCompressed) {
                            panVisibility = STPCardTextFieldStateHidden;
                        } else {
                            hPadding = STPPaymentCardNumberTextFieldMinimumPadding;
                            break;
                        }
                        hPadding = calculateMinimumPaddingWithLocalVars();
                    }
                }
                    break;
                case STPCardFieldTypePostalCode: {
                    /*
                     The user is entering postal code

                     It must be fully visible, and the previous field must
                     be visible
                     */
                    while (hPadding < STPPaymentCardNumberTextFieldMinimumPadding) {
                        if (panVisibility == STPCardTextFieldStateVisible) {
                            panVisibility = STPCardTextFieldStateCompressed;
                        } else if (panVisibility == STPCardTextFieldStateCompressed) {
                            panVisibility = STPCardTextFieldStateHidden;
                        } else {
                            hPadding = STPPaymentCardNumberTextFieldMinimumPadding;
                            break;
                        }
                        hPadding = calculateMinimumPaddingWithLocalVars();
                    }
                }
                    break;
            }
        }
    }

    // -- Do layout here --
    CGFloat xOffset = STPPaymentCardNumberTextFieldDefaultInsets;
    CGFloat width = 0;

    if (panVisibility == STPCardTextFieldStateCompressed) {
        // Need to lower xOffset so pan is partially off-screen

        BOOL hasEnteredCardNumber = self.cardNumber.length > 0;
        NSString *compressedCardNumber = [self.viewModel compressedCardNumberWithPlaceholder:self.numberPlaceholder];
        NSString *cardNumberToHide = [(hasEnteredCardNumber ? self.cardNumber : self.numberPlaceholder) stp_stringByRemovingSuffix:compressedCardNumber];

        if (cardNumberToHide.length > 0 && [STPCardValidator stringIsNumeric:cardNumberToHide]) {
            width = [self numberFieldFullWidth];

            CGFloat hiddenWidth = [self widthForCardNumber:cardNumberToHide];
            UIView *maskView = [[UIView alloc] initWithFrame:CGRectMake(hiddenWidth,
                                                                        0,
                                                                        (width - hiddenWidth),
                                                                        fieldsHeight)];
            maskView.backgroundColor = [UIColor blackColor];
            #ifdef __IPHONE_13_0
                if (@available(iOS 13.0, *)) {
                    maskView.backgroundColor = [UIColor labelColor];
                }
            #endif
            maskView.opaque = YES;
            maskView.userInteractionEnabled = NO;
            [UIView performWithoutAnimation:^{
                self.numberField.maskView = maskView;
            }];
        } else {
            [UIView performWithoutAnimation:^{
                self.numberField.maskView = nil;
            }];
        }
    } else {
        width = [self numberFieldFullWidth];
        [UIView performWithoutAnimation:^{
            self.numberField.maskView = nil;
        }];
    }
        
    xOffset += (self.brandImageView.frame.origin.x + self.brandImageView.bounds.size.width);

    self.numberField.frame = CGRectMake(xOffset, 0, bounds.size.width - xOffset - hPadding, fieldsHeight);

}

#pragma mark - private helper methods

- (STPFormTextField *)buildTextField {
    STPFormTextField *textField = [[STPFormTextField alloc] initWithFrame:CGRectZero];
    textField.backgroundColor = [UIColor clearColor];
    // setCountryCode: updates the postalCodeField keyboardType, this is safe
    textField.keyboardType = UIKeyboardTypeASCIICapableNumberPad;
    textField.textAlignment = NSTextAlignmentLeft;
    textField.font = self.font;
    textField.defaultColor = [UIColor blackColor];
    textField.errorColor = self.textErrorColor;
    textField.placeholderColor = self.placeholderColor;
    textField.formDelegate = self;
    textField.validText = true;
    return textField;
}

typedef void (^STPLayoutAnimationCompletionBlock)(BOOL completed);
- (void)layoutViewsToFocusField:(NSNumber *)focusedField
           becomeFirstResponder:(BOOL)shouldBecomeFirstResponder
                       animated:(BOOL)animated
                     completion:(STPLayoutAnimationCompletionBlock)completion {

    NSNumber *fieldtoFocus = focusedField;

    if (fieldtoFocus == nil
        && ![self.focusedTextFieldForLayout isEqualToNumber:@(STPCardFieldTypeNumber)]
        && ([self.viewModel validationStateForField:STPCardFieldTypeNumber] != STPCardValidationStateValid)) {
        fieldtoFocus = @(STPCardFieldTypeNumber);
        if (shouldBecomeFirstResponder) {
            [self.numberField becomeFirstResponder];
        }
    }

    if ((fieldtoFocus == nil && self.focusedTextFieldForLayout == nil)
        || (fieldtoFocus != nil && [self.focusedTextFieldForLayout isEqualToNumber:fieldtoFocus])
        ) {
        if (completion) {
            completion(YES);
        }
        return;
    }

    self.focusedTextFieldForLayout = fieldtoFocus;

    void (^animations)(void) = ^void() {
        [self recalculateSubviewLayout];
    };

    if (animated) {
        NSTimeInterval duration = animated * 0.3;
        [UIView animateWithDuration:duration
                              delay:0
             usingSpringWithDamping:0.85f
              initialSpringVelocity:0
                            options:0
                         animations:animations
                         completion:completion];
    } else {
        animations();
    }
}

- (CGFloat)widthForAttributedText:(NSAttributedString *)attributedText {
    // UITextField doesn't seem to size correctly here for unknown reasons
    // But UILabel reliably calculates size correctly using this method
    self.sizingLabel.attributedText = attributedText;
    [self.sizingLabel sizeToFit];
    return stp_ceilCGFloat((CGRectGetWidth(self.sizingLabel.bounds)));

}

- (CGFloat)widthForText:(NSString *)text {
    if (text.length == 0) {
        return 0;
    }

    NSNumber *cachedValue = self.textToWidthCache[text];
    if (cachedValue == nil) {
        self.sizingField.autoFormattingBehavior = STPFormTextFieldAutoFormattingBehaviorNone;
        [self.sizingField setText:STPNonLocalizedString(text)];
        cachedValue = @([self widthForAttributedText:self.sizingField.attributedText]);
        self.textToWidthCache[text] = cachedValue;
    }
    return (CGFloat)[cachedValue doubleValue];
}

- (CGFloat)widthForCardNumber:(NSString *)cardNumber {
    if (cardNumber.length == 0) {
        return 0;
    }

    NSNumber *cachedValue = self.numberToWidthCache[cardNumber];
    if (cachedValue == nil) {
        self.sizingField.autoFormattingBehavior = STPFormTextFieldAutoFormattingBehaviorCardNumbers;
        [self.sizingField setText:cardNumber];
        cachedValue = @([self widthForAttributedText:self.sizingField.attributedText]);
        self.numberToWidthCache[cardNumber] = cachedValue;
    }
    return (CGFloat)[cachedValue doubleValue];
}

#pragma mark STPFormTextFieldDelegate

- (void)formTextFieldDidBackspaceOnEmpty:(__unused STPFormTextField *)formTextField {
    STPFormTextField *previous = [self previousField];
    [previous becomeFirstResponder];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil);
    if (previous.hasText) {
        [previous deleteBackward];
    }
}

- (NSAttributedString *)formTextField:(STPFormTextField *)formTextField
   modifyIncomingTextChange:(NSAttributedString *)input {
    STPCardFieldType fieldType = formTextField.tag;
    switch (fieldType) {
        case STPCardFieldTypeNumber:
            self.viewModel.cardNumber = input.string;
            [self setNeedsLayout];
            break;
        default:
            break;
    }
    
      return [[NSAttributedString alloc] initWithString:self.viewModel.cardNumber
                                                     attributes:self.numberField.defaultTextAttributes];
         
}

- (void)formTextFieldTextDidChange:(STPFormTextField *)formTextField {
    STPCardFieldType fieldType = formTextField.tag;
    if (fieldType == STPCardFieldTypeNumber) {
        [self updateImageForFieldType:fieldType];
    }
    
    STPCardValidationState state = [self.viewModel validationStateForField:fieldType];
    formTextField.validText = YES;
    switch (state) {
        case STPCardValidationStateInvalid:
            formTextField.validText = NO;
            break;
        case STPCardValidationStateIncomplete:
            break;
        case STPCardValidationStateValid: {
            if (fieldType == STPCardFieldTypeCVC) {
                /*
                 Even though any CVC longer than the min required CVC length
                 is valid, we don't want to forward on to the next field
                 unless it is actually >= the max cvc length (otherwise when
                 postal code is showing, you can't easily enter CVCs longer than
                 the minimum.
                 */
                NSString *sanitizedCvc = [STPCardValidator sanitizedNumericStringForString:formTextField.text];
                if (sanitizedCvc.length < [STPCardValidator maxCVCLengthForCardBrand:self.viewModel.brand]) {
                    break;
                }
            } else if (fieldType == STPCardFieldTypePostalCode) {
                /*
                 Similar to the UX problems on CVC, since our Postal Code validation
                 is pretty light, we want to block auto-advance here. In the US, this
                 allows users to enter 9 digit zips if they want, and as many as they
                 need in non-US countries (where >0 characters is "valid")
                 */
                break;
            }

            // This is a no-op if this is the last field & they're all valid
            [[self nextFirstResponderField] becomeFirstResponder];
            UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil);
            
            break;
        }
    }

    [self onChange];
}

typedef NS_ENUM(NSInteger, STPFieldEditingTransitionCallSite) {
    STPFieldEditingTransitionCallSiteShouldBegin,
    STPFieldEditingTransitionCallSiteShouldEnd,
    STPFieldEditingTransitionCallSiteDidBegin,
    STPFieldEditingTransitionCallSiteDidEnd,
};

// Explanation of the logic here is with the definition of these properties
// at the top of this file
- (BOOL)getAndUpdateSubviewEditingTransitionStateFromCall:(STPFieldEditingTransitionCallSite)sendingMethod {
    BOOL stateToReturn;
    switch (sendingMethod) {
        case STPFieldEditingTransitionCallSiteShouldBegin:
            self.receivedUnmatchedShouldBeginEditing = YES;
            if (self.receivedUnmatchedShouldEndEditing) {
                self.isMidSubviewEditingTransitionInternal = YES;
            }
            stateToReturn = self.isMidSubviewEditingTransitionInternal;
            break;
        case STPFieldEditingTransitionCallSiteShouldEnd:
            self.receivedUnmatchedShouldEndEditing = YES;
            if (self.receivedUnmatchedShouldBeginEditing) {
                self.isMidSubviewEditingTransitionInternal = YES;
            }
            stateToReturn = self.isMidSubviewEditingTransitionInternal;
            break;
        case STPFieldEditingTransitionCallSiteDidBegin:
            stateToReturn = self.isMidSubviewEditingTransitionInternal;
            self.receivedUnmatchedShouldBeginEditing = NO;

            if (self.receivedUnmatchedShouldEndEditing == NO) {
                self.isMidSubviewEditingTransitionInternal = NO;
            }
            break;
        case STPFieldEditingTransitionCallSiteDidEnd:
            stateToReturn = self.isMidSubviewEditingTransitionInternal;
            self.receivedUnmatchedShouldEndEditing = NO;

            if (self.receivedUnmatchedShouldBeginEditing == NO) {
                self.isMidSubviewEditingTransitionInternal = NO;
            }
            break;
    }

    return stateToReturn;
}


- (void)resetSubviewEditingTransitionState {
    self.isMidSubviewEditingTransitionInternal = NO;
    self.receivedUnmatchedShouldBeginEditing = NO;
    self.receivedUnmatchedShouldEndEditing = NO;
}

- (BOOL)textFieldShouldBeginEditing:(__unused UITextField *)textField {
    [self getAndUpdateSubviewEditingTransitionStateFromCall:STPFieldEditingTransitionCallSiteShouldBegin];
    return YES;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    BOOL isMidSubviewEditingTransition = [self getAndUpdateSubviewEditingTransitionStateFromCall:STPFieldEditingTransitionCallSiteDidBegin];

    [self layoutViewsToFocusField:@(textField.tag)
             becomeFirstResponder:YES
                         animated:YES
                       completion:nil];

    if (!isMidSubviewEditingTransition) {
        if ([self.delegate respondsToSelector:@selector(paymentCardTextFieldDidBeginEditing:)]) {
            [self.delegate paymentCardTextFieldDidBeginEditing:self];
        }
    }

    switch ((STPCardFieldType)textField.tag) {
        case STPCardFieldTypeNumber:
            ((STPFormTextField *)textField).validText = YES;
            if ([self.delegate respondsToSelector:@selector(paymentCardTextFieldDidBeginEditingNumber:)]) {
                [self.delegate paymentCardTextFieldDidBeginEditingNumber:self];
            }
            break;
        case STPCardFieldTypeCVC:
            if ([self.delegate respondsToSelector:@selector(paymentCardTextFieldDidBeginEditingCVC:)]) {
                [self.delegate paymentCardTextFieldDidBeginEditingCVC:self];
            }
            break;
        case STPCardFieldTypeExpiration:
            if ([self.delegate respondsToSelector:@selector(paymentCardTextFieldDidBeginEditingExpiration:)]) {
                [self.delegate paymentCardTextFieldDidBeginEditingExpiration:self];
            }
            break;
        case STPCardFieldTypePostalCode:
            if ([self.delegate respondsToSelector:@selector(paymentCardTextFieldDidBeginEditingPostalCode:)]) {
                [self.delegate paymentCardTextFieldDidBeginEditingPostalCode:self];
            }
            break;
    }
    [self updateImageForFieldType:textField.tag];
}

- (BOOL)textFieldShouldEndEditing:(__unused UITextField *)textField {
    [self getAndUpdateSubviewEditingTransitionStateFromCall:STPFieldEditingTransitionCallSiteShouldEnd];
    [self updateImageForFieldType:STPCardFieldTypeNumber];
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    BOOL isMidSubviewEditingTransition = [self getAndUpdateSubviewEditingTransitionStateFromCall:STPFieldEditingTransitionCallSiteDidEnd];

    switch ((STPCardFieldType)textField.tag) {
        case STPCardFieldTypeNumber:
            if ([self.viewModel validationStateForField:STPCardFieldTypeNumber] == STPCardValidationStateIncomplete) {
                ((STPFormTextField *)textField).validText = NO;
            }
            if ([self.delegate respondsToSelector:@selector(paymentCardTextFieldDidEndEditingNumber:)]) {
                [self.delegate paymentCardTextFieldDidEndEditingNumber:self];
            }
            break;
        case STPCardFieldTypeCVC:
            if ([self.delegate respondsToSelector:@selector(paymentCardTextFieldDidEndEditingCVC:)]) {
                [self.delegate paymentCardTextFieldDidEndEditingCVC:self];
            }
            break;
        case STPCardFieldTypeExpiration:
            if ([self.delegate respondsToSelector:@selector(paymentCardTextFieldDidEndEditingExpiration:)]) {
                [self.delegate paymentCardTextFieldDidEndEditingExpiration:self];
            }
            break;
        case STPCardFieldTypePostalCode:
            if ([self.delegate respondsToSelector:@selector(paymentCardTextFieldDidEndEditingPostalCode:)]) {
                [self.delegate paymentCardTextFieldDidEndEditingPostalCode:self];
            }
            break;
    }

    if (!isMidSubviewEditingTransition) {
        [self layoutViewsToFocusField:nil
                 becomeFirstResponder:NO
                             animated:YES
                           completion:nil];
        [self updateImageForFieldType:STPCardFieldTypeNumber];
        if ([self.delegate respondsToSelector:@selector(paymentCardTextFieldDidEndEditing:)]) {
            [self.delegate paymentCardTextFieldDidEndEditing:self];
        }
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if ([self.delegate respondsToSelector:@selector(paymentCardTextFieldWillEndEditingForReturn:)]) {
        [self.delegate paymentCardTextFieldWillEndEditingForReturn:self];
    }
    [self resignFirstResponder];

    return NO;
}

- (UIImage *)brandImage {
    STPCardFieldType fieldType = STPCardFieldTypeNumber;
    if (self.currentFirstResponderField) {
        fieldType = self.currentFirstResponderField.tag;
    }
    STPCardValidationState validationState = [self.viewModel validationStateForField:fieldType];
    return [self brandImageForFieldType:fieldType validationState:validationState];
}

+ (UIImage *)cvcImageForCardBrand:(STPCardBrand)cardBrand {
    return [STPImageLibrary cvcImageForCardBrand:cardBrand];
}

+ (UIImage *)brandImageForCardBrand:(STPCardBrand)cardBrand {
    return [STPImageLibrary brandImageForCardBrand:cardBrand];
}

+ (UIImage *)errorImageForCardBrand:(STPCardBrand)cardBrand {
    return [STPImageLibrary errorImageForCardBrand:cardBrand];
}

- (UIImage *)brandImageForFieldType:(STPCardFieldType)fieldType validationState:(STPCardValidationState)validationState {
    switch (fieldType) {
        case STPCardFieldTypeNumber:
            if (validationState == STPCardValidationStateInvalid) {
                return [self.class errorImageForCardBrand:self.viewModel.brand];
            } else {
                return [self.class brandImageForCardBrand:self.viewModel.brand];
            }
        case STPCardFieldTypeCVC:
            return [self.class cvcImageForCardBrand:self.viewModel.brand];
        case STPCardFieldTypeExpiration:
            return [self.class brandImageForCardBrand:self.viewModel.brand];
        case STPCardFieldTypePostalCode:
            return [self.class brandImageForCardBrand:self.viewModel.brand];
    }
}

- (UIViewAnimationOptions)brandImageAnimationOptionsForNewType:(STPCardFieldType)newType
                                                      newBrand:(STPCardBrand)newBrand
                                                       oldType:(STPCardFieldType)oldType
                                                      oldBrand:(STPCardBrand)oldBrand {

    if (newType == STPCardFieldTypeCVC
        && oldType != STPCardFieldTypeCVC) {
        // Transitioning to show CVC

        if (newBrand != STPCardBrandAmex) {
            // CVC is on the back
            return (UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionTransitionFlipFromRight);
        }
    } else if (newType != STPCardFieldTypeCVC
             && oldType == STPCardFieldTypeCVC) {
        // Transitioning to stop showing CVC

        if (oldBrand != STPCardBrandAmex) {
            // CVC was on the back
            return (UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionTransitionFlipFromLeft);
        }
    }

    // All other cases just cross dissolve
    return (UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionTransitionCrossDissolve);

}

- (void)updateImageForFieldType:(STPCardFieldType)fieldType {
    STPCardValidationState validationState = [self.viewModel validationStateForField:fieldType];
    UIImage *image = [self brandImageForFieldType:fieldType validationState:validationState];
    if (![image isEqual:self.brandImageView.image]) {

        STPCardBrand newBrand = self.viewModel.brand;
        UIViewAnimationOptions imageAnimationOptions = [self brandImageAnimationOptionsForNewType:fieldType
                                                                                         newBrand:newBrand
                                                                                          oldType:self.currentBrandImageFieldType
                                                                                         oldBrand:self.currentBrandImageBrand];

        self.currentBrandImageFieldType = fieldType;
        self.currentBrandImageBrand = newBrand;

        [UIView transitionWithView:self.brandImageView
                          duration:0.2
                           options:imageAnimationOptions
                        animations:^{
                            self.brandImageView.image = image;
                        }
                        completion:nil];
    }
}

- (void)onChange {
    if ([self.delegate respondsToSelector:@selector(paymentCardTextFieldDidChange:)]) {
        [self.delegate paymentCardTextFieldDidChange:self];
    }
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

#pragma mark UIKeyInput

- (BOOL)hasText {
    return self.numberField.hasText;
}

- (void)insertText:(NSString *)text {
    [self.currentFirstResponderField insertText:text];
}

- (void)deleteBackward {
    [self.currentFirstResponderField deleteBackward];
}

+ (NSSet<NSString *> *)keyPathsForValuesAffectingIsValid {
    return [NSSet setWithArray:@[
                                 [NSString stringWithFormat:@"%@.%@",
                                  NSStringFromSelector(@selector(viewModel)),
                                  NSStringFromSelector(@selector(valid))],
                                 ]];
}

@end
