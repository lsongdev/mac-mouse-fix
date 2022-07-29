//
// --------------------------------------------------------------------------
// GestureScrollSimulator.m
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2020
// Licensed under MIT
// --------------------------------------------------------------------------
//

#import "GestureScrollSimulator.h"
#import <QuartzCore/QuartzCore.h>
#import <Cocoa/Cocoa.h>
#import "TouchSimulator.h"
#import "HelperUtility.h"
#import "SharedUtility.h"
#import "VectorSubPixelator.h"
#import "TransformationUtility.h"
#import "Mac_Mouse_Fix_Helper-Swift.h"
#import "WannabePrefixHeader.h"

/**
 This generates fliud scroll events containing gesture data similar to the Apple Trackpad or Apple Magic Mouse driver.
 The events that this generates don't exactly match the ones generated by the Apple Drivers. Most notably they don't contain any raw touch  information. But in most situations, they will work exactly like scrolling on an Apple Trackpad or Magic Mouse

Also see:
 - GestureScrollSimulatorOld.m - an older implementation which tried to emulate the Apple drivers more closely. See the notes in GestureScrollSimulatorOld.m for more info.
 - TouchExtractor-twoFingerSwipe.xcproj for the code we used to figure this out and more relevant notes.
 - Notes in other places I can't think of
 */


@implementation GestureScrollSimulator

#pragma mark - Constants

static double _pixelsPerLine = 10;

#pragma mark - Vars and init

static VectorSubPixelator *_scrollLinePixelator;

static PixelatedVectorAnimator *_momentumAnimator;

static dispatch_queue_t _queue; /// Use this queue for interface functions to avoid race conditions

+ (void)initialize
{
    if (self == [GestureScrollSimulator class]) {
        
        /// Init dispatch queue
        
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, -1);
        _queue = dispatch_queue_create("com.nuebling.mac-mouse-fix.gesture-scroll", attr);
        
        /// Init Pixelators
        
        _scrollLinePixelator = [VectorSubPixelator biasedPixelator]; /// I think biased is only beneficial on linePixelator. Too lazy to explain.
        
        /// Momentum scroll
        
        _momentumAnimator = [[PixelatedVectorAnimator alloc] init];
        
    }
}

#pragma mark - Main interface

/**
 Post scroll events that behave as if they are coming from an Apple Trackpad or Magic Mouse.
 This function is a wrapper for `postGestureScrollEventWithGestureVector:scrollVector:scrollVectorPoint:phase:momentumPhase:`

 Scrolling will continue automatically but get slower over time after the function has been called with phase kIOHIDEventPhaseEnded. (Momentum scroll)
 
    - The initial speed of this "momentum phase" is based on the delta values of last time that this function is called with at least one non-zero delta and with phase kIOHIDEventPhaseBegan or kIOHIDEventPhaseChanged before it is called with phase kIOHIDEventPhaseEnded.
 
    - The reason behind this is that this is how real trackpad input seems to work. Some apps like Xcode will automatically keep scrolling if no events are sent after the event with phase kIOHIDEventPhaseEnded. And others, like Safari will not. This function wil automatically keep sending events after it has been called with kIOHIDEventPhaseEnded in order to make all apps react as consistently as possible.
 
 \note In order to minimize momentum scrolling,  send an event with a very small but non-zero scroll delta before calling the function with phase kIOHIDEventPhaseEnded, or call stopMomentumScroll()
 \note For more info on which delta values and which phases to use, see the documentation for `postGestureScrollEventWithGestureDeltaX:deltaY:phase:momentumPhase:scrollDeltaConversionFunction:scrollPointDeltaConversionFunction:`. In contrast to the aforementioned function, you shouldn't need to call this function with kIOHIDEventPhaseUndefined.
*/

+ (void)postGestureScrollEventWithDeltaX:(int64_t)dx deltaY:(int64_t)dy phase:(IOHIDEventPhaseBits)phase {
    
    /// Convenience function that sets autoMomentumScroll = YES
    
    [self postGestureScrollEventWithDeltaX:dx deltaY:dy phase:phase autoMomentumScroll:YES];
}

