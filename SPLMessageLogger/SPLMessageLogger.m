//
//  SPLMessageLogger.m
//  SPLMessageLogger
//
//  Created by Oliver Letterer on 22.03.14.
//  Copyright 2014 Sparrowlabs. All rights reserved.
//

#import "SPLMessageLogger.h"
#import <objc/message.h>
#import <imp_implementationForwardingToSelector.h>

static BOOL class_shouldForwardActionToMessageLogger(Class class, SEL action)
{
    return [NSStringFromSelector(action) hasPrefix:@"__SPLMessageLogger_"];
}

static void class_swizzleSelector(Class class, SEL originalSelector, SEL newSelector)
{
    Method origMethod = class_getInstanceMethod(class, originalSelector);
    Method newMethod = class_getInstanceMethod(class, newSelector);
    if(class_addMethod(class, originalSelector, method_getImplementation(newMethod), method_getTypeEncoding(newMethod))) {
        class_replaceMethod(class, newSelector, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, newMethod);
    }
}

void spl_classLogSelector(Class recordingClass, SEL originalSelector)
{
    SEL forwardingSelector = NSSelectorFromString([NSString stringWithFormat:@"__SPLMessageLogger_%@_%@", NSStringFromClass(recordingClass), NSStringFromSelector(originalSelector)]);
    SEL selectorForOriginalImplementation = NSSelectorFromString([NSString stringWithFormat:@"__SPLMessageLogger_original_%@_%@", NSStringFromClass(recordingClass), NSStringFromSelector(originalSelector)]);

    BOOL recordingClassDoesImplementOriginalSelector = [recordingClass instanceMethodForSelector:originalSelector] != [[recordingClass superclass] instanceMethodForSelector:originalSelector];

    if (![recordingClass instancesRespondToSelector:forwardingSelector] && ![recordingClass instancesRespondToSelector:selectorForOriginalImplementation] && recordingClassDoesImplementOriginalSelector) {
        Method method = class_getInstanceMethod(recordingClass, originalSelector);
        const char *encoding = method_getTypeEncoding(method);
        BOOL methodReturnsStructValue = encoding[0] == '{';
#ifdef __i386__
        if ( methodReturnsStructValue ) {
            @try {
                NSUInteger valueSize = 0;
                NSGetSizeAndAlignment(encoding, &valueSize, NULL);

                if (valueSize == 1 || valueSize == 2 || valueSize == 4 || valueSize == 8) {
                    methodReturnsStructValue = NO;
                }
            } @catch (NSException *e) {}
        }
#endif
        IMP forwardingImplementation = imp_implementationForwardingToSelector(forwardingSelector, methodReturnsStructValue);

        class_addMethod(recordingClass, selectorForOriginalImplementation, method_getImplementation(method), method_getTypeEncoding(method));
        method_setImplementation(method, forwardingImplementation);
    }
}



@interface SPLMessageLogger : NSObject

@property (nonatomic, unsafe_unretained) id target;
@property (nonatomic, assign) SEL selector;

- (instancetype)initWithTarget:(id)target selector:(SEL)selector;

@end


@interface SPLMessageLoggerRecorder : NSObject @end

@interface SPLMessageLoggerRecorder()

@property (nonatomic, readonly) Class recordingClass;
- (instancetype)initWithClass:(Class)class;

@end

@implementation SPLMessageLoggerRecorder

- (Class)class
{
    return (id)[[SPLMessageLoggerRecorder alloc] initWithClass:objc_getMetaClass(class_getName(self.recordingClass))];
}