+ (void)postGestureScrollEventWithDeltaX:(int64_t)dx deltaY:(int64_t)dy phase:(IOHIDEventPhaseBits)phase autoMomentumScroll:(BOOL)autoMomentumScroll {
    
    /// Schedule event to be posted on _queue and return immediately
    
    dispatch_async(_queue, ^{
        postGestureScrollEvent_Unsafe(dx, dy, phase, autoMomentumScroll);
    });
}

void postGestureScrollEvent_Unsafe(int64_t dx, int64_t dy, IOHIDEventPhaseBits phase, Boolean autoMomentumScroll) {
    /// This function doesn't dispatch to _queue. It should only be called if you're already on _queue. Otherwise there will be race conditions with the other functions that execute on _queue.
    /// `autoMomentumScroll` should always be true, except if you are going to post momentumScrolls manually using `+ postMomentumScrollEvent`
    
    /// Debug
    
    //    DDLogDebug(@"Request to post Gesture Scroll: (%f, %f), phase: %d", dx, dy, phase);
    
    /// Validate input
    
    if (phase != kIOHIDEventPhaseEnded && dx == 0.0 && dy == 0.0) {
        /// Maybe kIOHIDEventPhaseBegan events from the Trackpad driver can also contain zero-deltas? I don't think so by I'm not sure.
        /// Real trackpad driver seems to only produce zero deltas when phase is kIOHIDEventPhaseEnded.
        ///     - (And probably also if phase is kIOHIDEventPhaseCancelled or kIOHIDEventPhaseMayBegin, but we're not using those here - IIRC those are only produced when the user touches the trackpad but doesn't begin scrolling before lifting fingers off again)
        /// The main practical reason we're emulating this behavour of the trackpad driver because of this: There are certain apps (or views?) which create their own momentum scrolls and ignore the momentum scroll deltas contained in the momentum scroll events we send. E.g. Xcode or the Finder collection view. I think that these views ignore all zero-delta events when they calculate what the initial momentum scroll speed should be. (It's been months since I discovered that though, so maybe I'm rememvering wrong) We want to match these apps momentum scroll algortihm closely to provide a consisten experience. So we're not sending the zero-delta events either and ignoring them for the purposes of our momentum scroll calculation and everything else.
        
        DDLogWarn(@"Trying to post gesture scroll with zero deltas while phase is not kIOHIDEventPhaseEnded - ignoring");
        
        return;
    }
    
    
    /// Stop momentum scroll
    ///     Do it sync otherwise it will be stopped immediately after it's startet by this block
    [GestureScrollSimulator stopMomentumScroll_Unsafe];
    
    /// Timestamps and static vars

    static CFTimeInterval lastInputTime;
    static Vector lastScrollPointVector;
    
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval timeSinceLastInput;
    
    if (phase == kIOHIDEventPhaseBegan) {
        timeSinceLastInput = DBL_MAX; /// This means we can't say anything useful about the time since last input
    } else {
        timeSinceLastInput = now - lastInputTime;
    }
    
    /// Main
    
    if (phase == kIOHIDEventPhaseBegan) {
        
        /// Reset subpixelator
        [_scrollLinePixelator reset];
    }
    if (phase == kIOHIDEventPhaseBegan || phase == kIOHIDEventPhaseChanged) {
        
        /// Get vectors
        
        Vector vecScrollPoint = (Vector){ .x = dx, .y = dy };
        Vector vecScrollLine = scrollLineVector_FromScrollPointVector(vecScrollPoint);
        Vector vecGesture = gestureVector_FromScrollPointVector(vecScrollPoint);
        
        /// Subpixelate vector
        ///     No need to subpixelate the other two vecs because they are integer
        
        vecScrollLine = [_scrollLinePixelator intVectorWithDoubleVector:vecScrollLine];
        
        /// Record last scroll point vec
        
        lastScrollPointVector = vecScrollPoint;
        
        /// Post events
        
        [GestureScrollSimulator postGestureScrollEventWithGestureVector:vecGesture
                                                       scrollVectorLine:vecScrollLine
                                                      scrollVectorPoint:vecScrollPoint
                                                                  phase:phase
                                                          momentumPhase:kCGMomentumScrollPhaseNone
                                                               location:getPointerLocation()];
        
        /// Debug
        //        DDLogInfo(@"timeSinceLast: %f scrollVec: %f %f speed: %f", timeSinceLastInput, vecScrollPoint.x, vecScrollPoint.y, vecScrollPoint.y / timeSinceLastInput);
        /// ^ We're trying to analyze what makes a sequence of (modifiedDrag) scrolls produce an absurly fast momentum Scroll in Xcode (Xcode has it's own momentumScroll algorirthm that doesn't just follow our smoothed algorithm)
        ///     I can't see a simple pattern. I don't get it.
        ///     I do see thought that the timeSinceLast fluctuates wildly. This might be part of the issue.
        ///         Solution idea: Feed the deltas from modifiedDrag into a display-synced coalescing loop. This coalescing loop will then call GestureScrollSimulator at most [refreshRate] times a second.
        
    } else if (phase == kIOHIDEventPhaseEnded) {
        
        /// Post `ended` event
        [GestureScrollSimulator postGestureScrollEventWithGestureVector:(Vector){}
                                                       scrollVectorLine:(Vector){}
                                                      scrollVectorPoint:(Vector){}
                                                                  phase:kIOHIDEventPhaseEnded
                                                          momentumPhase:0
                                                               location:getPointerLocation()];
        
        if (autoMomentumScroll) {
        
            /// Get exitSpeed (aka initialSpeed for momentum Scroll)
            
            Vector exitVelocity = (Vector) {
                .x = lastScrollPointVector.x / timeSinceLastInput,
                .y = lastScrollPointVector.y / timeSinceLastInput
            };
            
            /// Get momentum scroll params
            
            ScrollConfig *config = [ScrollConfig copyOfConfig];
            MFScrollAnimationCurveParameters *trackpadParams = [config animationCurveParamsForPreset:kMFScrollAnimationCurvePresetTrackpad]; /// This is a really stupid way to access the Trackpad params. TODO: Find a better way (e.g. just hardcode them or make `- animationCurveParamsForPreset:` a class function)
            
            double stopSpeed = trackpadParams.stopSpeed;
            double dragCoeff = trackpadParams.dragCoefficient;
            double dragExp = trackpadParams.dragExponent;
            
            /// Do start momentum scroll
            
            startMomentumScroll(timeSinceLastInput, exitVelocity, stopSpeed, dragCoeff, dragExp);
        }
        
    } else {
        DDLogError(@"Trying to send GestureScroll with invalid IOHIDEventPhase: %d", phase);
        assert(false);
    }
    
    lastInputTime = now; /// Make sure you don't return early so this is always executed
}

#pragma mark - Direct momentum scroll interface

+ (void)postMomentumScrollDirectlyWithDeltaX:(double)dx
                                   deltaY:(double)dy
                            momentumPhase:(CGMomentumScrollPhase)momentumPhase {
    
    dispatch_async(_queue, ^{
        
        CGPoint loc = getPointerLocation();
        
        Vector zeroVector = (Vector){ .x = 0, .y = 0 };
        Vector deltaVec = (Vector){ .x = dx, .y = dy };
        Vector deltaVecLine = (Vector){ .x = dx/10, .y = dy/10 }; /// TODO: Subpixelate this
        
        [GestureScrollSimulator postGestureScrollEventWithGestureVector:zeroVector
                                                       scrollVectorLine:deltaVecLine
                                                      scrollVectorPoint:deltaVec
                                                                  phase:kIOHIDEventPhaseUndefined
                                                          momentumPhase:momentumPhase
                                                               location:loc];
    });
}

#pragma mark - Auto momentum scroll

static void (^_momentumScrollCallback)(void);

+ (void)afterStartingMomentumScroll:(void (^ _Nullable)(void))callback {
    /// `callback` will be called after the last `kIOHIDEventPhaseEnd` event has been sent, leading momentum scroll to be started
    ///     If it's decided that momentumScroll shouldn't be started because the `kIOHIDEventPhaseEnd` event had a too low delta or some other reason, then `callback` will be called right away.
    ///     If momentum scroll *is* started, then `callback` will be called after the first momentumScroll event has been sent.
    ///
    ///     This is only used by `ModifiedDrag`.
    ///     It probably shouldn't be sued by other classes, because of its specific behaviour and because, other classes might override eachothers callbacks, which would lead to really bad issues in ModifiedDrag
    
    dispatch_async(_queue, ^{
        
        if (_momentumAnimator.isRunning && callback != NULL) {
            /// ^ `&& callback != NULL` is a hack to make ModifiedDragOutputTwoFingerSwipe work properly. I'm not sure what I'm doing.
            
            DDLogError(@"Trying to set momentumScroll start callback while it's running. This can lead to bad issues and you probably don't want to do it.");
            assert(false);
        }
        
        _momentumScrollCallback = callback;
    });
}