+ (instancetype)messageLogger
{
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (instancetype)initWithClass:(Class)class
{
    if (self = [super init]) {
        _recordingClass = class;
    }

    return self;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    Method instanceMethod = class_getInstanceMethod(self.recordingClass, aSelector);
    if (method_getName(instanceMethod) == aSelector) {
        return [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(instanceMethod)];
    }

    return nil;
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
    SEL originalSelector = anInvocation.selector;
    BOOL recordingClassDoesImplementOriginalSelector = [self.recordingClass instanceMethodForSelector:originalSelector] != [[self.recordingClass superclass] instanceMethodForSelector:originalSelector];

    spl_classLogSelector(self.recordingClass, originalSelector);

    if (anInvocation.methodSignature.methodReturnLength > 0) {
        size_t *zeroedReturnValue = calloc(anInvocation.methodSignature.methodReturnLength, sizeof(size_t));
        [anInvocation setReturnValue:zeroedReturnValue];
        free(zeroedReturnValue);
    }

    if (!recordingClassDoesImplementOriginalSelector) {
        NSLog(@"[%@ %@] has been skipped because %@ does not implement %@", self.recordingClass, NSStringFromSelector(originalSelector), self.recordingClass, NSStringFromSelector(originalSelector));
    }
}

@end



@implementation NSObject (SPLMessageLogger)

+ (instancetype)messageLogger
{
    SPLMessageLoggerRecorder *recorder = [[SPLMessageLoggerRecorder alloc] initWithClass:self];
    return (id)recorder;
}

+ (void)load
{
    class_swizzleSelector(self, @selector(forwardingTargetForSelector:), @selector(__SPLMessageLogger_forwardingTargetForSelector:));
}

- (id)__SPLMessageLogger_forwardingTargetForSelector:(SEL)aSelector
{
    if (class_shouldForwardActionToMessageLogger(object_getClass(self), aSelector) && ![self isKindOfClass:[SPLMessageLogger class]]) {
        return [[SPLMessageLogger alloc] initWithTarget:self selector:aSelector];
    }

    return [self __SPLMessageLogger_forwardingTargetForSelector:aSelector];
}

@end



@implementation NSInvocation (SPLMessageLogger)

// Thanks to the ReactiveCocoa team for providing a generic solution for this.
- (id)spl_descriptionAtIndex:(NSInteger)index
{
	const char *argType = index < 0 ? self.methodSignature.methodReturnType :
                            [self.methodSignature getArgumentTypeAtIndex:index];
	// Skip const type qualifier.
	if (argType[0] == 'r') argType++;

#define WRAP_AND_RETURN(type) do { type val = 0; index < 0 ? [self getReturnValue:&val] : [self getArgument:&val atIndex:index]; return @(val); } while (0)
	if (strcmp(argType, @encode(id)) == 0 || strcmp(argType, @encode(Class)) == 0) {
		__unsafe_unretained id returnObj =nil;
        if ( index < 0 )
            [self getReturnValue:&returnObj];
        else
            [self getArgument:&returnObj atIndex:index];
        NSUInteger nullIdiom = ~0; // sometimes encountered on messages with Idom: argument
		return (NSUInteger)returnObj != nullIdiom ? [returnObj description] : @(nullIdiom);
	} else if (strcmp(argType, @encode(char)) == 0) {
		WRAP_AND_RETURN(char);
	} else if (strcmp(argType, @encode(int)) == 0) {
		WRAP_AND_RETURN(int);
	} else if (strcmp(argType, @encode(short)) == 0) {
		WRAP_AND_RETURN(short);
	} else if (strcmp(argType, @encode(long)) == 0) {
		WRAP_AND_RETURN(long);
	} else if (strcmp(argType, @encode(long long)) == 0) {
		WRAP_AND_RETURN(long long);
	} else if (strcmp(argType, @encode(unsigned char)) == 0) {
		WRAP_AND_RETURN(unsigned char);
	} else if (strcmp(argType, @encode(unsigned int)) == 0) {
		WRAP_AND_RETURN(unsigned int);
	} else if (strcmp(argType, @encode(unsigned short)) == 0) {
		WRAP_AND_RETURN(unsigned short);
	} else if (strcmp(argType, @encode(unsigned long)) == 0) {
		WRAP_AND_RETURN(unsigned long);
	} else if (strcmp(argType, @encode(unsigned long long)) == 0) {
		WRAP_AND_RETURN(unsigned long long);
	} else if (strcmp(argType, @encode(float)) == 0) {
		WRAP_AND_RETURN(float);
	} else if (strcmp(argType, @encode(double)) == 0) {
		WRAP_AND_RETURN(double);
	} else if (strcmp(argType, @encode(BOOL)) == 0) {
		WRAP_AND_RETURN(BOOL);
	} else if (strcmp(argType, @encode(char *)) == 0) {
		WRAP_AND_RETURN(const char *);
	} else if (strcmp(argType, @encode(void (^)(void))) == 0) {
		__unsafe_unretained id block = nil;
		[self getArgument:&block atIndex:index];
		return [block description];
	} else {
		NSUInteger valueSize = 0;
		NSGetSizeAndAlignment(argType, &valueSize, NULL);

		unsigned char valueBytes[valueSize];
        if ( index < 0 )
            [self getReturnValue:valueBytes];
        else
            [self getArgument:valueBytes atIndex:index];

		return [NSValue valueWithBytes:valueBytes objCType:argType];
	}

	return nil;
#undef WRAP_AND_RETURN
}

@end

@implementation SPLMessageLogger

- (instancetype)initWithTarget:(id)target selector:(SEL)selector
{
    if (self = [super init]) {
        _target = target;
        _selector = NSSelectorFromString([NSStringFromSelector(selector) stringByReplacingOccurrencesOfString:@"__SPLMessageLogger_" withString:@"__SPLMessageLogger_original_"]);
    }
    return self;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    Method method = class_getInstanceMethod(object_getClass(self.target), self.selector);
    return [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
    anInvocation.target = self.target;

    NSString *targetString = [NSString stringWithFormat:@"<%@:%p>", object_getClass(self.target), self.target];

    NSInteger logLevel = [[NSThread currentThread].threadDictionary[@"SPLMessageLoggerLogLevel"] integerValue] + 1;
    [NSThread currentThread].threadDictionary[@"SPLMessageLoggerLogLevel"] = @([[NSThread currentThread].threadDictionary[@"SPLMessageLoggerLogLevel"] integerValue] + 1);

    NSString *selectorString = [NSStringFromSelector(self.selector) stringByReplacingOccurrencesOfString:@"__SPLMessageLogger_original_" withString:@""];
    NSInteger index = [selectorString rangeOfString:@"_"].location;

    NSString *classString = [selectorString substringToIndex:index];
    NSString *originalSelectorName = [selectorString substringFromIndex:index + 1];

    NSMutableArray *selectorComponents = [NSMutableArray array];
    for (NSString *component in [originalSelectorName componentsSeparatedByString:@":"]) {
        if (component.length > 0) {
            [selectorComponents addObject:component];
        }
    }

    // log invocation
    NSMutableString *logString = [NSMutableString stringWithFormat:@"> %@: -[%@", targetString, classString];
    for (NSInteger i = 0; i < logLevel; i++) {
        [logString insertString:@"-" atIndex:0];
    }

    BOOL invocationArgumentsDidMatch = selectorComponents.count == anInvocation.methodSignature.numberOfArguments - 2;
    if (invocationArgumentsDidMatch) {
        for (NSUInteger argument = 2; argument < anInvocation.methodSignature.numberOfArguments; argument++) {
            NSString *description = [anInvocation spl_descriptionAtIndex:argument];
            [logString appendFormat:@" %@:%@", selectorComponents[argument - 2], description];
        }
    } else {
        [logString appendFormat:@" %@", originalSelectorName];
    }

    [logString appendString:@"]"];
    printf("%s\n", [logString UTF8String]); // printf much faster than NSLog

    anInvocation.selector = self.selector;
    [anInvocation invoke];

    [NSThread currentThread].threadDictionary[@"SPLMessageLoggerLogLevel"] = @([[NSThread currentThread].threadDictionary[@"SPLMessageLoggerLogLevel"] integerValue] - 1);

    // log result
    {
        NSMutableString *logString = [NSMutableString stringWithFormat:@">"];
        for (NSInteger i = 0; i < logLevel; i++) {
            [logString insertString:@"=" atIndex:0];
        }

        if (anInvocation.methodSignature.methodReturnLength > 0) {
            [logString appendFormat:@" %@", [anInvocation spl_descriptionAtIndex:-1]];
        } else {
            [logString appendString:@" void"];
        }
        
        printf("%s\n", [logString UTF8String]);
    }
}

@end