/// Stop momentum scroll

+ (void)stopMomentumScroll {
    
    DDLogDebug(@"momentumScroll stop request. Caller: %@", [SharedUtility callerInfo]);
    
    dispatch_async(_queue, ^{
        [self stopMomentumScroll_Unsafe];
    });
}

+ (void)stopMomentumScroll_Unsafe {
    /// Only use this when you know you're already running on _queue
    
    /// Debug
    
//    DDLogDebug(@"momentumScroll stop request. Caller: %@", [SharedUtility callerInfo]);
    
    /// Stop
    
    if (_momentumAnimator.isRunning) {
        
        /// Stop our animator
        [_momentumAnimator stop];
        
        /// Debug
        DDLogDebug(@"... Sending momentumScroll stop event");
        
        /// Get event for location
        CGEventRef event = CGEventCreate(NULL);
        
        /// Get location from event
        CGPoint location = CGEventGetLocation(event);
        
        /// Send kCGMomentumScrollPhaseEnd event.
        ///  This will stop scrolling in apps like Xcode which implement their own momentum scroll algorithm
        Vector zeroVector = (Vector){ .x = 0.0, .y = 0.0 };
        [GestureScrollSimulator postGestureScrollEventWithGestureVector:zeroVector
                                                       scrollVectorLine:zeroVector
                                                      scrollVectorPoint:zeroVector
                                                                  phase:kIOHIDEventPhaseUndefined
                                                          momentumPhase:kCGMomentumScrollPhaseEnd
                                                               location:location];
    } else {
        /// Debug
        DDLogDebug(@"Not stopping because momentumScroll insn't running");
    }
}

/// Momentum scroll main

static void startMomentumScroll(double timeSinceLastInput, Vector exitVelocity, double stopSpeed, double dragCoefficient, double dragExponent) {
    
    ///Debug
    
    DDLogDebug(@"momentumScroll start request");
    
//    DDLogDebug(@"Exit velocity: %f, %f", exitVelocity.x, exitVelocity.y);
    
    /// Declare constants
    
    Vector zeroVector = (Vector){ .x = 0, .y = 0 };
    
    /// Stop immediately, if too much time has passed since last event (So if the mouse is stationary)
    if (OtherConfig.mouseMovingMaxIntervalLarge < timeSinceLastInput
        || timeSinceLastInput == DBL_MAX) { /// This should never be true at this point, because it's only set to DBL_MAX when phase == kIOHIDEventPhaseBegan
        DDLogDebug(@"Not sending momentum scroll - timeSinceLastInput: %f", timeSinceLastInput);
        _momentumScrollCallback();
        [GestureScrollSimulator stopMomentumScroll];
        return;
    }
    
    /// Start animator
    
//    [_momentumAnimator startWithDuration:duration valueInterval:distanceInterval animationCurve:animationCurve
//                       integerCallback:^(NSInteger pointDelta, double timeDelta, MFAnimationPhase animationPhase) {
    
    /// Init animator
    
    [_momentumAnimator resetSubPixelator];
    [_momentumAnimator linkToMainScreen];
    
    /// Init animator
    
    [_momentumAnimator startWithParams:^NSDictionary<NSString *,id> * _Nonnull(Vector valueLeft, BOOL isRunning, Curve * _Nullable curve) {
        
        NSMutableDictionary *p = [NSMutableDictionary dictionary];
        
        /// Reset subpixelators
        
//        [_scrollPointPixelator reset];
        [_scrollLinePixelator reset];
        /// Don't need to reset _gesturePixelator, because we don't send gesture events during momentum scroll
        
        /// Get animator params
        
        /// Get initial velocity
        Vector initialVelocity = initalMomentumScrollVelocity_FromExitVelocity(exitVelocity);
        
        /// Get initial speed
        double initialSpeed = magnitudeOfVector(initialVelocity); /// Magnitude is always positive
        
        /// Stop momentumScroll immediately, if the initial Speed is too small
        if (initialSpeed <= stopSpeed) {
            DDLogDebug(@"Not starting momentum scroll - initialSpeed smaller stopSpeed: i: %f, s: %f", initialSpeed, stopSpeed);
            _momentumScrollCallback();
            [GestureScrollSimulator stopMomentumScroll];
            p[@"doStart"] = @(NO);
            return p;
        }
        
        /// Get drag animation curve
        
        DragCurve *animationCurve = [[DragCurve alloc] initWithCoefficient:dragCoefficient
                                                                  exponent:dragExponent
                                                              initialSpeed:initialSpeed
                                                                 stopSpeed:stopSpeed];
        
        /// Get duration and distance for animation from DragCurve
        
        double duration = animationCurve.timeInterval.length;
        double distance = animationCurve.distanceInterval.length;
        
        /// Get distanceVec
        
        Vector distanceVec = scaledVector(unitVector(initialVelocity), distance);
        
        /// Return
        
        p[@"vector"] = nsValueFromVector(distanceVec);
        p[@"duration"] = @(duration);
        p[@"curve"] = animationCurve;
        
        return p;
        
    } integerCallback:^(Vector deltaVec, MFAnimationCallbackPhase animationPhase, MFMomentumHint subCurve) {
        
        /// Debug
        DDLogDebug(@"Momentum scrolling - delta: (%f, %f), animationPhase: %d", deltaVec.x, deltaVec.y, animationPhase);
        
        /// Get line vector and subpixelate
        Vector directedLineDelta = scrollLineVector_FromScrollPointVector(deltaVec);
        Vector directedLineDeltaInt = [_scrollLinePixelator intVectorWithDoubleVector:directedLineDelta];
        
        /// Call momentumScrollStart callback
        
        if (animationPhase == kMFAnimationCallbackPhaseStart) {
            
            if (_momentumScrollCallback != NULL) _momentumScrollCallback();
        }
        
        /// Get momentumPhase from animationPhase
        
        CGMomentumScrollPhase momentumPhase;
        
        if (animationPhase == kMFAnimationCallbackPhaseStart) {
            momentumPhase = kCGMomentumScrollPhaseBegin;
        } else if (animationPhase == kMFAnimationCallbackPhaseContinue) {
            momentumPhase = kCGMomentumScrollPhaseContinue;
        } else if (animationPhase == kMFAnimationCallbackPhaseEnd) {
            momentumPhase = kCGMomentumScrollPhaseEnd;
        } else {
            assert(false);
        }
        
        /// Validate
        if (momentumPhase == kCGMomentumScrollPhaseEnd) {
            assert(isZeroVector(deltaVec));
        }
        
        /// Get pointer location for posting event
        CGPoint postLocation = getPointerLocation();
        
        /// Post event
        [GestureScrollSimulator postGestureScrollEventWithGestureVector:zeroVector
                                                       scrollVectorLine:directedLineDeltaInt
                                                      scrollVectorPoint:deltaVec
                                                                  phase:kIOHIDEventPhaseUndefined
                                                          momentumPhase:momentumPhase
                                                               location:postLocation];

    }];
    
}

#pragma mark - Vector math functions

static Vector scrollLineVector_FromScrollPointVector(Vector vec) {
    
    return scaledVectorWithFunction(vec, ^double(double x) {
        return x / _pixelsPerLine; /// See CGEventSource.pixelsPerLine - it's 10 by default
    });
}

static Vector gestureVector_FromScrollPointVector(Vector vec) {
    
    return scaledVectorWithFunction(vec, ^double(double x) {
//        return 1.35 * x; /// This makes swipe to mark unread in Apple Mail feel really nice
//        return 1.0 * x; /// This feels better for swiping between pages in Safari
//        return 1.15 * x; /// I think this is a nice compromise
//        return 1.0 * x; /// Even 1.15 feels to fast right now. Edit: But why? Swipeing between pages and marking as unread feel to hard to trigger with this.
        return 1.67 * x; /// This makes click and drag to swipe between pages in Safari appropriately easy to trigger
    });
}

static Vector initalMomentumScrollVelocity_FromExitVelocity(Vector exitVelocity) {
    
    return scaledVectorWithFunction(exitVelocity, ^double(double x) {
//        return pow(fabs(x), 1.08) * sign(x);
        return x * 1;
    });
}

#pragma mark - Post CGEvents


/// Post scroll events that behave as if they are coming from an Apple Trackpad or Magic Mouse.
/// This allows for swiping between pages in apps like Safari or Preview, and it also makes overscroll and inertial scrolling work.
/// Phases
///     1. kIOHIDEventPhaseMayBegin - First event. Deltas should be 0.
///     2. kIOHIDEventPhaseBegan - Second event. At least one of the two deltas should be non-0.
///     4. kIOHIDEventPhaseChanged - All events in between. At least one of the two deltas should be non-0.
///     5. kIOHIDEventPhaseEnded - Last event before momentum phase. Deltas should be 0.
///       - If you stop sending events at this point, scrolling will continue in certain apps like Xcode, but get slower with time until it stops. The initial speed and direction of this "automatic momentum phase" seems to be based on the last kIOHIDEventPhaseChanged event which contained at least one non-zero delta.
///       - To stop this from happening, either give the last kIOHIDEventPhaseChanged event very small deltas, or send an event with phase kIOHIDEventPhaseUndefined and momentumPhase kCGMomentumScrollPhaseEnd right after this one.
///     6. kIOHIDEventPhaseUndefined - Use this phase with non-0 momentumPhase values. (0 being kCGMomentumScrollPhaseNone)
///     7. What about kIOHIDEventPhaseCanceled? It seems to occur when you touch the trackpad (producing MayBegin events) and then lift your fingers off before scrolling. I guess the deltas are always gonna be 0 on that, too, but I'm not sure.

+ (void)postGestureScrollEventWithGestureVector:(Vector)vecGesture
                               scrollVectorLine:(Vector)vecScroll
                              scrollVectorPoint:(Vector)vecScrollPoint
                                          phase:(IOHIDEventPhaseBits)phase
                                  momentumPhase:(CGMomentumScrollPhase)momentumPhase
                                       location:(CGPoint)loc {

    /// Debug
    
    static double tsLast = 0;
    double ts = CACurrentMediaTime();
    double timeSinceLast = ts - tsLast;
    tsLast = ts;
    
    DDLogDebug(@"\nHNGG Posting: gesture: (%f, %f) \t\t scroll: (%f, %f) \t scrollPt: (%f, %f) \t phases: (%d, %d) \t timeSinceLast: %f \t loc: (%f, %f)\n", vecGesture.x, vecGesture.y, vecScroll.x, vecScroll.y, vecScrollPoint.x, vecScrollPoint.y, phase, momentumPhase, timeSinceLast*1000, loc.x, loc.y);
    
    assert((phase == kIOHIDEventPhaseUndefined || momentumPhase == kCGMomentumScrollPhaseNone)); /// At least one of the phases has to be 0
    
    ///
    ///  Get stuff we need for both the type 22 and the type 29 event
    ///
    
    CGPoint eventLocation = loc;
    CGEventTimestamp eventTs = (CACurrentMediaTime() * NSEC_PER_SEC); /// Timestamp doesn't seem to make a difference anywhere. Could also set to 0
    
    ///
    /// Create type 22 event
    ///     (scroll event)
    ///
    
    CGEventRef e22 = CGEventCreate(NULL);
    
    /// Set static fields
    
    CGEventSetDoubleValueField(e22, 55, 22); /// 22 -> NSEventTypeScrollWheel // Setting field 55 is the same as using CGEventSetType(), I'm not sure if that has weird side-effects though, so I'd rather do it this way.
    CGEventSetDoubleValueField(e22, 88, 1); /// 88 -> kCGScrollWheelEventIsContinuous
    CGEventSetDoubleValueField(e22, 137, 1); /// Maybe this is NSEvent.directionInvertedFromDevice
    
    /// Set dynamic fields
    
    /// Scroll deltas
    /// We used to round here, but rounding is not necessary, because we make sure that the incoming vectors only contain integers
    ///      Even if we didn't, I'm not sure rounding would make a difference
    /// Fixed point deltas are set automatically by setting these deltas IIRC.
    
    CGEventSetDoubleValueField(e22, 11, vecScroll.y); /// 11 -> kCGScrollWheelEventDeltaAxis1
    CGEventSetDoubleValueField(e22, 96, vecScrollPoint.y); /// 96 -> kCGScrollWheelEventPointDeltaAxis1
    
    CGEventSetDoubleValueField(e22, 12, vecScroll.x); /// 12 -> kCGScrollWheelEventDeltaAxis2
    CGEventSetDoubleValueField(e22, 97, vecScrollPoint.x); /// 97 -> kCGScrollWheelEventPointDeltaAxis2
    
    /// Phase
    
    CGEventSetDoubleValueField(e22, 99, phase);
    CGEventSetDoubleValueField(e22, 123, momentumPhase);

    /// Post t22s0 event
    ///     Posting after the t29s6 event because I thought that was close to real trackpad events. But in real trackpad events the order is always different it seems.
    ///     Wow, posting this after the t29s6 events removed the little stutter when swiping between pages, nice!
    
    CGEventSetTimestamp(e22, eventTs);
    CGEventSetLocation(e22, eventLocation);
    CGEventPost(kCGSessionEventTap, e22); /// Needs to be kCGHIDEventTap instead of kCGSessionEventTap to work with Swish, but that will make the events feed back into our scroll event tap. That's not tooo bad, because we ignore continuous events anyways, still bad because CPU use and stuff.
    CFRelease(e22);
    
    if (phase != kIOHIDEventPhaseUndefined) {
       
        /// Create type 29 subtype 6 event
        ///     (gesture event)
        
        CGEventRef e29 = CGEventCreate(NULL);
        
        /// Set static fields
        
        CGEventSetDoubleValueField(e29, 55, 29); /// 29 -> NSEventTypeGesture // Setting field 55 is the same as using CGEventSetType()
        CGEventSetDoubleValueField(e29, 110, 6); /// 110 -> subtype // 6 -> kIOHIDEventTypeScroll
        
        /// Set dynamic fields
        
        /// Deltas
        double dxGesture = (double)vecGesture.x;
        double dyGesture = (double)vecGesture.y;
        if (dxGesture == 0) dxGesture = -0.0f; /// The original events only contain -0 but this probably doesn't make a difference.
        if (dyGesture == 0) dyGesture = -0.0f;
        CGEventSetDoubleValueField(e29, 116, dxGesture);
        CGEventSetDoubleValueField(e29, 119, dyGesture);
        
        /// Phase
        CGEventSetIntegerValueField(e29, 132, phase);
        
        /// Post t29s6 events
        CGEventSetTimestamp(e29, eventTs);
        CGEventSetLocation(e29, eventLocation);
        CGEventPost(kCGSessionEventTap, e29);
        CFRelease(e29);
    }
    
}

@end
